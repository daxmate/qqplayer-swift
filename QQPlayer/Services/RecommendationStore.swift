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

    static let empty = RecommendationBlacklist()

    init() {}

    init(trackKeys: Set<String>, artists: Set<String>) {
        self.trackKeys = trackKeys
        self.artists = artists
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

    // MARK: Codable（排序输出，避免 Set 顺序导致文件抖动）

    private enum CodingKeys: String, CodingKey {
        case trackKeys
        case artists
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackKeys = Set(try container.decodeIfPresent([String].self, forKey: .trackKeys) ?? [])
        artists = Set(try container.decodeIfPresent([String].self, forKey: .artists) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(trackKeys.sorted(), forKey: .trackKeys)
        try container.encode(artists.sorted(), forKey: .artists)
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
