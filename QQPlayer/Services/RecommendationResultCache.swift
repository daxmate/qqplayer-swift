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
//  过期不删：超过 24h 的条目仍作为 stale 候选（≤ 7 天）垫底，后台重算完成后被新键条目替换。
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
    /// 召回源版本（P2：主源 / 降级链升级必须让旧缓存失效）。
    var sourceVersion: String = ""
    /// 软黑名单版本（最近推过集合变化 → 旧结果可能重复）。
    var blacklistVersion: String = ""

    /// stale 索引键：只含「请求身份」（原话 + planner + 模型 + locale），**不含**画像摘要 / 曲库指纹。
    /// 曲库或画像变化时精确键失效，但仍能按它找回同一次请求的旧候选。
    var baseKey: String {
        RecommendationCacheDigest.sha256(
            [
                "base-v1",
                "raw:\(Self.normalizeText(rawText))",
                "planner:\(planner.rawValue)",
                "model:\(modelIdentity.lowercased())",
                "locale:\(localeIdentifier.lowercased())",
            ].joined(separator: "\n")
        )
    }

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
            "source:\(sourceVersion.lowercased())",
            "blacklist:\(blacklistVersion.lowercased())",
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
    /// stale 索引键（`RecommendationCacheKeyInput.baseKey`）：只看请求身份，跨画像 / 曲库变化复用。
    var baseKey: String
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
    /// true = 同请求的旧结果（精确键已失效）：先展示，后台重算后平滑替换。
    var isStale: Bool = false
}

// MARK: - 存储

struct RecommendationResultCache {
    /// 缓存格式版本：不匹配即 miss。
    ///
    /// v2（2026-11-12）：年代意图不再直接搜泛词 + 结果增加「纯年代标题」硬过滤，
    /// v1 缓存里残留的 `1990s` / `2000s` 脏结果必须整体失效。
    ///
    /// v3（2026-11-12）：条目新增 `baseKey`（stale 索引），结构变化 → 旧版本缓存整体失效一次。
    static let schemaVersion = 3
    static let ttl: TimeInterval = 24 * 3600
    /// stale 复用上限：更老的条目不再作为旧结果垫底（精确 TTL 仍是 24h）。
    static let staleMaxAge: TimeInterval = 7 * 24 * 3600
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
            // 旧 schema 结构不同也会解码失败：静默删除，别谎报「损坏」。
            if let header = try? Self.makeDecoder().decode(RecommendationCacheHeader.self, from: data),
               header.schemaVersion != Self.schemaVersion {
                try? fileManager.removeItem(at: url)
                return nil
            }
            AppLog.warn(.general, "⚠️ 推荐缓存损坏，按 miss 删除：\(url.lastPathComponent)")
            try? fileManager.removeItem(at: url)
            return nil
        }
        guard entry.schemaVersion == Self.schemaVersion else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        let now = clock()
        // 过期不删：仍是 stale 候选（≤ `staleMaxAge`），由 `pruneIfNeeded` 统一清理。
        guard now.timeIntervalSince(entry.createdAt) < Self.ttl else { return nil }

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

    /// stale 命中：同 `baseKey`、schema 匹配、`createdAt` 在 `staleMaxAge` 内的**最新**条目。
    ///
    /// 目录扫描只读头部字段（`RecommendationCacheHeader`，不构造候选列表），最多扫 `maxEntryCount` 个文件；
    /// 命中后才读整份条目。读取视为一次访问（刷新 `lastAccessedAt` / `hitCount`），避免被 LRU 提前淘汰。
    func loadStale(baseKey: String, now: Date) -> RecommendationCacheHit? {
        var best: (url: URL, header: RecommendationCacheHeader)?
        for url in jsonFileURLs().prefix(Self.maxEntryCount) {
            guard let header = header(at: url) else {
                try? fileManager.removeItem(at: url)
                continue
            }
            guard header.schemaVersion == Self.schemaVersion else {
                try? fileManager.removeItem(at: url)
                continue
            }
            guard header.baseKey == baseKey,
                  now.timeIntervalSince(header.createdAt) < Self.staleMaxAge
            else {
                continue
            }
            if let best, best.header.createdAt >= header.createdAt { continue }
            best = (url, header)
        }
        guard let best else { return nil }
        guard let data = try? Data(contentsOf: best.url),
              let entry = try? Self.makeDecoder().decode(RecommendationCacheEntry.self, from: data)
        else {
            try? fileManager.removeItem(at: best.url)
            return nil
        }

        var refreshed = entry
        refreshed.lastAccessedAt = now
        refreshed.hitCount += 1
        _ = write(refreshed, key: best.url.deletingPathExtension().lastPathComponent)

        return RecommendationCacheHit(
            candidates: entry.candidates,
            planSource: entry.planSource,
            createdAt: entry.createdAt,
            hitCount: refreshed.hitCount,
            requestedArtist: entry.requestedArtist,
            isStale: true
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
            baseKey: key.baseKey,
            requestedArtist: requestedArtist
        )
        guard write(entry, key: key.sha256) else { return false }
        pruneIfNeeded()
        return true
    }

    /// 手动刷新 / 拉黑：清掉当前精确键，并清掉同 `baseKey` 的 stale 兄弟条目
    /// （否则手动刷新后后台又会拿旧结果垫底，或把已拉黑的歌带回来）。
    func invalidate(_ key: RecommendationCacheKeyInput) {
        for url in jsonFileURLs() {
            if url.lastPathComponent == "\(key.sha256).json" {
                try? fileManager.removeItem(at: url)
                continue
            }
            guard let header = header(at: url), header.baseKey == key.baseKey else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    func entryCount() -> Int {
        jsonFileURLs().count
    }

    // MARK: 内部

    /// 只解出头部字段（候选列表不构造），供目录扫描用。
    private func header(at url: URL) -> RecommendationCacheHeader? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.makeDecoder().decode(RecommendationCacheHeader.self, from: data)
    }

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
        let now = clock()
        var entries: [(url: URL, lastAccessedAt: Date)] = []
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? Self.makeDecoder().decode(RecommendationCacheEntry.self, from: data)
            else {
                try? fileManager.removeItem(at: url)
                continue
            }
            // 超过 stale 上限的条目彻底没用（精确 TTL 更短），直接清掉。
            if now.timeIntervalSince(entry.createdAt) >= Self.staleMaxAge {
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

/// 目录扫描用的头部字段（解码时不构造候选列表）。
private struct RecommendationCacheHeader: Decodable {
    var schemaVersion: Int
    var createdAt: Date
    /// 旧版本条目没有该字段 → nil（只用于静默清理，不参与新条目写入）。
    var baseKey: String?
}

// MARK: - 哈希

enum RecommendationCacheDigest {
    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
