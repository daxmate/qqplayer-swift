//
//  SpotifyAPITests.swift
//  QQPlayerTests
//
//  Spotify API 单元测试（MusicAPITests 拆分）：
//  - token 获取成功 / 401 / 403、token 过期自动刷新、搜索解码现状锁定、findBestMatch、缓存
//  - MockURLProtocol 拦截全部请求，无真实网络
//
//  本文件是 @Suite(.serialized) struct MusicAPITests 的 extension（骨架与共享基建在
//  MusicAPIMockSupport.swift）：MockURLProtocol 的 handler / 请求记录是进程级静态状态，
//  拆成多个独立套件会跨套件并行执行互相覆盖。
//

import Foundation
import Testing

@testable import QQPlayer

extension MusicAPITests {
    // MARK: - Fixtures：Spotify（本文件专用）

    private static func installSpotifyHandler(
        authStatus: Int = 200,
        authBody: String? = nil,
        searchStatus: Int = 200,
        searchBody: String? = nil
    ) {
        let auth = authBody ?? Self.spotifyAuthJSON
        let search = searchBody ?? Self.spotifySearchJSON(artists: [])
        MockURLProtocol.handler = { request in
            if request.url?.absoluteString.hasPrefix("https://accounts.spotify.com/api/token") == true {
                return MockURLProtocol.jsonResponse(auth, status: authStatus, for: request)
            }
            return MockURLProtocol.jsonResponse(search, status: searchStatus, for: request)
        }
    }

    private func expectSpotifyError(_ expected: SpotifyAPIError, _ body: () async throws -> Void) async {
        do {
            try await body()
            Issue.record("应抛出 \(expected)，但成功返回")
        } catch let error as SpotifyAPIError {
            switch (expected, error) {
            case (.httpError(let expectedCode), .httpError(let actualCode)):
                #expect(expectedCode == actualCode)
            case (.forbidden(let expectedBody), .forbidden(let actualBody)):
                #expect(expectedBody == actualBody)
            default:
                Issue.record("错误不匹配：期望 \(expected)，实际 \(error)")
            }
        } catch {
            Issue.record("错误类型不匹配：期望 SpotifyAPIError，实际 \(error)")
        }
    }

    // MARK: - Spotify：token 获取

    @Test("token 获取成功：搜索携带 Bearer token 并返回匹配艺人")
    func spotifyAuthSuccess() async throws {
        MockURLProtocol.reset()
        let service = makeSpotifyService(cacheDir: makeTempCacheDir("spotify-auth-ok"))
        Self.installSpotifyHandler(searchBody: Self.spotifySearchJSON(artists: [("Radiohead", "id-rh")]))

        let artist = try await service.searchArtist(name: "Radiohead")

        #expect(artist?.name == "Radiohead")
        #expect(Self.spotifyAuthRequests.count == 1)
        // Basic base64("fake-client:fake-secret")
        let expected = "Basic " + Data("fake-client:fake-secret".utf8).base64EncodedString()
        #expect(Self.spotifyAuthRequests.first?.value(forHTTPHeaderField: "Authorization") == expected)
        #expect(Self.spotifySearchRequests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token-1")
    }

    @Test("认证接口 401：抛 httpError(401)，不再发起搜索")
    func spotifyAuth401() async {
        MockURLProtocol.reset()
        let service = makeSpotifyService(cacheDir: makeTempCacheDir("spotify-auth-401"))
        Self.installSpotifyHandler(authStatus: 401, authBody: #"{"error":"invalid_client"}"#)

        await expectSpotifyError(.httpError(401)) {
            _ = try await service.searchArtist(name: "Radiohead")
        }
        #expect(Self.spotifyAuthRequests.count == 1)
        #expect(Self.spotifySearchRequests.isEmpty)
    }

    @Test("token 过期后自动刷新：两次搜索分别使用新 token")
    func spotifyTokenRefresh() async throws {
        MockURLProtocol.reset()
        let service = makeSpotifyService(cacheDir: makeTempCacheDir("spotify-refresh"))

        // expires_in=59 → expiresAt 取 now-1s，立即视为过期 → 每次搜索都会重新取 token
        let authCalls = Box(0)
        MockURLProtocol.handler = { request in
            if request.url?.absoluteString.hasPrefix("https://accounts.spotify.com/api/token") == true {
                authCalls.value += 1
                let body = #"{"access_token":"tok-\#(authCalls.value)","token_type":"Bearer","expires_in":59}"#
                return MockURLProtocol.jsonResponse(body, for: request)
            }
            return MockURLProtocol.jsonResponse(Self.spotifySearchJSON(artists: [("Radiohead", "id-rh")]), for: request)
        }

        let first = try await service.searchArtist(name: "Radiohead")
        #expect(first?.name == "Radiohead")
        let second = try await service.searchArtist(name: "Radiohead II") // 不同名字避开艺人缓存
        #expect(second?.name == "Radiohead")

        #expect(Self.spotifyAuthRequests.count == 2)
        #expect(Self.spotifySearchRequests.count == 2)
        // 第二次搜索必须使用刷新后的 token
        #expect(Self.spotifySearchRequests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer tok-2")
    }

    @Test("token 未过期：连续搜索只获取一次 token")
    func spotifyTokenReuse() async throws {
        MockURLProtocol.reset()
        let service = makeSpotifyService(cacheDir: makeTempCacheDir("spotify-reuse"))
        Self.installSpotifyHandler(searchBody: Self.spotifySearchJSON(artists: [("Radiohead", "id-rh")]))

        _ = try await service.searchArtist(name: "Radiohead")
        _ = try await service.searchArtist(name: "Coldplay")

        #expect(Self.spotifyAuthRequests.count == 1)
        #expect(Self.spotifySearchRequests.count == 2)
    }

    @Test("搜索接口 401：抛 httpError(401)，不触发 token 刷新（锁现状）")
    func spotifySearch401DoesNotRefresh() async {
        MockURLProtocol.reset()
        let service = makeSpotifyService(cacheDir: makeTempCacheDir("spotify-search-401"))
        Self.installSpotifyHandler(searchStatus: 401, searchBody: #"{"error":{"message":"Invalid access token"}}"#)

        await expectSpotifyError(.httpError(401)) {
            _ = try await service.searchArtist(name: "Radiohead")
        }
        #expect(Self.spotifyAuthRequests.count == 1) // 只取了一次 token，没有刷新重试
    }

    @Test("搜索接口 403：抛 forbidden 并携带响应体")
    func spotifySearch403Forbidden() async {
        MockURLProtocol.reset()
        let service = makeSpotifyService(cacheDir: makeTempCacheDir("spotify-search-403"))
        Self.installSpotifyHandler(searchStatus: 403, searchBody: #"{"error":"rate limited"}"#)

        await expectSpotifyError(.forbidden(#"{"error":"rate limited"}"#)) {
            _ = try await service.searchArtist(name: "Radiohead")
        }
    }

    // MARK: - Spotify：搜索解码

    @Test("搜索解码：缺少必填字段抛 DecodingError（现状：字段全非 Optional）")
    func spotifyDecodeMissingField() async {
        MockURLProtocol.reset()
        let service = makeSpotifyService(cacheDir: makeTempCacheDir("spotify-decode"))
        // 艺人对象缺 popularity（当前模型非 Optional，缺失即解码失败）——锁现状
        let malformed = """
        {"artists":{"href":"h","items":[{"id":"id-1","name":"Radiohead","genres":[],"images":[],\
        "followers":{"href":null,"total":1},"external_urls":{"spotify":"s"},"href":"h","uri":"u"}],\
        "limit":10,"next":null,"offset":0,"previous":null,"total":1}}
        """
        Self.installSpotifyHandler(searchBody: malformed)

        do {
            _ = try await service.searchArtist(name: "Radiohead")
            Issue.record("缺少 popularity 字段应解码失败")
        } catch is DecodingError {
            // 现状锁定：解码失败直接抛出
        } catch {
            Issue.record("期望 DecodingError，实际 \(error)")
        }
    }

    // MARK: - Spotify：findBestMatch

    @Test("findBestMatch：精确匹配优先于部分匹配")
    func spotifyBestMatchExactWins() async throws {
        MockURLProtocol.reset()
        let service = makeSpotifyService(cacheDir: makeTempCacheDir("spotify-exact"))
        Self.installSpotifyHandler(searchBody: Self.spotifySearchJSON(artists: [("Radiohead - Live", "id-1"), ("Radiohead", "id-2")]))

        let artist = try await service.searchArtist(name: "Radiohead")
        #expect(artist?.id == "id-2")
    }

    @Test("findBestMatch：大小写与标点归一后可精确匹配")
    func spotifyBestMatchNormalization() async throws {
        MockURLProtocol.reset()
        let service = makeSpotifyService(cacheDir: makeTempCacheDir("spotify-norm"))
        Self.installSpotifyHandler(searchBody: Self.spotifySearchJSON(artists: [("Radiohead", "id-1")]))

        let artist = try await service.searchArtist(name: "RADIOHEAD.")
        #expect(artist?.id == "id-1")
    }

    @Test("findBestMatch：无精确匹配时部分匹配（子串命中）")
    func spotifyBestMatchPartial() async throws {
        MockURLProtocol.reset()
        let service = makeSpotifyService(cacheDir: makeTempCacheDir("spotify-partial"))
        Self.installSpotifyHandler(searchBody: Self.spotifySearchJSON(artists: [("The Beatles", "id-1"), ("Radiohead in Concert", "id-2")]))

        let artist = try await service.searchArtist(name: "Radiohead")
        #expect(artist?.id == "id-2")
    }

    @Test("findBestMatch：无匹配时回退第一个结果")
    func spotifyBestMatchFallsBackToFirst() async throws {
        MockURLProtocol.reset()
        let service = makeSpotifyService(cacheDir: makeTempCacheDir("spotify-fallback"))
        Self.installSpotifyHandler(searchBody: Self.spotifySearchJSON(artists: [("The Beatles", "id-1"), ("Pink Floyd", "id-2")]))

        let artist = try await service.searchArtist(name: "Radiohead")
        #expect(artist?.id == "id-1")
    }

    @Test("findBestMatch：空结果返回 nil")
    func spotifyBestMatchNoResults() async throws {
        MockURLProtocol.reset()
        let service = makeSpotifyService(cacheDir: makeTempCacheDir("spotify-empty"))
        Self.installSpotifyHandler(searchBody: Self.spotifySearchJSON(artists: []))

        let artist = try await service.searchArtist(name: "Radiohead")
        #expect(artist == nil)
    }

    // MARK: - Spotify：缓存

    @Test("缓存命中：第二次搜索不发起网络请求")
    func spotifyCacheHit() async throws {
        MockURLProtocol.reset()
        let service = makeSpotifyService(cacheDir: makeTempCacheDir("spotify-cache-hit"))
        Self.installSpotifyHandler(searchBody: Self.spotifySearchJSON(artists: [("Adele", "id-adele")]))

        let first = try await service.searchArtist(name: "Adele")
        #expect(first?.id == "id-adele")
        #expect(MockURLProtocol.receivedRequests.count == 2) // auth + search

        let second = try await service.searchArtist(name: "Adele")
        #expect(second?.id == "id-adele")
        #expect(MockURLProtocol.receivedRequests.count == 2) // 无新增请求
    }

    @Test("过期磁盘缓存：不命中，重新拉取并覆盖")
    func spotifyCacheExpiredRefetches() async throws {
        MockURLProtocol.reset()
        let cacheDir = makeTempCacheDir("spotify-cache-expired")
        let service = makeSpotifyService(cacheDir: cacheDir)
        Self.installSpotifyHandler(searchBody: Self.spotifySearchJSON(artists: [("Adele", "id-adele")]))

        // 预写一份 8 天前的过期磁盘缓存（同构 Codable，直接落盘）
        let stale = CachedSpotifyArtistInfo(
            artistName: "Adele",
            spotifyArtist: Self.staleSpotifyArtist(),
            cachedAt: Date().addingTimeInterval(-8 * 24 * 3600)
        )
        let fileURL = cacheDir.appendingPathComponent("adele.json")
        try Data(try JSONEncoder().encode(stale)).write(to: fileURL)

        let artist = try await service.searchArtist(name: "Adele")

        #expect(artist?.name == "Adele") // 新鲜结果，而非过期数据
        #expect(MockURLProtocol.receivedRequests.count == 2) // 走了网络

        // 磁盘缓存被新数据覆盖
        let refreshed = try JSONDecoder().decode(CachedSpotifyArtistInfo.self, from: Data(contentsOf: fileURL))
        #expect(refreshed.spotifyArtist.name == "Adele")
        #expect(refreshed.cachedAt > Date().addingTimeInterval(-60))
    }

    private static func staleSpotifyArtist() -> SpotifyArtist {
        SpotifyArtist(
            id: "id-stale",
            name: "Stale Adele",
            genres: [],
            images: [],
            popularity: 1,
            followers: SpotifyFollowers(href: nil, total: 1),
            externalUrls: SpotifyExternalUrls(spotify: "https://open.spotify.com/artist/id-stale"),
            href: "https://api.spotify.com/v1/artists/id-stale",
            uri: "spotify:artist:id-stale"
        )
    }
}
