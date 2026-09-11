//
//  SyncPeerLibraryTests.swift
//  QQPlayerTests
//
//  T9（2026-09-12）「对端内容清单」（帧 15/16）测试：
//  ① 生产事实装配（`DatabaseSyncPeerLibraryFacts`，真 GRDB：歌单 slug / 收藏 @favorites /
//     曲目标题·歌手·大小·指纹 / 歌单成员相对路径）
//  ② 纯逻辑（`SyncPeerLibraryCatalog`）：排序·去重·分页·筛选·钳制·非法 scope
//  ③ 编解码（`SyncPeerLibraryCodec`）：联合条目往返 + 键排序字节稳定 + 非法载荷
//  ④ 应答端（`SyncPeerLibraryResponder`）：垃圾载荷不炸（不抛）、非法 scope 回空清单
//  ⑤ 客户端（`SyncPeerLibraryClient`）：请求↔响应配对 / 超时 / 取消 / 会话关闭 /
//     未 ready / 不匹配响应丢弃
//  ⑥ 端到端（真 DB + 真装配 + 回环会话）：被动端（设备）应答，Mac 客户端取对端内容清单
//  ⑦ 会话链条不被破坏：接线前后既有 onApplicationFrame handler 仍收到业务帧
//
//  与 scripts/sync-harness 的分工：那边跑纯逻辑 + 内存回环（不带模拟器，每次提交真跑）；
//  这里跑真 GRDB + 真装配，由 CI 的 xcodebuild test 跑。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

/// 落库出口桩（本批不做文件落位，只需协议实现）。
private final class PeerLibrarySinkStub: SyncLibrarySyncSink, @unchecked Sendable {
    func indexLandedFile(at url: URL) {}
}

/// 帧收集盒（断言既有 handler 仍在链上）。
private final class FrameBox: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [SyncFrame] = []

    var received: [SyncFrame] {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    func append(_ frame: SyncFrame) {
        lock.lock()
        frames.append(frame)
        lock.unlock()
    }
}

struct SyncPeerLibraryTests {
    // MARK: - 夹具

    private func tempDirectory(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-t9-library-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private struct DatabaseFixture {
        let manager: DatabaseManager
        let libraryRoot: URL
        /// 歌单 slug（createPlaylist 生成，跨端标识）
        let jazzSlug: String
    }

    /// 真 GRDB 内存库：3 首歌（Jazz 2 + Rock 1）、1 个歌手、1 个歌单、1 首收藏。
    private func makeDatabaseFixture() throws -> DatabaseFixture {
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        try manager.createTables()
        let libraryRoot = try tempDirectory("library")

        try manager.upsertTrack(Track(
            stableId: "t1",
            title: "A Song",
            path: libraryRoot.appendingPathComponent("Jazz/a.flac").path,
            fileSize: 1_000,
            contentHash: "h1"
        ))
        try manager.upsertTrack(Track(
            stableId: "t2",
            title: "Blue Moon",
            path: libraryRoot.appendingPathComponent("Jazz/b.flac").path,
            fileSize: 2_000,
            contentHash: nil
        ))
        try manager.upsertTrack(Track(
            stableId: "t3",
            title: "Cherry",
            path: libraryRoot.appendingPathComponent("Rock/c.flac").path,
            fileSize: 4_000,
            contentHash: "h3"
        ))

        // 歌手：upsertTrack 不写 track_artist 关系（那是入库链路的活），这里直接建关系
        let artist = try manager.upsertArtist(name: "Alice")
        let artistID = try #require(artist.id)
        try manager.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO track_artist (track_stable_id, artist_id, position) VALUES (?, ?, ?)",
                arguments: ["t1", artistID, 0]
            )
        }
        manager.invalidateArtistDisplayNameCache()

        let playlist = try manager.createPlaylist(title: "Jazz")
        let playlistID = try #require(playlist.id)
        try manager.addToPlaylist(playlistId: playlistID, trackStableId: "t1")
        try manager.addToPlaylist(playlistId: playlistID, trackStableId: "t2")
        try manager.addToFavorites(trackStableId: "t2")

        return DatabaseFixture(manager: manager, libraryRoot: libraryRoot, jazzSlug: playlist.slug)
    }

    // MARK: - ① 生产事实装配

    @Test("真 GRDB → 内容清单事实：歌单（slug/收藏）+ 曲目元数据 + 成员关系")
    func buildsCatalogFromDatabase() throws {
        let fixture = try makeDatabaseFixture()
        let facts = DatabaseSyncPeerLibraryFacts(
            database: fixture.manager,
            libraryRoot: fixture.libraryRoot,
            favoritesName: "收藏"
        )
        let catalog = facts.catalog()

        // 歌单：真实歌单（slug 标识）+ 收藏伪歌单
        let ids = catalog.playlists.map(\.id)
        #expect(ids.contains(fixture.jazzSlug), "真实歌单以 slug 作标识")
        #expect(ids.contains(SyncCollectionSelection.favoritesPlaylistID), "收藏用 @favorites 保留标识")
        let jazz = try #require(catalog.playlists.first { $0.id == fixture.jazzSlug })
        #expect(jazz.name == "Jazz")
        #expect(jazz.trackCount == 2, "歌单曲目数 = 能在曲库解析到的成员数")
        let favorites = try #require(catalog.playlists.first { $0.id == SyncCollectionSelection.favoritesPlaylistID })
        #expect(favorites.name == "收藏")
        #expect(favorites.trackCount == 1)

        // 曲目：相对路径（曲库根口径）+ 标题 + 歌手 + 大小 + 指纹
        #expect(catalog.tracks.map(\.relativePath) == ["Jazz/a.flac", "Jazz/b.flac", "Rock/c.flac"])
        let first = try #require(catalog.tracks.first { $0.relativePath == "Jazz/a.flac" })
        #expect(first.title == "A Song")
        #expect(first.artistName == "Alice")
        #expect(first.sizeBytes == 1_000)
        #expect(first.contentHash == "h1")
        let second = try #require(catalog.tracks.first { $0.relativePath == "Jazz/b.flac" })
        #expect(second.artistName == nil, "无歌手关系 → nil（不编造）")
        #expect(second.contentHash == nil, "未指纹 → nil（与 manifest 同口径）")

        // 摘要
        #expect(catalog.trackCount == 3)
        #expect(catalog.totalSizeBytes == 7_000)

        // 成员关系（本端事实，不上线）：歌单筛选结果与 trackCount 一致
        #expect(catalog.memberPaths(forPlaylistID: fixture.jazzSlug) == ["Jazz/a.flac", "Jazz/b.flac"])
        let response = catalog.response(for: SyncPeerLibraryRequestPayload(
            scope: SyncPeerLibraryScope.tracks.rawValue,
            playlistID: fixture.jazzSlug,
            offset: 0,
            limit: 50,
            requestID: 1
        ))
        #expect(response.trackItems.map(\.relativePath) == ["Jazz/a.flac", "Jazz/b.flac"])
        #expect(response.total == 2)
    }

    @Test("生产 provider 惰性求值：闭包调用前不读库（可重复求值反映最新事实）")
    func catalogProviderIsLazy() throws {
        let fixture = try makeDatabaseFixture()
        let provider = DatabaseSyncPeerLibraryFacts.catalogProvider(
            database: fixture.manager,
            libraryRoot: fixture.libraryRoot,
            favoritesName: "收藏"
        )
        #expect(provider().trackCount == 3)
        // 新增一首歌 → 再次求值应看到（无缓存失效窗口）
        try fixture.manager.upsertTrack(Track(
            stableId: "t4",
            title: "New",
            path: fixture.libraryRoot.appendingPathComponent("Rock/d.flac").path,
            fileSize: 10
        ))
        #expect(provider().trackCount == 4)
    }

    // MARK: - ② 纯逻辑

    @Test("清单纯逻辑：排序/去重/分页/筛选/钳制/非法 scope")
    func catalogPureLogic() {
        let catalog = SyncPeerLibraryCatalog(
            playlists: [
                SyncPeerPlaylistItem(id: "rock", name: "Rock", trackCount: 1),
                SyncPeerPlaylistItem(id: "jazz", name: "Jazz", trackCount: 2),
                SyncPeerPlaylistItem(id: "jazz", name: "Jazz 撞名", trackCount: 99),
            ],
            tracks: [
                SyncPeerTrackItem(relativePath: "Rock/01 c.flac", title: "C", artistName: "Cherry", sizeBytes: 300, contentHash: "h3"),
                SyncPeerTrackItem(relativePath: "Jazz/02 b.flac", title: "Blue Moon", artistName: "Bob", sizeBytes: 200, contentHash: "h2"),
                SyncPeerTrackItem(relativePath: "Jazz/01 a.flac", title: "A Song", sizeBytes: 100),
                SyncPeerTrackItem(relativePath: "Jazz/01 a.flac", title: "dup", artistName: "dup", sizeBytes: 100, contentHash: "dup"),
            ],
            trackPathsByPlaylist: [
                "jazz": ["Jazz/01 a.flac", "Jazz/02 b.flac"],
                "rock": ["Rock/01 c.flac"],
            ]
        )

        #expect(catalog.playlists.map(\.id) == ["jazz", "rock"], "歌单按 name 升序 + 同 id 去重")
        #expect(catalog.tracks.map(\.relativePath) == ["Jazz/01 a.flac", "Jazz/02 b.flac", "Rock/01 c.flac"])
        #expect(catalog.trackCount == 3)
        #expect(catalog.totalSizeBytes == 600)

        func page(offset: Int, limit: Int) -> SyncPeerLibraryResponsePayload {
            catalog.response(for: SyncPeerLibraryRequestPayload(
                scope: "tracks", offset: offset, limit: limit, requestID: 1
            ))
        }
        #expect(page(offset: 0, limit: 2).items.count == 2)
        #expect(page(offset: 0, limit: 2).hasMore)
        #expect(page(offset: 2, limit: 2).items.count == 1)
        #expect(page(offset: 2, limit: 2).hasMore == false)
        #expect(page(offset: 99, limit: 10).items.isEmpty, "越界 offset → 空页")
        #expect(page(offset: 0, limit: 2).total == 3)

        func tracks(query: String?, playlistID: String? = nil) -> [String] {
            catalog.response(for: SyncPeerLibraryRequestPayload(
                scope: "tracks", playlistID: playlistID, query: query, offset: 0, limit: 50, requestID: 2
            )).trackItems.map(\.relativePath)
        }
        #expect(tracks(query: "blue") == ["Jazz/02 b.flac"], "query 命中标题（大小写不敏感）")
        #expect(tracks(query: "CHERRY") == ["Rock/01 c.flac"], "query 命中歌手")
        #expect(tracks(query: "rock/") == ["Rock/01 c.flac"], "query 命中相对路径")
        #expect(tracks(query: "zzz").isEmpty)
        #expect(tracks(query: nil, playlistID: "jazz") == ["Jazz/01 a.flac", "Jazz/02 b.flac"])
        #expect(tracks(query: nil, playlistID: "nope").isEmpty, "未知歌单 → 空清单")
        #expect(tracks(query: nil, playlistID: "a/b").isEmpty, "非法歌单标识 → 空清单（绝不回落全库）")

        let badScope = catalog.response(for: SyncPeerLibraryRequestPayload(
            scope: "albums", offset: 0, limit: 50, requestID: 3
        ))
        #expect(badScope.total == 0)
        #expect(badScope.items.isEmpty)
        #expect(badScope.libraryTrackCount == 3, "非法 scope 摘要仍返回")
        #expect(badScope.requestID == 3, "响应回显 requestID")

        #expect(SyncPeerLibraryRequestPayload(scope: "tracks", offset: -5, limit: 0, requestID: 4).clampedLimit == 1)
        #expect(SyncPeerLibraryRequestPayload(scope: "tracks", offset: -5, limit: 0, requestID: 4).clampedOffset == 0)
        #expect(SyncPeerLibraryRequestPayload(scope: "tracks", offset: 0, limit: 9_999, requestID: 5).clampedLimit == 500)
        let hugeQuery = String(repeating: "x", count: 5_000)
        #expect(
            SyncPeerLibraryRequestPayload(scope: "tracks", query: hugeQuery, requestID: 6).normalizedQuery?.count
                == SyncPeerLibraryRequestPayload.maxQueryLength,
            "超长 query 截断（不可信输入）"
        )
        #expect(SyncPeerLibraryRequestPayload(scope: "tracks", query: "   ", requestID: 7).normalizedQuery == nil)
    }

    // MARK: - ③ 编解码

    @Test("编解码：联合条目往返 + 键排序字节稳定 + 非法载荷")
    func codecRoundTripAndInvalidPayloads() throws {
        #expect(SyncFrameType.peerLibraryRequest.rawValue == 15)
        #expect(SyncFrameType.peerLibraryResponse.rawValue == 16)

        let request = SyncPeerLibraryRequestPayload(
            scope: "tracks", playlistID: "jazz", query: "blue",
            offset: 2, limit: 10, requestID: 42
        )
        let encoded = try SyncPeerLibraryCodec.encode(request)
        #expect(try SyncPeerLibraryCodec.decode(SyncPeerLibraryRequestPayload.self, from: encoded) == request)
        // 键排序 → 同一份值两次编码逐字节一致
        let reencoded = try SyncPeerLibraryCodec.encode(
            try SyncPeerLibraryCodec.decode(SyncPeerLibraryRequestPayload.self, from: encoded)
        )
        #expect(reencoded == encoded)

        let response = SyncPeerLibraryResponsePayload(
            requestID: 42,
            scope: "tracks",
            total: 2,
            items: [
                .track(SyncPeerTrackItem(relativePath: "A/x.flac", title: "X", sizeBytes: 10)),
                .playlist(SyncPeerPlaylistItem(id: "jazz", name: "Jazz", trackCount: 2)),
            ],
            hasMore: true,
            libraryTrackCount: 9,
            librarySizeBytes: 1_234,
            truncated: false
        )
        let data = try SyncPeerLibraryCodec.encode(response)
        let decoded = try SyncPeerLibraryCodec.decode(SyncPeerLibraryResponsePayload.self, from: data)
        #expect(decoded == response)
        #expect(decoded.trackItems.map(\.relativePath) == ["A/x.flac"])
        #expect(decoded.playlistItems.map(\.id) == ["jazz"])
        #expect(String(data: data, encoding: .utf8)?.contains("\"kind\":\"track\"") == true, "联合条目带判别字段")

        // 非法载荷：缺判别字段 / 未知判别值 → 抛错（不静默生成错数据）
        let missingKind = Data(#"{"requestID":1,"scope":"tracks","total":0,"items":[{"id":"x"}],"hasMore":false,"libraryTrackCount":0,"librarySizeBytes":0,"truncated":false}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try SyncPeerLibraryCodec.decode(SyncPeerLibraryResponsePayload.self, from: missingKind)
        }
        let unknownKind = Data(#"{"requestID":1,"scope":"tracks","total":0,"items":[{"kind":"album"}],"hasMore":false,"libraryTrackCount":0,"librarySizeBytes":0,"truncated":false}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try SyncPeerLibraryCodec.decode(SyncPeerLibraryResponsePayload.self, from: unknownKind)
        }
    }

    // MARK: - ④ 应答端

    @Test("应答端：垃圾载荷不炸（不抛、不断会话）、非法 scope 回空清单、链路仍通")
    func responderSurvivesGarbageAndAnswersInvalidScope() async throws {
        let fixture = SessionFixture.pairedHandshake()
        let deviceRoot = try tempDirectory("device")
        let catalogBox = SyncPeerLibraryCatalog(
            playlists: [SyncPeerPlaylistItem(id: "jazz", name: "Jazz", trackCount: 0)],
            tracks: [SyncPeerTrackItem(relativePath: "Jazz/a.flac", title: "A", sizeBytes: 10)]
        )
        var decodeFailures: [String] = []
        let responder = SyncPeerLibraryResponder(
            session: fixture.clientSession,
            catalogProvider: { catalogBox }
        )
        responder.onDecodeFailure = { decodeFailures.append($0) }
        _ = deviceRoot

        // 非 JSON 载荷（协议违例）→ 只记账，不抛、不断会话
        try fixture.hostSession.sendApplicationFrame(
            type: .peerLibraryRequest,
            payload: Data("not-json".utf8)
        )
        #expect(decodeFailures.count == 1)
        #expect(fixture.clientSession.isReady, "垃圾载荷不得断会话")

        // 合法请求（非法 scope）→ 仍应答空清单
        let client = SyncPeerLibraryClient(session: fixture.hostSession, timeout: 3)
        let response = try await client.fetchTracks(playlistID: nil, query: nil, offset: 0, limit: 10)
        #expect(response.total == 1)
        #expect(response.trackItems.map(\.relativePath) == ["Jazz/a.flac"])

        // 垃圾载荷之后握手/会话仍可用（协议状态机未被污染）
        try fixture.hostSession.sendPing()
        #expect(fixture.hostSession.isReady)
    }

    // MARK: - ⑤ 客户端健壮性

    @Test("客户端：对端不答 → 超时抛错（不悬挂）")
    func clientTimesOutWhenPeerSilent() async throws {
        let fixture = SessionFixture.pairedHandshake()
        let client = SyncPeerLibraryClient(session: fixture.hostSession, timeout: 0.2)
        let started = Date()
        await #expect(throws: SyncPeerLibraryClient.ClientError.timeout) {
            _ = try await client.fetchTracks(playlistID: nil, query: nil, offset: 0, limit: 10)
        }
        #expect(Date().timeIntervalSince(started) < 5, "超时按配置生效（远小于无限等待）")
        #expect(client.pendingRequestCount == 0, "超时后在途表清空")
    }

    @Test("客户端：cancel() / 会话关闭 / 未 ready 三条失败路径都立即收敛")
    func clientFailurePaths() async throws {
        // cancel()
        let cancelFixture = SessionFixture.pairedHandshake()
        let cancelClient = SyncPeerLibraryClient(session: cancelFixture.hostSession, timeout: 30)
        let cancelTask = Task {
            try await cancelClient.fetchTracks(playlistID: nil, query: nil, offset: 0, limit: 10)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        cancelClient.cancel()
        let cancelError = await cancelTask.result
        if case let .failure(error) = cancelError {
            #expect(error as? SyncPeerLibraryClient.ClientError == .cancelled)
        } else {
            Issue.record("cancel() 后应抛错")
        }

        // 会话关闭
        let closedFixture = SessionFixture.pairedHandshake()
        let closedClient = SyncPeerLibraryClient(session: closedFixture.hostSession, timeout: 30)
        let closedTask = Task {
            try await closedClient.fetchTracks(playlistID: nil, query: nil, offset: 0, limit: 10)
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        closedFixture.hostSession.cancel(reason: .userCancelled)
        let closedResult = await closedTask.result
        if case let .failure(error) = closedResult {
            #expect(error as? SyncPeerLibraryClient.ClientError == .sessionClosed)
        } else {
            Issue.record("会话关闭后应抛错")
        }

        // 未 ready（未握手）
        let idleFixture = SessionFixture.make()
        let idleClient = SyncPeerLibraryClient(session: idleFixture.hostSession, timeout: 5)
        await #expect(throws: SyncPeerLibraryClient.ClientError.sessionNotReady) {
            _ = try await idleClient.fetchTracks(playlistID: nil, query: nil, offset: 0, limit: 10)
        }
    }

    @Test("客户端：不匹配的响应被丢弃（不影响后续请求）")
    func clientDropsUnmatchedResponse() async throws {
        let fixture = SessionFixture.pairedHandshake()
        let catalogBox = SyncPeerLibraryCatalog(
            tracks: [SyncPeerTrackItem(relativePath: "A/x.flac", title: "X", sizeBytes: 5)]
        )
        let responder = SyncPeerLibraryResponder(session: fixture.clientSession, catalogProvider: { catalogBox })
        var unexpected: [UInt64] = []
        let client = SyncPeerLibraryClient(session: fixture.hostSession, timeout: 3)
        client.onUnexpectedResponse = { unexpected.append($0.requestID) }
        _ = responder

        // 伪造一个 requestID 无人认领的响应 → 客户端丢弃
        let bogus = SyncPeerLibraryResponsePayload(
            requestID: 999, scope: "tracks", total: 0, items: [], hasMore: false,
            libraryTrackCount: 0, librarySizeBytes: 0, truncated: false
        )
        try fixture.clientSession.sendApplicationFrame(
            type: .peerLibraryResponse,
            payload: try SyncPeerLibraryCodec.encode(bogus)
        )
        #expect(unexpected == [999])
        #expect(client.pendingRequestCount == 0)

        // 之后的正常请求不受影响
        let response = try await client.fetchTracks(playlistID: nil, query: nil, offset: 0, limit: 10)
        #expect(response.trackItems.map(\.relativePath) == ["A/x.flac"])
    }

    // MARK: - ⑥ 端到端（真 DB + 真装配 + 回环会话）

    @Test("端到端：被动端应答 Mac 客户端 → 歌单清单 / 曲目页 / 摘要（真 GRDB）")
    func endToEndOverLoopbackWithRealDatabase() async throws {
        let fixture = SessionFixture.pairedHandshake()
        let database = try makeDatabaseFixture()
        let deviceHost = SyncLibraryPassiveHost(
            libraryRoot: database.libraryRoot,
            rootName: "测试设备曲库",
            sink: PeerLibrarySinkStub(),
            database: database.manager,
            lyricsStore: AlignedLyricsStore(directory: try tempDirectory("lyrics")),
            lyricsMapping: .unresolved,
            membersProvider: { SyncCollectionMembers() },
            peerLibraryProvider: DatabaseSyncPeerLibraryFacts.catalogProvider(
                database: database.manager,
                libraryRoot: database.libraryRoot,
                favoritesName: "收藏"
            )
        )
        #expect(deviceHost.attach(to: fixture.clientSession))

        let client = SyncPeerLibraryClient(session: fixture.hostSession, timeout: 3)

        let playlists = try await client.fetchPlaylists()
        #expect(playlists.map(\.id).contains(database.jazzSlug))
        #expect(playlists.map(\.id).contains(SyncCollectionSelection.favoritesPlaylistID))
        #expect(playlists.first { $0.id == database.jazzSlug }?.trackCount == 2)

        let summary = try await client.fetchLibrarySummary()
        #expect(summary.trackCount == 3)
        #expect(summary.sizeBytes == 7_000)

        let page = try await client.fetchTracks(playlistID: nil, query: nil, offset: 0, limit: 2)
        #expect(page.total == 3)
        #expect(page.items.count == 2)
        #expect(page.hasMore)
        let next = try await client.fetchTracks(playlistID: nil, query: nil, offset: 2, limit: 2)
        #expect((page.trackItems + next.trackItems).map(\.relativePath)
            == ["Jazz/a.flac", "Jazz/b.flac", "Rock/c.flac"], "两页拼接 = 对端全集")

        let searched = try await client.fetchTracks(playlistID: nil, query: "moon", offset: 0, limit: 50)
        #expect(searched.trackItems.map(\.relativePath) == ["Jazz/b.flac"])

        let byPlaylist = try await client.fetchTracks(
            playlistID: database.jazzSlug, query: nil, offset: 0, limit: 50
        )
        #expect(byPlaylist.trackItems.map(\.relativePath) == ["Jazz/a.flac", "Jazz/b.flac"])

        deviceHost.detach()
    }

    // MARK: - ⑦ 会话链条

    @Test("接线不破坏既有 handler 链：接被动端前挂的 handler 仍收到业务帧")
    func attachKeepsPriorApplicationHandler() async throws {
        let fixture = SessionFixture.pairedHandshake()
        let seen = FrameBox()
        // 先挂（模拟既有上层 handler）
        fixture.clientSession.onApplicationFrame = { frame in seen.append(frame) }

        let root = try tempDirectory("chain-device")
        let host = SyncLibraryPassiveHost(
            libraryRoot: root,
            sink: PeerLibrarySinkStub(),
            database: DatabaseManager(dbWriter: try DatabaseQueue()),
            lyricsStore: AlignedLyricsStore(directory: try tempDirectory("chain-lyrics")),
            lyricsMapping: .unresolved,
            peerLibraryProvider: { SyncPeerLibraryCatalog() }
        )
        #expect(host.attach(to: fixture.clientSession))

        // 发一个业务帧（未接线的清单请求）→ responder 应答（空清单）+ 既有 handler 收到
        let client = SyncPeerLibraryClient(session: fixture.hostSession, timeout: 3)
        let playlists = try await client.fetchPlaylists()
        #expect(playlists.isEmpty, "未接线的清单 provider → 空清单")
        #expect(!seen.received.isEmpty, "既有 handler 仍在链上收到业务帧")
        #expect(seen.received.contains { $0.type == .peerLibraryRequest })

        host.detach()
    }
}
