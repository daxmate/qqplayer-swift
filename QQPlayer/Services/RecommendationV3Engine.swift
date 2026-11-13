//
//  RecommendationV3Engine.swift
//  QQPlayer
//
//  推荐 v3：三通道召回（A 种子艺人热歌 / B 相似艺人热歌 / C 风格探索）+ 过滤 + 排序。
//
//  降级链（任一环失败都静默降级，不影响其它通道）：
//    A：Last.fm artist.gettoptracks → 现有在线源 search(艺人)
//    B：Last.fm artist.getsimilar → MusicBrainz 相关艺人 → 现有在线源 search(艺人)
//    C：现有在线源 search(genre) + 本地年代 / 语种过滤
//
//  额外通道：用户点名 / 指令输入仍走既有 RecommendationEngine（不占配额）。
//

import Foundation

/// 相似艺人来源抽象（Last.fm 之外的降级源，如 MusicBrainz）。
protocol SimilarArtistProviding: Sendable {
    func similarArtists(to artist: String, limit: Int) async -> [LastFMArtist]
}

struct MusicBrainzSimilarArtistSource: SimilarArtistProviding {
    var client: MusicBrainzClient = MusicBrainzClient()

    func similarArtists(to artist: String, limit: Int) async -> [LastFMArtist] {
        do {
            let names = try await client.relatedArtists(for: artist, limit: limit)
            return names.map { LastFMArtist(name: $0, match: nil) }
        } catch {
            return []
        }
    }
}

struct RecommendationV3Engine: Sendable {
    /// 在线搜索源（复用现有降级链；测试注入桩）。
    var providers: [any OnlineSearchProviding]
    var lastFM: LastFMClient?
    /// 网易云客户端（A 通道中文歌手主源：艺人热歌接口；nil = 只用通用搜索）。
    var netease: NeteaseOnlineClient?
    var similarArtistSource: (any SimilarArtistProviding)?
    /// iTunes 元数据标准化（B；nil = 跳过）。
    var metadataNormalizer: RecommendationMetadataNormalizer?
    /// iTunes 调用预算（与标准化共用；每轮 beginRun 重置）。
    var itunesBudget: RecommendationRunBudget?
    /// 榜单热度参照（C；只当热度，不当相似源）。
    var chartClient: AppleMusicChartClient?
    var quotas: RecommendationChannelQuotas = .defaults
    var perSourceLimit: Int = 10
    /// A 通道最多探测多少个种子艺人。
    var maxSeedArtists: Int = 8
    /// B 通道最多为多少个种子艺人找相似。
    var maxSimilarSeeds: Int = 3
    var maxSimilarPerSeed: Int = 3
    /// C 通道最多探测多少个风格簇。
    var maxClusters: Int = 3

    init(
        providers: [any OnlineSearchProviding]? = nil,
        lastFM: LastFMClient? = nil,
        netease: NeteaseOnlineClient? = nil,
        similarArtistSource: (any SimilarArtistProviding)? = nil,
        metadataNormalizer: RecommendationMetadataNormalizer? = nil,
        itunesBudget: RecommendationRunBudget? = nil,
        chartClient: AppleMusicChartClient? = nil
    ) {
        if let providers {
            self.providers = providers
        } else {
            let budget = RecommendationRunBudget()
            let audit = RecommendationChainAudit()
            self.providers = [RecommendationSourceChain.defaultProvider(budget: budget, audit: audit)]
        }
        self.lastFM = lastFM
        self.netease = netease
        self.similarArtistSource = similarArtistSource
        self.metadataNormalizer = metadataNormalizer
        self.itunesBudget = itunesBudget
        self.chartClient = chartClient
    }

    /// 生产接线（Settings 读取配额）。
    static func configured(_ settings: DeleteSettings = .load()) -> RecommendationV3Engine {
        let budget = RecommendationRunBudget(maxITunesCalls: settings.recommendationV3.itunesLookupLimit)
        let iTunes = ITunesRecommendationProvider(storefront: "us", budget: budget)
        var engine = RecommendationV3Engine(
            lastFM: LastFMClient(),
            netease: .shared,
            similarArtistSource: MusicBrainzSimilarArtistSource(),
            metadataNormalizer: RecommendationMetadataNormalizer(
                provider: iTunes,
                maxLookups: settings.recommendationV3.itunesLookupLimit
            ),
            itunesBudget: budget,
            chartClient: AppleMusicChartClient()
        )
        engine.quotas = settings.recommendationChannelQuotas
        return engine
    }

    // MARK: - 入口

    func recommend(
        profile: RecommendationTasteProfileV3,
        count: Int,
        excludedTrackKeys: Set<String> = []
    ) async -> Result<[RecommendedCandidate], RecommendationError> {
        guard !profile.isEmpty else { return .success([]) }
        let target = max(1, count)
        await itunesBudget?.beginRun(maxITunesCalls: metadataNormalizer?.maxLookups ?? 0)

        var pool: [RecommendationV3Candidate] = []
        pool.append(contentsOf: await recallSeedChannel(profile: profile))
        pool.append(contentsOf: await recallSimilarChannel(profile: profile))
        let chartIndex = await chartClient?.index()
        pool.append(contentsOf: await recallExploreChannel(profile: profile, chartIndex: chartIndex))

        // iTunes 元数据标准化：只补高分段（缓存 + 限速 + 预算内），失败不阻塞。
        var metadataHits = 0
        if let metadataNormalizer {
            let normalized = await metadataNormalizer.normalize(pool, profile: profile)
            pool = normalized.candidates
            metadataHits = normalized.hits
        }

        var effectiveProfile = profile
        effectiveProfile.libraryKeys.formUnion(excludedTrackKeys)
        let ranked = RecommendationRankerV3.rank(pool, profile: effectiveProfile)
        guard !ranked.isEmpty else { return .success([]) }

        let allocation = quotas.allocation(total: target)
        let picked = select(ranked, allocation: allocation, total: target)
        AppLog.info(
            .general,
            "reco=v3 seeds=\(profile.seeds.count) clusters=\(profile.clusters.count) pooled=\(pool.count) normalized=\(metadataHits) ranked=\(ranked.count) picked=\(picked.count) alloc=\(allocation.seed)/\(allocation.similar)/\(allocation.explore)"
        )
        return .success(picked.map { convert($0) })
    }

    /// 配额选择：先按通道各取配额内最高分，再用全局排序补满；全程按归一化键去重。
    private func select(
        _ ranked: [RecommendationV3Candidate],
        allocation: (seed: Int, similar: Int, explore: Int),
        total: Int
    ) -> [RecommendationV3Candidate] {
        var picked: [RecommendationV3Candidate] = []
        var used = Set<String>()
        let planned: [(RecommendationChannel, Int)] = [
            (.seed, allocation.seed),
            (.similar, allocation.similar),
            (.explore, allocation.explore),
        ]
        for (channel, quota) in planned where quota > 0 {
            var taken = 0
            for candidate in ranked where candidate.context.channel == channel && taken < quota {
                guard used.insert(candidate.libraryKey).inserted else { continue }
                picked.append(candidate)
                taken += 1
            }
        }
        if picked.count < total {
            for candidate in ranked where picked.count < total {
                guard used.insert(candidate.libraryKey).inserted else { continue }
                picked.append(candidate)
            }
        }
        return picked
    }

    private func convert(_ candidate: RecommendationV3Candidate) -> RecommendedCandidate {
        var result = RecommendedCandidate(
            title: candidate.song.title,
            artist: candidate.song.artist,
            album: candidate.song.album,
            year: candidate.song.year,
            source: candidate.song.source ?? .netease
        )
        result.score = candidate.score
        result.genre = candidate.context.genre
        result.channel = candidate.context.channel
        result.seedArtist = candidate.context.seedArtist
        result.language = candidate.context.language
        result.reasons = RecommendationReasonV3.reason(for: candidate).map { [$0] } ?? []
        return result
    }

    // MARK: - 召回

    /// A：种子艺人热歌。
    private func recallSeedChannel(profile: RecommendationTasteProfileV3) async -> [RecommendationV3Candidate] {
        var out: [RecommendationV3Candidate] = []
        for seed in profile.seeds.prefix(maxSeedArtists) {
            let songs = await artistTopSongs(artist: seed.artist)
            for (index, song) in songs.enumerated() {
                let language = RecommendationLanguageDetector.detect(in: [song.artist, song.title])
                out.append(
                    RecommendationV3Candidate(
                        song: song,
                        context: RecommendationCandidateContext(
                            channel: .seed,
                            seedArtist: seed.artist,
                            popularity: song.popularity ?? popularity(rank: index, count: songs.count),
                            language: language,
                            year: song.year,
                            affinity: seed.affinity
                        ),
                        sourceRank: index
                    )
                )
            }
        }
        return out
    }

    /// B：相似艺人热歌。
    private func recallSimilarChannel(profile: RecommendationTasteProfileV3) async -> [RecommendationV3Candidate] {
        var out: [RecommendationV3Candidate] = []
        for seed in profile.seeds.prefix(maxSimilarSeeds) {
            let similar = await similarArtists(to: seed.artist, limit: maxSimilarPerSeed)
            for related in similar.prefix(maxSimilarPerSeed) {
                guard !isSameArtist(related.name, seed.artist) else { continue }
                let songs = await artistTopSongs(artist: related.name)
                for (index, song) in songs.enumerated() {
                    let language = RecommendationLanguageDetector.detect(in: [song.artist, song.title])
                    out.append(
                        RecommendationV3Candidate(
                            song: song,
                            context: RecommendationCandidateContext(
                                channel: .similar,
                                seedArtist: seed.artist,
                                similarity: related.match,
                                popularity: song.popularity ?? popularity(rank: index, count: songs.count),
                                language: language,
                                year: song.year,
                                affinity: seed.affinity
                            ),
                            sourceRank: index
                        )
                    )
                }
            }
        }
        return out
    }

    /// C：风格探索（同簇的其他艺人；不跨语种）。
    private func recallExploreChannel(
        profile: RecommendationTasteProfileV3,
        chartIndex: ChartPopularityIndex?
    ) async -> [RecommendationV3Candidate] {
        let seedArtists = Set(profile.seeds.map { RecommendationLibraryMatcher.artistKey($0.artist) })
        var out: [RecommendationV3Candidate] = []
        for cluster in profile.clusters.prefix(maxClusters) {
            let songs = await search(query: cluster.genre, limit: perSourceLimit)
            for (index, song) in songs.enumerated() {
                let language = RecommendationLanguageDetector.detect(in: [song.artist, song.title])
                // 不跨语种：簇语言已知时必须一致。
                if cluster.language != .unknown, language != .unknown, language != cluster.language { continue }
                // 同簇的其他艺人：种子艺人的曲目不算探索。
                if seedArtists.contains(RecommendationLibraryMatcher.artistKey(song.artist)) { continue }
                if let decade = cluster.decade,
                   let year = song.year,
                   RecommendationProfileV3Builder.decadeStart(year) != decade { continue }
                out.append(
                    RecommendationV3Candidate(
                        song: song,
                        context: RecommendationCandidateContext(
                            channel: .explore,
                            seedArtist: nil,
                            popularity: explorePopularity(
                                song: song,
                                rank: index,
                                count: songs.count,
                                chartIndex: chartIndex
                            ),
                            language: language,
                            year: song.year,
                            affinity: max(0.2, cluster.share),
                            genre: cluster.genre
                        ),
                        sourceRank: index
                    )
                )
            }
        }
        return out
    }

    /// 探索通道热度：来源热度 / 榜单热度取高者，再退回名次归一（C：榜单只当热度参照）。
    private func explorePopularity(
        song: RecommendationRemoteSong,
        rank: Int,
        count: Int,
        chartIndex: ChartPopularityIndex?
    ) -> Double {
        let chart = chartIndex?.popularity(songID: song.songID, title: song.title, artist: song.artist)
        let ranked = popularity(rank: rank, count: count)
        return [song.popularity ?? 0, chart ?? 0, ranked].max() ?? ranked
    }

    // MARK: - 来源适配（降级链）

    /// 艺人热歌：中文歌手优先网易云（实测 Last.fm 中文曲名映射脏），西文歌手优先 Last.fm。
    /// 两者都失败再降级通用搜索。
    private func artistTopSongs(artist: String) async -> [RecommendationRemoteSong] {
        if isCJKArtist(artist) {
            if let songs = await neteaseTopSongs(artist: artist) { return songs }
            if let songs = await lastFMTopSongs(artist: artist) { return songs }
        } else {
            if let songs = await lastFMTopSongs(artist: artist) { return songs }
            // 西文：iTunes Search（链内 tw/us 优先）在通用搜索里，先于网易云。
            let generic = await search(query: artist, limit: perSourceLimit)
            if !generic.isEmpty { return generic }
            if let songs = await neteaseTopSongs(artist: artist) { return songs }
        }
        return await search(query: artist, limit: perSourceLimit)
    }

    /// Last.fm 艺人的热歌（无 key / 空结果 → nil）。
    private func lastFMTopSongs(artist: String) async -> [RecommendationRemoteSong]? {
        guard let lastFM else { return nil }
        let tracks = await lastFM.topTracks(artist: artist, limit: perSourceLimit)
        guard !tracks.isEmpty else { return nil }
        let total = tracks.count
        return tracks.enumerated().map { index, track in
            RecommendationRemoteSong(
                title: track.title,
                artist: track.artist.isEmpty ? artist : track.artist,
                album: track.album,
                durationMs: track.durationMs,
                source: .lastfm,
                popularity: popularity(rank: index, count: total)
            )
        }
    }

    /// 网易云艺人热歌（无客户端 / 失败 / 空结果 → nil；`pop` 直接当热度）。
    private func neteaseTopSongs(artist: String) async -> [RecommendationRemoteSong]? {
        guard let netease else { return nil }
        guard let songs = try? await netease.artistTopSongs(artistName: artist, limit: perSourceLimit),
              !songs.isEmpty
        else { return nil }
        return songs.map { song in
            RecommendationRemoteSong(
                title: song.title,
                artist: song.artist.isEmpty ? artist : song.artist,
                album: song.album,
                songID: song.id,
                durationMs: song.durationMs,
                source: .netease,
                popularity: song.popularity
            )
        }
    }

    /// 中日韩文字（决定热歌主源：中文优先网易云，西文优先 Last.fm）。
    private func isCJKArtist(_ name: String) -> Bool {
        for scalar in name.unicodeScalars {
            let value = scalar.value
            if (0x3040 ... 0x30FF).contains(value) || (0x4E00 ... 0x9FFF).contains(value) || (0xAC00 ... 0xD7AF).contains(value) {
                return true
            }
        }
        return false
    }

    /// 相似艺人：Last.fm → MusicBrainz。
    private func similarArtists(to artist: String, limit: Int) async -> [LastFMArtist] {
        if let lastFM {
            let related = await lastFM.similarArtists(artist: artist, limit: limit)
            if !related.isEmpty { return related }
        }
        if let similarArtistSource {
            return await similarArtistSource.similarArtists(to: artist, limit: limit)
        }
        return []
    }

    /// 现有在线源（多源按顺序取第一个非空结果的聚合语义）。
    private func search(query: String, limit: Int) async -> [RecommendationRemoteSong] {
        for provider in providers {
            if let songs = try? await provider.search(query: query, limit: limit), !songs.isEmpty {
                return songs
            }
        }
        return []
    }

    private func popularity(rank: Int, count: Int) -> Double {
        guard count > 1 else { return rank == 0 ? 1 : 0.5 }
        return max(0.1, 1.0 - Double(rank) / Double(count))
    }

    private func isSameArtist(_ lhs: String, _ rhs: String) -> Bool {
        RecommendationLibraryMatcher.artistKey(lhs) == RecommendationLibraryMatcher.artistKey(rhs)
    }
}
