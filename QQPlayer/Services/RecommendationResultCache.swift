//
//  RecommendationResultCache.swift
//  QQPlayer
//
//  本地 AI 推荐 P3：结果级缓存（**纯 Foundation，可单测**）。
//
//  语义：同一份输入（请求原话 + 画像摘要 + 曲库指纹 + planner/模型 + locale）不重复跑
//  规则 / 本地模型，直接返回缓存结果；手动刷新显式绕过并覆盖。
//  存储：<App Support>/QQPlayerMac/Cache/Recommendations/<sha256>.json
//        （用户私有数据，不进 DSQ 共享目录、不参与同步）。
//  淘汰：LRU，最多 20 条（按 lastAccessedAt 最旧删）。
//  失效：键任一输入变化 / 超过 24h / schemaVersion 不匹配 / JSON 损坏（损坏文件删除后按 miss 处理）。
//
//  ⚠️ 结果 DTO 只用 `RecommendedCandidate`（渲染字段，本身不含下载进度 / 选中态等 UI 状态），
//     不另立第二套候选结构。
//

import CryptoKit
import Foundation

// MARK: - 键

/// 一次推荐的缓存键输入（纯值）。
///
/// 归一化规则（顺序固定，改动即等于换键，需同步递增 `RecommendationResultCache.schemaVersion`）：
/// - `rawText`：按空白切分后单空格连接 + `lowercased()`（大小写 / 连续空白 / 首尾空白不产生新键）
/// - `profileSummary`：`RecommendationProfileSummary.cacheKeyText`（字段定序、小数固定 4 位、locale 无关）
/// - `libraryFingerprint`：曲库指纹（见 `RecommendationLibraryFingerprint`）
/// - `planner`：`rule` / `localModel`（规则与模型结果互不串键）
/// - `modelIdentity`：模型 id + 体量；未启用写 `none`
/// - `localeIdentifier`：当前 locale 标识符，小写
struct RecommendationCacheKeyInput: Equatable {
    var rawText: String
    var profileSummary: String
    var libraryFingerprint: String
    var planner: RecommendationPlanSource
    var modelIdentity: String
    var localeIdentifier: String

    /// 确定性键文本：字段带标签、固定顺序，字段值里不会出现换行（避免拼接歧义）。
    var canonicalText: String {
        [
            "schema:\(RecommendationResultCache.schemaVersion)",
            "raw:\(Self.normalizeText(rawText))",
            "profile:\(profileSummary)",
            "library:\(libraryFingerprint)",
            "planner:\(planner.rawValue)",
            "model:\(modelIdentity.lowercased())",
            "locale:\(localeIdentifier.lowercased())",
        ].joined(separator: "\n")
    }

    var sha256: String {
        RecommendationCacheDigest.sha256(canonicalText)
    }

    static func normalizeText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

// MARK: - 键摘要（条目内留档，便于排查命中 / 失效原因）

struct RecommendationCacheKeySummary: Codable, Equatable, Sendable {
    var rawText: String
    var profileSummary: String
    var libraryFingerprint: String
    var planner: String
    var modelIdentity: String
    var localeIdentifier: String

    init(input: RecommendationCacheKeyInput) {
        rawText = RecommendationCacheKeyInput.normalizeText(input.rawText)
        profileSummary = input.profileSummary
        libraryFingerprint = input.libraryFingerprint
        planner = input.planner.rawValue
        modelIdentity = input.modelIdentity
        localeIdentifier = input.localeIdentifier
    }
}

// MARK: - 摘要 / 指纹

extension RecommendationProfileSummary {
    /// 缓存键用的稳定文本：字段顺序固定，小数固定 4 位（en_US_POSIX，避免 locale 影响键）。
    var cacheKeyText: String {
        let decades = self.decades
            .map { "\($0.decade):\(Self.fixed($0.share))" }
            .joined(separator: ",")
        return [
            "artists=\(topArtists.joined(separator: ","))",
            "decades=\(decades)",
            "genres=\(genres.joined(separator: ","))",
            "completion=\(Self.fixed(completionRate))",
            "size=\(librarySize)",
            "languages=\(languageHints.joined(separator: ","))",
        ].joined(separator: ";")
    }

    private static func fixed(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

/// 曲库指纹：优先用 revision/change counter（当前没有），退化为
/// 「trackCount + 最新文件时间 + 排序后首尾 stableId」的哈希 —— 不读全量曲库内容。
///
/// 说明：`track` 表没有导入时间列，用 `modification_date` 的最大值作为「最新变化时间」代理；
/// 增 / 删 / 替换都会改变 count 或首尾 / 最大值中的至少一项。
enum RecommendationLibraryFingerprint {
    static func make(stableIds: [String], latestModificationMicros: Int64?) -> String {
        let sorted = stableIds.sorted()
        let canonical = [
            "v1",
            "count:\(sorted.count)",
            "first:\(sorted.first ?? "")",
            "last:\(sorted.last ?? "")",
            "latest-mod:\(latestModificationMicros ?? -1)",
        ].joined(separator: "\n")
        return RecommendationCacheDigest.sha256(canonical)
    }
}

// MARK: - 条目

/// 缓存条目（`schemaVersion` 不匹配即视为 miss 并删除）。
struct RecommendationCacheEntry: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var createdAt: Date
    var lastAccessedAt: Date
    var hitCount: Int
    var planSource: RecommendationPlanSource
    var keySummary: RecommendationCacheKeySummary
    var candidates: [RecommendedCandidate]
    /// 点名艺人展示名（旧条目无此字段 → nil，UI 不展示不足说明）。
    var requestedArtist: String?
}

/// 命中结果（`createdAt` 用于 UI「缓存结果 · X 分钟前」）。
struct RecommendationCacheHit: Equatable, Sendable {
    var candidates: [RecommendedCandidate]
    var planSource: RecommendationPlanSource
    var createdAt: Date
    var hitCount: Int
    var requestedArtist: String?
}

// MARK: - 存储

struct RecommendationResultCache {
    /// 缓存格式版本：不匹配即 miss。
    ///
    /// v2（2026-11-12）：年代意图不再直接搜泛词 + 结果增加「纯年代标题」硬过滤，
    /// v1 缓存里残留的 `1990s` / `2000s` 脏结果必须整体失效。
    static let schemaVersion = 2
    static let ttl: TimeInterval = 24 * 3600
    static let maxEntryCount = 20
    static let directoryComponent = "Cache/Recommendations"

    let directory: URL
    let clock: () -> Date
    let fileManager: FileManager

    init(
        directory: URL,
        clock: @escaping () -> Date = { Date() },
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.clock = clock
        self.fileManager = fileManager
    }

    /// macOS 数据根下的缓存目录（唯一默认位置；iOS 返回 nil，缓存只有 Mac 用）。
    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL? {
        #if os(macOS)
            guard let root = LibraryRoot.macAppSupportRootURL(fileManager: fileManager) else { return nil }
            return root.appendingPathComponent(directoryComponent, isDirectory: true)
        #else
            return nil
        #endif
    }

    // MARK: 读

    /// 命中返回结果并刷新 `lastAccessedAt` / `hitCount`；未命中 / 过期 / 损坏返回 nil。
    func load(_ key: RecommendationCacheKeyInput) -> RecommendationCacheHit? {
        let url = fileURL(for: key.sha256)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let entry = try? Self.makeDecoder().decode(RecommendationCacheEntry.self, from: data) else {
            AppLog.warn(.general, "⚠️ 推荐缓存损坏，按 miss 删除：\(url.lastPathComponent)")
            try? fileManager.removeItem(at: url)
            return nil
        }
        guard entry.schemaVersion == Self.schemaVersion else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        let now = clock()
        guard now.timeIntervalSince(entry.createdAt) < Self.ttl else {
            try? fileManager.removeItem(at: url)
            return nil
        }

        var refreshed = entry
        refreshed.lastAccessedAt = now
        refreshed.hitCount += 1
        _ = write(refreshed, key: key.sha256)

        return RecommendationCacheHit(
            candidates: entry.candidates,
            planSource: entry.planSource,
            createdAt: entry.createdAt,
            hitCount: refreshed.hitCount,
            requestedArtist: entry.requestedArtist
        )
    }

    // MARK: 写

    /// 空结果不缓存（失败结果由调用方保证不进来）。
    @discardableResult
    func store(
        _ key: RecommendationCacheKeyInput,
        planSource: RecommendationPlanSource,
        candidates: [RecommendedCandidate],
        requestedArtist: String? = nil
    ) -> Bool {
        guard !candidates.isEmpty else { return false }
        let now = clock()
        let entry = RecommendationCacheEntry(
            schemaVersion: Self.schemaVersion,
            createdAt: now,
            lastAccessedAt: now,
            hitCount: 0,
            planSource: planSource,
            keySummary: RecommendationCacheKeySummary(input: key),
            candidates: candidates,
            requestedArtist: requestedArtist
        )
        guard write(entry, key: key.sha256) else { return false }
        pruneIfNeeded()
        return true
    }

    /// 手动刷新：先清当前键再重算。
    func invalidate(_ key: RecommendationCacheKeyInput) {
        try? fileManager.removeItem(at: fileURL(for: key.sha256))
    }

    func entryCount() -> Int {
        jsonFileURLs().count
    }

    // MARK: 内部

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    private static func makeDecoder() -> JSONDecoder {
        JSONDecoder()
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func write(_ entry: RecommendationCacheEntry, key: String) -> Bool {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder().encode(entry)
            let destination = fileURL(for: key)
            // 原子写：先落同目录临时文件，再 replace / move（不直接覆写目标）。
            let temporary = directory.appendingPathComponent(".\(key).\(UUID().uuidString).tmp")
            try data.write(to: temporary, options: .atomic)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            return true
        } catch {
            AppLog.warn(.general, "⚠️ 推荐缓存写入失败：\(error)")
            return false
        }
    }

    /// LRU：超过上限时按 `lastAccessedAt` 最旧删除；顺带清掉损坏文件与残留临时文件。
    private func pruneIfNeeded() {
        let urls = jsonFileURLs()
        guard !urls.isEmpty else { return }
        var entries: [(url: URL, lastAccessedAt: Date)] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? Self.makeDecoder().decode(RecommendationCacheEntry.self, from: data)
            else {
                try? fileManager.removeItem(at: url)
                continue
            }
            entries.append((url: url, lastAccessedAt: entry.lastAccessedAt))
        }
        let overflow = entries.count - Self.maxEntryCount
        guard overflow > 0 else { return }
        for item in entries.sorted(by: { $0.lastAccessedAt < $1.lastAccessedAt }).prefix(overflow) {
            try? fileManager.removeItem(at: item.url)
        }
    }

    private func jsonFileURLs() -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return urls.filter { $0.pathExtension == "json" }
    }
}

// MARK: - 哈希

enum RecommendationCacheDigest {
    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
