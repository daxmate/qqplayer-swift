//
//  RecommendationProfileV3.swift
//  QQPlayer
//
//  推荐 v3：口味画像（歌手亲和度 + 风格簇）。纯逻辑，不读 DB、不发网络。
//
//  亲和度（四项各自归一到 0…1 后加权，权重和归一到 1）：
//    lib = log1p(该歌手曲目数) / log1p(全库单歌手最大曲目数)
//    play = log1p(该歌手总播放次数) / log1p(最大总播放次数)
//    fav = 收藏 / 歌单命中 ? 1 : 0
//    rec = exp(-距今天数 / 180)
//    affinity = wLib*lib + wPlay*play + wFav*fav + wRec*rec
//
//  边界行为（全部有确定结果，不崩）：
//    - 空库 → seeds 为空，emptyReason = .emptyLibrary
//    - 曲目都没有艺人名 → seeds 为空，emptyReason = .noArtistData
//    - 全零播放 / 没有收藏 → 对应项为 0（不编造数据）
//

import Foundation

/// 画像 v3 输入（DB 行 / 测试夹具共用）。
struct RecommendationProfileV3Input: Sendable, Equatable {
    struct Track: Sendable, Equatable {
        var stableId: String
        var title: String
        var artist: String
        var album: String?
        var genre: String?
        var year: Int?
        var durationMs: Int?
        /// 加入曲库时间（DB 没有该列时由调用方用文件修改时间兜底；仍无 = nil）。
        var addedAt: Date?
        var isFavorite: Bool
        var isInPlaylist: Bool
        var playCount: Int
        var totalPlayedMs: Int64

        init(
            stableId: String = "",
            title: String,
            artist: String,
            album: String? = nil,
            genre: String? = nil,
            year: Int? = nil,
            durationMs: Int? = nil,
            addedAt: Date? = nil,
            isFavorite: Bool = false,
            isInPlaylist: Bool = false,
            playCount: Int = 0,
            totalPlayedMs: Int64 = 0
        ) {
            self.stableId = stableId
            self.title = title
            self.artist = artist
            self.album = album
            self.genre = genre
            self.year = year
            self.durationMs = durationMs
            self.addedAt = addedAt
            self.isFavorite = isFavorite
            self.isInPlaylist = isInPlaylist
            self.playCount = playCount
            self.totalPlayedMs = totalPlayedMs
        }
    }

    var tracks: [Track] = []
    var blacklistTracks: Set<String> = []
    var blacklistArtists: Set<String> = []
    var now: Date = Date()
}

extension RecommendationProfileV3Input {
    /// 从既有画像输入转换（DB 同一次读取；新增字段由 `RecommendationDataSource` 补齐）。
    init(legacy: RecommendationProfileInput) {
        let tracks = legacy.tracks.map { track in
            RecommendationProfileV3Input.Track(
                stableId: track.stableId,
                title: track.title,
                artist: track.artist,
                album: track.album,
                genre: track.genre,
                year: track.year,
                durationMs: track.durationMs,
                addedAt: track.addedAt,
                isFavorite: track.isFavorite,
                isInPlaylist: track.isInPlaylist,
                playCount: track.playCount
            )
        }
        self.init(
            tracks: tracks,
            blacklistTracks: legacy.blacklist.trackKeys,
            blacklistArtists: legacy.blacklist.artists,
            now: legacy.now
        )
    }
}

enum RecommendationProfileV3Builder {
    static let maxSeeds = 15
    static let maxClusters = 5
    /// 亲和度时间衰减半衰天数。
    static let recencyHalfLifeDays: Double = 180

    static func build(
        _ input: RecommendationProfileV3Input,
        weights: RecommendationProfileWeights = .defaults
    ) -> RecommendationTasteProfileV3 {
        var profile = RecommendationTasteProfileV3()
        profile.blacklistTracks = input.blacklistTracks
        profile.blacklistArtists = input.blacklistArtists

        let tracks = input.tracks.filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        profile.libraryKeys = Set(tracks.map { RecommendationLibraryMatcher.key(title: $0.title, artist: $0.artist) })
        profile.playedKeys = Set(
            tracks.filter { $0.playCount > 0 }
                .map { RecommendationLibraryMatcher.key(title: $0.title, artist: $0.artist) }
        )

        guard !tracks.isEmpty else {
            profile.emptyReason = .emptyLibrary
            return profile
        }

        var groups: [String: [RecommendationProfileV3Input.Track]] = [:]
        for track in tracks {
            let key = RecommendationLibraryMatcher.artistKey(track.artist)
            guard !key.isEmpty else { continue }
            groups[key, default: []].append(track)
        }
        guard !groups.isEmpty else {
            profile.emptyReason = .noArtistData
            return profile
        }

        let maxLibraryCount = groups.values.map(\.count).max() ?? 0
        let maxPlayCount = groups.values.map { $0.reduce(0) { $0 + $1.playCount } }.max() ?? 0
        let normalizedWeights = weights.normalized()

        var seeds: [RecommendationSeedArtist] = []
        seeds.reserveCapacity(groups.count)
        for (key, items) in groups {
            let libraryCount = items.count
            let playCount = items.reduce(0) { $0 + $1.playCount }
            let favorite = items.contains { $0.isFavorite || $0.isInPlaylist }
            let lib = logRatio(libraryCount, maxLibraryCount)
            let play = logRatio(playCount, maxPlayCount)
            let fav = favorite ? 1.0 : 0.0
            let rec = recency(items.compactMap(\.addedAt).max(), now: input.now)
            let affinity = normalizedWeights.library * lib
                + normalizedWeights.play * play
                + normalizedWeights.favorite * fav
                + normalizedWeights.recency * rec
            let displayArtist = items.first?.artist.trimmingCharacters(in: .whitespacesAndNewlines) ?? key
            seeds.append(
                RecommendationSeedArtist(
                    artist: displayArtist,
                    affinity: clamp01(affinity),
                    libraryCount: libraryCount,
                    playCount: playCount,
                    representativeTitles: representativeTitles(items)
                )
            )
        }

        seeds.sort { lhs, rhs in
            if abs(lhs.affinity - rhs.affinity) > 0.000_001 { return lhs.affinity > rhs.affinity }
            if lhs.libraryCount != rhs.libraryCount { return lhs.libraryCount > rhs.libraryCount }
            if lhs.playCount != rhs.playCount { return lhs.playCount > rhs.playCount }
            return RecommendationLibraryMatcher.artistKey(lhs.artist) < RecommendationLibraryMatcher.artistKey(rhs.artist)
        }
        profile.seeds = Array(seeds.prefix(maxSeeds))
        profile.clusters = clusters(from: tracks)

        if profile.seeds.isEmpty { profile.emptyReason = .noArtistData }
        return profile
    }

    // MARK: - 内部步骤

    private static func logRatio(_ value: Int, _ maxValue: Int) -> Double {
        guard maxValue > 0, value > 0 else { return 0 }
        let denominator = log1p(Double(maxValue))
        guard denominator > 0 else { return 0 }
        return min(1, log1p(Double(value)) / denominator)
    }

    private static func recency(_ addedAt: Date?, now: Date) -> Double {
        guard let addedAt else { return 0 }
        let days = now.timeIntervalSince(addedAt) / 86_400
        guard days.isFinite else { return 0 }
        return exp(-max(0, days) / recencyHalfLifeDays)
    }

    private static func clamp01(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    private static func representativeTitles(_ items: [RecommendationProfileV3Input.Track]) -> [String] {
        var seen = Set<String>()
        var ranked: [RecommendationProfileV3Input.Track] = []
        for track in items {
            let key = RecommendationLibraryMatcher.titleKey(track.title)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            ranked.append(track)
        }
        ranked.sort { lhs, rhs in
            if lhs.playCount != rhs.playCount { return lhs.playCount > rhs.playCount }
            return RecommendationLibraryMatcher.titleKey(lhs.title) < RecommendationLibraryMatcher.titleKey(rhs.title)
        }
        return Array(ranked.prefix(3)).map { $0.title }
    }

    /// 风格簇：genre × decade × language 的曲目占比 Top（最多 5 个）。
    private static func clusters(from tracks: [RecommendationProfileV3Input.Track]) -> [RecommendationStyleCluster] {
        struct Key: Hashable { var genre: String; var decade: Int?; var language: RecommendationLanguage }
        var counts: [Key: Int] = [:]
        var total = 0
        for track in tracks {
            guard let genre = cleanGenre(track.genre) else { continue }
            let language = RecommendationLanguageDetector.detect(in: [track.artist, track.title])
            let key = Key(genre: genre, decade: decadeStart(track.year), language: language)
            counts[key, default: 0] += 1
            total += 1
        }
        guard total > 0 else { return [] }
        let ranked = counts.map { (key: $0.key, count: $0.value) }.sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            if lhs.key.genre != rhs.key.genre { return lhs.key.genre < rhs.key.genre }
            if lhs.key.decade != rhs.key.decade {
                return (lhs.key.decade ?? Int.max) < (rhs.key.decade ?? Int.max)
            }
            return lhs.key.language.rawValue < rhs.key.language.rawValue
        }
        return ranked.prefix(maxClusters).map {
            RecommendationStyleCluster(
                genre: $0.key.genre,
                decade: $0.key.decade,
                language: $0.key.language,
                share: Double($0.count) / Double(total)
            )
        }
    }

    /// 只接受「干净」的曲风值（过滤数字 / 纯标点 / 过长脏值）。
    private static func cleanGenre(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2 ... 40).contains(trimmed.count) else { return nil }
        guard trimmed.contains(where: { $0.isLetter }) else { return nil }
        return trimmed.lowercased()
    }

    static func decadeStart(_ year: Int?) -> Int? {
        guard let year, (1900 ... 2100).contains(year) else { return nil }
        return year / 10 * 10
    }
}
