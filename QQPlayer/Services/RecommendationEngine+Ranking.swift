//
//  RecommendationEngine+Ranking.swift
//  QQPlayer
//
//  推荐重排：逐条打分 + 意图置信度加成（榜单热度在 rank 里换成分量）。
//
//  2026-11-13 从 RecommendationEngine.swift 原样拆出：主文件加热度接线后触及 600 行结构预算，
//  本次只搬家 + 接 chartIndex，不改排序语义。
//

import Foundation

extension RecommendationEngine {
    // MARK: 重排

    struct RankedItem: Sendable {
        var item: GatheredItem
        var score: Double
        /// 是否命中 Apple Music 榜单（推荐理由「近期热门」用）。
        var isChartHit: Bool = false
    }

    func rank(
        _ items: [GatheredItem],
        profile: TasteProfile,
        chartIndex: ChartPopularityIndex = .empty
    ) -> [RankedItem] {
        items.map { item in
            let key = RecommendationKey.normalize(title: item.song.title, artist: item.song.artist)
            let chartRank = chartIndex.rank(songID: item.song.songID, title: item.song.title, artist: item.song.artist)
            let score = RecommendationScorer.score(
                RecommendationScoreInput(
                    artist: item.song.artist,
                    year: item.song.year,
                    source: item.source,
                    isKnownTrack: profile.playedKeys.contains(key),
                    popularity: chartIndex.popularity(forRank: chartRank)
                ),
                profile: profile
            )
            return RankedItem(item: item, score: score.total + intentBoost(item.intent), isChartHit: chartRank != nil)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.item.song.title.localizedStandardCompare(rhs.item.song.title) == .orderedAscending
            }
            return lhs.score > rhs.score
        }
    }
}
