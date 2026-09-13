//
//  PlaylistReorderTests.swift
//  QQPlayerTests
//
//  审计 🔵-7 回归：reorderPlaylistItems 两阶段 updateAll 的行定位方式。
//
//  修复前两阶段都按 `(playlist_id, track_stable_id)` 匹配行：同一曲目在歌单里
//  出现两次时（playlist_item 主键是 (playlist_id, position)，允许重复 stable_id），
//  两条行会被写成同一个 position → 撞主键 → 整个重排事务回滚（抛错）。
//  修复后按**旧 position** 定位行，两阶段命中各自唯一行。
//
//  走 DatabaseManager(dbWriter:) 测试缝 + createTables()，跑真实生产代码路径。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

struct PlaylistReorderTests {
    private static func makeManager() throws -> (DatabaseManager, DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        return (manager, dbQueue)
    }

    private static func insertPlaylist(_ db: Database, items: [(position: Int, stableId: String)]) throws {
        try db.execute(
            sql: "INSERT INTO playlist (id, slug, title, created_at, updated_at) VALUES (1, 'p', 'P', 0, 0)"
        )
        for item in items {
            try db.execute(
                sql: "INSERT INTO playlist_item (playlist_id, position, track_stable_id) VALUES (1, ?, ?)",
                arguments: [item.position, item.stableId]
            )
        }
    }

    private static func orderedStableIds(_ db: Database) throws -> [String] {
        try String.fetchAll(
            db,
            sql: "SELECT track_stable_id FROM playlist_item WHERE playlist_id = 1 ORDER BY position"
        )
    }

    @Test("同一曲目在歌单中出现两次 → 重排不再撞主键回滚（修复前整事务抛错）")
    func duplicateStableIdReordersWithoutConflict() throws {
        let (manager, dbQueue) = try Self.makeManager()
        try dbQueue.write { db in
            try Self.insertPlaylist(db, items: [
                (0, "dup"), (1, "other"), (2, "dup"),
            ])
        }

        // 把 position 2（第二个 dup）移到队首
        try manager.reorderPlaylistItems(playlistId: 1, from: 2, to: 0)

        try dbQueue.read { db in
            let ids = try Self.orderedStableIds(db)
            #expect(ids.count == 3)
            #expect(ids == ["dup", "dup", "other"])
        }
    }

    @Test("常规重排（无重复曲目）：位置按移动结果重排，行数不变")
    func normalReorderRewritesPositions() throws {
        let (manager, dbQueue) = try Self.makeManager()
        try dbQueue.write { db in
            try Self.insertPlaylist(db, items: [
                (0, "a"), (1, "b"), (2, "c"),
            ])
        }

        try manager.reorderPlaylistItems(playlistId: 1, from: 0, to: 2)

        try dbQueue.read { db in
            let ids = try Self.orderedStableIds(db)
            #expect(ids == ["b", "c", "a"])
        }
    }
}
