//
//  RecommendationEngine.swift
//  QQPlayer
//
//  本地 AI 推荐 P1：规则召回 + 去重 + 打分 + N 选（不接模型）。
//
//  链路：画像（RecommendationProfile）→ 检索意图（top 艺人 / 年代 / 干净 genre）
//  → 在线源召回（网易云 + 歌曲海，复用既有客户端）→ 归一化去重
//  → 剔除库内与黑名单 → 打分 → 同艺人上限 → 取前 count。
//
//  失败语义：单源失败不影响另一源；所有源都失败返回 `.allSourcesFailed`。
//  本层**不**调用下载链路、不写曲库、不建歌单。
//

import Foundation

// MARK: - 在线召回契约

/// 在线源返回的歌曲（两源归一后的最小字段；年份/专辑给不出就是 nil，不编造）。
struct RecommendationRemoteSong: Sendable, Equatable {
    var title: String
    var artist: String
    var album: String?
    var year: Int?
}

/// 在线搜索 seam（生产适配既有客户端，测试注入桩；不新增第二套搜索实现）。
protocol OnlineSearchProviding: Sendable {
    var source: RecommendationSource { get }
    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong]
}

/// 网易云适配器（复用 `NeteaseOnlineClient.search`，不改客户端）。
struct NeteaseSearchProvider: OnlineSearchProviding {
    var client: NeteaseOnlineClient = .shared

    var source: RecommendationSource { .netease }

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        let songs = try await client.search(query: query, limit: limit)
        return songs.map {
            RecommendationRemoteSong(title: $0.title, artist: $0.artist, album: $0.album, year: nil)
        }
    }
}

/// 歌曲海适配器。
///
/// `GequhaiClient.search` 的既有语义是「失败返回 [] 不抛」，这里保持原语义；
/// `@unchecked Sendable` 的理由：客户端是值类型 + URLSession，搜索路径无共享可变状态，
/// 下载/扫码路径（Quark cookie）不经过本适配器。
final class GequhaiSearchProvider: OnlineSearchProviding, @unchecked Sendable {
    private let client: GequhaiClient

    init(client: GequhaiClient = GequhaiClient()) {
        self.client = client
    }

    var source: RecommendationSource { .gequhai }

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        let songs = await client.search(query: query, limit: limit)
        return songs.map {
            RecommendationRemoteSong(title: $0.title, artist: $0.artist, album: nil, year: nil)
        }
    }
}

// MARK: - 检索意图

struct RecommendationIntent: Sendable, Equatable {
    enum Kind: String, Sendable {
        case artist
        case decade
        case genre
    }

    var query: String
    var kind: Kind
}

/// 意图生成（纯函数）：top 艺人 ≤ 8 + 年代 ≤ 2 + 干净 genre ≤ 2，总数 ≤ 12。
enum RecommendationIntentBuilder {
    static let maxArtistIntents = 8
    static let maxDecadeIntents = 2
    static let maxGenreIntents = 2
    static let maxTotalIntents = 12
    /// 年代桶占比低于该值不生成意图（避免长尾噪声）。
    static let minimumDecadeShare = 0.2

    static func intents(from profile: TasteProfile) -> [RecommendationIntent] {
        var intents: [RecommendationIntent] = []

        for artist in profile.topArtists.prefix(maxArtistIntents) where !artist.artist.isEmpty {
            intents.append(RecommendationIntent(query: artist.artist, kind: .artist))
        }

        let dominantDecades = profile.decadeShare.filter { share in
            share.value >= minimumDecadeShare
        }
        let orderedDecades = dominantDecades.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value > rhs.value
        }
        for decade in orderedDecades.prefix(maxDecadeIntents) {
            intents.append(RecommendationIntent(query: "\(decade.key)年代", kind: .decade))
        }

        for genre in profile.topGenres.prefix(maxGenreIntents) {
            intents.append(RecommendationIntent(query: genre, kind: .genre))
        }

        return Array(intents.prefix(maxTotalIntents))
    }
}

// MARK: - 错误

enum RecommendationError: LocalizedError, Equatable {
    /// 所有在线源都失败（网络断 / 双源同时不可用）。
    case allSourcesFailed

    var errorDescription: String? {
        switch self {
        case .allSourcesFailed:
            return "recommendation_error_all_sources".localized
        }
    }
}

// MARK: - 引擎

/// 规则推荐引擎（无状态、可注入 providers；测试用桩，不打真实网络）。
struct RecommendationEngine: Sendable {
    var providers: [any OnlineSearchProviding]
    /// 每个意图每源取前 N 条。
    var perIntentLimit: Int = 10
    /// 同一艺人最多 N 首。
    var maxSongsPerArtist: Int = 2

    init(
        providers: [any OnlineSearchProviding] = [NeteaseSearchProvider(), GequhaiSearchProvider()],
        perIntentLimit: Int = 10,
        maxSongsPerArtist: Int = 2
    ) {
        self.providers = providers
        self.perIntentLimit = perIntentLimit
        self.maxSongsPerArtist = maxSongsPerArtist
    }

    func recommend(profile: TasteProfile, count: Int) async -> Result<[RecommendedCandidate], RecommendationError> {
        await recommend(
            profile: profile,
            count: count,
            intents: RecommendationIntentBuilder.intents(from: profile)
        )
    }

    /// P2：意图由 planner（规则 / 本地模型）注入；召回、去重、打分逻辑不变。
    func recommend(
        profile: TasteProfile,
        count: Int,
        intents: [RecommendationIntent]
    ) async -> Result<[RecommendedCandidate], RecommendationError> {
        guard !providers.isEmpty else { return .failure(.allSourcesFailed) }
        guard !intents.isEmpty else { return .success([]) }

        let limit = perIntentLimit
        var candidatesByKey: [String: RecommendedCandidate] = [:]
        var succeededSources = 0
        var failedAttempts = 0

        for intent in intents {
            let outcomes = await withTaskGroup(of: SourceOutcome.self) { group -> [SourceOutcome] in
                for provider in providers {
                    group.addTask {
                        do {
                            let songs = try await provider.search(query: intent.query, limit: limit)
                            return SourceOutcome(source: provider.source, songs: songs, failed: false)
                        } catch {
                            return SourceOutcome(source: provider.source, songs: [], failed: true)
                        }
                    }
                }
                var collected: [SourceOutcome] = []
                for await outcome in group {
                    collected.append(outcome)
                }
                return collected
            }

            for outcome in outcomes {
                if outcome.failed {
                    failedAttempts += 1
                    continue
                }
                succeededSources += 1
                for song in outcome.songs {
                    let key = RecommendationKey.normalize(title: song.title, artist: song.artist)
                    guard !key.hasPrefix("|"), !profile.libraryKeys.contains(key) else { continue }
                    let artistKey = RecommendationKey.primaryArtist(song.artist)
                    guard !artistKey.isEmpty else { continue }
                    guard !profile.blacklistTracks.contains(key),
                          !profile.blacklistArtists.contains(artistKey)
                    else { continue }

                    let candidate = RecommendedCandidate(
                        title: song.title,
                        artist: song.artist,
                        album: song.album,
                        year: song.year,
                        source: outcome.source
                    )
                    if let existing = candidatesByKey[key] {
                        // 同曲两源都召回：保留可靠度更高的源（网易云 > 歌曲海）。
                        if outcome.source.reliability > existing.source.reliability {
                            candidatesByKey[key] = candidate
                        }
                    } else {
                        candidatesByKey[key] = candidate
                    }
                }
            }
        }

        // 全失败（一个成功响应都没有）→ 明确错误，不假装「没找到」。
        if succeededSources == 0, failedAttempts > 0 {
            return .failure(.allSourcesFailed)
        }

        var scored: [RecommendedCandidate] = candidatesByKey.map { key, candidate in
            var scoredCandidate = candidate
            let score = RecommendationScorer.score(
                RecommendationScoreInput(
                    artist: candidate.artist,
                    year: candidate.year,
                    source: candidate.source,
                    isKnownTrack: profile.playedKeys.contains(key)
                ),
                profile: profile
            )
            scoredCandidate.score = score.total
            scoredCandidate.reasons = score.reasons
            return scoredCandidate
        }

        scored.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.title < rhs.title : lhs.score > rhs.score
        }

        var perArtistCount: [String: Int] = [:]
        var picked: [RecommendedCandidate] = []
        for candidate in scored {
            let artistKey = RecommendationKey.primaryArtist(candidate.artist)
            let used = perArtistCount[artistKey, default: 0]
            guard used < maxSongsPerArtist else { continue }
            perArtistCount[artistKey] = used + 1
            picked.append(candidate)
            if picked.count >= max(1, count) { break }
        }

        return .success(picked)
    }

    private struct SourceOutcome: Sendable {
        var source: RecommendationSource
        var songs: [RecommendationRemoteSong]
        var failed: Bool
    }
}

// MARK: - 数据源（唯一 I/O 点）

/// 从本地 DB 读画像输入（四表一次读取，再交给纯函数构建）。
///
/// 只读：不写曲库、不改 schema。读取失败返回 nil（调用方展示失败态，不编造假数据）。
enum RecommendationDataSource {
    static func loadInput(now: Date = Date(), blacklist: RecommendationBlacklist) async -> RecommendationProfileInput? {
        await Task.detached(priority: .utility) { () -> RecommendationProfileInput? in
            do {
                return try DatabaseManager.shared.read { db in
                    let tracks = try Track.fetchAll(db)
                    let artists = try Artist.fetchAll(db)
                    let albums = try Album.fetchAll(db)
                    let plays = try PlayHistoryEntry.fetchAll(db)

                    let artistNames = Dictionary(
                        artists.compactMap { artist in artist.id.map { ($0, artist.name) } },
                        uniquingKeysWith: { first, _ in first }
                    )
                    let albumInfo = Dictionary(
                        albums.compactMap { album in album.id.map { ($0, album) } },
                        uniquingKeysWith: { first, _ in first }
                    )

                    let trackInfos = tracks.map { track in
                        let album = track.albumId.flatMap { albumInfo[$0] }
                        return RecommendationProfileInput.TrackInfo(
                            stableId: track.stableId,
                            title: track.title,
                            artist: track.artistId.flatMap { artistNames[$0] } ?? "",
                            album: album?.title,
                            year: album?.year,
                            durationMs: track.durationMs,
                            genre: track.genre
                        )
                    }

                    let playRows = plays.map { play in
                        RecommendationProfileInput.Play(
                            trackStableId: play.trackStableId,
                            playedAt: Date(timeIntervalSince1970: TimeInterval(play.playedAt)),
                            playDurationMs: play.playDurationMs
                        )
                    }

                    return RecommendationProfileInput(
                        plays: playRows,
                        tracks: trackInfos,
                        blacklist: blacklist,
                        now: now
                    )
                }
            } catch {
                AppLog.error(.general, "❌ 推荐画像读取失败：\(error)")
                return nil
            }
        }.value
    }
}
