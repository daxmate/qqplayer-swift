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
    /// 在线源歌曲 ID（相似歌曲召回用；给不出就是 nil）。
    var songID: Int?
    /// 时长（毫秒；歌单 / 串烧过滤用；给不出就是 nil）。
    var durationMs: Int?

    init(
        title: String,
        artist: String,
        album: String? = nil,
        year: Int? = nil,
        songID: Int? = nil,
        durationMs: Int? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.songID = songID
        self.durationMs = durationMs
    }
}

/// 在线搜索 seam（生产适配既有客户端，测试注入桩；不新增第二套搜索实现）。
protocol OnlineSearchProviding: Sendable {
    var source: RecommendationSource { get }
    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong]
}

/// 网易云适配器（复用 `NeteaseOnlineClient.search`，不改客户端）。
struct NeteaseSearchProvider: OnlineSearchProviding, SimilarSongProviding {
    var client: NeteaseOnlineClient = .shared

    var source: RecommendationSource { .netease }

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        let songs = try await client.search(query: query, limit: limit)
        return songs.map {
            RecommendationRemoteSong(
                title: $0.title, artist: $0.artist, album: $0.album, year: nil,
                songID: $0.id, durationMs: $0.durationMs
            )
        }
    }

    /// 相似歌曲（网易云 eapi）；不可用时抛错，由引擎降级到同艺人热歌。
    func similarSongs(songID: Int, limit: Int) async throws -> [RecommendationRemoteSong] {
        let songs = try await client.similarSongs(songID: songID, limit: limit)
        return songs.map {
            RecommendationRemoteSong(
                title: $0.title, artist: $0.artist, album: $0.album, year: nil,
                songID: $0.id, durationMs: $0.durationMs
            )
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

// MARK: - 错误

enum RecommendationError: LocalizedError, Equatable {
    /// 所有在线源都失败（网络断 / 双源同时不可用）。
    case allSourcesFailed
    /// 指令输入没有解析出任何有效条件（提示用户换个说法，不退回画像推荐）。
    case emptyRequest

    var errorDescription: String? {
        switch self {
        case .allSourcesFailed:
            return "recommendation_error_all_sources".localized
        case .emptyRequest:
            return "recommendation_empty_request".localized
        }
    }
}

// MARK: - 相似歌曲召回契约

/// 可选能力：支持「相似歌曲」的在线源（当前只有网易云）。
///
/// 接口不可用（匿名态未登录 / 改版）时必须抛错或返回空；引擎运行时探测后整轮降级，
/// 绝不阻塞主召回链路。
protocol SimilarSongProviding: Sendable {
    func similarSongs(songID: Int, limit: Int) async throws -> [RecommendationRemoteSong]
}

// MARK: - 引擎

/// 规则推荐引擎（无状态、可注入 providers；测试用桩，不打真实网络）。
struct RecommendationEngine: Sendable {
    var providers: [any OnlineSearchProviding]
    /// 每个意图每源取前 N 条。
    var perIntentLimit: Int = 10
    /// 同一艺人最多 N 首。
    var maxSongsPerArtist: Int = 2
    /// 单个意图最多贡献 N 条（来源多样性）。
    var maxSongsPerIntent: Int = 4
    /// 单一在线源最多占最终列表的比例。
    var maxSourceShare: Double = 0.7
    /// 是否尝试相似歌曲召回（接口不可用时自动降级）。
    var similarRecallEnabled: Bool = true
    /// 最多对几个艺人意图做相似召回（限制请求放大）。
    var maxSimilarProbes: Int = 3

    init(
        providers: [any OnlineSearchProviding] = [NeteaseSearchProvider(), GequhaiSearchProvider()],
        perIntentLimit: Int = 10,
        maxSongsPerArtist: Int = 2
    ) {
        self.providers = providers
        self.perIntentLimit = perIntentLimit
        self.maxSongsPerArtist = maxSongsPerArtist
    }

    func recommend(
        profile: TasteProfile,
        count: Int
    ) async -> Result<[RecommendedCandidate], RecommendationError> {
        await recommend(
            profile: profile,
            count: count,
            intents: RecommendationIntentBuilder.intents(from: profile)
        )
    }

    /// P2：意图由 planner（规则 / 本地模型）注入；召回、打分、理由逻辑不变。
    func recommend(
        profile: TasteProfile,
        count: Int,
        intents: [RecommendationIntent]
    ) async -> Result<[RecommendedCandidate], RecommendationError> {
        guard !providers.isEmpty else { return .failure(.allSourcesFailed) }
        guard !intents.isEmpty else { return .success([]) }

        let gathered = await gather(profile: profile, intents: intents)
        if gathered.items.isEmpty {
            // 一个成功响应都没有、且有失败尝试 → 明确错误，不假装「没找到」。
            return gathered.allFailed ? .failure(.allSourcesFailed) : .success([])
        }

        let ranked = rank(gathered.items, profile: profile)
        let picked = select(ranked, count: count, profile: profile)
        return .success(picked)
    }

    /// 指令输入：显式条件优先于画像；召回 / 打分 / 去重 / 多样性上限全部复用。
    func recommend(
        request: RecommendationUserRequest,
        profile: TasteProfile,
        count: Int
    ) async -> Result<[RecommendedCandidate], RecommendationError> {
        guard !request.isEmpty else { return .failure(.emptyRequest) }
        let intents = RecommendationIntentBuilder.intents(from: request, profile: profile)
        guard !intents.isEmpty else { return .failure(.emptyRequest) }
        guard !providers.isEmpty else { return .failure(.allSourcesFailed) }

        let excluded = Set(
            request.excludeArtists
                .map { RecommendationKey.primaryArtist($0) }
                .filter { !$0.isEmpty }
        )
        let gathered = await gather(profile: profile, intents: intents, excludedArtists: excluded)
        if gathered.items.isEmpty {
            return gathered.allFailed ? .failure(.allSourcesFailed) : .success([])
        }

        let ranked = rank(gathered.items, profile: profile)
        let picked = select(ranked, count: count, profile: profile)
        return .success(picked)
    }

    // MARK: 召回

    private struct GatheredItem: Sendable {
        var song: RecommendationRemoteSong
        var source: RecommendationSource
        var intent: RecommendationIntent
    }

    private struct GatherResult: Sendable {
        var items: [GatheredItem]
        var allFailed: Bool
    }

    private struct SourceOutcome: Sendable {
        var source: RecommendationSource
        var songs: [RecommendationRemoteSong]
        var failed: Bool
    }

    private func gather(
        profile: TasteProfile,
        intents: [RecommendationIntent],
        excludedArtists: Set<String> = []
    ) async -> GatherResult {
        var items: [GatheredItem] = []
        var indexByKey: [String: Int] = [:]
        var failedAttempts = 0
        var succeededSources = 0

        func accept(_ song: RecommendationRemoteSong, source: RecommendationSource, intent: RecommendationIntent) {
            guard !song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let artistKey = RecommendationKey.primaryArtist(song.artist)
            guard !artistKey.isEmpty else { return }
            let key = RecommendationKey.normalize(title: song.title, artist: song.artist)
            guard !profile.libraryKeys.contains(key),
                  !profile.blacklistTracks.contains(key),
                  !profile.blacklistArtists.contains(artistKey),
                  !excludedArtists.contains(artistKey)
            else { return }
            guard !RecommendationCandidateFilter.isLikelyNonSong(song) else { return }

            if let existing = indexByKey[key] {
                // 同曲两源都召回：保留可靠度更高的源。
                if source.reliability > items[existing].source.reliability {
                    items[existing].source = source
                }
                return
            }
            indexByKey[key] = items.count
            items.append(GatheredItem(song: song, source: source, intent: intent))
        }

        for intent in intents {
            let outcomes = await searchAll(query: intent.query, limit: perIntentLimit)
            for outcome in outcomes {
                if outcome.failed {
                    failedAttempts += 1
                    continue
                }
                succeededSources += 1
                for song in outcome.songs {
                    accept(song, source: outcome.source, intent: intent)
                }
            }
        }

        // 相似歌曲：运行时特性探测——第一次不可用就整轮放弃，回落到同艺人热歌。
        if similarRecallEnabled {
            var probes = 0
            var similarUnavailable = false
            for intent in intents where intent.kind == .artist {
                guard probes < maxSimilarProbes, !similarUnavailable else { break }
                guard let seed = seedSongID(for: intent, in: items) else { continue }
                probes += 1
                let outcomes = await similarAll(songID: seed, limit: perIntentLimit)
                let usable = outcomes.filter { !$0.failed && !$0.songs.isEmpty }
                guard !usable.isEmpty else {
                    similarUnavailable = true
                    continue
                }
                let similarIntent = RecommendationIntent(
                    query: intent.query,
                    kind: .similar,
                    artist: intent.artist,
                    decade: intent.decade,
                    genre: intent.genre
                )
                for outcome in usable {
                    for song in outcome.songs {
                        accept(song, source: outcome.source, intent: similarIntent)
                    }
                }
            }
        }

        let allFailed = succeededSources == 0 && failedAttempts > 0
        return GatherResult(items: items, allFailed: allFailed)
    }

    private func seedSongID(for intent: RecommendationIntent, in items: [GatheredItem]) -> Int? {
        let artistKey = RecommendationKey.primaryArtist(intent.artist ?? intent.query)
        let sameArtist = items.first {
            $0.song.songID != nil
                && RecommendationKey.primaryArtist($0.song.artist) == artistKey
                && $0.intent.kind != .similar
        }
        return sameArtist?.song.songID
    }

    private func searchAll(query: String, limit: Int) async -> [SourceOutcome] {
        let providers = self.providers
        return await withTaskGroup(of: SourceOutcome.self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let songs = try await provider.search(query: query, limit: limit)
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
    }

    private func similarAll(songID: Int, limit: Int) async -> [SourceOutcome] {
        let providers = self.providers
        return await withTaskGroup(of: SourceOutcome.self) { group in
            for provider in providers {
                guard let similar = provider as? any SimilarSongProviding else { continue }
                group.addTask {
                    do {
                        let songs = try await similar.similarSongs(songID: songID, limit: limit)
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
    }

    // MARK: 重排

    private struct RankedItem: Sendable {
        var item: GatheredItem
        var score: Double
    }

    private func rank(_ items: [GatheredItem], profile: TasteProfile) -> [RankedItem] {
        items.map { item in
            let key = RecommendationKey.normalize(title: item.song.title, artist: item.song.artist)
            let score = RecommendationScorer.score(
                RecommendationScoreInput(
                    artist: item.song.artist,
                    year: item.song.year,
                    source: item.source,
                    isKnownTrack: profile.playedKeys.contains(key)
                ),
                profile: profile
            )
            return RankedItem(item: item, score: score.total + intentBoost(item.intent))
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.item.song.title.localizedStandardCompare(rhs.item.song.title) == .orderedAscending
            }
            return lhs.score > rhs.score
        }
    }

    /// 意图置信度加成：相似 > 同艺人 > 年代 > 曲风（越具体越靠前）。
    private func intentBoost(_ intent: RecommendationIntent) -> Double {
        switch intent.kind {
        case .similar: return 0.08
        case .artist: return 0.06
        case .keyword: return 0.06
        case .decade: return 0.04
        case .genre: return 0.03
        }
    }

    private func intentKey(_ intent: RecommendationIntent) -> String {
        "\(intent.kind.rawValue)|\(intent.query.lowercased())"
    }

    // MARK: 选取（上限 + 多样性）

    private func select(_ ranked: [RankedItem], count: Int, profile: TasteProfile) -> [RecommendedCandidate] {
        let target = max(1, count)
        let perIntentCap = max(2, min(maxSongsPerIntent, target / 3 + 1))
        let perSourceCap = max(1, Int((Double(target) * maxSourceShare).rounded(.up)))
        let perArtistCap = max(1, maxSongsPerArtist)

        var artistCounts: [String: Int] = [:]
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
            intentCounts[intentKey(item.item.intent), default: 0] += 1
            sourceCounts[item.item.source, default: 0] += 1
            usedKeys.insert(key)

            let reasons = reasonsFor(item.item, previousPrimary: previousPrimary)
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
                if pass == 0 {
                    if intentCounts[intentKey(item.item.intent), default: 0] >= perIntentCap { continue }
                    if sourceCounts[item.item.source, default: 0] >= perSourceCap { continue }
                }
                take(item)
            }
        }

        return picked
    }

    /// 逐曲理由：由**产生该候选的意图**生成；相邻行首条理由不能相同。
    private func reasonsFor(_ item: GatheredItem, previousPrimary: String?) -> [String] {
        var reasons: [String] = []
        let display = RecommendationKey.displayPrimaryArtist(item.intent.artist ?? item.song.artist)

        switch item.intent.kind {
        case .artist:
            if !display.isEmpty {
                reasons.append("recommendation_reason_artist".localized(with: display))
            }
        case .similar:
            if !display.isEmpty {
                reasons.append("recommendation_reason_similar_artist".localized(with: display))
            }
        case .decade:
            if let decade = item.intent.decade {
                reasons.append("recommendation_reason_era".localized(with: decade))
            }
        case .genre:
            if let genre = item.intent.genre, !genre.isEmpty {
                reasons.append("recommendation_reason_genre".localized(with: genre))
            }
        case .keyword:
            if !item.intent.query.isEmpty {
                reasons.append("recommendation_reason_request".localized(with: item.intent.query))
            }
        }

        if let year = item.song.year {
            let decade = RecommendationScorer.decadeBucket(for: year)
            if item.intent.decade != decade {
                reasons.append("recommendation_reason_era".localized(with: decade))
            }
        }

        var unique: [String] = []
        for reason in reasons where !unique.contains(reason) {
            unique.append(reason)
        }
        if unique.isEmpty {
            unique.append("recommendation_reason_matched_taste".localized)
        }

        if let previousPrimary, unique.first == previousPrimary {
            if unique.count > 1 {
                unique.removeFirst()
            } else {
                unique = ["recommendation_reason_matched_taste".localized]
            }
        }

        return Array(unique.prefix(2))
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
