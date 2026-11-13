//
//  RecommendationEngine+Selection.swift
//  QQPlayer
//
//  推荐 P1/P2：N 选（同艺人 / 同专辑 / 意图 / 来源上限 + 多样性放宽）。
//  从 RecommendationEngine.swift 拆出：加 P2 专辑上限后文件触及 600 行结构预算，本次只搬家。
//
//  点名艺人（artistConstraint）走独立口径：本人优先填满、相似补位 ≤ 批次 1/3（见 select 的点名分支）。
//

import Foundation

extension RecommendationEngine {
    func select(
        _ ranked: [RankedItem],
        count: Int,
        profile: TasteProfile,
        artistConstraint: RecommendationArtistConstraint? = nil
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
            if let maxSongsPerAlbum {
                let albumKey = Self.albumKey(album: item.item.song.album, artist: item.item.song.artist)
                if albumCounts[albumKey, default: 0] >= maxSongsPerAlbum { return false }
            }
            if let intentCap, intentCounts[item.item.intent.priorityKey, default: 0] >= intentCap { return false }
            if let sourceCap, sourceCounts[item.item.source, default: 0] >= sourceCap { return false }
            return true
        }

        func take(_ item: RankedItem) {
            let artistKey = RecommendationKey.primaryArtist(item.item.song.artist)
            artistCounts[artistKey, default: 0] += 1
            albumCounts[Self.albumKey(album: item.item.song.album, artist: item.item.song.artist), default: 0] += 1
            intentCounts[item.item.intent.priorityKey, default: 0] += 1
            sourceCounts[item.item.source, default: 0] += 1
            usedKeys.insert(key(item))

            let reasons = reasonsFor(
                item.item,
                previousPrimary: previousPrimary,
                artistConstraint: artistConstraint
            )
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

        // 点名艺人：本人 / 相似按固定比例取满（share=0 = 纯本人）；某段不足由另一段补位（本人优先）。
        if let artistConstraint {
            let quota = RecommendationArtistMix.quota(displayTarget: target, share: relatedArtistShare)
            for pass in 0 ..< 2 {
                for item in ranked where artistConstraint.matches(artist: item.item.song.artist) {
                    guard picked.count < quota.direct else { break }
                    guard admits(item, intentCap: nil, sourceCap: pass == 0 ? perSourceCap : nil) else { continue }
                    take(item)
                }
            }
            var relatedPicked = 0
            for pass in 0 ..< 2 {
                for item in ranked where !artistConstraint.matches(artist: item.item.song.artist) {
                    guard picked.count < target, relatedPicked < quota.related else { break }
                    guard admits(
                        item,
                        intentCap: pass == 0 ? perIntentCap : nil,
                        sourceCap: pass == 0 ? perSourceCap : nil
                    ) else { continue }
                    take(item)
                    relatedPicked += 1
                }
            }
            // 本人优先补位：相似段不足时用本人凑满 target（相似段不再超过名额）。
            if picked.count < target {
                for pass in 0 ..< 2 {
                    for item in ranked where artistConstraint.matches(artist: item.item.song.artist) {
                        guard picked.count < target else { break }
                        guard admits(item, intentCap: nil, sourceCap: pass == 0 ? perSourceCap : nil) else { continue }
                        take(item)
                    }
                }
            }
            // 展示顺序：本人行在前、相似补位行在后（补位行可能因凑满被排到直采之后）。
            return picked.filter { $0.relatedTo == nil } + picked.filter { $0.relatedTo != nil }
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

    /// 同专辑归并键（专辑给不出时按艺人分桶，避免把无专辑曲目互相压掉）。
    private static func albumKey(album: String?, artist: String) -> String {
        guard let album, !album.isEmpty else {
            return "no-album#" + RecommendationKey.primaryArtist(artist)
        }
        return RecommendationNormalization.normalizeTitle(album)
    }

}
