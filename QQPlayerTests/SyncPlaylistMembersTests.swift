//
//  SyncPlaylistMembersTests.swift
//  QQPlayerTests
//
//  M6 T7b（2026-09-11）**歌单成员表**（`SyncCollectionMembers`）生产构建 + 两端接线。
//
//  背景（本批要堵的洞）：T7 的 `.playlists(ids)` 让对端按歌单过滤自己的曲库
//  （`SyncCollection.filter(entries, members:)`）。但 `SyncCollectionMembers` 此前
//  全仓只有默认空值（没有任何生产填充点）→ `selectedStableIds` 恒为空集 →
//  应答端回**空清单** → 「按歌单上传/下载」静默空转。
//
//  本文件覆盖三层：
//  ① 构建：`DatabaseSyncCollectionFacts.buildMembers(database:)`
//     —— 歌单 slug → 成员 stableId；收藏走 `@favorites`；空歌单留空集；不抛
//  ② 回归（核心）：同一份条目，空成员表 → 滤成空（钉住改造前行为）；
//     接线真实成员表 → 有内容（钉住修复后行为）
//  ③ 接线：`SyncLocalLibraryProvider` 应答路径按需取成员表（`.all`/空选择零求值）
//     + 端到端：`SyncLibraryPassiveHost`（iOS 被动端）应答 `.playlists` 请求只回成员文件
//
//  夹具：内存 GRDB（`DatabaseManager(dbWriter: try DatabaseQueue())`）+ 临时曲库根 /
//  临时歌词库（不触真实曲库与单例副作用）；会话用回环传输（`SessionFixture`）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

// MARK: - 夹具

/// 落库出口桩：本批不落位任何文件（只需要协议实现，避免碰真实入库链路）。
private final class SyncSinkStub: SyncLibrarySyncSink, @unchecked Sendable {
    func indexLandedFile(at url: URL) {}
}

/// 求值计数（断言"惰性"：无关集合不得碰成员表）。
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

@MainActor
struct SyncPlaylistMembersTests {
    // MARK: - 夹具构造

    private func makeDatabase() throws -> DatabaseManager {
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        try manager.createTables()
        return manager
    }

    private func tempDirectory(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-t7b-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 入库曲目（content_hash 显式给：扫描侧不再读文件内容）。
    private func insertTrack(
        _ manager: DatabaseManager,
        root: URL,
        stableId: String,
        relativePath: String
    ) throws {
        try manager.upsertTrack(
            Track(
                stableId: stableId,
                title: "T-\(stableId)",
                path: root.appendingPathComponent(relativePath).path,
                contentHash: "hash-\(stableId)"
            )
        )
    }

    private func writeAudioFile(_ relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x5A, count: 512).write(to: url)
    }

    /// 两条条目（一条属 jazz 歌单、一条不属）——集合过滤断言的对照组。
    private func sampleEntries() -> [ManifestEntry] {
        [
            ManifestEntry(relativePath: "jazz/one.flac", size: 1, mtimeMs: 0, contentHash: "h1", stableId: "t1"),
            ManifestEntry(relativePath: "rock/three.flac", size: 1, mtimeMs: 0, contentHash: "h3", stableId: "t3"),
        ]
    }

    /// 建库 + 曲目 + 「Jazz」歌单（成员 t1）+ 收藏（t3）；返回 (库, 已建成员表)。
    private func makeMembersFixture() throws -> (DatabaseManager, SyncCollectionMembers, URL) {
        let database = try makeDatabase()
        let root = try tempDirectory("library")
        try insertTrack(database, root: root, stableId: "t1", relativePath: "jazz/one.flac")
        try insertTrack(database, root: root, stableId: "t2", relativePath: "jazz/two.flac")
        try insertTrack(database, root: root, stableId: "t3", relativePath: "rock/three.flac")
        let jazz = try database.createPlaylist(title: "Jazz")
        let jazzID = try #require(jazz.id)
        try database.addToPlaylist(playlistId: jazzID, trackStableId: "t1")
        try database.addToPlaylist(playlistId: jazzID, trackStableId: "t2")
        _ = try database.createPlaylist(title: "Empty")
        try database.addToFavorites(trackStableId: "t3")
        return (database, DatabaseSyncCollectionFacts.buildMembers(database: database), root)
    }

    // MARK: - ① 成员表构建

    @Test("构建：歌单 slug → 成员 stableId；收藏走 @favorites；空歌单留空集；未知歌单不出现")
    func buildMembersFromDatabase() throws {
        let (database, members, _) = try makeMembersFixture()
        _ = database // 仅为夹具副作用（建库 + 歌单）

        #expect(members.stableIdsByPlaylist["jazz"] == ["t1", "t2"])
        #expect(members.stableIdsByPlaylist["empty"] == [])
        #expect(members.stableIdsByPlaylist[SyncCollectionSelection.favoritesPlaylistID] == ["t3"])
        #expect(members.stableIdsByPlaylist["ghost"] == nil)
        // 只有真实歌单 + 收藏会留键（未知标识不凭空造）
        #expect(members.stableIdsByPlaylist.keys.sorted() == ["@favorites", "empty", "jazz"])
    }

    @Test("构建：空库 / 无歌单 → 空成员表（不抛）")
    func buildMembersOnEmptyDatabase() throws {
        let database = try makeDatabase()
        let members = DatabaseSyncCollectionFacts.buildMembers(database: database)
        // 收藏查询成功但为空 → 留键空集；没有任何歌单
        #expect(members.stableIdsByPlaylist["jazz"] == nil)
        #expect(members.stableIdsByPlaylist[SyncCollectionSelection.favoritesPlaylistID]?.isEmpty != false)
    }

    @Test("构建：孤儿成员行（歌单指向已消失曲目）不影响其他成员")
    func buildMembersSkipsOrphanRows() throws {
        let database = try makeDatabase()
        let root = try tempDirectory("orphan")
        try insertTrack(database, root: root, stableId: "keep", relativePath: "p/keep.flac")
        let playlist = try database.createPlaylist(title: "Mixed")
        let playlistID = try #require(playlist.id)
        try database.addToPlaylist(playlistId: playlistID, trackStableId: "keep")
        try database.write { db in
            try PlaylistItem(playlistId: playlistID, position: 99, trackStableId: "ghost").insert(db)
        }

        let members = DatabaseSyncCollectionFacts.buildMembers(database: database)
        // "ghost" 没有曲目行也照样是歌单成员（过滤时按 stableId 匹配，命中不了即天然出局）
        #expect(members.stableIdsByPlaylist["mixed"] == ["keep", "ghost"])
    }

    // MARK: - ② 回归（本批核心）

    @Test("★回归：.playlists 在空成员表下滤成空（T7b 前的静默空转），真实成员表下能筛出条目")
    func playlistsFilterRegression() throws {
        let (_, members, _) = try makeMembersFixture()
        let entries = sampleEntries()
        let collection = SyncCollection.playlists(["jazz"])

        // 改造前：全仓成员表恒空 → 选中集为空集 → 一条都不留（对端回空清单的根因）
        #expect(collection.filter(entries, members: SyncCollectionMembers()) == [])

        // 修复后：真实成员表 → 只留歌单成员
        #expect(collection.filter(entries, members: members).map(\.stableId) == ["t1"])
        // 收藏标识同样可解释
        #expect(
            SyncCollection.playlists([SyncCollectionSelection.favoritesPlaylistID])
                .filter(entries, members: members).map(\.stableId) == ["t3"]
        )
        // 未知歌单仍宁少不误删
        #expect(SyncCollection.playlists(["ghost"]).filter(entries, members: members) == [])
    }

    // MARK: - ③ 接线：应答路径（descriptor 注入）

    @Test("接线：descriptor 注入成员表后 .playlists 不再为空；.all / 空选择不触发求值（惰性）")
    func responderPathUsesInjectedMembers() throws {
        let (_, members, root) = try makeMembersFixture()
        let counter = CallCounter()
        let descriptor = SyncLocalLibraryDescriptor(
            libraryRoot: root,
            rootName: "测试曲库",
            sourceFiles: {
                [
                    SyncManifestSourceFile(
                        relativePath: "jazz/one.flac", size: 1, contentHash: "h1", stableId: "t1"
                    ),
                    SyncManifestSourceFile(
                        relativePath: "rock/three.flac", size: 1, contentHash: "h3", stableId: "t3"
                    ),
                ]
            },
            members: {
                counter.increment()
                return members
            }
        )
        let provider = SyncLocalLibraryProvider(descriptor: descriptor)

        // .all 不含过滤 → 全部条目，且不查成员表（会话线程上不该白跑 DB）
        #expect(provider.manifest(collection: .all).count == 2)
        #expect(counter.value == 0)
        // .tracks 的选择集就是 ids，同样不需要成员表
        #expect(provider.manifest(collection: .tracks(["t3"])).map(\.relativePath) == ["rock/three.flac"])
        #expect(counter.value == 0)
        // 空歌单选择（.playlists([])）语义 = 不选任何文件，也无需查表
        #expect(provider.manifest(collection: .playlists([])) == [])
        #expect(counter.value == 0)

        // 真正的按歌单请求：求值一次并筛出成员
        #expect(provider.manifest(collection: .playlists(["jazz"])).map(\.stableId) == ["t1"])
        #expect(counter.value == 1)
        // （对端请求只发生一次，重复调用每次求值一次 = 拿的是当下的歌单成员，不做跨请求缓存）
    }

    @Test("接线：显式传入 members 覆盖注入表（诊断/测试逃生口）")
    func explicitMembersOverrideInjected() throws {
        let (_, members, root) = try makeMembersFixture()
        let descriptor = SyncLocalLibraryDescriptor(
            libraryRoot: root,
            rootName: "测试曲库",
            sourceFiles: {
                [
                    SyncManifestSourceFile(
                        relativePath: "jazz/one.flac", size: 1, contentHash: "h1", stableId: "t1"
                    ),
                    SyncManifestSourceFile(
                        relativePath: "rock/three.flac", size: 1, contentHash: "h3", stableId: "t3"
                    ),
                ]
            },
            members: { members }
        )
        let provider = SyncLocalLibraryProvider(descriptor: descriptor)
        let override = SyncCollectionMembers(stableIdsByPlaylist: ["jazz": ["t3"]])
        #expect(
            provider.manifest(collection: .playlists(["jazz"]), members: override).map(\.stableId) == ["t3"]
        )
    }

    // MARK: - ③ 接线：iOS 被动端端到端

    @Test("★端到端：iOS 被动端应答 .playlists 请求 → 只回该歌单成员（默认接真实 DB 成员表）")
    func passiveHostAnswersPlaylistScopedManifest() throws {
        let fixture = SessionFixture.pairedHandshake()
        let root = try tempDirectory("device")
        try writeAudioFile("jazz/one.flac", in: root)
        try writeAudioFile("rock/three.flac", in: root)
        let database = try makeDatabase()
        try insertTrack(database, root: root, stableId: "t1", relativePath: "jazz/one.flac")
        try insertTrack(database, root: root, stableId: "t3", relativePath: "rock/three.flac")
        let jazz = try database.createPlaylist(title: "Jazz")
        try database.addToPlaylist(playlistId: try #require(jazz.id), trackStableId: "t1")

        let lyricsStore = AlignedLyricsStore(directory: try tempDirectory("lyrics"))
        let deviceHost = SyncLibraryPassiveHost(
            libraryRoot: root,
            sink: SyncSinkStub(),
            database: database,
            lyricsStore: lyricsStore,
            lyricsMapping: .unresolved
        )
        #expect(deviceHost.attach(to: fixture.clientSession))

        let peer = SyncManifestPeer(session: fixture.hostSession)
        var received: SyncManifestResponse?
        peer.onManifestReceived = { response in received = response }
        try peer.requestManifest(collection: .playlists(["jazz"]))

        let response = try #require(received)
        // 改造前这里是空数组（成员表恒空）→ Mac「按歌单下载」拿不回任何文件
        #expect(response.entries.map(\.relativePath) == ["jazz/one.flac"])
        #expect(response.entries.map(\.stableId) == ["t1"])
    }

    @Test("端到端对照：同一次装配下 .all 仍回全量（集合语义不被成员表污染）")
    func passiveHostAnswersAllUnchanged() throws {
        let fixture = SessionFixture.pairedHandshake()
        let root = try tempDirectory("device-all")
        try writeAudioFile("jazz/one.flac", in: root)
        try writeAudioFile("rock/three.flac", in: root)
        let database = try makeDatabase()
        try insertTrack(database, root: root, stableId: "t1", relativePath: "jazz/one.flac")
        try insertTrack(database, root: root, stableId: "t3", relativePath: "rock/three.flac")
        let jazz = try database.createPlaylist(title: "Jazz")
        try database.addToPlaylist(playlistId: try #require(jazz.id), trackStableId: "t1")

        let lyricsStore = AlignedLyricsStore(directory: try tempDirectory("lyrics-all"))
        let deviceHost = SyncLibraryPassiveHost(
            libraryRoot: root,
            sink: SyncSinkStub(),
            database: database,
            lyricsStore: lyricsStore,
            lyricsMapping: .unresolved
        )
        #expect(deviceHost.attach(to: fixture.clientSession))

        let peer = SyncManifestPeer(session: fixture.hostSession)
        var received: SyncManifestResponse?
        peer.onManifestReceived = { response in received = response }
        try peer.requestManifest(collection: .all)

        let response = try #require(received)
        #expect(response.entries.map(\.relativePath) == ["jazz/one.flac", "rock/three.flac"])
    }
}
