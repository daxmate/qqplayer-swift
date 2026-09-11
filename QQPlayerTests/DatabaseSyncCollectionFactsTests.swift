//
//  DatabaseSyncCollectionFactsTests.swift
//  QQPlayerTests
//
//  M6（T2）同步集合曲库事实生产实现 `DatabaseSyncCollectionFacts` 测试（契约 C2）：
//  - 歌单标识 → 成员曲目：真实歌单按 **slug** 匹配；收藏走保留标识 `@favorites`
//  - 相对路径口径 = `SyncManifestGenerator.relativePath(of:baseDirectory:)`（与 manifest 侧同源）
//  - 指纹口径 = M4-2a `SyncContentHashResolver`（未指纹 → nil，交给展开器计入 unresolved）
//  - 歌词口径 = aligned 库同根 + `@lyrics/{歌曲 content_hash}.json` 命名空间
//  - **失败路径一律"查不到"**：未知歌单 → nil、未入库路径 → nil、无歌词 → false，全部不抛
//  - 与展开器联跑：`.playlists(["jazz"])` → 期望条目（含随歌歌词）
//
//  fixture：`DatabaseManager(dbWriter: try DatabaseQueue())` 内存库（同 DeviceStoreTests 模式）
//  + 临时曲库根 / 临时歌词库（不触真实曲库与单例副作用）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

struct DatabaseSyncCollectionFactsTests {
    // MARK: - 夹具

    private struct Fixture {
        let manager: DatabaseManager
        let libraryRoot: URL
        let lyricsStore: AlignedLyricsStore
        let facts: DatabaseSyncCollectionFacts
    }

    private func tempDirectory(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-m6-facts-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFixture() throws -> Fixture {
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        try manager.createTables()
        let libraryRoot = try tempDirectory("library")
        let lyricsStore = AlignedLyricsStore(directory: try tempDirectory("lyrics"))
        let facts = DatabaseSyncCollectionFacts(
            database: manager,
            libraryRoot: libraryRoot,
            lyricsStore: lyricsStore,
            // 生产映射（M4-2a）——顺带覆盖 stableId ↔ content_hash 真实接线
            lyricsMapping: .live(database: manager)
        )
        return Fixture(
            manager: manager,
            libraryRoot: libraryRoot,
            lyricsStore: lyricsStore,
            facts: facts
        )
    }

    /// 入库曲目（content_hash 显式给：不碰文件）。
    private func insertTrack(
        _ manager: DatabaseManager,
        libraryRoot: URL,
        stableId: String,
        relativePath: String,
        contentHash: String?
    ) throws {
        try manager.upsertTrack(
            Track(
                stableId: stableId,
                title: "T-\(stableId)",
                path: libraryRoot.appendingPathComponent(relativePath).path,
                contentHash: contentHash
            )
        )
    }

    private func sampleLyrics(_ text: String) -> Lyrics {
        Lyrics(
            plainLyrics: text,
            syncedLyrics: [LyricsLine(timestamp: 1.0, text: text)],
            isInstrumental: false,
            source: .lrclib
        )
    }

    // MARK: - 歌单成员

    @Test("真实歌单（slug 匹配）：成员曲目 + 相对路径 + 指纹")
    func tracksInPlaylistBySlug() throws {
        let fixture = try makeFixture()
        try insertTrack(
            fixture.manager, libraryRoot: fixture.libraryRoot,
            stableId: "t1", relativePath: "jazz/song1.flac", contentHash: "hash-1"
        )
        try insertTrack(
            fixture.manager, libraryRoot: fixture.libraryRoot,
            stableId: "t2", relativePath: "jazz/song2.flac", contentHash: nil
        )
        let playlist = try fixture.manager.createPlaylist(title: "Jazz")
        try fixture.manager.addToPlaylist(playlistId: try #require(playlist.id), trackStableId: "t1")
        try fixture.manager.addToPlaylist(playlistId: try #require(playlist.id), trackStableId: "t2")

        let facts = try #require(fixture.facts.tracks(inPlaylist: "jazz"))
        #expect(facts.count == 2)
        let first = try #require(facts.first { $0.stableId == "t1" })
        #expect(first.relativePath == "jazz/song1.flac")
        #expect(first.contentHash == "hash-1")
        // 未指纹 → nil（展开器据此计入 not_fingerprinted，不伪造指纹）
        let second = try #require(facts.first { $0.stableId == "t2" })
        #expect(second.relativePath == "jazz/song2.flac")
        #expect(second.contentHash == nil)
    }

    @Test("收藏：保留标识 @favorites → getFavoriteTracks() 口径")
    func favoritesPlaylist() throws {
        let fixture = try makeFixture()
        try insertTrack(
            fixture.manager, libraryRoot: fixture.libraryRoot,
            stableId: "f1", relativePath: "fav/a.flac", contentHash: "hash-f1"
        )
        try insertTrack(
            fixture.manager, libraryRoot: fixture.libraryRoot,
            stableId: "f2", relativePath: "other/b.flac", contentHash: "hash-f2"
        )
        try fixture.manager.addToFavorites(trackStableId: "f1")

        let facts = try #require(
            fixture.facts.tracks(inPlaylist: SyncCollectionSelection.favoritesPlaylistID)
        )
        #expect(facts.map(\.stableId) == ["f1"])
        #expect(facts.first?.contentHash == "hash-f1")
    }

    @Test("歌单为空：返回空数组（歌单存在 ≠ 不存在）")
    func emptyPlaylistReturnsEmptyArray() throws {
        let fixture = try makeFixture()
        _ = try fixture.manager.createPlaylist(title: "Empty")
        #expect(fixture.facts.tracks(inPlaylist: "empty") == [])
    }

    @Test("失败路径：未知歌单 → nil；非法标识 → nil（不抛）")
    func unknownAndInvalidPlaylistReturnNil() throws {
        let fixture = try makeFixture()
        #expect(fixture.facts.tracks(inPlaylist: "does-not-exist") == nil)
        #expect(fixture.facts.tracks(inPlaylist: "") == nil)
        #expect(fixture.facts.tracks(inPlaylist: "bad/id") == nil)
        #expect(fixture.facts.tracks(inPlaylist: "..") == nil)
        #expect(fixture.facts.tracks(inPlaylist: String(repeating: "x", count: 200)) == nil)
    }

    @Test("歌单成员已从曲库消失：该成员跳过，其余照常")
    func missingMemberIsSkipped() throws {
        let fixture = try makeFixture()
        try insertTrack(
            fixture.manager, libraryRoot: fixture.libraryRoot,
            stableId: "keep", relativePath: "p/keep.flac", contentHash: "hash-keep"
        )
        let playlist = try fixture.manager.createPlaylist(title: "Mixed")
        let playlistID = try #require(playlist.id)
        try fixture.manager.addToPlaylist(playlistId: playlistID, trackStableId: "keep")
        // 直接插一条指向不存在曲目的成员行（模拟外部删除留下的孤儿行）
        try fixture.manager.write { db in
            try PlaylistItem(playlistId: playlistID, position: 99, trackStableId: "ghost")
                .insert(db)
        }

        let facts = try #require(fixture.facts.tracks(inPlaylist: "mixed"))
        #expect(facts.map(\.stableId) == ["keep"])
    }

    // MARK: - 显式路径

    @Test("显式相对路径：命中 / 未入库 / 非法路径")
    func trackAtRelativePath() throws {
        let fixture = try makeFixture()
        try insertTrack(
            fixture.manager, libraryRoot: fixture.libraryRoot,
            stableId: "p1", relativePath: "a/b/c.flac", contentHash: "hash-p1"
        )

        let hit = try #require(fixture.facts.track(atRelativePath: "a/b/c.flac"))
        #expect(hit.stableId == "p1")
        #expect(hit.relativePath == "a/b/c.flac")
        #expect(hit.contentHash == "hash-p1")
        // 规范化形态（`./` 前缀）也命中（与 manifest 对账键同口径）
        #expect(fixture.facts.track(atRelativePath: "./a/b/c.flac")?.stableId == "p1")

        #expect(fixture.facts.track(atRelativePath: "a/missing.flac") == nil)
        #expect(fixture.facts.track(atRelativePath: "../escape.flac") == nil)
        #expect(fixture.facts.track(atRelativePath: "") == nil)
        #expect(fixture.facts.track(atRelativePath: "/absolute.flac") == nil)
    }

    @Test("曲库根外的曲目：曲目事实拿不到相对路径（nil）")
    func trackOutsideLibraryRootHasNoRelativePath() throws {
        let fixture = try makeFixture()
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-m6-outside-\(UUID().uuidString)/song.flac")
        try fixture.manager.upsertTrack(
            Track(stableId: "out", title: "Out", path: outside.path, contentHash: "hash-out")
        )
        let playlist = try fixture.manager.createPlaylist(title: "Outside")
        try fixture.manager.addToPlaylist(
            playlistId: try #require(playlist.id),
            trackStableId: "out"
        )
        let facts = try #require(fixture.facts.tracks(inPlaylist: "outside"))
        #expect(facts.count == 1)
        #expect(facts.first?.relativePath == nil)
    }

    // MARK: - 歌词

    @Test("歌词：wire 路径 → 歌曲 hash → 本端歌词库存在性")
    func hasLyricsAtWirePath() throws {
        let fixture = try makeFixture()
        try insertTrack(
            fixture.manager, libraryRoot: fixture.libraryRoot,
            stableId: "l1", relativePath: "a/l1.flac", contentHash: "hash-l1"
        )
        try fixture.lyricsStore.write(sampleLyrics("第一行"), forStableId: "l1")

        #expect(fixture.facts.hasLyrics(atWirePath: "@lyrics/hash-l1.json"))
        #expect(!fixture.facts.hasLyrics(atWirePath: "@lyrics/hash-unknown.json"))
        // 未指纹的歌（hash 映射不到 stableId）→ 无歌词
        #expect(!fixture.facts.hasLyrics(atWirePath: "@lyrics/hash-l2.json"))
        // 非歌词命名空间 / 形态非法 → false（不可信输入按形态拒）
        #expect(!fixture.facts.hasLyrics(atWirePath: "a/l1.flac"))
        #expect(!fixture.facts.hasLyrics(atWirePath: "@lyrics/../x.json"))
        #expect(!fixture.facts.hasLyrics(atWirePath: "@lyrics/sub/hash-l1.json"))
        #expect(!fixture.facts.hasLyrics(atWirePath: ""))
    }

    // MARK: - 与展开器联跑

    @Test("展开器联跑：选中歌单 → 曲目条目 + 随歌歌词条目；未指纹计入 unresolved")
    func expanderIntegration() throws {
        let fixture = try makeFixture()
        try insertTrack(
            fixture.manager, libraryRoot: fixture.libraryRoot,
            stableId: "e1", relativePath: "e/with-lyrics.flac", contentHash: "hash-e1"
        )
        try insertTrack(
            fixture.manager, libraryRoot: fixture.libraryRoot,
            stableId: "e2", relativePath: "e/no-fingerprint.flac", contentHash: nil
        )
        try fixture.lyricsStore.write(sampleLyrics("行"), forStableId: "e1")
        let playlist = try fixture.manager.createPlaylist(title: "Expanded")
        let playlistID = try #require(playlist.id)
        try fixture.manager.addToPlaylist(playlistId: playlistID, trackStableId: "e1")
        try fixture.manager.addToPlaylist(playlistId: playlistID, trackStableId: "e2")

        let expansion = SyncCollectionExpander.expand(
            selection: .playlists(["expanded"]),
            facts: fixture.facts
        )
        #expect(!expansion.isLibraryWide)
        #expect(expansion.unknownPlaylistIDs.isEmpty)
        #expect(expansion.relativePaths == ["@lyrics/hash-e1.json", "e/with-lyrics.flac"])
        #expect(expansion.lyricsEntryCount == 1)
        #expect(expansion.songEntryCount == 1)
        #expect(expansion.unresolvedCount == 1)
        #expect(expansion.unresolved.first?.reason == SyncCollectionUnresolvedReason.notFingerprinted)
    }

    @Test("展开器联跑：未知歌单 → 记账 unknownPlaylistIDs（不抛）")
    func expanderRecordsUnknownPlaylist() throws {
        let fixture = try makeFixture()
        let expansion = SyncCollectionExpander.expand(
            selection: .playlists(["ghost-playlist"]),
            facts: fixture.facts
        )
        #expect(expansion.unknownPlaylistIDs == ["ghost-playlist"])
        #expect(expansion.entries.isEmpty)
    }

    // MARK: - 失败路径：DB 不可用也必须"查不到"而不是抛

    @Test("DB 查询失败（表未建）→ 全部按查不到返回，不抛")
    func queryFailureReturnsNotFound() throws {
        // 刻意不 createTables()：任何查询都会抛 → 生产实现必须吞掉并返回"查不到"
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        let facts = DatabaseSyncCollectionFacts(
            database: manager,
            libraryRoot: try tempDirectory("empty"),
            lyricsStore: AlignedLyricsStore(directory: try tempDirectory("empty-lyrics"))
        )

        #expect(facts.tracks(inPlaylist: "anything") == nil)
        #expect(facts.tracks(inPlaylist: SyncCollectionSelection.favoritesPlaylistID) == nil)
        #expect(facts.track(atRelativePath: "a.flac") == nil)
        #expect(!facts.hasLyrics(atWirePath: "@lyrics/deadbeef.json"))
    }
}
