//
//  RecommendationP2Tests.swift
//  QQPlayerTests
//
//  推荐 v2 P2 纯逻辑单测：会话池（15 首 / 换一批）、降级链预算、软黑名单、iTunes 映射。
//  不打真实网络；链 / 客户端全部用桩与可注入时钟验证。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 夹具

/// 线程安全调用记录（链顺序断言用）。
private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []

    func record(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        names.append(name)
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return names
    }
}

/// 链上的桩源：返回固定候选，或抛错。
private struct ChainStubProvider: OnlineSearchProviding {
    var source: RecommendationSource
    var songs: [RecommendationRemoteSong]
    var fails = false
    var recorder: CallRecorder?
    var name = "stub"

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        recorder?.record(name)
        if fails { throw URLError(.timedOut) }
        return songs
    }
}

private func candidate(
    _ title: String,
    _ artist: String,
    album: String? = nil,
    source: RecommendationSource = .itunes,
    score: Double = 1
) -> RecommendedCandidate {
    var item = RecommendedCandidate(title: title, artist: artist, album: album, year: 2020, source: source)
    item.score = score
    return item
}

private func remote(_ title: String, _ artist: String) -> RecommendationRemoteSong {
    RecommendationRemoteSong(title: title, artist: artist, songID: 1)
}

// MARK: - 会话池

@Suite("推荐 P2 · 会话池")
struct RecommendationRecallSessionTests {
    @Test("首批 15 首，游标推进且不重复")
    func firstBatchSizeAndNoRepeat() {
        let pool = (1 ... 40).map { candidate("Song \($0)", "Artist \(($0 % 20))") }
        var session = RecallSession(pool: pool)
        let first = session.nextBatch()
        #expect(first.count == 15)
        let second = session.nextBatch()
        #expect(second.count == 15)
        let overlap = Set(first.map(\.id)).intersection(Set(second.map(\.id)))
        #expect(overlap.isEmpty)
    }

    @Test("同批同艺人 ≤4、同专辑 ≤2")
    func batchDiversityCaps() {
        var pool: [RecommendedCandidate] = []
        for index in 0 ..< 12 {
            pool.append(candidate("A\(index)", "Same Artist", album: "Album One", score: Double(100 - index)))
        }
        for index in 0 ..< 20 {
            pool.append(candidate("B\(index)", "Other \(index)", album: "Album \(index)", score: Double(90 - index)))
        }
        var session = RecallSession(pool: pool)
        let batch = session.nextBatch()
        let sameArtist = batch.filter { $0.artist == "Same Artist" }
        #expect(sameArtist.count <= 4)
        let albumOne = batch.filter { $0.album == "Album One" }
        #expect(albumOne.count <= 2)
        #expect(batch.count == 15)
    }

    @Test("剩余不足一批 → needsRefill；耗尽 → exhausted")
    func refillState() {
        var session = RecallSession(pool: (1 ... 16).map { candidate("S\($0)", "A\($0)") })
        _ = session.nextBatch()
        #expect(session.state == .needsRefill)
        _ = session.nextBatch()
        #expect(session.state == .exhausted)
    }

    @Test("池剩 1 首不出残批：补池后第二批仍是 15")
    func refillKeepsBatchFull() {
        var session = RecallSession(pool: (1 ... 16).map { candidate("Old \($0)", "OldArtist\($0)") })
        let first = session.nextBatch()
        #expect(first.count == 15)
        #expect(session.remaining == 1)
        #expect(session.state == .needsRefill)
        let added = session.append(pool: (1 ... 20).map { candidate("New \($0)", "NewArtist\($0)") })
        #expect(added == 20)
        let second = session.nextBatch()
        #expect(second.count == 15)
    }

    @Test("增量补池去重且保留游标")
    func appendRefillDeduplicates() {
        var session = RecallSession(pool: [candidate("S1", "A")])
        _ = session.nextBatch()
        let added = session.append(pool: [candidate("S1", "A"), candidate("S2", "B")])
        #expect(added == 1)
        #expect(session.remaining == 1)
    }
}

// MARK: - 降级链

@Suite("推荐 P2 · 降级链")
struct RecommendationDegradationTests {
    @Test("软失败 → 硬失败 → 下一级成功，结果带真实来源与降级原因")
    func degradesAndAttributesSource() async throws {
        let recorder = CallRecorder()
        let budget = RecommendationRunBudget(maxDowngrades: 2)
        let audit = RecommendationChainAudit()
        let chain = RecommendationDegradingProvider(
            steps: [
                RecommendationChainStep(
                    kind: .itunesTW,
                    provider: ChainStubProvider(
                        source: .itunes,
                        songs: (1 ... 5).map { remote("t\($0)", "a") },
                        recorder: recorder,
                        name: "tw"
                    ),
                    minimumCandidates: 30,
                    degradedReason: nil
                ),
                RecommendationChainStep(
                    kind: .itunesUS,
                    provider: ChainStubProvider(
                        source: .itunes,
                        songs: [],
                        fails: true,
                        recorder: recorder,
                        name: "us"
                    ),
                    minimumCandidates: 30,
                    degradedReason: "itunes_us_fallback"
                ),
                RecommendationChainStep(
                    kind: .musicbrainz,
                    provider: ChainStubProvider(
                        source: .musicbrainz,
                        songs: (1 ... 10).map { remote("m\($0)", "b") },
                        recorder: recorder,
                        name: "mb"
                    ),
                    minimumCandidates: 8,
                    degradedReason: "musicbrainz_fallback"
                ),
            ],
            budget: budget,
            audit: audit
        )

        let songs = try await chain.search(query: "artist", limit: 10)
        #expect(recorder.calls == ["tw", "us", "mb"])
        #expect(songs.count == 10)
        #expect(songs.allSatisfy { $0.source == .musicbrainz })
        #expect(songs.allSatisfy { $0.degradedReason == "musicbrainz_fallback" })
        #expect(audit.summary.contains("downgrades=itunes-tw>itunes-us"))
    }

    @Test("单轮最多降 2 级：预算用尽后不再往下")
    func downgradeBudgetCaps() async {
        let recorder = CallRecorder()
        let budget = RecommendationRunBudget(maxDowngrades: 2)
        let chain = RecommendationDegradingProvider(
            steps: [
                RecommendationChainStep(
                    kind: .itunesTW,
                    provider: ChainStubProvider(source: .itunes, songs: [], recorder: recorder, name: "tw"),
                    minimumCandidates: 30,
                    degradedReason: nil
                ),
                RecommendationChainStep(
                    kind: .itunesUS,
                    provider: ChainStubProvider(source: .itunes, songs: [], recorder: recorder, name: "us"),
                    minimumCandidates: 30,
                    degradedReason: "us"
                ),
                RecommendationChainStep(
                    kind: .musicbrainz,
                    provider: ChainStubProvider(source: .musicbrainz, songs: [], recorder: recorder, name: "mb"),
                    minimumCandidates: 8,
                    degradedReason: "mb"
                ),
                RecommendationChainStep(
                    kind: .netease,
                    provider: ChainStubProvider(source: .netease, songs: [remote("n", "c")], recorder: recorder, name: "ne"),
                    minimumCandidates: 0,
                    degradedReason: "netease_fallback"
                ),
            ],
            budget: budget,
            audit: nil
        )

        _ = try? await chain.search(query: "artist", limit: 10)
        #expect(recorder.calls == ["tw", "us", "mb"])
    }
}

// MARK: - 软黑名单

@Suite("推荐 P2 · 最近推过")
struct RecommendationRecentBlacklistTests {
    @Test("7 天内命中，过期后不再命中")
    func sevenDayWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var blacklist = RecommendationBlacklist()
        blacklist.markRecommended([candidate("Song", "Artist")], at: now)
        #expect(blacklist.wasRecentlyRecommended(title: "Song", artist: "Artist", at: now))
        #expect(!blacklist.wasRecentlyRecommended(
            title: "Song",
            artist: "Artist",
            at: now.addingTimeInterval(8 * 24 * 3600)
        ))
        #expect(blacklist.activeRecentKeys(at: now).contains(RecommendationKey.normalize(title: "Song", artist: "Artist")))
        #expect(blacklist.activeRecentKeys(at: now.addingTimeInterval(8 * 24 * 3600)).isEmpty)
    }

    @Test("旧文件（无 recentTrackKeys 字段）可解码")
    func decodesLegacyFile() throws {
        let json = #"{"trackKeys":["a|b"],"artists":["b"]}"#
        let decoded = try JSONDecoder().decode(RecommendationBlacklist.self, from: Data(json.utf8))
        #expect(decoded.trackKeys == Set(["a|b"]))
        #expect(decoded.recentTrackKeys.isEmpty)
    }
}

// MARK: - iTunes 映射

@Suite("推荐 P2 · iTunes 映射")
struct RecommendationITunesMappingTests {
    @Test("search 结果取首个 artistId")
    func firstArtistID() {
        let results: [[String: Any]] = [
            ["artistId": 0],
            ["artistId": NSNumber(value: 1234)],
            ["artistId": "5678"],
        ]
        #expect(ITunesRecommendationProvider.firstArtistID(in: results) == 1234)
    }

    @Test("歌曲字段映射（previewUrl / 年份 / 时长）；缺 title 返回 nil")
    func mapsSongFields() {
        let dict: [String: Any] = [
            "trackName": "晴天",
            "artistName": "周杰伦",
            "collectionName": "叶惠美",
            "releaseDate": "2003-07-31T07:00:00Z",
            "trackTimeMillis": NSNumber(value: 269_000),
            "previewUrl": "https://example.com/preview.m4a",
            "trackId": NSNumber(value: 42),
        ]
        let song = ITunesRecommendationProvider.song(from: dict)
        #expect(song?.title == "晴天")
        #expect(song?.artist == "周杰伦")
        #expect(song?.album == "叶惠美")
        #expect(song?.year == 2003)
        #expect(song?.durationMs == 269_000)
        #expect(song?.previewURL?.absoluteString == "https://example.com/preview.m4a")
        #expect(song?.source == .itunes)
        #expect(ITunesRecommendationProvider.song(from: ["artistName": "x"]) == nil)
    }

    @Test("lookup URL 使用 id + limit=200；search URL 用 term")
    func requestURLs() {
        let lookup = ITunesScrapeClient.requestURL(id: 99, entity: "song", storefront: "tw", limit: 200)
        #expect(lookup?.absoluteString.contains("id=99") == true)
        #expect(lookup?.absoluteString.contains("limit=200") == true)
        #expect(lookup?.absoluteString.contains("country=tw") == true)
        let search = ITunesScrapeClient.requestURL(term: "周杰伦", entity: "song", storefront: "us", limit: 200)
        #expect(search?.absoluteString.contains("entity=song") == true)
        #expect(search?.absoluteString.contains("country=us") == true)
    }
}

// MARK: - 艺人 / 关键词路径

/// 记录 search / searchArtist 走了哪条路径。
private final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    func record(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        paths.append(path)
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }
}

private struct ArtistAwareStub: OnlineSearchProviding, ArtistSearchProviding {
    var source: RecommendationSource = .itunes
    var name: String
    var recorder: PathRecorder
    var failArtist = false

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        recorder.record("search:\(name)")
        return [RecommendationRemoteSong(title: "\(name)-kw", artist: "kw", songID: 1)]
    }

    func searchArtist(_ name: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        recorder.record("artist:\(self.name)")
        if failArtist { throw URLError(.timedOut) }
        return [RecommendationRemoteSong(title: "\(self.name)-song", artist: name, songID: 2)]
    }
}

private struct PoolStubProvider: OnlineSearchProviding {
    var source: RecommendationSource = .itunes

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        (1 ... 20).map { index in
            RecommendationRemoteSong(
                title: query + "-" + String(index),
                artist: query + " Artist",
                album: query + " Album",
                songID: index,
                durationMs: 200_000
            )
        }
    }
}

@Suite("推荐 P2 · 引擎池容量")
struct RecommendationPoolCapacityTests {
    @Test("6 个艺人意图 × 20 首 → 池能拿到 ≥60（不受每艺人/每专辑池上限压制）")
    func poolCanReachSixty() async {
        var engine = RecommendationEngine(
            providers: [PoolStubProvider()],
            perIntentLimit: 20,
            maxSongsPerArtist: 10_000,
            maxSongsPerAlbum: nil
        )
        engine.maxSongsPerIntent = 20
        engine.maxSourceShare = 1.0
        let intents = (1 ... 6).map { index in
            RecommendationIntent(query: "Artist\(index)", kind: .artist, artist: "Artist\(index)")
        }
        let result = await engine.recommend(profile: TasteProfile(), count: 60, intents: intents)
        switch result {
        case let .success(list):
            #expect(list.count >= 60)
        case let .failure(error):
            Issue.record("池构建失败：\(error)")
        }
    }
}

@Suite("推荐 P2 · 艺人 / 关键词分发")
struct RecommendationArtistDispatchTests {
    @Test("artist 意图走 searchArtist，keyword 意图走 search")
    func engineDispatchesByIntentKind() async {
        let recorder = PathRecorder()
        let stub = ArtistAwareStub(name: "stub", recorder: recorder)
        let engine = RecommendationEngine(providers: [stub], perIntentLimit: 10)
        let intents = [
            RecommendationIntent(query: "ArtistA", kind: .artist, artist: "ArtistA"),
            RecommendationIntent(query: "夏天 海边", kind: .keyword),
        ]
        _ = await engine.recommend(profile: TasteProfile(), count: 5, intents: intents)
        #expect(recorder.calls.contains("artist:stub"))
        #expect(recorder.calls.contains("search:stub"))
        // 两意图各一次，且路径与意图类型一一对应（不会互相串）。
        #expect(recorder.calls.count == 2)
    }

    @Test("链上 artist 意图 tw 失败后，us 仍走 artist 路径")
    func chainKeepsArtistModeAfterFallback() async throws {
        let recorder = PathRecorder()
        let chain = RecommendationDegradingProvider(
            steps: [
                RecommendationChainStep(
                    kind: .itunesTW,
                    provider: ArtistAwareStub(name: "tw", recorder: recorder, failArtist: true),
                    minimumCandidates: 1,
                    degradedReason: nil
                ),
                RecommendationChainStep(
                    kind: .itunesUS,
                    provider: ArtistAwareStub(name: "us", recorder: recorder),
                    minimumCandidates: 1,
                    degradedReason: "itunes_us_fallback"
                ),
            ],
            budget: RecommendationRunBudget(maxDowngrades: 2),
            audit: nil
        )
        let songs = try await chain.searchArtist("周杰伦", limit: 10)
        #expect(recorder.calls == ["artist:tw", "artist:us"])
        #expect(songs.count == 1)
        #expect(songs.first?.degradedReason == "itunes_us_fallback")
    }

    @Test("关键词 query 在链上只走 search（不触发 artist 路径）")
    func chainKeywordUsesSearch() async throws {
        let recorder = PathRecorder()
        let chain = RecommendationDegradingProvider(
            steps: [
                RecommendationChainStep(
                    kind: .itunesTW,
                    provider: ArtistAwareStub(name: "tw", recorder: recorder),
                    minimumCandidates: 1,
                    degradedReason: nil
                ),
            ],
            budget: RecommendationRunBudget(maxDowngrades: 2),
            audit: nil
        )
        _ = try await chain.search(query: "夏天", limit: 10)
        #expect(recorder.calls == ["search:tw"])
    }
}

// MARK: - iTunes 请求路径

private final class P2ITunesMockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?
    nonisolated(unsafe) static var requestCount = 0

    static func reset() {
        handler = nil
        requestCount = 0
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        P2ITunesMockURLProtocol.requestCount += 1
        guard let handler = P2ITunesMockURLProtocol.handler else {
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

private func p2ITunesResponse(
    for request: URLRequest,
    search: [[String: Any]],
    lookup: [[String: Any]]
) throws -> (HTTPURLResponse, Data) {
    let isLookup = (request.url?.absoluteString.contains("id=") ?? false)
    let results = isLookup ? lookup : search
    let data = try JSONSerialization.data(withJSONObject: ["resultCount": results.count, "results": results])
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    return (response, data)
}

@Suite("推荐 P2 · iTunes 请求路径", .serialized)
struct RecommendationITunesRequestPathTests {
    private func makeProvider() -> ITunesRecommendationProvider {
        ITunesRecommendationProvider(
            storefront: "tw",
            client: ITunesScrapeClient(protocolClasses: [P2ITunesMockURLProtocol.self]),
            gate: ITunesRecommendationGate(minInterval: 0, cacheTTL: 0, sleep: { _ in }),
            budget: RecommendationRunBudget(maxDowngrades: 2, maxITunesCalls: 6)
        )
    }

    @Test("艺人路径：search→artistId→lookup 共 2 次请求")
    func artistPathDoesLookup() async throws {
        P2ITunesMockURLProtocol.reset()
        P2ITunesMockURLProtocol.handler = { request in
            try p2ITunesResponse(
                for: request,
                search: [["artistId": 42, "trackName": "hit", "artistName": "周杰伦"]],
                lookup: [["trackId": 7, "trackName": "晴天", "artistName": "周杰伦"]]
            )
        }
        let songs = try await makeProvider().searchArtist("周杰伦", limit: 20)
        #expect(songs.first?.title == "晴天")
        #expect(P2ITunesMockURLProtocol.requestCount == 2)
    }

    @Test("关键词路径：只发 1 次 song search，不 lookup 艺人碟")
    func keywordPathSkipsLookup() async throws {
        P2ITunesMockURLProtocol.reset()
        P2ITunesMockURLProtocol.handler = { request in
            try p2ITunesResponse(
                for: request,
                search: [["artistId": 42, "trackName": "夏天的风", "artistName": "温岚"]],
                lookup: []
            )
        }
        let songs = try await makeProvider().search(query: "夏天 海边", limit: 20)
        #expect(songs.first?.title == "夏天的风")
        #expect(P2ITunesMockURLProtocol.requestCount == 1)
    }
}
