//
//  RecommendationEngine+Selection.swift
//  QQPlayer
//
//  推荐 P1/P2：N 选（同艺人 / 同专辑 / 意图 / 来源上限 + 多样性放宽）。
//  从 RecommendationEngine.swift 拆出：加 P2 专辑上限后文件触及 600 行结构预算，本次只搬家。
//
//  批次 C（2026-11-25）：点名艺人配额口径随输入框一并移除，只剩通用 N 选。ct 的点名分支）。
//

import Foundation

extension RecommendationEngine {
    func select(
        _ ranked: [RankedItem],
        count: Int,
        profile: TasteProfile
    ) -> [RecommendedCandidate] {
        let target = max(1, count)
        let perIntentCap = max(2, min(maxSongsPerIntent, target / 3 + 1))
        let perSourceCap = max(1, Int((Double(target) * maxSourceShare).rounded(.up)))
        let perArtistCap = max(1, maxSongsPerArtist)

        var artistCounts: [String: Int] = [:]
        var albumCounts: [String: Int] = [:]
        var intentCounts: [String: Int] = [:]
        var sourceCounts: [RecommendationSource: Int] = [:]
        var usedKeys = Set<String>()
        var picked: [RecommendedCandidate] = []
        var previousPrimary: String?

        func key(_ item: RankedItem) -> String {
            RecommendationKey.normalize(title: item.item.song.title, artist: item.item.song.artist)
                + "#" + item.item.source.rawValue
        }

        /// 上限判定的**唯一入口**：`intentCap` / `sourceCap` 传 nil = 本轮不限制该上限。
        func admits(_ item: RankedItem, intentCap: Int?, sourceCap: Int?) -> Bool {
            guard !usedKeys.contains(key(item)) else { return false }
            let artistKey = RecommendationKey.primaryArtist(item.item.song.artist)
            if artistCounts[artistKey, default: 0] >= perArtistCap { return false }
            if let maxSongsPerAlbum,
               let albumKey = Self.albumKey(album: item.item.song.album) {
                if albumCounts[albumKey, default: 0] >= maxSongsPerAlbum { return false }
            }

            if let intentCap, intentCounts[item.item.intent.priorityKey, default: 0] >= intentCap { return false }
            if let sourceCap, sourceCounts[item.item.source, default: 0] >= sourceCap { return false }
            return true
        }

        func take(_ item: RankedItem) {
            let artistKey = RecommendationKey.primaryArtist(item.item.song.artist)
            artistCounts[artistKey, default: 0] += 1
            if let albumKey = Self.albumKey(album: item.item.song.album) {
                albumCounts[albumKey, default: 0] += 1
            }

            intentCounts[item.item.intent.priorityKey, default: 0] += 1
            sourceCounts[item.item.source, default: 0] += 1
            usedKeys.insert(key(item))

            var reasons = reasonsFor(
                item.item,
                previousPrimary: previousPrimary
            )
            // 榜单命中：追加「近期热门」并保证它落在 UI 展示的前两条里（规则理由上限仍为 2 条）。
            if item.isChartHit {
                let chartReason = "recommendation_reason_chart_hot".localized
                if !reasons.contains(chartReason) {
                    if reasons.count >= 2 { reasons.removeLast() }
                    reasons.append(chartReason)
                }
            }
            previousPrimary = reasons.first

            var candidate = RecommendedCandidate(
                title: item.item.song.title,
                artist: item.item.song.artist,
                album: item.item.song.album,
                year: item.item.song.year,
                source: item.item.source,
                relatedTo: item.item.relatedTo
            )
            candidate.score = item.score
            candidate.reasons = reasons
            // P3：曲风只用来约束批次多样性（缺 genre 的条目不参与该约束）。
            candidate.genre = item.item.intent.kind == .genre ? item.item.intent.genre : nil
            picked.append(candidate)
        }

        // 第一轮守多样性上限；条数不够时第二轮放宽意图 / 来源上限（艺人上限始终保留）。
        for pass in 0 ..< 2 {
            for item in ranked {
                guard picked.count < target else { break }
                guard admits(
                    item,
                    intentCap: pass == 0 ? perIntentCap : nil,
                    sourceCap: pass == 0 ? perSourceCap : nil
                ) else { continue }
                take(item)
            }
        }

        return picked
    }

    /// 同专辑归并键；专辑缺失（空串，或降级源恒为 nil）→ nil = 不参与专辑上限。
    ///
    /// 不能伪造「无专辑」分桶：那样同一艺人的无专辑曲目会互相压到上限首数，
    /// 点名场景下直接把本人段砍到 2 首。
    private static func albumKey(album: String?) -> String? {
        guard let album, !album.isEmpty else { return nil }
        return RecommendationNormalization.normalizeTitle(album)
    }

}
