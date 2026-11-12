//
//  RecommendationStore.swift
//  QQPlayer
//
//  本地 AI 推荐 P1：黑名单本地持久化（App Support JSON，**不建表、不迁移**）。
//
//  黑名单语义：单曲键（`RecommendationKey.normalize`）+ 主艺人集合。
//  唯一写入口是推荐页的「不再推荐」；不参与同步（P1 明确不做同步逻辑）。
//

import Foundation

/// 推荐黑名单（纯数据；归一化在写入与查询两侧都执行，防不同写法漏判）。
struct RecommendationBlacklist: Codable, Equatable, Sendable {
    var trackKeys: Set<String> = []
    var artists: Set<String> = []
    /// 「最近推过」软黑名单：归一化单曲键 → 最近一次推荐时间（epoch 秒）。
    /// 与会永久生效的「不再推荐」区分：只在 7 天窗口内跳过（`RecommendationBatchPolicy.recentBlacklistWindow`）。
    var recentTrackKeys: [String: Double] = [:]

    static let empty = RecommendationBlacklist()

    init() {}

    init(trackKeys: Set<String>, artists: Set<String>, recentTrackKeys: [String: Double] = [:]) {
        self.trackKeys = trackKeys
        self.artists = artists
        self.recentTrackKeys = recentTrackKeys
    }

    /// 加入一条「不再推荐」。
    mutating func add(title: String, artist: String) {
        trackKeys.insert(RecommendationKey.normalize(title: title, artist: artist))
        let artistKey = RecommendationKey.primaryArtist(artist)
        if !artistKey.isEmpty {
            artists.insert(artistKey)
        }
    }

    /// 单曲或艺人任一命中即视为拉黑。
    func contains(title: String, artist: String) -> Bool {
        trackKeys.contains(RecommendationKey.normalize(title: title, artist: artist))
            || artists.contains(RecommendationKey.primaryArtist(artist))
    }

    var isEmpty: Bool {
        trackKeys.isEmpty && artists.isEmpty
    }

    // MARK: 软黑名单（P2：最近推过 7 天）

    /// 记录一批已推荐曲目（写入前先清理过期条目，文件不无限增长）。
    mutating func markRecommended(_ candidates: [RecommendedCandidate], at date: Date) {
        pruneRecent(before: date.addingTimeInterval(-RecommendationBatchPolicy.recentBlacklistWindow))
        for candidate in candidates {
            recentTrackKeys[RecommendationKey.normalize(title: candidate.title, artist: candidate.artist)] = date.timeIntervalSince1970
        }
    }

    /// 最近推过（窗口内）→ true。
    func wasRecentlyRecommended(title: String, artist: String, at date: Date) -> Bool {
        let key = RecommendationKey.normalize(title: title, artist: artist)
        guard let timestamp = recentTrackKeys[key] else { return false }
        return date.timeIntervalSince1970 - timestamp < RecommendationBatchPolicy.recentBlacklistWindow
    }

    /// 窗口内仍生效的软黑名单键（作为召回排除集）。
    func activeRecentKeys(at date: Date) -> Set<String> {
        let cutoff = date.timeIntervalSince1970 - RecommendationBatchPolicy.recentBlacklistWindow
        return Set(recentTrackKeys.filter { $0.value >= cutoff }.keys)
    }

    /// 缓存键用的软黑名单版本（内容变化 → 版本变化；与具体时间无关的稳定字符串）。
    var recentVersion: String {
        recentTrackKeys.keys.sorted().joined(separator: "|")
    }

    private mutating func pruneRecent(before cutoff: Date) {
        let cutoffSeconds = cutoff.timeIntervalSince1970
        recentTrackKeys = recentTrackKeys.filter { $0.value >= cutoffSeconds }
    }

    // MARK: Codable（排序输出，避免 Set 顺序导致文件抖动）

    private enum CodingKeys: String, CodingKey {
        case trackKeys
        case artists
        case recentTrackKeys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recentTrackKeys = try container.decodeIfPresent([String: Double].self, forKey: .recentTrackKeys) ?? [:]
        trackKeys = Set(try container.decodeIfPresent([String].self, forKey: .trackKeys) ?? [])
        artists = Set(try container.decodeIfPresent([String].self, forKey: .artists) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trackKeys.sorted(), forKey: .trackKeys)
        try container.encode(artists.sorted(), forKey: .artists)
        try container.encode(recentTrackKeys, forKey: .recentTrackKeys)
    }
}

/// 黑名单读写（文件不存在 / 损坏 = 空名单；写失败只记日志，不阻断推荐）。
enum RecommendationBlacklistStore {
    static let fileName = "recommendation-blacklist.json"

    /// 默认落点：`<Application Support>/QQPlayerMac/recommendation-blacklist.json`。
    static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let root = LibraryRoot.macAppSupportRootURL(fileManager: fileManager) else { return nil }
        return root.appendingPathComponent(fileName)
    }

    static func load(from url: URL?) -> RecommendationBlacklist {
        guard let url, let data = try? Data(contentsOf: url) else { return .empty }
        return (try? JSONDecoder().decode(RecommendationBlacklist.self, from: data)) ?? .empty
    }

    @discardableResult
    static func save(_ blacklist: RecommendationBlacklist, to url: URL?) -> Bool {
        guard let url else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(blacklist).write(to: url, options: .atomic)
            return true
        } catch {
            AppLog.warn(.general, "⚠️ 推荐黑名单写入失败：\(error)")
            return false
        }
    }
}
