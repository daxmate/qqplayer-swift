//
//  RecommendationArtistMix.swift
//  QQPlayer
//
//  推荐：「点名艺人 = 本人为主 + 相似补位」的纯逻辑口径。
//
//  - `quota`：相似名额 = round(target × share)（默认 30%，15 → 5），本人名额 = target − 相似；
//    某段不足时由另一段补位（本人优先），相似段永不超过名额；
//  - `directCount` / `shortfallNotice`：不足提示用**本人匹配数**（不是整批数量）；
//  - `batchMaxPerArtist`：点名批次允许该艺人占满本人那一段（整批同艺人不算多样性放宽）。
//
//  ⚠️ 本文件只依赖 Foundation：不碰网络与 UI，可直接单测。
//

import Foundation

enum RecommendationArtistMix {
    /// 点名请求：有 `referenceArtists` 且不是「相似 / 风格接近」语义（与硬约束同一口径）。
    static func isNamedArtistRequest(_ request: RecommendationUserRequest) -> Bool {
        guard !RecommendationArtistRequestSemantics.isSimilarityRequest(request.rawText) else { return false }
        return request.referenceArtists.contains {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 名额换算：相似 = round(target × share)，本人 = target − 相似（2026-11-13 用户口径：固定比例）。
    ///
    /// 例：target 15、share 0.30 → 10 / 5；share 0 → 15 / 0；share 0.50 → 7 / 8（7.5 四舍五入）。
    /// 两段都够时按此比例取满；某段不足时由另一段补位（本人优先），相似段永不超过名额。
    static func quota(displayTarget: Int, share: Double) -> (direct: Int, related: Int) {
        let target = max(0, displayTarget)
        let ratio = min(1, max(0, share.isFinite ? share : 0))
        let related = min(target, Int((Double(target) * ratio).rounded()))
        return (target - related, related)
    }

    /// 本人行判定：相似补位行带 `relatedTo` 标记（来源的唯一判据）。
    static func isRelated(_ candidate: RecommendedCandidate) -> Bool {
        candidate.relatedTo != nil
    }

    /// 本人匹配数（点名场景）：当前批次里直接命中点名艺人的条数。
    static func directCount(in candidates: [RecommendedCandidate]) -> Int {
        candidates.reduce(into: 0) { count, candidate in
            guard candidate.relatedTo == nil else { return }
            count += 1
        }
    }

    /// 点名批次的同艺人上限：本人可以占满整批（相似补位在召回层已限 ≤ 1/3 批次）。
    static func batchMaxPerArtist(namedArtist: Bool) -> Int {
        namedArtist ? RecommendationBatchPolicy.batchSize : RecommendationBatchPolicy.maxSongsPerArtist
    }

    /// 点名批次的「不同艺人」目标：整批同一个艺人属预期，不该标记为多样性放宽。
    static func batchMinDistinctArtists(namedArtist: Bool) -> Int {
        namedArtist ? 1 : RecommendationBatchPolicy.minDistinctArtists
    }

    /// 不足提示：本人 < 目标时给出文案；本人够了返回 nil（不打扰）。
    ///
    /// 有相似补位 → 新文案（本人 N 首 + 补 M 首）；无补位 → 沿用原「只找到 N 首」。
    static func shortfallNotice(
        artist: String,
        directCount: Int,
        relatedCount: Int,
        target: Int
    ) -> String? {
        guard directCount < max(1, target) else { return nil }
        if relatedCount > 0 {
            return "recommendation_artist_shortfall_filled".localized(
                with: artist, directCount, relatedCount
            )
        }
        return "recommendation_artist_shortfall".localized(with: directCount, artist)
    }
}
