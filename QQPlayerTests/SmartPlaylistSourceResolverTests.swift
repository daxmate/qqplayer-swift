//
//  SmartPlaylistSourceResolverTests.swift
//  QQPlayerTests
//
//  S2 同步页「来源 → 成员曲目」生产解析器测试（2026-09-13）：
//  - 全部曲库 / 收藏 / 真实歌单（按 slug）/ 自动歌单（最近添加 / 最近播放 / 常听排行）
//  - 成员相对路径口径 = `SyncManifestGenerator.relativePath(of:baseDirectory:)`（曲库根外 → 跳过）
//  - 自动歌单与播放列表页**同一数据层口径**（`SmartPlaylistStore.limit` / 排序语义）
//  - 未知 / 非法标识 → 空集（**绝不回落全库**）；DB 表缺失 → 空集且不抛
//
//  fixture：`DatabaseManager(dbWriter: try DatabaseQueue())` 内存库（同
//  `DatabaseSyncCollectionFactsTests` 模式）+ 临时曲库根（不触真实曲库与单例副作用）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

struct SmartPlaylistSourceResolverTests {
    // MARK: - 夹具

    private struct Fixture {
        let manager: DatabaseManager
        let libraryRoot: URL
        let resolver: SmartPlaylistSourceResolver
    }

    private func tempDirectory(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-browse-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 入库一条曲目（显式给指纹 → 不碰文件系统；大小固定 1 KiB，本测试不涉大小）。
    private func insertTrack(
        _ manager: DatabaseManager,
        libraryRoot: URL,
        stableId: String,
        relativePath: String,
        modificationDate: Int64?
    ) throws {
        try manager.upsertTrack(
            Track(
                stableId: stableId,
                title: "T-\(stableId)",
                path: libraryRoot.appendingPathComponent(relativePath).path,
                fileSize: 1024,
                modificationDate: modificationDate,
                contentHash: "h-\(stableId)"
            )
        )
    }

    /// 骨架 fixture：
    /// - 曲目：t1 Jazz/a.flac（mod 1000）、t2 Jazz/b.flac（mod 3000）、t3 Rock/c.flac（mod 2000）
    ///   以及 t4 = **曲库根外**的曲目（不得出现在任何相对路径集合里）
    /// - 播放历史：t1 两条（最新 300，合计 15）、t2 一条（500）、t3 三条（460/450/400，合计 0）
    /// - 收藏：t3；歌单 jazz：t1 + t2
    private func makeFixture() throws -> Fixture {
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        try manager.createTables()
        let libraryRoot = try tempDirectory("library")

        try insertTrack(manager, libraryRoot: libraryRoot, stableId: "t1", relativePath: "Jazz/a.flac", modificationDate: 1000)
        try insertTrack(manager, libraryRoot: libraryRoot, stableId: "t2", relativePath: "Jazz/b.flac", modificationDate: 3000)
        try insertTrack(manager, libraryRoot: libraryRoot, stableId: "t3", relativePath: "Rock/c.flac", modificationDate: 2000)
        try insertTrack(
            manager,
            libraryRoot: try tempDirectory("outside"),
            stableId: "t4",
            relativePath: "Elsewhere/d.flac",
            modificationDate: 500
        )

        try manager.write { db in
            let rows: [(String, Int64, Int64)] = [
                ("t1", 100, 5), ("t1", 300, 10),
                ("t2", 500, 1),
                ("t3", 400, 0), ("t3", 450, 0), ("t3", 460, 0),
            ]
            for row in rows {
                try db.execute(
                    sql: "INSERT INTO play_history (track_stable_id, played_at, play_duration_ms) VALUES (?, ?, ?)",
                    arguments: [row.0, row.1, row.2]
                )
            }
        }

        try manager.addToFavorites(trackStableId: "t3")
        let playlist = try manager.createPlaylist(title: "Jazz")
        let playlistID = try #require(playlist.id)
        try manager.addToPlaylist(playlistId: playlistID, trackStableId: "t1")
        try manager.addToPlaylist(playlistId: playlistID, trackStableId: "t2")

        return Fixture(
            manager: manager,
            libraryRoot: libraryRoot,
            resolver: SmartPlaylistSourceResolver(database: manager, libraryRoot: libraryRoot)
        )
    }

    // MARK: - 全部曲库 / 收藏 / 真实歌单

    @Test("全部曲库：成员 = 全库曲目（曲库根外的曲目不进相对路径集合）")
    func librarySource() throws {
        let fixture = try makeFixture()
        #expect(fixture.resolver.tracks(for: .library).count == 4, "成员 = 全部曲目行")
        #expect(
            fixture.resolver.relativePaths(for: .library) == ["Jazz/a.flac", "Jazz/b.flac", "Rock/c.flac"],
            "升序 + 去重；曲库根外的 t4 跳过（不编造路径）"
        )
        #expect(fixture.resolver.pathSet(for: .library) == Set(fixture.resolver.relativePaths(for: .library)))
        #expect(!fixture.resolver.relativePaths(for: .library).contains("Elsewhere/d.flac"))
    }

    @Test("收藏：只含收藏曲目")
    func favoritesSource() throws {
        let fixture = try makeFixture()
        #expect(fixture.resolver.tracks(for: .favorites).map(\.stableId) == ["t3"])
        #expect(fixture.resolver.relativePaths(for: .favorites) == ["Rock/c.flac"])
    }

    @Test("真实歌单：按 slug 匹配，成员 = 歌单条目序")
    func playlistSource() throws {
        let fixture = try makeFixture()
        let ref = try #require(SyncBrowseSourceRef.playlist("jazz"))
        #expect(fixture.resolver.tracks(for: ref).map(\.stableId) == ["t1", "t2"])
        #expect(fixture.resolver.relativePaths(for: ref) == ["Jazz/a.flac", "Jazz/b.flac"])
    }

    @Test("未知歌单 slug → 空集（绝不回落全库）")
    func unknownPlaylist() throws {
        let fixture = try makeFixture()
        let ref = try #require(SyncBrowseSourceRef.playlist("nope"))
        #expect(fixture.resolver.tracks(for: ref).isEmpty)
        #expect(fixture.resolver.relativePaths(for: ref).isEmpty)
    }

    // MARK: - 自动歌单（与播放列表页同一口径）

    @Test("最近添加：modification_date 降序（曲库根外的曲目也在成员里，只是拿不到相对路径）")
    func recentAdded() throws {
        let fixture = try makeFixture()
        let ref = SyncBrowseSourceRef.smart(.recentAdded)
        #expect(
            fixture.resolver.tracks(for: ref).map(\.stableId) == ["t2", "t3", "t1", "t4"],
            "定义序 = modification_date 降序（500 的 t4 最后）"
        )
        #expect(fixture.resolver.relativePaths(for: ref) == ["Jazz/a.flac", "Jazz/b.flac", "Rock/c.flac"])
    }

    @Test("最近播放：按最新播放时间倒序 + 同一曲目只留最新一条")
    func recentPlayed() throws {
        let fixture = try makeFixture()
        let ref = SyncBrowseSourceRef.smart(.recentPlayed)
        #expect(fixture.resolver.tracks(for: ref).map(\.stableId) == ["t2", "t3", "t1"], "去重 + 最新优先")
    }

    @Test("常听排行：播放次数降序，并列按累计时长")
    func topPlayed() throws {
        let fixture = try makeFixture()
        let ref = SyncBrowseSourceRef.smart(.topPlayed)
        #expect(fixture.resolver.tracks(for: ref).map(\.stableId) == ["t3", "t1", "t2"])
    }

    @Test("自动歌单条数上限 = 播放列表页同一条数（SmartPlaylistStore.limit）")
    func smartLimitMatchesPlaylistPage() throws {
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        try manager.createTables()
        let libraryRoot = try tempDirectory("limit")
        // 上限 + 10 首（modification_date 递增 → 最近添加取最后 50 首）
        for index in 0 ..< (SmartPlaylistStore.limit + 10) {
            try insertTrack(
                manager,
                libraryRoot: libraryRoot,
                stableId: "s\(index)",
                relativePath: "Bulk/s\(index).flac",
                modificationDate: Int64(index)
            )
        }
        let resolver = SmartPlaylistSourceResolver(database: manager, libraryRoot: libraryRoot)
        let tracks = resolver.tracks(for: SyncBrowseSourceRef.smart(.recentAdded))
        #expect(tracks.count == SmartPlaylistStore.limit)
        #expect(tracks.first?.stableId == "s59", "最新添加在前")
        #expect(!tracks.contains { $0.stableId == "s0" })
    }

    // MARK: - 失败路径一律「查不到」

    @Test("表缺失 / 查询失败 → 空集且不抛（协议硬要求）")
    func failureIsEmpty() throws {
        // 不调 createTables()：任何查询都会失败
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        let resolver = SmartPlaylistSourceResolver(database: manager, libraryRoot: try tempDirectory("empty"))
        #expect(resolver.tracks(for: .library).isEmpty)
        #expect(resolver.tracks(for: .favorites).isEmpty)
        #expect(resolver.tracks(for: .smart(.recentPlayed)).isEmpty)
        #expect(resolver.relativePaths(for: .library).isEmpty)
        #expect(resolver.pathSet(for: .smart(.topPlayed)).isEmpty)
    }

    @Test("空曲库 → 各来源都是空集（不崩、不编造）")
    func emptyLibrary() throws {
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        try manager.createTables()
        let resolver = SmartPlaylistSourceResolver(database: manager, libraryRoot: try tempDirectory("blank"))
        for kind in SyncBrowseSmartKind.allCases {
            #expect(resolver.relativePaths(for: SyncBrowseSourceRef.smart(kind)).isEmpty)
        }
        #expect(resolver.relativePaths(for: .favorites).isEmpty)
        #expect(resolver.relativePaths(for: .library).isEmpty)
    }
}
