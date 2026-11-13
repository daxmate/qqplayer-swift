//
//  RecommendationScoring.swift
//  QQPlayer
//
//  推荐打分：权重集中处 + 规则打分（六项含榜单热度，和恒为 1.0，由单测锁死）。
//
//  2026-11-13 从 RecommendationTypes.swift 原样拆出：加入 popularity 分量后主文件触及 600 行结构预算，
//  本次只搬家（行为差异只有新增的 popularity 项）。
//

import Foundation

/// 权重集中处（P2 替换为模型分数时只改这里）。
///
/// 2026-11-13 起加入榜单热度（六项权重，和恒为 1.0，由单测锁死）：
/// 艺人亲和 0.36 / 年代 0.16 / 近期漂移 0.09 / 源可靠度 0.08 / 新鲜度 0.11 / 榜单热度 0.20。
enum RecommendationWeights {
    static let artistAffinity = 0.36
    static let eraMatch = 0.16
    static let freshness = 0.09
    static let sourceReliability = 0.08
    static let novelty = 0.11
    /// Apple Music 榜单热度（0.5 中性 / 上榜 0.6…1.0）。
    static let popularity = 0.20

    /// 无年代 / 无漂移数据时的中性分。
    static let neutral = 0.5
    /// 已播过（但不在库）的单曲 novelty 分。
    static let repeatedTrackNovelty = 0.4
}

/// 规则打分（纯函数）：艺人亲和 0.36 / 年代 0.16 / 近期漂移 0.09 /
/// 源可靠度 0.08 / 新鲜度 0.11 / 榜单热度 0.20。
enum RecommendationScorer {
    static func score(_ input: RecommendationScoreInput, profile: TasteProfile) -> RecommendationScore {
        let artistKey = RecommendationKey.primaryArtist(input.artist)

        let maxArtistWeight = profile.topArtists.first?.weight ?? 0
        let artistWeight = profile.weight(forArtist: artistKey)
        let artistAffinity = maxArtistWeight > 0 ? min(1, artistWeight / maxArtistWeight) : 0

        let eraMatch = eraScore(year: input.year, profile: profile)
        let freshness = freshnessScore(artistKey: artistKey, profile: profile)
        let sourceReliability = input.source.reliability
        let novelty = input.isKnownTrack ? RecommendationWeights.repeatedTrackNovelty : 1.0

        let popularity = input.popularity

        let total = artistAffinity * RecommendationWeights.artistAffinity
            + eraMatch * RecommendationWeights.eraMatch
            + freshness * RecommendationWeights.freshness
            + sourceReliability * RecommendationWeights.sourceReliability
            + novelty * RecommendationWeights.novelty
            + popularity * RecommendationWeights.popularity

        var reasons: [String] = []
        if artistAffinity >= 0.5 {
            reasons.append("recommendation_reason_artist".localized(with: RecommendationKey.displayPrimaryArtist(input.artist)))
        }
        if eraMatch >= 0.6, let year = input.year {
            let decade = decadeBucket(for: year)
            reasons.append("recommendation_reason_era".localized(with: decade))
        }
        if freshness >= 0.6 {
            reasons.append("recommendation_reason_trend".localized(with: RecommendationKey.displayPrimaryArtist(input.artist)))
        }
        if !input.isKnownTrack {
            reasons.append("recommendation_reason_new".localized)
        }

        return RecommendationScore(
            total: total,
            reasons: reasons,
            artistAffinity: artistAffinity,
            eraMatch: eraMatch,
            freshness: freshness,
            sourceReliability: sourceReliability,
            novelty: novelty,
            popularity: popularity
        )
    }

    /// 年份 → 十年桶（1998 → 1990）。
    static func decadeBucket(for year: Int) -> Int {
        (year / 10) * 10
    }

    private static func eraScore(year: Int?, profile: TasteProfile) -> Double {
        guard let year, !profile.decadeShare.isEmpty else { return RecommendationWeights.neutral }
        let bucket = decadeBucket(for: year)
        guard let share = profile.decadeShare[bucket] else { return 0 }
        let maxShare = profile.decadeShare.values.max() ?? 0
        return maxShare > 0 ? min(1, share / maxShare) : RecommendationWeights.neutral
    }

    private static func freshnessScore(artistKey: String, profile: TasteProfile) -> Double {
        // 没有任何漂移数据（新库 / 历史太短）→ 中性，不惩罚。
        guard !profile.recentArtistDrift.isEmpty else { return RecommendationWeights.neutral }
        let drift = profile.recentArtistDrift[artistKey] ?? 0
        let maxPositive = profile.recentArtistDrift.values.filter { $0 > 0 }.max() ?? 0
        guard maxPositive > 0, drift > 0 else { return 0 }
        return min(1, drift / maxPositive)
    }
}
