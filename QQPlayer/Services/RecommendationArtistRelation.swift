//
//  RecommendationArtistRelation.swift
//  QQPlayer
//
//  推荐 v2 P4：MusicBrainz 艺人关系扩展（可选、默认关）。
//
//  - 默认关（引擎 artistRelation == nil）：召回与 P3 完全一致，零额外网络请求。
//  - 打开后：只对 .artist 意图扩展——每意图最多 maxArtistsPerIntent 个相关艺人，
//    整轮最多 maxQueriesPerRun 次 MB 关系查询；扩展艺人走 iTunes 主源
//    （ITunesRecommendationProvider.searchArtist），结果并入候选池并标 .musicbrainz。
//  - 任何失败只打日志：不计入主链失败、不改变主链来源判定、不影响最终结果正确性。
//
//  为什么扩展用**独立** iTunes 预算：主链先跑、6 次调用预算通常已用尽，复用同一份预算
//  会让扩展在首次运行必然「预算用尽」→ 功能等于不存在。独立预算保证主链语义不变，
//  同时把扩展的请求放大关进自己的上限里（≤6 次调用 ≈ 3 个相关艺人）。
//
//  测试 seam：MB 关系查询 ArtistRelatedArtistProviding、相关艺人召回
//  RelatedArtistRecallProviding——引擎只认这两个协议，不认具体实现。
//

import Foundation

// MARK: - seam

/// MB 艺人关系查询（生产实现 = MusicBrainzClient）。
protocol ArtistRelatedArtistProviding: Sendable {
    func relatedArtists(for artistName: String, limit: Int) async throws -> [String]
}

/// 相关艺人召回（生产实现 = iTunes 主源）。
protocol RelatedArtistRecallProviding: Sendable {
    func songsForRelatedArtist(_ name: String, limit: Int) async throws -> [RecommendationRemoteSong]
}

extension MusicBrainzClient: ArtistRelatedArtistProviding {}

extension ITunesRecommendationProvider: RelatedArtistRecallProviding {
    /// 相关艺人 → 该艺人歌曲：复用 searchArtist 的 artistId → lookup、限流与 24h 缓存。
    func songsForRelatedArtist(_ name: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        try await searchArtist(name, limit: limit)
    }
}

// MARK: - MB 关系缓存

/// MB 艺人关系 24h 进程内缓存（key = 归一化艺人名；空结果也缓存 = 负缓存，
/// 避免同一艺人反复打 MB）。class 引用语义：跨 MusicBrainzClient 实例共享。
final class MusicBrainzRelationCache: @unchecked Sendable {
    static let shared = MusicBrainzRelationCache()

    private let lock = NSLock()
    private let ttl: TimeInterval
    private var entries: [String: (storedAt: Date, artists: [String])] = [:]

    init(ttl: TimeInterval = 24 * 3600) {
        self.ttl = ttl
    }

    /// 命中且未过期 → 关系名；未命中 / 过期 → nil（调用方去打网络）。
    func artists(for key: String, now: Date) -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key], now.timeIntervalSince(entry.storedAt) < ttl else {
            return nil
        }
        return entry.artists
    }

    func store(_ artists: [String], for key: String, now: Date) {
        lock.lock()
        defer { lock.unlock() }
        entries[key] = (storedAt: now, artists: artists)
    }
}

// MARK: - 预算 / 诊断

/// 一次推荐的艺人关系扩展计数（每轮重置；进 summary 日志）。
///
/// 用锁而不是 actor：logRunSummary 是同步路径，summary 必须同步可读。
final class RecommendationArtistRelationBudget: @unchecked Sendable {
    /// 整轮 MB 关系查询上限（请求放大闸）。
    let maxQueriesPerRun: Int
    /// 单意图相关艺人上限。
    let maxArtistsPerIntent: Int

    private let lock = NSLock()
    private var remainingQueries: Int
    private var queries = 0
    private var artists = 0

    init(maxQueriesPerRun: Int = 2, maxArtistsPerIntent: Int = 3) {
        self.maxQueriesPerRun = max(0, maxQueriesPerRun)
        self.maxArtistsPerIntent = max(0, maxArtistsPerIntent)
        remainingQueries = self.maxQueriesPerRun
    }

    func beginRun() {
        lock.lock()
        defer { lock.unlock() }
        remainingQueries = maxQueriesPerRun
        queries = 0
        artists = 0
    }

    /// 消耗一次 MB 关系查询；false = 本轮已用尽（不再扩展）。
    func consumeQuery() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard remainingQueries > 0 else { return false }
        remainingQueries -= 1
        queries += 1
        return true
    }

    /// 记一次「已发起相关艺人召回」（含失败：用于看请求放大）。
    func recordArtists(_ count: Int = 1) {
        lock.lock()
        defer { lock.unlock() }
        artists += max(0, count)
    }

    var queryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queries
    }

    var artistCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return artists
    }

    /// summary 载荷：queries:N:artists:M（固定顺序、可 grep）。
    var summary: String {
        lock.lock()
        defer { lock.unlock() }
        return "queries:\(queries):artists:\(artists)"
    }
}

// MARK: - 扩展配置

/// 艺人关系扩展配置（**存在即开**；nil = 关）。
struct RecommendationArtistRelation: Sendable {
    var client: any ArtistRelatedArtistProviding
    /// 相关艺人歌曲召回（生产 = iTunes 主源，挂在 itunesBudget 上）。
    var recall: any RelatedArtistRecallProviding
    /// MB 查询 / 艺人计数（summary 日志）。
    var budget: RecommendationArtistRelationBudget
    /// 扩展专用 iTunes 预算（不占主链；默认 6 次调用 ≈ 3 个相关艺人的 search + lookup）。
    var itunesBudget: RecommendationRunBudget

    init(
        client: any ArtistRelatedArtistProviding = MusicBrainzClient(),
        recall: (any RelatedArtistRecallProviding)? = nil,
        budget: RecommendationArtistRelationBudget = RecommendationArtistRelationBudget(),
        itunesBudget: RecommendationRunBudget = RecommendationRunBudget(maxDowngrades: 0, maxITunesCalls: 6)
    ) {
        self.client = client
        self.budget = budget
        self.itunesBudget = itunesBudget
        self.recall = recall ?? ITunesRecommendationProvider(storefront: "tw", budget: itunesBudget)
    }

    /// 每轮开始：重置查询 / 艺人计数与扩展 iTunes 预算。
    func beginRun() async {
        budget.beginRun()
        await itunesBudget.beginRun()
    }

    /// 设置开关 → 配置（关 = nil，零额外请求）。
    static func fromSettings(_ settings: DeleteSettings = .load()) -> RecommendationArtistRelation? {
        settings.recommendationArtistRelationExpansion ? RecommendationArtistRelation() : nil
    }
}

// MARK: - 引擎接线

extension RecommendationEngine {
    /// 默认引擎 + P4 接线（设置关 = 与 P3 完全等价的引擎）。
    static func configured(_ settings: DeleteSettings = .load()) -> RecommendationEngine {
        var engine = RecommendationEngine()
        engine.artistRelation = RecommendationArtistRelation.fromSettings(settings)
        return engine
    }

    /// 相关艺人召回结果（已标 .musicbrainz，归到 .similar 意图）。
    ///
    /// 逐个 artist 意图执行：先扣 MB 查询预算（整轮 ≤2），再逐相关艺人走主源召回。
    /// 任一步失败只记日志并继续，绝不 throw（失败不得影响主链）。
    func relatedArtistSongs(
        intents: [RecommendationIntent],
        limit: Int,
        expansion: RecommendationArtistRelation
    ) async -> [(song: RecommendationRemoteSong, intent: RecommendationIntent)] {
        var produced: [(song: RecommendationRemoteSong, intent: RecommendationIntent)] = []
        for intent in intents where intent.kind == .artist {
            guard expansion.budget.consumeQuery() else {
                AppLog.info(
                    .general,
                    "🎵 推荐艺人关系：本轮 MB 查询预算（\(expansion.budget.maxQueriesPerRun) 次）用尽，停止扩展"
                )
                break
            }
            let seed = (intent.artist ?? intent.query).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seed.isEmpty else { continue }
            let names: [String]
            do {
                names = try await expansion.client.relatedArtists(
                    for: seed,
                    limit: expansion.budget.maxArtistsPerIntent
                )
            } catch {
                AppLog.info(
                    .general,
                    "🎵 推荐艺人关系：MB 查询失败，跳过（\(seed)）：\(error.localizedDescription)"
                )
                continue
            }
            guard !names.isEmpty else { continue }
            // 扩展结果按「相似艺人」归因：理由文案不会说成「常听 X」（用户可能从没听过）。
            let relatedIntent = RecommendationIntent(
                query: intent.query,
                kind: .similar,
                artist: intent.artist,
                decade: intent.decade,
                genre: intent.genre
            )
            for name in names.prefix(expansion.budget.maxArtistsPerIntent) {
                expansion.budget.recordArtists()
                do {
                    let songs = try await expansion.recall.songsForRelatedArtist(name, limit: limit)
                    guard !songs.isEmpty else { continue }
                    for song in songs {
                        var song = song
                        song.source = .musicbrainz
                        produced.append((song: song, intent: relatedIntent))
                    }
                } catch {
                    AppLog.info(
                        .general,
                        "🎵 推荐艺人关系：相关艺人召回失败，跳过（\(name)）：\(error.localizedDescription)"
                    )
                }
            }
        }
        return produced
    }
}
