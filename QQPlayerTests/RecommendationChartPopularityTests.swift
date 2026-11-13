//
//  RecommendationChartPopularityTests.swift
//  QQPlayerTests
//
//  推荐热度（chart popularity）单测：解析 / 合并 / 匹配 / 映射 / 权重 / 缓存 / 降级。
//
//  纪律：**不打真实网络**（传输全部注入假实现），不碰模拟器 UI。
//  守卫自证：把 `ChartPopularityIndex.popularity(forRank:)` 改成常数、或把引擎改成不传 popularity，
//  第 6 条「榜内候选总分更高」会变红。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 夹具

private struct StubTransport: AppleMusicChartTransporting {
    var handler: @Sendable (URL) async throws -> Data

    func data(from url: URL) async throws -> Data {
        try await handler(url)
    }
}

private struct StubTransportError: Error {}

/// 请求计数（跨并发调用累加，断言「TTL 内不发请求」）。
private actor RequestLog {
    private var urls: [URL] = []

    var count: Int { urls.count }

    func record(_ url: URL) {
        urls.append(url)
    }
}

/// 可推进的测试时钟（NSLock 保护，避免 @Sendable 闭包捕获可变 var 的警告）。
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

/// 店区：/api/v2/<storefront>/music/...
private func storefront(of url: URL) -> String {
    let components = url.pathComponents
    return components.count > 3 ? components[3] : ""
}

private func feedJSON(_ items: [(id: String, name: String, artist: String)]) -> Data {
    let results: [[String: Any]] = items.map {
        ["id": $0.id, "name": $0.name, "artistName": $0.artist]
    }
    let object: [String: Any] = ["feed": ["results": results]]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}

private func makeTempCache() -> AppleMusicChartCache {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("chart-cache-\(UUID().uuidString)", isDirectory: true)
    return AppleMusicChartCache(directory: directory)
}

private func makeProfile(artists: [(String, Double)]) -> TasteProfile {
    var profile = TasteProfile()
    profile.topArtists = artists.map { ArtistWeight(artist: $0.0, weight: $0.1) }
    return profile
}

private func remote(_ title: String, _ artist: String, songID: Int? = nil) -> RecommendationRemoteSong {
    RecommendationRemoteSong(
        title: title,
        artist: artist,
        album: "\(title) Album",
        year: 2015,
        songID: songID,
        durationMs: 200_000
    )
}

/// 召回桩：任何查询都返回同一批歌。
private struct FixedProvider: OnlineSearchProviding {
    var source: RecommendationSource = .itunes
    var songs: [RecommendationRemoteSong]

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        Array(songs.prefix(limit))
    }
}

// MARK: - 解析 / 合并

@Suite("榜单解析与合并")
struct AppleMusicChartParsingTests {
    @Test("正常 feed：按序连续编号")
    func parsesNormalFeed() {
        let data = feedJSON([("1", "A", "X"), ("2", "B", "Y"), ("3", "C", "Z")])
        let entries = AppleMusicChartParser.entries(from: data)
        #expect(entries.map(\.id) == ["1", "2", "3"])
        #expect(entries.map(\.rank) == [1, 2, 3])
        #expect(entries.first?.title == "A")
        #expect(entries.first?.artist == "X")
    }

    @Test("空 results / 非 JSON：返回空数组，不崩")
    func parsesEmptyAndGarbage() {
        #expect(AppleMusicChartParser.entries(from: feedJSON([])).isEmpty)
        #expect(AppleMusicChartParser.entries(from: Data("not json".utf8)).isEmpty)
    }

    @Test("缺字段条目跳过，其余名次仍连续")
    func skipsIncompleteEntries() {
        let data = feedJSON([
            ("1", "OK", "Artist"),
            ("2", "", "Artist"),
            ("3", "No Artist", ""),
            ("4", "Also OK", "Artist2"),
        ])
        let entries = AppleMusicChartParser.entries(from: data)
        #expect(entries.map(\.id) == ["1", "4"])
        #expect(entries.map(\.rank) == [1, 2])
    }

    @Test("合并：tw 优先、us 去重追加、rank 连续")
    func mergesStorefronts() {
        let tw = [
            ChartEntry(id: "a", title: "A", artist: "X", rank: 1),
            ChartEntry(id: "b", title: "B", artist: "Y", rank: 2),
        ]
        let us = [
            ChartEntry(id: "b", title: "B", artist: "Y", rank: 1),
            ChartEntry(id: "c", title: "C", artist: "Z", rank: 2),
        ]
        let merged = AppleMusicChartParser.merged(tw: tw, us: us)
        #expect(merged.map(\.id) == ["a", "b", "c"])
        #expect(merged.map(\.rank) == [1, 2, 3])
    }
}

// MARK: - 匹配 / 映射

@Suite("榜单匹配与热度映射")
struct ChartPopularityMatchingTests {
    private let entries = [
        ChartEntry(id: "1001", title: "Shape of You (Remix)", artist: "Ed Sheeran", rank: 1),
        ChartEntry(id: "1002", title: "Hello", artist: "Adele", rank: 2),
        ChartEntry(id: "1003", title: "Last", artist: "Someone", rank: 3),
    ]

    @Test("id 精确命中优先")
    func matchesByID() {
        let index = ChartPopularityIndex(entries: entries)
        #expect(index.rank(songID: 1002, title: "别的歌名", artist: "别的艺人") == 2)
    }

    @Test("歌名 + 艺人归一化命中：大小写 / 括号后缀 / 空白")
    func matchesByNormalizedTitleArtist() {
        let index = ChartPopularityIndex(entries: entries)
        #expect(index.rank(songID: nil, title: "  shape of you  ", artist: "ED SHEERAN") == 1)
        #expect(index.isChartHit(songID: nil, title: "Hello (Live)", artist: "adele"))
    }

    @Test("未命中：rank nil、热度 0.5")
    func misses() {
        let index = ChartPopularityIndex(entries: entries)
        #expect(index.rank(songID: 9999, title: "Nope", artist: "Nobody") == nil)
        #expect(index.popularity(songID: 9999, title: "Nope", artist: "Nobody") == ChartPopularityIndex.neutralPopularity)
    }

    @Test("映射边界：rank1 = 1.0、rankN = 0.6、未知 = 0.5")
    func mapsRankToPopularity() {
        let many = (1 ... 100).map { ChartEntry(id: "\($0)", title: "T\($0)", artist: "A", rank: $0) }
        let index = ChartPopularityIndex(entries: many)
        #expect(abs(index.popularity(forRank: 1) - 1.0) < 1e-9)
        #expect(abs(index.popularity(forRank: 100) - 0.6) < 1e-9)
        #expect(abs(index.popularity(forRank: nil) - 0.5) < 1e-9)
        // 单调：名次越靠前热度越高。
        #expect(index.popularity(forRank: 5) > index.popularity(forRank: 50))
    }

    @Test("空索引：全部中性 0.5")
    func emptyIndexIsNeutral() {
        let index = ChartPopularityIndex.empty
        #expect(index.isEmpty)
        #expect(index.popularity(forRank: 1) == 0.5)
        #expect(index.popularity(songID: 1, title: "A", artist: "B") == 0.5)
    }
}

// MARK: - 权重

@Suite("推荐权重：六项含热度")
struct RecommendationWeightTests {
    @Test("权重和 == 1.0（容差 1e-9）且取值锁死")
    func weightsSumToOne() {
        #expect(RecommendationWeights.artistAffinity == 0.36)
        #expect(RecommendationWeights.eraMatch == 0.16)
        #expect(RecommendationWeights.freshness == 0.09)
        #expect(RecommendationWeights.sourceReliability == 0.08)
        #expect(RecommendationWeights.novelty == 0.11)
        #expect(RecommendationWeights.popularity == 0.20)
        let sum = RecommendationWeights.artistAffinity
            + RecommendationWeights.eraMatch
            + RecommendationWeights.freshness
            + RecommendationWeights.sourceReliability
            + RecommendationWeights.novelty
            + RecommendationWeights.popularity
        #expect(abs(sum - 1.0) < 1e-9)
    }

    @Test("打分：热度分量真实参与总分")
    func popularityMovesTotal() {
        let profile = makeProfile(artists: [("A", 10)])
        let neutral = RecommendationScorer.score(
            RecommendationScoreInput(artist: "A", year: 2015, source: .itunes, popularity: 0.5),
            profile: profile
        )
        let hit = RecommendationScorer.score(
            RecommendationScoreInput(artist: "A", year: 2015, source: .itunes, popularity: 1.0),
            profile: profile
        )
        #expect(hit.total > neutral.total)
        #expect(abs((hit.total - neutral.total) - 0.5 * RecommendationWeights.popularity) < 1e-9)
        #expect(hit.popularity == 1.0)
    }
}

// MARK: - 缓存

@Suite("榜单缓存：TTL / 回落")
struct AppleMusicChartCacheTests {
    @Test("TTL 内不发请求；过期重取；失败回落旧缓存")
    func cacheTTLAndStaleFallback() async {
        let clock = TestClock()
        let log = RequestLog()
        let payload: [String: Data] = [
            "tw": feedJSON([("1", "TW Song", "TW Artist")]),
            "us": feedJSON([("2", "US Song", "US Artist")]),
        ]
        let transport = StubTransport { url in
            await log.record(url)
            guard let data = payload[storefront(of: url)] else { throw StubTransportError() }
            return data
        }
        let cache = makeTempCache()
        let client = AppleMusicChartClient(transport: transport, cache: cache, clock: { clock.now })

        let first = await client.index()
        let callsAfterFirst = await log.count
        #expect(callsAfterFirst == 2)
        #expect(first.count == 2)
        #expect(first.twCount == 1)
        #expect(first.usCount == 1)

        // 同一实例（memo）与全新实例（磁盘缓存）在 TTL 内都不该再发请求。
        _ = await client.index()
        let client2 = AppleMusicChartClient(transport: transport, cache: cache, clock: { clock.now })
        _ = await client2.index()
        let callsAfterCached = await log.count
        #expect(callsAfterCached == 2)

        // 过期 → 重新抓取。
        clock.advance(AppleMusicChartCache.ttl + 60)
        _ = await client2.index()
        let callsAfterExpiry = await log.count
        #expect(callsAfterExpiry == 4)

        // 过期 + 网络全失败 → 回落旧缓存，不抛错。
        clock.advance(AppleMusicChartCache.ttl + 60)
        let failing = StubTransport { _ in throw StubTransportError() }
        let staleClient = AppleMusicChartClient(transport: failing, cache: cache, clock: { clock.now })
        let stale = await staleClient.index()
        #expect(stale.count == 2)
        #expect(stale.isChartHit(songID: 2, title: "US Song", artist: "US Artist"))
    }

    @Test("无缓存 + 网络全失败 → 空索引（不抛错）")
    func failureWithoutCacheIsEmpty() async {
        let failing = StubTransport { _ in throw StubTransportError() }
        let client = AppleMusicChartClient(transport: failing, cache: nil)
        let index = await client.index()
        #expect(index.isEmpty)
    }
}

// MARK: - 引擎集成

@Suite("引擎集成：热度影响排序 / 理由 / 降级")
struct RecommendationChartEngineTests {
    private func chartPayload() -> [String: Data] {
        [
            "tw": feedJSON([
                ("501", "Chart Hit", "Artist X"),
                ("502", "Another Hit", "Artist Y"),
            ]),
            "us": feedJSON([]),
        ]
    }

    @Test("核心回归：同艺人同亲和，榜内前 10 的候选总分更高")
    func chartHitOutranksUnknown() async {
        let transport = StubTransport { url in
            guard let data = chartPayload()[storefront(of: url)] else { throw StubTransportError() }
            return data
        }
        var engine = RecommendationEngine(
            providers: [
                FixedProvider(songs: [
                    remote("Unknown Song", "Artist X"),
                    remote("Chart Hit", "Artist X", songID: 501),
                ]),
            ]
        )
        engine.chartClient = AppleMusicChartClient(transport: transport, cache: nil)
        let profile = makeProfile(artists: [("artist x", 10)])

        guard case let .success(list) = await engine.recommend(profile: profile, count: 2) else {
            Issue.record("推荐应成功")
            return
        }
        #expect(list.count == 2)
        #expect(list.first?.title == "Chart Hit")
        #expect((list.first?.score ?? 0) > (list.last?.score ?? 0))
        // 上榜候选带「近期热门」理由，未上榜的不带。
        let chartReason = "recommendation_reason_chart_hot".localized
        #expect(list.first?.reasons.contains(chartReason) == true)
        #expect(list.last?.reasons.contains(chartReason) == false)
    }

    @Test("降级：榜单全失败时推荐主流程照常返回候选")
    func chartFailureDoesNotBreakRecommendation() async {
        let failing = StubTransport { _ in throw StubTransportError() }
        var engine = RecommendationEngine(
            providers: [FixedProvider(songs: [remote("Song A", "Artist X"), remote("Song B", "Artist X")])]
        )
        engine.chartClient = AppleMusicChartClient(transport: failing, cache: nil)
        let profile = makeProfile(artists: [("artist x", 10)])

        guard case let .success(list) = await engine.recommend(profile: profile, count: 2) else {
            Issue.record("榜单失败不应影响推荐")
            return
        }
        #expect(list.count == 2)
        #expect(list.allSatisfy { $0.score > 0 })
        #expect(list.allSatisfy { !$0.reasons.contains("recommendation_reason_chart_hot".localized) })
    }
}
