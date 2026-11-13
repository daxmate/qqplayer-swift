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

// MARK: - 引擎

/// 规则推荐引擎（无状态、可注入 providers；测试用桩，不打真实网络）。
struct RecommendationEngine: Sendable {
    var providers: [any OnlineSearchProviding]
    /// P2：降级 / iTunes 调用预算（默认链自带；显式注入 providers 时为 nil）。
    var runBudget: RecommendationRunBudget?
    /// P2：降级链诊断（summary 日志用）。
    var chainAudit: RecommendationChainAudit?
    /// 每个意图每源取前 N 条。
    var perIntentLimit: Int = 10
    /// 同一艺人最多 N 首。
    var maxSongsPerArtist: Int = 2
    /// 同一专辑最多 N 首（nil = 不限；P2 池构建传 2）。
    var maxSongsPerAlbum: Int?
    /// 单个意图最多贡献 N 条（来源多样性）。
    var maxSongsPerIntent: Int = 4
    /// 单一在线源最多占最终列表的比例。
    var maxSourceShare: Double = 0.7
    /// 是否尝试相似歌曲召回（接口不可用时自动降级）。
    var similarRecallEnabled: Bool = true
    /// 最多对几个艺人意图做相似召回（限制请求放大）。
    var maxSimilarProbes: Int = 3
    /// P4：MusicBrainz 艺人关系扩展（nil = 关：零额外请求，召回行为与 P3 完全一致）。
    var artistRelation: RecommendationArtistRelation?
    /// 点名场景的关系扩展兜底（设置为关也启用，用于相似补位）；nil = 不自动启用（测试默认）。
    var namedArtistRelationFallback: RecommendationArtistRelation?
    /// 点名场景的相似补位比例（0...0.5，默认 0.30）：相似名额 = round(target × share)。
    var relatedArtistShare: Double = DeleteSettings.defaultRelatedArtistShare
    /// 榜单热度客户端（nil = 不取榜单，热度恒为中性 0.5；测试默认 nil，生产由 `configured()` 接线）。
    var chartClient: AppleMusicChartClient?

    /// 默认 = P2 主源降级链（iTunes tw → us → MusicBrainz → 网易云）；
    /// 测试注入 providers 时预算 / 诊断不接线（行为与 P1 相同）。
    init(
        providers: [any OnlineSearchProviding]? = nil,
        perIntentLimit: Int = 10,
        maxSongsPerArtist: Int = 2,
        maxSongsPerAlbum: Int? = nil
    ) {
        if let providers {
            self.providers = providers
            runBudget = nil
            chainAudit = nil
        } else {
            let budget = RecommendationRunBudget()
            let audit = RecommendationChainAudit()
            self.providers = [RecommendationSourceChain.defaultProvider(budget: budget, audit: audit)]
            runBudget = budget
            chainAudit = audit
        }
        self.perIntentLimit = perIntentLimit
        self.maxSongsPerArtist = maxSongsPerArtist
        self.maxSongsPerAlbum = maxSongsPerAlbum
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
    ///
    /// P1 观测：一次推荐产出一条 summary（管线边界打点，不绑定具体在线源）。
    func recommend(
        profile: TasteProfile,
        count: Int,
        intents: [RecommendationIntent],
        planSource: RecommendationPlanSource? = nil,
        excludedTrackKeys: Set<String> = []
    ) async -> Result<[RecommendedCandidate], RecommendationError> {
        await runBudget?.beginRun()
        chainAudit?.reset()
        await artistRelation?.beginRun()
        let context = RecommendationRunContext(
            requestText: intents.map(\.query).joined(separator: ","),
            planSource: planSource
        )
        if providers.isEmpty {
            logRunSummary(
                context: context, intents: intents, gathered: nil,
                finalCount: 0, targetCount: count
            )
            return .failure(.allSourcesFailed)
        }
        guard !intents.isEmpty else {
            logRunSummary(
                context: context, intents: [], gathered: nil,
                finalCount: 0, targetCount: count
            )
            return .success([])
        }

        let gathered = await gather(profile: profile, intents: intents, excludedTrackKeys: excludedTrackKeys)
        if gathered.items.isEmpty {
            logRunSummary(
                context: context, intents: intents, gathered: gathered,
                finalCount: 0, targetCount: count
            )
            // 一个成功响应都没有、且有失败尝试 → 明确错误，不假装「没找到」。
            return gathered.allFailed ? .failure(.allSourcesFailed) : .success([])
        }

        // 热度只取一次（跨意图共享）：客户端自带 run 级 memo + 6 小时缓存，失败静默为空榜单。
        let chartIndex = await currentChartIndex()
        logChartPopularity(index: chartIndex, items: gathered.items)
        let ranked = rank(gathered.items, profile: profile, chartIndex: chartIndex)
        let picked = select(ranked, count: count, profile: profile)
        logRunSummary(
            context: context, intents: intents, gathered: gathered,
            finalCount: picked.count, targetCount: count
        )
        return .success(picked)
    }

    // MARK: 召回

    struct GatheredItem: Sendable {
        var song: RecommendationRemoteSong
        var source: RecommendationSource
        var intent: RecommendationIntent
        /// 相似补位来源（nil = 本人匹配行）：点名场景里「相关艺人」召回的行带此标记。
        var relatedTo: String?
    }

    struct GatherResult: Sendable {
        var items: [GatheredItem]
        var allFailed: Bool
        /// 观测（P1）：每源 成功 / 失败 / 条数。
        var sourceStats: [RecommendationSourceStat] = []
        /// 观测（P1）：每道闸的 in/out，顺序见 gateOrder。
        var gateStats: [RecommendationGateStat] = []
        /// 观测（P1）：准入闸拒绝原因计数（原因 rawValue → 次数）。
        var rejectionCounts: [String: Int] = [:]
        /// 观测（P1）：**只计数不拒绝**的标记（维度 rawValue → 次数，目前只有 missing_song_id）。
        var flaggedCounts: [String: Int] = [:]
    }

    private struct SourceOutcome: Sendable {
        var source: RecommendationSource
        var songs: [RecommendationRemoteSong]
        var failed: Bool
    }

    func gather(
        profile: TasteProfile,
        intents: [RecommendationIntent],
        excludedArtists: Set<String> = [],
        artistConstraint: RecommendationArtistConstraint? = nil,
        excludedTrackKeys: Set<String> = []
    ) async -> GatherResult {
        var items: [GatheredItem] = []
        var indexByKey: [String: Int] = [:]
        var failedAttempts = 0
        var succeededSources = 0
        var rejectedByArtist = 0
        var gateStats: [String: (inCount: Int, outCount: Int)] = [:]
        var rejectionCounts: [String: Int] = [:]
        var flaggedCounts: [String: Int] = [:]
        var sourceStats: [RecommendationSource: (ok: Int, failed: Int, songs: Int)] = [:]

        // 观测（P1）：每道闸的进/出。候选按序过闸，前面的闸不过就不会走到后面的闸（漏斗口径）。
        func passGate(_ name: String, _ passes: Bool) -> Bool {
            var stat = gateStats[name] ?? (inCount: 0, outCount: 0)
            stat.inCount += 1
            if !passes { stat.outCount += 1 }
            gateStats[name] = stat
            return passes
        }

        func recordSource(_ outcome: SourceOutcome) {
            var stat = sourceStats[outcome.source] ?? (ok: 0, failed: 0, songs: 0)
            if outcome.failed {
                stat.failed += 1
            } else {
                stat.ok += 1
                stat.songs += outcome.songs.count
            }
            sourceStats[outcome.source] = stat
        }

        func accept(
            _ song: RecommendationRemoteSong,
            providerSource: RecommendationSource,
            intent: RecommendationIntent,
            relatedTo: String? = nil
        ) {
            // 降级链结果自带真实来源（song.source）；provider 的 source 只是原级归属。
            let source = song.source ?? providerSource
            let artistKey = RecommendationKey.primaryArtist(song.artist)
            let hasFields = !song.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !artistKey.isEmpty
            guard passGate("fields", hasFields) else { return }
            // 歌曲 ID 缺失只是 flagged（不拒绝）：歌曲海源全量无 id，该字段不是「是不是单曲」的判据。
            if song.songID == nil {
                flaggedCounts[RecommendationAdmissionRejection.missingSongID.rawValue, default: 0] += 1
            }
            // 点名艺人是硬约束：主艺人不在点名集合内直接剔除（标题命中也不算）。
            // 相似补位行（relatedTo != nil）是被点名艺人的「相关艺人」，放行但不计本人。
            if let artistConstraint, relatedTo == nil {
                guard passGate("artist_constraint", artistConstraint.matches(artist: song.artist)) else {
                    rejectedByArtist += 1
                    return
                }
            }
            // 准入闸：唯一判定入口 isLikelyNonSong 的原因版本（顺序判定，宁严）。
            if let reason = RecommendationCandidateFilter.admissionRejection(for: song) {
                _ = passGate("admission", false)
                rejectionCounts[reason.rawValue, default: 0] += 1
                return
            }
            _ = passGate("admission", true)

            let key = RecommendationKey.normalize(title: song.title, artist: song.artist)
            guard passGate("library", !profile.libraryKeys.contains(key)) else { return }
            guard passGate(
                "blacklist",
                !profile.blacklistTracks.contains(key) && !profile.blacklistArtists.contains(artistKey)
            ) else { return }
            guard passGate("excluded_artists", !excludedArtists.contains(artistKey)) else { return }
            // P2 软黑名单：最近 7 天推过的曲目直接跳过（跨会话，不永久拉黑）。
            guard passGate("recent", !excludedTrackKeys.contains(key)) else { return }

            if let existing = indexByKey[key] {
                _ = passGate("dedupe", false)
                // 同曲两源都召回：保留可靠度更高的源。
                if source.reliability > items[existing].source.reliability {
                    items[existing].source = source
                }
                return
            }
            _ = passGate("dedupe", true)
            indexByKey[key] = items.count
            items.append(GatheredItem(song: song, source: source, intent: intent, relatedTo: relatedTo))
        }

        // 年代标签先解析成画像艺人：召回层永远拿不到「1990s」这种泛词 query。
        let resolvedIntents = RecommendationIntentBuilder.resolved(intents, profile: profile)
        for intent in resolvedIntents {
            let before = items.count
            let outcomes = await searchAll(
                query: intent.query,
                limit: perIntentLimit,
                artistName: intent.kind == .artist ? (intent.artist ?? intent.query) : nil
            )
            for outcome in outcomes {
                recordSource(outcome)
                if outcome.failed {
                    failedAttempts += 1
                    AppLog.debug(
                        .general,
                        "🎵 推荐召回失败：\(outcome.source.rawValue) [\(intent.kind.rawValue)] \(intent.query)"
                    )
                    continue
                }
                succeededSources += 1
                for song in outcome.songs {
                    accept(song, providerSource: outcome.source, intent: intent)
                }
            }
            AppLog.debug(
                .general,
                "🎵 推荐召回： [\(intent.kind.rawValue)] \(intent.query) 新增 \(items.count - before) 条"
            )
        }

        // 相似歌曲：运行时特性探测——第一次不可用就整轮放弃，回落到同艺人热歌。
        if similarRecallEnabled {
            var probes = 0
            var similarUnavailable = false
            for intent in resolvedIntents where intent.kind == .artist {
                guard probes < maxSimilarProbes, !similarUnavailable else { break }
                guard let seed = seedSongID(for: intent, in: items) else { continue }
                probes += 1
                let outcomes = await similarAll(songID: seed, limit: perIntentLimit)
                for outcome in outcomes {
                    recordSource(outcome)
                }
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
                        accept(song, providerSource: outcome.source, intent: similarIntent)
                    }
                }
            }
        }

        // P4：可选艺人关系扩展（默认关 = 零请求）。
        // 点名场景即使设置为关也启用（相似补位）：结果带 relatedTo 标记、不被硬约束闸剔除；
        // 比例 0（纯本人）时不召回相似，避免无谓的 MB / 源请求。
        let expansion = artistRelation ?? (artistConstraint == nil ? nil : namedArtistRelationFallback)
        if let expansion, artistConstraint == nil || relatedArtistShare > 0 {
            let related = await relatedArtistSongs(
                intents: resolvedIntents,
                limit: perIntentLimit,
                expansion: expansion
            )
            for produced in related {
                // 相关艺人自己就是点名艺人时不打标记（仍按本人行算）。
                let relatedTo = artistConstraint.flatMap {
                    $0.matches(artist: produced.song.artist) ? nil : $0.displayName
                }
                accept(
                    produced.song,
                    providerSource: .musicbrainz,
                    intent: produced.intent,
                    relatedTo: relatedTo
                )
            }
            if !related.isEmpty {
                AppLog.debug(
                    .general,
                    "🎵 推荐艺人关系扩展：召回 \(related.count) 条（\(expansion.budget.summary)）"
                )
            }
        }

        if let artistConstraint {
            AppLog.info(
                .general,
                "🎵 推荐艺人约束：\(artistConstraint.displayName) 剔除 artist 不符 \(rejectedByArtist) 条，保留 \(items.count) 条"
            )
        }

        let allFailed = succeededSources == 0 && failedAttempts > 0
        return GatherResult(
            items: items,
            allFailed: allFailed,
            sourceStats: sortedSourceStats(sourceStats),
            gateStats: sortedGateStats(gateStats),
            rejectionCounts: rejectionCounts,
            flaggedCounts: flaggedCounts
        )
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

    private func searchAll(query: String, limit: Int, artistName: String? = nil) async -> [SourceOutcome] {
        let providers = self.providers
        return await withTaskGroup(of: SourceOutcome.self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        // 艺人意图优先走 artist 路径（iTunes artistId→lookup）；不支持则回落普通 search。
                        let songs: [RecommendationRemoteSong]
                        if let artistName, let artistProvider = provider as? any ArtistSearchProviding {
                            songs = try await artistProvider.searchArtist(artistName, limit: limit)
                        } else {
                            songs = try await provider.search(query: query, limit: limit)
                        }
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

    /// 本次推荐看到的榜单索引（无客户端 → 空索引，热度全部 0.5）。
    private func currentChartIndex() async -> ChartPopularityIndex {
        guard let chartClient else { return .empty }
        return await chartClient.index()
    }

    /// 批次观测：榜单覆盖 + 命中率（判断热度分是否真的在起作用，不绑定具体抓取结果）。
    private func logChartPopularity(index: ChartPopularityIndex, items: [GatheredItem]) {
        let hits = items.reduce(into: 0) { count, item in
            if index.isChartHit(songID: item.song.songID, title: item.song.title, artist: item.song.artist) {
                count += 1
            }
        }
        AppLog.info(.general, "🎵 榜单热度：tw=\(index.twCount) us=\(index.usCount) 命中=\(hits)/\(items.count)")
    }

    /// 意图置信度加成：相似 > 同艺人 > 年代 > 曲风（越具体越靠前）。
    func intentBoost(_ intent: RecommendationIntent) -> Double {
        switch intent.kind {
        case .similar: return 0.08
        case .artist: return 0.06
        case .keyword: return 0.06
        case .decade: return 0.04
        case .genre: return 0.03
        }
    }

    /// 逐曲理由：由**产生该候选的意图**生成；相邻行首条理由不能相同。
    func reasonsFor(
        _ item: GatheredItem,
        previousPrimary: String?,
        artistConstraint: RecommendationArtistConstraint? = nil
    ) -> [String] {
        var reasons: [String] = []
        let display = RecommendationKey.displayPrimaryArtist(item.intent.artist ?? item.song.artist)
        // 相似补位行必须明示来源：用歌本身的艺人（= 相关艺人），绝不说成点名艺人。
        let relatedArtist = item.relatedTo == nil
            ? nil
            : RecommendationKey.displayPrimaryArtist(item.song.artist)

        switch item.intent.kind {
        case .artist:
            if let artistConstraint, artistConstraint.matches(artist: item.song.artist) {
                // 点名艺人的结果不说「常听 X」（用户可能从没听过）。
                reasons.append("recommendation_reason_requested_artist".localized)
            } else if !display.isEmpty {
                reasons.append("recommendation_reason_artist".localized(with: display))
            }
        case .similar:
            if let relatedArtist, !relatedArtist.isEmpty {
                reasons.append("recommendation_reason_related_artist".localized(with: relatedArtist))
            } else if !display.isEmpty {
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

        // 点名艺人理由可以相邻重复：整份列表本来就都是「你点名的艺人」。
        let requestedArtistReason = "recommendation_reason_requested_artist".localized
        // 来源标记行（点名本人 / 相似补位）不受相邻去重影响：否则连续同艺人会把来源盖掉。
        if let previousPrimary, unique.first == previousPrimary, unique.first != requestedArtistReason,
           relatedArtist == nil {
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
                    let favorites = try Favorite.fetchAll(db)
                    let playlistItems = try PlaylistItem.fetchAll(db)
                    let favoriteIds = Set(favorites.map(\.trackStableId))
                    let playlistIds = Set(playlistItems.map(\.trackStableId))
                    var playCounts: [String: Int] = [:]
                    for play in plays { playCounts[play.trackStableId, default: 0] += 1 }

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
                            genre: track.genre,
                            addedAt: track.modificationDate.map { Date(timeIntervalSince1970: Double($0) / 1_000_000) },
                            isFavorite: favoriteIds.contains(track.stableId),
                            isInPlaylist: playlistIds.contains(track.stableId),
                            playCount: playCounts[track.stableId] ?? 0
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
                        now: now,
                        libraryFingerprint: RecommendationLibraryFingerprint.make(
                            stableIds: tracks.map(\.stableId),
                            latestModificationMicros: tracks.compactMap(\.modificationDate).max()
                        )
                    )
                }
            } catch {
                AppLog.error(.general, "❌ 推荐画像读取失败：\(error)")
                return nil
            }
        }.value
    }
}
