//
//  RecommendationSeedSampler.swift
//  QQPlayer
//
//  推荐 v4：种子艺人抽样（纯逻辑，可注入随机源）。
//
//  口径（产品已拍板「每次刷新重新抽」）：
//   1. 只在亲和度前 N 名（`affinityWindow`）内抽，避免冷门长尾艺人进首屏；
//   2. 加权无放回：权重 = max(affinity, `minWeight`)，亲和度高者概率大但不保证必中；
//   3. 亲和度并列时按 artist key 排序，保证同一随机源下结果稳定；
//   4. 批次内**不重抽**：调用方每轮只调用一次，抽出的种子写回画像副本再进召回。
//
//  确定性：同 seed → 同结果（单测依赖此性质，不要改成系统熵源）。
//

import Foundation

/// SplitMix64：确定性伪随机源（无系统熵、无时钟，跨进程可复现）。
struct RecommendationSeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        // 全零种子会让首轮输出偏弱，混入常数扰动（不影响可复现性）。
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 种子抽样器（加权无放回）。
enum RecommendationSeedSampler {
    /// 候选窗口：只在亲和度前 20 名内抽。
    static let affinityWindow = 20
    /// 权重下限：亲和度为 0 的艺人仍有极小概率被抽中，避免抽样完全退化。
    static let minWeight = 0.01

    /// 用给定随机源抽样（`k` 自动裁剪到窗口大小）。
    static func sample(
        _ seeds: [RecommendationSeedArtist],
        k: Int,
        using rng: inout some RandomNumberGenerator
    ) -> [RecommendationSeedArtist] {
        guard k > 0, !seeds.isEmpty else { return [] }
        let ordered = ranked(seeds)
        let window = Array(ordered.prefix(affinityWindow))
        guard k < window.count else { return window }
        var remaining = window
        var picked: [RecommendationSeedArtist] = []
        picked.reserveCapacity(k)
        for _ in 0 ..< k {
            let weights = remaining.map { max($0.affinity, minWeight) }
            let total = weights.reduce(0, +)
            guard total > 0 else { break }
            let target = Double.random(in: 0 ..< total, using: &rng)
            var cumulative = 0.0
            var index = remaining.count - 1
            for (offset, weight) in weights.enumerated() {
                cumulative += weight
                if target < cumulative {
                    index = offset
                    break
                }
            }
            picked.append(remaining.remove(at: index))
        }
        return picked
    }

    /// 用 64 位种子抽样（生产路径 / 单测都走这里，保证可复现）。
    static func sample(_ seeds: [RecommendationSeedArtist], k: Int, seed: UInt64) -> [RecommendationSeedArtist] {
        var rng = RecommendationSeededRandom(seed: seed)
        return sample(seeds, k: k, using: &rng)
    }

    /// 抽样前排序：亲和度降序，并列按 artist key 升序（稳定）。
    static func ranked(_ seeds: [RecommendationSeedArtist]) -> [RecommendationSeedArtist] {
        seeds.sorted { lhs, rhs in
            if lhs.affinity != rhs.affinity { return lhs.affinity > rhs.affinity }
            let lk = RecommendationLibraryMatcher.artistKey(lhs.artist)
            let rk = RecommendationLibraryMatcher.artistKey(rhs.artist)
            if lk != rk { return lk < rk }
            return lhs.artist < rhs.artist
        }
    }
}
