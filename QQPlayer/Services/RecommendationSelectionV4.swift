//
//  RecommendationSelectionV4.swift
//  QQPlayer
//
//  推荐 v4：批次选择（通道下限 + MMR 多样性 + 批内上限），纯逻辑、无 IO。
//
//  与 v3 的差别：
//   1. v3 是 40/40/20 硬配额，通道按比例**占位**，相关性再高也挤不进别的通道；
//      v4 改成**每通道下限**（seed ≥2 / similar ≥2 / explore ≥1，目标 <5 时按比例缩小），
//      其余位置按全局分数竞争，某通道候选不足时名额自动让给其他通道。
//   2. v3 选择阶段不看相似度；v4 加 MMR：`0.7 * relevance - 0.3 * maxSimilarity`，
//      避免「同一艺人扎堆」这种靠硬上限压出来的假多样性。
//   3. v3 的批内上限（艺人 ≤2 / 专辑 ≤1）在 v4 仍然保留，但**只在这里执行**——
//      召回池已放宽到艺人 ≤4 / 专辑 ≤2，池大才有得选。
//   4. 已下载但本轮保留的候选最多 3 首（超出按分数丢弃）。
//
//  确定性：同输入同输出（分数降序 + key 升序做 tie-break，不依赖字典遍历顺序）。
//

import Foundation

/// 选择阶段的最小候选视图（引擎负责把 `RecommendationV3Candidate` 映射过来）。
struct RecommendationSelectionItem: Sendable, Equatable {
    /// 归一化曲目键（标题 + 主艺人），选择全程按它去重。
    var key: String
    var channel: RecommendationChannel
    /// 归一化艺人键（同艺人相似度 1.0）。
    var artistKey: String
    /// 归一化专辑键（同专辑相似度 0.6；无专辑 → 空串 = 不参与）。
    var albumKey: String
    /// 风格（同簇 0.3；缺失 = 不参与）。
    var genre: String?
    /// 年份（相差 ≤2 年 0.1；缺失 = 不参与）。
    var year: Int?
    var score: Double
    /// 本批保留的「已下载」候选（下载完成后不从列表消失）。
    var isRetainedDownload: Bool = false
}

enum RecommendationSelectionV4 {
    /// 每通道下限（目标 ≥5 时生效）。
    static let minimumSeed = 2
    static let minimumSimilar = 2
    static let minimumExplore = 1
    /// 单批保留的已下载项上限。
    static let maxRetainedDownloads = 3
    /// 批内上限（池级上限在 `RecommendationRankerV3`，更宽）。
    static let maxSongsPerArtist = 2
    static let maxSongsPerAlbum = 1
    /// MMR 参数：相关性 0.7 / 相似度惩罚 0.3。
    static let relevanceWeight = 0.7
    static let similarityPenalty = 0.3

    /// 通道下限（目标 <5 时按比例缩小：floor(下限 * total / 5)）。
    static func minimums(total: Int) -> (seed: Int, similar: Int, explore: Int) {
        let target = max(0, total)
        guard target >= 5 else {
            func scaled(_ base: Int) -> Int { base * target / 5 }
            return (scaled(minimumSeed), scaled(minimumSimilar), scaled(minimumExplore))
        }
        return (minimumSeed, minimumSimilar, minimumExplore)
    }

    /// 两个候选的相似度（取各信号的**最大**值；同艺人是硬信号）。
    static func similarity(_ lhs: RecommendationSelectionItem, _ rhs: RecommendationSelectionItem) -> Double {
        var best = 0.0
        if !lhs.artistKey.isEmpty, lhs.artistKey == rhs.artistKey { best = max(best, 1.0) }
        if !lhs.albumKey.isEmpty, lhs.albumKey == rhs.albumKey { best = max(best, 0.6) }
        if let lg = genreKey(lhs.genre), let rg = genreKey(rhs.genre), lg == rg { best = max(best, 0.3) }
        if let ly = lhs.year, let ry = rhs.year, abs(ly - ry) <= 2 { best = max(best, 0.1) }
        return best
    }

    /// 选择：返回 `items` 的下标（按选择顺序；调用方据此取回原候选）。
    static func select(_ items: [RecommendationSelectionItem], total: Int) -> [Int] {
        let target = max(0, total)
        guard target > 0, !items.isEmpty else { return [] }

        // 1. 归一化键去重（先按分数降序、再 key 升序，保证"留下的是高分那条"且结果稳定）。
        let ordered = items.enumerated().sorted { lhs, rhs in
            if lhs.element.score != rhs.element.score { return lhs.element.score > rhs.element.score }
            return lhs.element.key < rhs.element.key
        }
        var seen = Set<String>()
        var pool: [Int] = []
        pool.reserveCapacity(ordered.count)
        for entry in ordered {
            guard seen.insert(entry.element.key).inserted else { continue }
            pool.append(entry.offset)
        }

        var picked: [Int] = []
        var pickedKeys = Set<String>()
        var artistCounts: [String: Int] = [:]
        var albumCounts: [String: Int] = [:]
        var retainedCount = 0

        func canTake(_ index: Int) -> Bool {
            let item = items[index]
            guard !pickedKeys.contains(item.key) else { return false }
            if !item.artistKey.isEmpty, artistCounts[item.artistKey, default: 0] >= maxSongsPerArtist { return false }
            if !item.albumKey.isEmpty, albumCounts[item.albumKey, default: 0] >= maxSongsPerAlbum { return false }
            if item.isRetainedDownload, retainedCount >= maxRetainedDownloads { return false }
            return true
        }

        func take(_ index: Int) {
            let item = items[index]
            picked.append(index)
            pickedKeys.insert(item.key)
            if !item.artistKey.isEmpty { artistCounts[item.artistKey, default: 0] += 1 }
            if !item.albumKey.isEmpty { albumCounts[item.albumKey, default: 0] += 1 }
            if item.isRetainedDownload { retainedCount += 1 }
        }

        // 2. 下限先选（不吃 MMR，不得为了多样性破坏下限）。
        let floors = minimums(total: target)
        let planned: [(RecommendationChannel, Int)] = [
            (.seed, floors.seed),
            (.similar, floors.similar),
            (.explore, floors.explore),
        ]
        for (channel, need) in planned where need > 0 {
            var remaining = need
            for index in pool where remaining > 0 {
                guard items[index].channel == channel, canTake(index) else { continue }
                take(index)
                remaining -= 1
            }
        }

        // 3. 剩余位置：全局 MMR 竞争（相关性归一化到本批最高分）。
        let maxScore = pool.map { items[$0].score }.max() ?? 0
        while picked.count < target {
            var bestIndex: Int?
            var bestValue = -Double.infinity
            for index in pool where canTake(index) {
                let relevance = maxScore > 0 ? max(0, items[index].score) / maxScore : 0
                var maxSimilarity = 0.0
                for chosen in picked {
                    maxSimilarity = max(maxSimilarity, similarity(items[index], items[chosen]))
                }
                let value = relevanceWeight * relevance - similarityPenalty * maxSimilarity
                if value > bestValue + 1e-12 {
                    bestValue = value
                    bestIndex = index
                }
            }
            guard let index = bestIndex else { break }
            take(index)
        }
        return picked
    }

    /// 风格键（大小写 / 空白折叠；空串视为缺失）。
    private static func genreKey(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let key = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}
