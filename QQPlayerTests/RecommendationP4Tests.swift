//
//  RecommendationP4Tests.swift
//  QQPlayerTests
//
//  推荐 v2 P4 单测：MusicBrainz 艺人关系扩展（默认关、只对 artist 意图、
//  每意图 3 艺人 / 整轮 2 次查询上限、关系 JSON 解析与去重、失败不影响主链、
//  旧设置文件缺 key 解码为 false、MB 请求次数与 UA）。
//
//  不打真实网络：MB 走本文件独立的 URLProtocol mock，召回 / 引擎全部用桩。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 夹具

/// MB mock（静态状态只属于本文件，与其他 suite 的 URLProtocol mock 互不干扰）。
final class P4MockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?
    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []

    static func reset() {
        handler = nil
        receivedRequests = []
    }

    static func json(_ body: String, for request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        P4MockURLProtocol.receivedRequests.append(request)
        guard let handler = P4MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// 线程安全调用记录（调用顺序 / sleep 间隔断言用）。
private final class P4CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var sleeps: [TimeInterval] = []

    func record(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        items.append(value)
    }

    func recordSleep(_ value: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        sleeps.append(value)
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }

    var sleepIntervals: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return sleeps
    }
}

private func p4Remote(_ title: String, _ artist: String, songID: Int? = nil) -> RecommendationRemoteSong {
    RecommendationRemoteSong(title: title, artist: artist, year: 2020, songID: songID)
}

/// 主源桩（不实现 ArtistSearchProviding → artist 意图走普通 search）。
private struct P4MainProvider: OnlineSearchProviding {
    let source: RecommendationSource = .itunes
    var songs: [String: [RecommendationRemoteSong]] = [:]
    var log: P4CallLog?
    var fails = false

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        log?.record("main:\(query)")
        if fails { throw URLError(.timedOut) }
        return Array((songs[query] ?? []).prefix(limit))
    }
}

/// MB 关系查询桩。
private struct P4RelationClient: ArtistRelatedArtistProviding {
    var names: [String] = []
    var throwsError = false
    var log: P4CallLog?

    func relatedArtists(for artistName: String, limit: Int) async throws -> [String] {
        log?.record("mb:\(artistName):\(limit)")
        if throwsError { throw URLError(.cannotConnectToHost) }
        return Array(names.prefix(limit))
    }
}

/// 相关艺人召回桩（iTunes 主源替身）。
private struct P4RelatedRecall: RelatedArtistRecallProviding {
    var songsByArtist: [String: [RecommendationRemoteSong]] = [:]
    var failFor: Set<String> = []
    var log: P4CallLog?

    func songsForRelatedArtist(_ name: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        log?.record("recall:\(name)")
        if failFor.contains(name) { throw URLError(.timedOut) }
        return Array((songsByArtist[name] ?? []).prefix(limit))
    }
}

private func p4ArtistIntent(_ name: String) -> RecommendationIntent {
    RecommendationIntent(query: name, kind: .artist, artist: name)
}

private func p4Engine(
    main: P4MainProvider,
    client: P4RelationClient,
    recall: P4RelatedRecall,
    budget: RecommendationArtistRelationBudget,
    enabled: Bool = true
) -> RecommendationEngine {
    var engine = RecommendationEngine(providers: [main], perIntentLimit: 10)
    if enabled {
        engine.artistRelation = RecommendationArtistRelation(
            client: client,
            recall: recall,
            budget: budget
        )
    }
    return engine
}

// MARK: - 开关默认关

@Suite("推荐 P4 · 默认关")
struct RecommendationP4DefaultOffTests {
    @Test("默认关：一次 MB 请求都不发，召回与既有行为一致")
    func defaultOffMakesNoMBQuery() async {
        let log = P4CallLog()
        let engine = p4Engine(
            main: P4MainProvider(songs: ["Artist A": [p4Remote("Song A", "Artist A")]], log: log),
            client: P4RelationClient(names: ["Artist B"], log: log),
            recall: P4RelatedRecall(songsByArtist: ["Artist B": [p4Remote("Song B", "Artist B")]], log: log),
            budget: RecommendationArtistRelationBudget(),
            enabled: false
        )

        let result = await engine.recommend(
            profile: TasteProfile(),
            count: 10,
            intents: [p4ArtistIntent("Artist A")]
        )

        switch result {
        case let .success(list):
            #expect(list.map { $0.title } == ["Song A"])
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
        #expect(log.calls == ["main:Artist A"])
    }

    @Test("旧设置 JSON 缺 key → false，且不整份解码失败")
    func legacySettingsDecodeAsOff() throws {
        let legacy = Data("{}".utf8)
        let settings = try JSONDecoder().decode(DeleteSettings.self, from: legacy)
        #expect(settings.recommendationArtistRelationExpansion == false)
    }

    @Test("设置开关编解码往返：true 保留")
    func settingsRoundTrip() throws {
        var settings = DeleteSettings()
        settings.recommendationArtistRelationExpansion = true
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(DeleteSettings.self, from: data)
        #expect(decoded.recommendationArtistRelationExpansion)
    }
}

// MARK: - 只对 artist 意图扩展

@Suite("推荐 P4 · 意图范围")
struct RecommendationP4IntentScopeTests {
    @Test("开关打开：只对 artist 意图查 MB，关键词意图不查；扩展结果进池并标 musicbrainz")
    func onlyArtistIntentsExpand() async {
        let log = P4CallLog()
        let engine = p4Engine(
            main: P4MainProvider(
                songs: [
                    "Artist A": [p4Remote("Song A", "Artist A")],
                    "雨天": [p4Remote("Rainy Day", "Someone")],
                ],
                log: log
            ),
            client: P4RelationClient(names: ["Artist B"], log: log),
            recall: P4RelatedRecall(songsByArtist: ["Artist B": [p4Remote("Song B", "Artist B")]], log: log),
            budget: RecommendationArtistRelationBudget()
        )

        let intents = [
            p4ArtistIntent("Artist A"),
            RecommendationIntent(query: "雨天", kind: .keyword),
        ]
        let result = await engine.recommend(profile: TasteProfile(), count: 10, intents: intents)

        let mbCalls = log.calls.filter { $0.hasPrefix("mb:") }
        #expect(mbCalls == ["mb:Artist A:3"])

        switch result {
        case let .success(list):
            #expect(list.contains { $0.title == "Song B" })
            let expanded = list.first { $0.title == "Song B" }
            #expect(expanded?.source == .musicbrainz)
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("每意图最多 3 个相关艺人；整轮最多 2 次 MB 查询")
    func queryAndArtistLimits() async {
        let log = P4CallLog()
        let names = ["B1", "B2", "B3", "B4", "B5"]
        var recallSongs: [String: [RecommendationRemoteSong]] = [:]
        for name in names {
            recallSongs[name] = [p4Remote("Song \(name)", name)]
        }
        let engine = p4Engine(
            main: P4MainProvider(songs: [:], log: log),
            client: P4RelationClient(names: names, log: log),
            recall: P4RelatedRecall(songsByArtist: recallSongs, log: log),
            budget: RecommendationArtistRelationBudget()
        )

        _ = await engine.recommend(
            profile: TasteProfile(),
            count: 10,
            intents: (1 ... 5).map { p4ArtistIntent("Artist \($0)") }
        )

        let mbCalls = log.calls.filter { $0.hasPrefix("mb:") }
        #expect(mbCalls.count == 2)
        #expect(mbCalls.allSatisfy { $0.hasSuffix(":3") })

        let recalls = log.calls.filter { $0.hasPrefix("recall:") }
        #expect(recalls.count == 6)
        #expect(Set(recalls) == Set(["recall:B1", "recall:B2", "recall:B3"]))
    }

    @Test("预算计数进 summary：queries / artists 各计一次")
    func budgetSummaryCounts() async {
        let budget = RecommendationArtistRelationBudget()
        let log = P4CallLog()
        let engine = p4Engine(
            main: P4MainProvider(songs: [:], log: log),
            client: P4RelationClient(names: ["B1", "B2"], log: log),
            recall: P4RelatedRecall(
                songsByArtist: ["B1": [p4Remote("Song B1", "B1")], "B2": [p4Remote("Song B2", "B2")]],
                log: log
            ),
            budget: budget
        )

        _ = await engine.recommend(profile: TasteProfile(), count: 10, intents: [p4ArtistIntent("Artist A")])

        #expect(budget.queryCount == 1)
        #expect(budget.artistCount == 2)
        #expect(budget.summary == "queries:1:artists:2")
    }
}

// MARK: - 关系 JSON 解析

@Suite("推荐 P4 · 关系解析")
struct RecommendationP4RelationParsingTests {
    @Test("只取 artist-to-artist 关系：去重、排除种子、跳过空名、尊重 limit")
    func parseDedupeAndFilter() {
        let relations: [[String: Any]] = [
            ["type": "member of band", "artist": ["id": "1", "name": "Atoms for Peace"]],
            ["type": "collaboration", "artist": ["id": "2", "name": "  atoms for peace "]],
            ["type": "url-rels", "url": ["resource": "https://example.com/radiohead"]],
            ["type": "member of band", "artist": ["id": "3", "name": "   "]],
            ["type": "member of band", "artist": ["id": "4", "name": "Radiohead"]],
            ["type": "supporting musician", "artist": ["id": "5", "name": "Nigel Godrich"]],
        ]
        let detail: [String: Any] = ["relations": relations]

        #expect(MusicBrainzClient.relatedArtistNames(from: detail, seed: "Radiohead", limit: 3) == [
            "Atoms for Peace", "Nigel Godrich",
        ])
        #expect(MusicBrainzClient.relatedArtistNames(from: detail, seed: "Radiohead", limit: 1) == [
            "Atoms for Peace",
        ])
        #expect(MusicBrainzClient.relatedArtistNames(from: [:], seed: "Radiohead", limit: 3).isEmpty)
        #expect(MusicBrainzClient.relatedArtistNames(from: detail, seed: "Radiohead", limit: 0).isEmpty)
    }
}

// MARK: - 失败静默

@Suite("推荐 P4 · 失败不影响主链")
struct RecommendationP4FailureTests {
    @Test("MB 查询失败：主源结果照常返回，扩展静默跳过")
    func mbFailureKeepsMainChain() async {
        let log = P4CallLog()
        let engine = p4Engine(
            main: P4MainProvider(songs: ["Artist A": [p4Remote("Song A", "Artist A")]], log: log),
            client: P4RelationClient(names: ["B1"], throwsError: true, log: log),
            recall: P4RelatedRecall(songsByArtist: ["B1": [p4Remote("Song B1", "B1")]], log: log),
            budget: RecommendationArtistRelationBudget()
        )

        let result = await engine.recommend(profile: TasteProfile(), count: 10, intents: [p4ArtistIntent("Artist A")])

        switch result {
        case let .success(list):
            #expect(list.map { $0.title } == ["Song A"])
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
        #expect(log.calls.filter { $0.hasPrefix("mb:") }.count == 1)
        #expect(!log.calls.contains { $0.hasPrefix("recall:") })
    }

    @Test("扩展失败不把「无结果」变成 allSourcesFailed")
    func expansionFailureIsNotChainFailure() async {
        let log = P4CallLog()
        let engine = p4Engine(
            main: P4MainProvider(songs: [:], log: log),
            client: P4RelationClient(names: ["B1"], throwsError: true, log: log),
            recall: P4RelatedRecall(songsByArtist: ["B1": [p4Remote("Song B1", "B1")]], log: log),
            budget: RecommendationArtistRelationBudget()
        )

        let result = await engine.recommend(profile: TasteProfile(), count: 10, intents: [p4ArtistIntent("Artist A")])

        switch result {
        case let .success(list):
            #expect(list.isEmpty)
        case let .failure(error):
            Issue.record("不应判为主链全失败：\(error)")
        }
    }

    @Test("单个相关艺人召回失败：其余相关艺人仍并入")
    func partialRecallFailure() async {
        let log = P4CallLog()
        let engine = p4Engine(
            main: P4MainProvider(songs: ["Artist A": [p4Remote("Song A", "Artist A")]], log: log),
            client: P4RelationClient(names: ["B1", "B2"], log: log),
            recall: P4RelatedRecall(
                songsByArtist: [
                    "B1": [p4Remote("Song B1", "B1")],
                    "B2": [p4Remote("Song B2", "B2")],
                ],
                failFor: ["B1"],
                log: log
            ),
            budget: RecommendationArtistRelationBudget()
        )

        let result = await engine.recommend(profile: TasteProfile(), count: 10, intents: [p4ArtistIntent("Artist A")])

        switch result {
        case let .success(list):
            #expect(list.contains { $0.title == "Song B2" })
            #expect(!list.contains { $0.title == "Song B1" })
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }
}

// MARK: - MB 请求形态

@Suite("推荐 P4 · MB 请求形态", .serialized)
struct RecommendationP4MusicBrainzRequestTests {
    @Test("两次请求（定位 MBID + 关系）、UA 必填、各 sleep 1s、24h 缓存命中不再请求")
    func requestShapeAndCache() async throws {
        P4MockURLProtocol.reset()
        let log = P4CallLog()
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

        P4MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/ws/2/artist" {
                return P4MockURLProtocol.json(
                    #"{"artists":[{"id":"mbid-1","name":"Radiohead","score":100}]}"#,
                    for: request
                )
            }
            return P4MockURLProtocol.json(
                #"{"relations":[{"type":"member of band","artist":{"id":"x","name":"Atoms for Peace"}}]}"#,
                for: request
            )
        }

        let client = MusicBrainzClient(
            sleep: { log.recordSleep($0) },
            protocolClasses: [P4MockURLProtocol.self],
            relationCache: MusicBrainzRelationCache(),
            now: { fixedNow }
        )

        let names = try await client.relatedArtists(for: "Radiohead", limit: 3)
        #expect(names == ["Atoms for Peace"])
        #expect(log.sleepIntervals == [1, 1])

        let requests = P4MockURLProtocol.receivedRequests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == MusicBrainzClient.userAgent })
        #expect(requests.first?.url?.path == "/ws/2/artist")
        #expect(requests.last?.url?.path == "/ws/2/artist/mbid-1")
        #expect(requests.last?.url?.query?.contains("inc=artist-rels") == true)

        // 24h 缓存：同一艺人第二次调用不再发请求
        let again = try await client.relatedArtists(for: "radiohead ", limit: 3)
        #expect(again == ["Atoms for Peace"])
        #expect(P4MockURLProtocol.receivedRequests.count == 2)
    }

    @Test("MB 无匹配艺人：空结果缓存，不请求关系端点")
    func noArtistMatchStopsEarly() async throws {
        P4MockURLProtocol.reset()
        let log = P4CallLog()
        P4MockURLProtocol.handler = { request in
            P4MockURLProtocol.json(#"{"artists":[]}"#, for: request)
        }

        let client = MusicBrainzClient(
            sleep: { log.recordSleep($0) },
            protocolClasses: [P4MockURLProtocol.self],
            relationCache: MusicBrainzRelationCache()
        )

        let names = try await client.relatedArtists(for: "Nobody At All", limit: 3)
        #expect(names.isEmpty)
        #expect(P4MockURLProtocol.receivedRequests.count == 1)
        #expect(log.sleepIntervals == [1])
    }
}
