//
//  HybridMusicAPITests.swift
//  QQPlayerTests
//
//  Hybrid（Spotify→Discogs）API 单元测试（MusicAPITests 拆分）：
//  - Spotify→Discogs 回退顺序、缓存复用、searchAlternativeArtist、generateNameVariations 确定性
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
    // MARK: - Fixtures：Hybrid（本文件专用）

    private static func installHybridHandler(
        spotifySearchBody: String,
        discogsSearchBody: String,
        spotifyAuthStatus: Int = 200,
        discogsDetailsStatus: Int = 200,
        discogsDetailsBody: String? = nil
    ) {
        let details = discogsDetailsBody ?? Self.discogsArtistJSON(name: "Radiohead", id: 1)
        MockURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasPrefix("https://accounts.spotify.com/api/token") {
                return MockURLProtocol.jsonResponse(Self.spotifyAuthJSON, status: spotifyAuthStatus, for: request)
            }
            if url.hasPrefix("https://api.spotify.com/v1/search") {
                return MockURLProtocol.jsonResponse(spotifySearchBody, for: request)
            }
            if url.contains("/database/search") {
                return MockURLProtocol.jsonResponse(discogsSearchBody, for: request)
            }
            return MockURLProtocol.jsonResponse(details, status: discogsDetailsStatus, for: request)
        }
    }

    // MARK: - Hybrid：回退顺序

    @Test("回退顺序：Spotify 命中则用 Spotify，不查 Discogs")
    func hybridPrefersSpotify() async throws {
        MockURLProtocol.reset()
        let service = makeHybridService(cacheDir: makeTempCacheDir("hybrid-spotify-first"))
        Self.installHybridHandler(
            spotifySearchBody: Self.spotifySearchJSON(artists: [("Radiohead", "id-rh")]),
            discogsSearchBody: Self.discogsSearchJSON(results: [(1, "Radiohead")])
        )

        let artist = try await service.searchArtist(name: "Radiohead")

        #expect(artist?.source == .spotify)
        #expect(artist?.name == "Radiohead")
        #expect(Self.spotifySearchRequests.count == 1)
        #expect(Self.discogsSearchRequests.isEmpty) // Discogs 未被查询
    }

    @Test("回退顺序：Spotify 无结果时回退 Discogs")
    func hybridFallsBackToDiscogs() async throws {
        MockURLProtocol.reset()
        let service = makeHybridService(cacheDir: makeTempCacheDir("hybrid-fallback"))
        Self.installHybridHandler(
            spotifySearchBody: Self.spotifySearchJSON(artists: []),
            discogsSearchBody: Self.discogsSearchJSON(results: [(1, "Radiohead")])
        )

        let artist = try await service.searchArtist(name: "Radiohead")

        #expect(artist?.source == .discogs)
        #expect(artist?.name == "Radiohead")
        #expect(Self.spotifySearchRequests.count == 1)
        #expect(Self.discogsSearchRequests.count == 1)
        #expect(Self.discogsDetailsRequests.count == 1)
    }

    @Test("回退顺序：Spotify 抛错时回退 Discogs")
    func hybridFallsBackWhenSpotifyThrows() async throws {
        MockURLProtocol.reset()
        let service = makeHybridService(cacheDir: makeTempCacheDir("hybrid-fallback-error"))
        Self.installHybridHandler(
            spotifySearchBody: Self.spotifySearchJSON(artists: [("Radiohead", "id-rh")]),
            discogsSearchBody: Self.discogsSearchJSON(results: [(1, "Radiohead")]),
            spotifyAuthStatus: 500
        )

        let artist = try await service.searchArtist(name: "Radiohead")
        #expect(artist?.source == .discogs)
    }

    @Test("两平台都无结果：返回 nil")
    func hybridBothEmpty() async throws {
        MockURLProtocol.reset()
        let service = makeHybridService(cacheDir: makeTempCacheDir("hybrid-both-empty"))
        Self.installHybridHandler(
            spotifySearchBody: Self.spotifySearchJSON(artists: []),
            discogsSearchBody: Self.discogsSearchJSON(results: [])
        )

        let artist = try await service.searchArtist(name: "Radiohead")
        #expect(artist == nil)
    }

    @Test("两平台都抛错：返回 nil（错误被吞掉）")
    func hybridBothFail() async throws {
        MockURLProtocol.reset()
        let service = makeHybridService(cacheDir: makeTempCacheDir("hybrid-both-fail"))
        Self.installHybridHandler(
            spotifySearchBody: Self.spotifySearchJSON(artists: []),
            discogsSearchBody: "not-json", // Discogs 解码失败
            spotifyAuthStatus: 500
        )

        let artist = try await service.searchArtist(name: "Radiohead")
        #expect(artist == nil)
    }

    // MARK: - Hybrid：缓存复用

    @Test("缓存命中（Spotify 源）：第二次不请求网络")
    func hybridCacheHitSpotify() async throws {
        MockURLProtocol.reset()
        let service = makeHybridService(cacheDir: makeTempCacheDir("hybrid-cache-spotify"))
        Self.installHybridHandler(
            spotifySearchBody: Self.spotifySearchJSON(artists: [("Radiohead", "id-rh")]),
            discogsSearchBody: Self.discogsSearchJSON(results: [])
        )

        let first = try await service.searchArtist(name: "Radiohead")
        #expect(first?.source == .spotify)
        let requestsAfterFirst = MockURLProtocol.receivedRequests.count

        let second = try await service.searchArtist(name: "Radiohead")
        #expect(second?.source == .spotify)
        #expect(MockURLProtocol.receivedRequests.count == requestsAfterFirst) // 无新增请求
    }

    @Test("缓存 Discogs 源：仍先查 Spotify，未命中才复用缓存（不再查 Discogs）")
    func hybridCachedDiscogsRechecksSpotify() async throws {
        MockURLProtocol.reset()
        let service = makeHybridService(cacheDir: makeTempCacheDir("hybrid-cache-discogs"))
        Self.installHybridHandler(
            spotifySearchBody: Self.spotifySearchJSON(artists: []),
            discogsSearchBody: Self.discogsSearchJSON(results: [(1, "Radiohead")])
        )

        let first = try await service.searchArtist(name: "Radiohead")
        #expect(first?.source == .discogs)

        let requestsAfterFirst = MockURLProtocol.receivedRequests.count
        let discogsSearchesAfterFirst = Self.discogsSearchRequests.count

        let second = try await service.searchArtist(name: "Radiohead")
        #expect(second?.source == .discogs) // 复用缓存
        #expect(Self.spotifySearchRequests.count == 2) // 又查了一次 Spotify
        #expect(Self.discogsSearchRequests.count == discogsSearchesAfterFirst) // Discogs 未再查询
        #expect(MockURLProtocol.receivedRequests.count == requestsAfterFirst + 1) // 只新增 1 次 Spotify 搜索
    }

    // MARK: - Hybrid：searchAlternativeArtist

    @Test("searchAlternativeArtist：Spotify 源时只查 Discogs")
    func hybridAlternativeFromSpotify() async throws {
        MockURLProtocol.reset()
        let service = makeHybridService(cacheDir: makeTempCacheDir("hybrid-alt-spotify"))
        Self.installHybridHandler(
            spotifySearchBody: Self.spotifySearchJSON(artists: [("Radiohead", "id-rh")]),
            discogsSearchBody: Self.discogsSearchJSON(results: [(1, "Radiohead")])
        )

        let artist = try await service.searchAlternativeArtist(name: "Radiohead", currentSource: .spotify)

        #expect(artist?.source == .discogs)
        #expect(Self.spotifySearchRequests.isEmpty) // 不查 Spotify
        #expect(Self.discogsSearchRequests.count == 1)
    }

    @Test("searchAlternativeArtist：Discogs 源时只查 Spotify")
    func hybridAlternativeFromDiscogs() async throws {
        MockURLProtocol.reset()
        let service = makeHybridService(cacheDir: makeTempCacheDir("hybrid-alt-discogs"))
        Self.installHybridHandler(
            spotifySearchBody: Self.spotifySearchJSON(artists: [("Radiohead", "id-rh")]),
            discogsSearchBody: Self.discogsSearchJSON(results: [(1, "Radiohead")])
        )

        let artist = try await service.searchAlternativeArtist(name: "Radiohead", currentSource: .discogs)

        #expect(artist?.source == .spotify)
        #expect(Self.discogsSearchRequests.isEmpty)
        #expect(Self.spotifySearchRequests.count == 1)
    }

    @Test("generateNameVariations：去掉常见后缀与括号内容，保持生成顺序")
    func nameVariationsOrderAndDedup() {
        let service = makeHybridService(cacheDir: makeTempCacheDir("variations-order"))

        #expect(service.generateNameVariations("Radiohead - Topic") == ["Radiohead", "The Radiohead - Topic"])
        // 去 "The" 前缀从完整原名上做 dropFirst，括号内容保留
        #expect(service.generateNameVariations("The Beatles (Remastered)") == ["The Beatles", "Beatles (Remastered)"])
        // 括号正则只删括号内容不折叠内部空白（现状锁定）
        #expect(service.generateNameVariations("Artist (Live) - Topic") == ["Artist (Live)", "Artist  - Topic", "The Artist (Live) - Topic"])
    }

    @Test("generateNameVariations：去重且最多 3 个")
    func nameVariationsDedupAndLimit() {
        let service = makeHybridService(cacheDir: makeTempCacheDir("variations-limit"))

        let variations = service.generateNameVariations("X - Topic (Official)")
        #expect(variations.count <= 3)
        #expect(variations.count == Set(variations).count) // 无重复
        #expect(variations.contains("X - Topic")) // 括号清理与后缀清理产出的重复项被去重
    }

    @Test("searchSimilarArtist：按变体顺序尝试，首个命中即返回")
    func hybridSearchSimilar() async throws {
        MockURLProtocol.reset()
        let service = makeHybridService(cacheDir: makeTempCacheDir("hybrid-similar"))

        // "Radiohead - Topic" → 变体 ["Radiohead", "The Radiohead - Topic"]（跳过原词），
        // 只有 "Radiohead" 有结果 → 第二个变体不应被查询
        let hitJSON = Self.spotifySearchJSON(artists: [("Radiohead", "id-rh")])
        let missJSON = Self.spotifySearchJSON(artists: [])
        MockURLProtocol.handler = { request in
            let url = request.url?.absoluteString ?? ""
            if url.hasPrefix("https://accounts.spotify.com/api/token") {
                return MockURLProtocol.jsonResponse(Self.spotifyAuthJSON, for: request)
            }
            if url.hasPrefix("https://api.spotify.com/v1/search") {
                let query = url.components(separatedBy: "q=").last ?? ""
                return MockURLProtocol.jsonResponse(query.hasPrefix("Radiohead&") ? hitJSON : missJSON, for: request)
            }
            if url.contains("/database/search") {
                return MockURLProtocol.jsonResponse(missJSON, for: request)
            }
            return MockURLProtocol.jsonResponse(Self.discogsArtistJSON(name: "x", id: 1), for: request)
        }

        let artist = try await service.searchSimilarArtist(originalName: "Radiohead - Topic", currentSource: nil)

        #expect(artist?.name == "Radiohead")
        #expect(artist?.source == .spotify)
        #expect(Self.spotifySearchRequests.count == 1) // 只查询了第一个变体 "Radiohead"
    }
}
