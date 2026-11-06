//
//  RecommendationProfile.swift
//  QQPlayer
//
//  本地 AI 推荐 P1：听歌画像（纯逻辑、可单测）。
//
//  输入是**可注入的行数组**（不直接读 DB）：播放历史行 + 曲库行 + 黑名单，
//  输出 `TasteProfile`。DB 读取在 `RecommendationEngine.swift` 的
//  `RecommendationDataSource`（唯一 I/O 点），本文件只做纯计算。
//
//  时间衰减：半衰期 30 天；完成率权重：`max(0.2, min(1, 播放时长/时长))`。
//

import Foundation

// MARK: - 输入

/// 画像输入（DB 行 / 测试夹具共用）。
struct RecommendationProfileInput: Sendable {
    /// `play_history` 行（play_duration_ms 为毫秒）。
    struct Play: Sendable, Equatable {
        var trackStableId: String
        var playedAt: Date
        var playDurationMs: Int64
    }

    /// `track` + `artist` + `album` 的连接结果（stable_id 对齐）。
    struct TrackInfo: Sendable, Equatable {
        var stableId: String
        var title: String
        var artist: String
        var album: String?
        var year: Int?
        var durationMs: Int?
        var genre: String?
    }

    var plays: [Play] = []
    var tracks: [TrackInfo] = []
    var blacklist: RecommendationBlacklist = RecommendationBlacklist()
    var now: Date = Date()
    /// 曲库指纹（缓存键用；空串 = 未知，调用方按不可缓存处理）。
    var libraryFingerprint: String = ""
}

// MARK: - 输出

/// 艺人权重（画像主产物）。
struct ArtistWeight: Sendable, Equatable {
    var artist: String
    var weight: Double
}

/// 听歌画像：规则召回与打分的唯一输入。
struct TasteProfile: Sendable, Equatable {
    /// 艺人权重（降序；weight = Σ 时间衰减 × 完成率权重）。
    var topArtists: [ArtistWeight] = []
    /// 平均完成率（只统计 duration > 15s 且有进度的记录；无样本 = 0）。
    var completionRate: Double = 0
    /// 年代桶占比（key = 十年起点，如 1990；无年份数据的库为空，不编造）。
    var decadeShare: [Int: Double] = [:]
    /// 最近 14 天 vs 之前 90 天的艺人权重差（归一化占比之差）。
    var recentArtistDrift: [String: Double] = [:]
    /// 曲库归一化单曲键集合（召回去重用）。
    var libraryKeys: Set<String> = []
    /// 播放过的归一化单曲键集合（novelty 用）。
    var playedKeys: Set<String> = []
    var blacklistTracks: Set<String> = []
    var blacklistArtists: Set<String> = []
    /// 曲库里干净且高频的 genre 值（召回意图用；脏值已在构建期剔除）。
    var topGenres: [String] = []

    /// 年代 → 该年代的高权重艺人（按权重降序；召回回退用，不硬编码年代代表歌手）。
    var decadeArtists: [Int: [String]] = [:]

    /// 曲风 → 该曲风的高权重艺人（按权重降序）。
    var genreArtists: [String: [String]] = [:]

    /// 艺人权重查表（artist 为归一化主艺人）。
    func weight(forArtist artist: String) -> Double {
        topArtists.first { $0.artist == artist }?.weight ?? 0
    }

    /// 画像是否为空（新库 / 无播放历史）。
    var isEmpty: Bool {
        topArtists.isEmpty && libraryKeys.isEmpty
    }
}

// MARK: - 构建

/// 画像构建器（纯函数；阈值集中在常量）。
enum RecommendationProfileBuilder {
    /// 时间衰减半衰期（天）。
    static let halfLifeDays: Double = 30
    /// 近期窗口（天）—— 与基线窗口起点一致。
    static let recentWindowDays: Double = 14
    /// 基线窗口长度（天）：最近 14 天 vs 之前 90 天。
    static let baselineWindowDays: Double = 90
    /// 完成率只统计 duration > 15s 的记录。
    static let minimumDurationSeconds: Double = 15
    /// 完成率权重下限（播一下就切走也给一点权重，避免权重为 0 无法排序）。
    static let minimumCompletionWeight: Double = 0.2
    static let maxTopArtists = 50
    static let maxGenres = 5
    /// 每个年代 / 曲风最多保留几个代表艺人。
    static let maxArtistsPerBucket = 2
    static let maxGenreLength = 24

    static func build(_ input: RecommendationProfileInput) -> TasteProfile {
        let tracksById = Dictionary(
            input.tracks.map { ($0.stableId, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var profile = TasteProfile()
        profile.libraryKeys = Set(input.tracks.map {
            RecommendationKey.normalize(title: $0.title, artist: $0.artist)
        })
        profile.blacklistTracks = input.blacklist.trackKeys
        profile.blacklistArtists = input.blacklist.artists

        var artistWeights: [String: Double] = [:]
        var recentWeights: [String: Double] = [:]
        var baselineWeights: [String: Double] = [:]
        var decadeWeights: [Int: Double] = [:]
        var completionSamples: [Double] = []
        var genreCounts: [String: (display: String, count: Int)] = [:]

        for track in input.tracks {
            guard let genre = cleanedGenre(track.genre) else { continue }
            let lowered = genre.lowercased()
            if let existing = genreCounts[lowered] {
                genreCounts[lowered] = (existing.display, existing.count + 1)
            } else {
                genreCounts[lowered] = (genre, 1)
            }
        }

        for play in input.plays {
            guard let track = tracksById[play.trackStableId] else { continue }
            let key = RecommendationKey.normalize(title: track.title, artist: track.artist)
            profile.playedKeys.insert(key)

            let ageDays = max(0, input.now.timeIntervalSince(play.playedAt) / 86400)
            let decay = pow(0.5, ageDays / halfLifeDays)

            let playSeconds = Double(play.playDurationMs) / 1000
            let durationSeconds = track.durationMs.map { Double($0) / 1000 }
            let completion: Double
            if let durationSeconds, durationSeconds > 0 {
                completion = min(1, max(0, playSeconds / durationSeconds))
            } else {
                completion = 0.5 // 时长未知：中性，不奖励也不惩罚
            }
            let weight = decay * max(minimumCompletionWeight, completion)

            let artistKey = RecommendationKey.primaryArtist(track.artist)
            artistWeights[artistKey, default: 0] += weight

            if ageDays <= recentWindowDays {
                recentWeights[artistKey, default: 0] += weight
            } else if ageDays <= recentWindowDays + baselineWindowDays {
                baselineWeights[artistKey, default: 0] += weight
            }

            if let durationSeconds, durationSeconds > minimumDurationSeconds, playSeconds > 0 {
                completionSamples.append(completion)
            }

            if let year = track.year {
                let bucket = RecommendationScorer.decadeBucket(for: year)
                decadeWeights[bucket, default: 0] += weight
            }
        }

        let orderedArtists: [ArtistWeight] = artistWeights.map { key, value in
            ArtistWeight(artist: key, weight: value)
        }.sorted { lhs, rhs in
            lhs.weight == rhs.weight ? lhs.artist < rhs.artist : lhs.weight > rhs.weight
        }
        profile.topArtists = Array(orderedArtists.prefix(maxTopArtists))

        if !completionSamples.isEmpty {
            profile.completionRate = completionSamples.reduce(0, +) / Double(completionSamples.count)
        }

        profile.decadeShare = normalizedDecadeShares(decadeWeights)

        let recentShares = normalizedArtistShares(recentWeights)
        let baselineShares = normalizedArtistShares(baselineWeights)
        var drift: [String: Double] = [:]
        for artist in Set(recentShares.keys).union(baselineShares.keys) {
            let delta = (recentShares[artist] ?? 0) - (baselineShares[artist] ?? 0)
            if abs(delta) > 0.000_1 { drift[artist] = delta }
        }
        profile.recentArtistDrift = drift

        let orderedGenres = genreCounts.values.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs.display < rhs.display : lhs.count > rhs.count
        }
        profile.topGenres = Array(orderedGenres.prefix(maxGenres)).map { $0.display }

        // 年代 / 曲风 → 代表艺人：只用用户曲库里的高权重艺人，不硬编码年代代表歌手。
        var decadeArtistWeights: [Int: [String: Double]] = [:]
        var genreArtistWeights: [String: [String: Double]] = [:]
        for track in input.tracks {
            let artistKey = RecommendationKey.primaryArtist(track.artist)
            guard !artistKey.isEmpty, let weight = artistWeights[artistKey] else { continue }
            if let year = track.year {
                let bucket = RecommendationScorer.decadeBucket(for: year)
                decadeArtistWeights[bucket, default: [:]][artistKey, default: 0] += weight
            }
            if let genre = cleanedGenre(track.genre), let display = genreCounts[genre.lowercased()]?.display {
                genreArtistWeights[display, default: [:]][artistKey, default: 0] += weight
            }
        }
        profile.decadeArtists = decadeArtistWeights.mapValues { weights in
            Array(
                weights.sorted { lhs, rhs in
                    lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
                }.prefix(maxArtistsPerBucket).map(\.key)
            )
        }
        profile.genreArtists = genreArtistWeights.mapValues { weights in
            Array(
                weights.sorted { lhs, rhs in
                    lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
                }.prefix(maxArtistsPerBucket).map(\.key)
            )
        }

        return profile
    }

    /// 脏 genre 过滤（域名 / 超长串 / 路径 / 未知值一律不算召回意图）。
    static func cleanedGenre(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maxGenreLength else { return nil }
        let lowered = value.lowercased()
        let dirtyMarkers = ["http", "www.", ".com", "/", "\\", "<", ">", "未知", "unknown"]
        guard !dirtyMarkers.contains(where: { lowered.contains($0) }) else { return nil }
        guard value.rangeOfCharacter(from: .letters) != nil else { return nil }
        return value
    }

    private static func normalizedDecadeShares(_ weights: [Int: Double]) -> [Int: Double] {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return weights.mapValues { $0 / total }
    }

    private static func normalizedArtistShares(_ weights: [String: Double]) -> [String: Double] {
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return [:] }
        return weights.mapValues { $0 / total }
    }
}
