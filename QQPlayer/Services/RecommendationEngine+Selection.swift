//
//  RecommendationEngine+Selection.swift
//  QQPlayer
//
//  推荐 P1/P2：N 选（同艺人 / 同专辑 / 意图 / 来源上限 + 多样性放宽）。
//  从 RecommendationEngine.swift 拆出：加 P2 专辑上限后文件触及 600 行结构预算，本次只搬家。
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

        func take(_ item: RankedItem) {
            let artistKey = RecommendationKey.primaryArtist(item.item.song.artist)
            let key = RecommendationKey.normalize(title: item.item.song.title, artist: item.item.song.artist)
                + "#" + item.item.source.rawValue
            artistCounts[artistKey, default: 0] += 1
            albumCounts[Self.albumKey(album: item.item.song.album, artist: item.item.song.artist), default: 0] += 1
            intentCounts[item.item.intent.priorityKey, default: 0] += 1
            sourceCounts[item.item.source, default: 0] += 1
            usedKeys.insert(key)

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
                source: item.item.source
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
                let key = RecommendationKey.normalize(title: item.item.song.title, artist: item.item.song.artist)
                    + "#" + item.item.source.rawValue
                guard !usedKeys.contains(key) else { continue }
                let artistKey = RecommendationKey.primaryArtist(item.item.song.artist)
                if artistCounts[artistKey, default: 0] >= perArtistCap { continue }
                if let maxSongsPerAlbum,
                   albumCounts[Self.albumKey(album: item.item.song.album, artist: item.item.song.artist), default: 0] >= maxSongsPerAlbum {
                    continue
                }
                if pass == 0 {
                    if intentCounts[item.item.intent.priorityKey, default: 0] >= perIntentCap { continue }
                    if sourceCounts[item.item.source, default: 0] >= perSourceCap { continue }
                }
                take(item)
            }
        }

        return picked
    }

    /// 同专辑归并键（专辑给不出时按艺人分桶，避免把无专辑曲目互相压掉）。
    static func albumKey(album: String?, artist: String) -> String {
        guard let album, !album.isEmpty else {
            return "no-album#" + RecommendationKey.primaryArtist(artist)
        }
        return RecommendationNormalization.normalizeTitle(album)
    }

}
