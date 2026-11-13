//
//  RecommendationArtistMix.swift
//  QQPlayer
//
//  推荐：「点名艺人 = 本人为主 + 相似补位」的纯逻辑口径。
//
//  - `relatedCap`：相似补位上限按**用户可见批次**（15）的 1/3 计算，池容量不放宽它；
//  - `directCount` / `shortfallNotice`：不足提示用**本人匹配数**（不是整批数量）；
//  - `batchMaxPerArtist`：点名批次允许该艺人占满整批（相似补位已在召回层限 ≤ 1/3 批次）。
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

    /// 相似补位上限：`target / 3`，target 取用户可见批次（15 → 5）。
    ///
    /// 池构建时传入的是池容量（60）：直接按 60/3 会让一批 15 首里塞进 20 首相似歌，
    /// 所以额度按 `min(target, batchSize)` 计算。
    static func relatedCap(displayTarget: Int) -> Int {
        max(0, min(max(0, displayTarget), RecommendationBatchPolicy.batchSize) / 3)
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
