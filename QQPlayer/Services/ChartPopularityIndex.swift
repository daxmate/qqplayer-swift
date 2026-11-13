//
//  ChartPopularityIndex.swift
//  QQPlayer
//
//  推荐热度索引：把榜单条目变成「候选 → 热度分」的纯查询结构。
//
//  匹配口径（顺序固定）：
//   1. `RecommendationRemoteSong.songID` 精确匹配榜单 `id`（iTunes search 的 trackId 就是 Apple 歌曲 id）；
//   2. 归一化歌名 + 主艺人匹配（复用 `RecommendationKey`，容忍大小写 / 括号后缀 / 空白差异）。
//
//  映射（rank 1 → 1.0，榜尾 → 0.6，未命中 → 0.5 中性）：热度只是打分的一个分量，
//  未上榜不等于不流行（可能只是没进 tw/us 双榜），所以不给 0。
//
//  ⚠️ 纯逻辑：无 I/O、无平台 API，iOS / macOS 共享。
//

import Foundation

/// 榜单热度索引（值类型，构造一次多处复用；线程安全，可 Sendable 传递）。
struct ChartPopularityIndex: Equatable, Sendable {
    /// 未命中时的中性分。
    static let neutralPopularity: Double = 0.5
    /// 榜尾下限（榜内最低分）。
    static let chartFloorPopularity: Double = 0.6
    /// 空索引（无榜单 / 全失败）。
    static let empty = ChartPopularityIndex(entries: [], twCount: 0, usCount: 0)

    /// 合并后的条目（rank 升序），保留原始信息便于观测。
    let entries: [ChartEntry]
    /// 各店区抓到的条数（批次日志用；合并去重前的数量）。
    let twCount: Int
    let usCount: Int

    private let rankByID: [String: Int]
    private let rankByKey: [String: Int]

    init(entries: [ChartEntry], twCount: Int = 0, usCount: Int = 0) {
        self.entries = entries
        self.twCount = twCount
        self.usCount = usCount
        var byID: [String: Int] = [:]
        var byKey: [String: Int] = [:]
        for entry in entries {
            if byID[entry.id] == nil { byID[entry.id] = entry.rank }
            let key = RecommendationKey.normalize(title: entry.title, artist: entry.artist)
            // 同一首歌可能以不同艺人拼写重复上榜：保留最靠前的名次。
            if let existing = byKey[key], existing <= entry.rank { continue }
            byKey[key] = entry.rank
        }
        rankByID = byID
        rankByKey = byKey
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    /// 命中名次（先 id，后 歌名+艺人 归一化匹配）；未命中 nil。
    func rank(songID: Int?, title: String, artist: String) -> Int? {
        if let songID, let rank = rankByID[String(songID)] { return rank }
        let key = RecommendationKey.normalize(title: title, artist: artist)
        return rankByKey[key]
    }

    /// 是否上榜（推荐理由「近期热门」用）。
    func isChartHit(songID: Int?, title: String, artist: String) -> Bool {
        rank(songID: songID, title: title, artist: artist) != nil
    }

    /// 热度分：rank1 → 1.0，榜尾 → 0.6，未命中 → 0.5。
    func popularity(songID: Int?, title: String, artist: String) -> Double {
        popularity(forRank: rank(songID: songID, title: title, artist: artist))
    }

    /// 由已算好的名次取热度分（引擎逐条只查一次名次，避免重复匹配）。
    func popularity(forRank rank: Int?) -> Double {
        guard let rank, !isEmpty else { return Self.neutralPopularity }
        let span = Double(max(1, count - 1))
        let position = Double(max(0, rank - 1)) / span
        return Self.chartFloorPopularity + (1 - Self.chartFloorPopularity) * (1 - position)
    }
}
