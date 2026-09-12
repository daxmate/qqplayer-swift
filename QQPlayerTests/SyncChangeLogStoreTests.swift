//
//  SyncChangeLogStoreTests.swift
//  QQPlayerTests
//
//  S2 M4-1 播放数据同步存储层测试：
//  - 新表迁移幂等：createTables 连跑两次不炸（旧库启动自动补表语义）
//  - outbox 捕获：收藏增删 / 播放历史写入 / 歌单与歌单项变更 → 同事务落
//    sync_outbox（entity/row_key/op/updated_at/payload_json）
//    （v2 2026-09-10 §12b-7：本地 delete **照常记录**——本地事务完整；只是该行不上线，
//     发送侧由 SyncChangeLogDeletionPolicy 过滤，接收侧一律忽略）
//  - 游标与增量拉取：cursor 默认 0、setCursor upsert、entries(after:) 增量、
//    maxOutboxID
//
//  fixture 走 DatabaseManager.init(dbWriter:) 测试缝 + createTables()（内存库
//  跑真实生产代码路径，同 PlayHistoryCleanupTests 惯例）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

@MainActor
struct SyncChangeLogStoreTests {
    // MARK: - Fixture

    private static func makeManager() throws -> (DatabaseManager, DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        return (manager, dbQueue)
    }

    private static func outboxRows(_ db: Database) throws -> [SyncChangeLogRow] {
        try SyncChangeLogRow.order(Column("id")).fetchAll(db)
    }

    private static func insertTrack(db: Database, stableId: String, title: String = "T") throws {
        try db.execute(
            sql: "INSERT INTO track (stable_id, title, path) VALUES (?, ?, ?)",
            arguments: [stableId, title, "/m/\(stableId).flac"]
        )
    }

    // MARK: - 迁移幂等

    @Test("新表迁移幂等：sync_outbox/sync_cursor 建表后可重复 createTables")
    func migrationIdempotent() throws {
        let (manager, _) = try Self.makeManager()
        try manager.createTables() // 第二遍：IF NOT EXISTS 幂等
        try manager.read { db in
            let hasOutbox = try db.tableExists("sync_outbox")
            #expect(hasOutbox)
            let hasCursor = try db.tableExists("sync_cursor")
            #expect(hasCursor)
            // 列契约
            let outboxColumns = try db.columns(in: "sync_outbox").map(\.name)
            #expect(outboxColumns.contains("id"))
            #expect(outboxColumns.contains("entity"))
            #expect(outboxColumns.contains("row_key"))
            #expect(outboxColumns.contains("op"))
            #expect(outboxColumns.contains("updated_at"))
            #expect(outboxColumns.contains("payload_json"))
            let cursorColumns = try db.columns(in: "sync_cursor").map(\.name)
            #expect(cursorColumns.contains("peer_id"))
            #expect(cursorColumns.contains("last_outbox_id"))
        }
    }

    // MARK: - 收藏捕获

    @Test("收藏 upsert/delete → outbox：addToFavorites 记 upsert，removeFromFavorites 记 delete")
    func favoriteCapture() throws {
        let (manager, dbQueue) = try Self.makeManager()

        try manager.addToFavorites(trackStableId: "fav-1")

        try dbQueue.read { db in
            let rows = try Self.outboxRows(db)
            #expect(rows.count == 1)
            #expect(rows[0].entity == SyncChangeEntity.favorite.rawValue)
            #expect(rows[0].rowKey == "fav-1")
            #expect(rows[0].op == SyncChangeOp.upsert.rawValue)
            let snapshot = try SyncSnapshotCodec.decode(SyncFavoriteSnapshot.self, from: rows[0].payloadJSON)
            #expect(snapshot.trackStableId == "fav-1")
        }

        try manager.removeFromFavorites(trackStableId: "fav-1")

        try dbQueue.read { db in
            let rows = try Self.outboxRows(db)
            #expect(rows.count == 2)
            #expect(rows[1].entity == SyncChangeEntity.favorite.rawValue)
            #expect(rows[1].rowKey == "fav-1")
            #expect(rows[1].op == SyncChangeOp.delete.rawValue)
            // v2：本地照记 delete（本地删除是本地事务），该行不上线
        }
    }

    @Test("批量收藏恢复 → 逐条 outbox upsert")
    func favoriteBatchCapture() throws {
        let (manager, dbQueue) = try Self.makeManager()
        try manager.addToFavorites(trackStableIds: ["a", "b", "c"])
        try dbQueue.read { db in
            let rows = try Self.outboxRows(db)
            #expect(rows.count == 3)
            #expect(rows.allSatisfy { $0.op == SyncChangeOp.upsert.rawValue })
            #expect(Set(rows.map(\.rowKey)) == ["a", "b", "c"])
        }
    }

    @Test("删除不存在的收藏 → 不记 outbox delete（幂等无变更）")
    func favoriteDeleteNoopCapture() throws {
        let (manager, dbQueue) = try Self.makeManager()
        try manager.removeFromFavorites(trackStableId: "ghost")
        try dbQueue.read { db in
            let rows = try Self.outboxRows(db)
            #expect(rows.isEmpty)
        }
    }

    // MARK: - 播放历史捕获

    @Test("播放历史：会话开始记初始 upsert，settle 记最终态（含累计时长）")
    func playHistoryCapture() throws {
        let (manager, dbQueue) = try Self.makeManager()
        try dbQueue.write { db in
            try Self.insertTrack(db: db, stableId: "hist-1")
        }
        let recorder = PlayHistoryRecorder(database: manager)

        // 会话开始（0 时长快照）
        let track = try manager.read { db in
            try Track.filter(Column("stable_id") == "hist-1").fetchOne(db)
        }
        recorder.playbackBegan(track: track, at: 0)

        try dbQueue.read { db in
            let rows = try Self.outboxRows(db)
            #expect(rows.count == 1)
            #expect(rows[0].entity == SyncChangeEntity.playHistory.rawValue)
            let snapshot = try SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: rows[0].payloadJSON)
            #expect(snapshot.trackStableId == "hist-1")
            #expect(snapshot.playDurationMs == 0)
        }

        // settle → 最终态 upsert（row_key 相同 = stableId|playedAt，updated_at 更大）
        recorder.playbackEnded(track: track, at: 0)

        try dbQueue.read { db in
            let rows = try Self.outboxRows(db)
            #expect(rows.count == 2)
            #expect(rows[1].entity == SyncChangeEntity.playHistory.rawValue)
            #expect(rows[1].rowKey == rows[0].rowKey)
            #expect(rows[1].updatedAtMs >= rows[0].updatedAtMs)
            let snapshot = try SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: rows[1].payloadJSON)
            #expect(snapshot.trackStableId == "hist-1")
            #expect(snapshot.playedAt == rows[0].payloadJSON.flatMap {
                try? SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: $0).playedAt
            })
        }
    }

    // MARK: - 歌单捕获

    @Test("歌单：createPlaylist/rename/delete → playlist upsert/delete")
    func playlistCapture() throws {
        let (manager, dbQueue) = try Self.makeManager()

        let playlist = try manager.createPlaylist(title: "My Mix")

        try dbQueue.read { db in
            let rows = try Self.outboxRows(db)
            #expect(rows.count == 1)
            #expect(rows[0].entity == SyncChangeEntity.playlist.rawValue)
            #expect(rows[0].rowKey == playlist.slug)
            #expect(rows[0].op == SyncChangeOp.upsert.rawValue)
        }

        let playlistId = try #require(playlist.id)
        try manager.renamePlaylist(playlistId: playlistId, newTitle: "My Mix Renamed")

        try dbQueue.read { db in
            let rows = try Self.outboxRows(db)
            #expect(rows.count == 2)
            #expect(rows[1].op == SyncChangeOp.upsert.rawValue)
            let snapshot = try SyncSnapshotCodec.decode(SyncPlaylistSnapshot.self, from: rows[1].payloadJSON)
            #expect(snapshot.title == "My Mix Renamed")
            #expect(snapshot.slug == playlist.slug) // slug 稳定 = 行键稳定
        }

        try manager.deletePlaylist(playlistId: playlistId)

        try dbQueue.read { db in
            let rows = try Self.outboxRows(db)
            #expect(rows.count == 3)
            #expect(rows[2].op == SyncChangeOp.delete.rawValue)
            #expect(rows[2].rowKey == playlist.slug) // v2：本地照记 delete，不上线
        }
    }

    @Test("歌单项：addToPlaylist/removeFromPlaylist → item upsert/delete")
    func playlistItemCapture() throws {
        let (manager, dbQueue) = try Self.makeManager()
        let playlist = try manager.createPlaylist(title: "Item Mix")
        let playlistId = try #require(playlist.id)
        try dbQueue.write { db in
            try Self.insertTrack(db: db, stableId: "item-1")
        }

        try manager.addToPlaylist(playlistId: playlistId, trackStableId: "item-1")

        try dbQueue.read { db in
            let rows = try Self.outboxRows(db)
            let itemRows = rows.filter { $0.entity == SyncChangeEntity.playlistItem.rawValue }
            #expect(itemRows.count == 1)
            #expect(itemRows[0].op == SyncChangeOp.upsert.rawValue)
            #expect(itemRows[0].rowKey == "\(playlist.slug)|item-1")
            let snapshot = try SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: itemRows[0].payloadJSON)
            #expect(snapshot.playlistSlug == playlist.slug)
            #expect(snapshot.position == 1)
            #expect(snapshot.trackStableId == "item-1")
        }

        try manager.removeFromPlaylist(playlistId: playlistId, trackStableId: "item-1")

        try dbQueue.read { db in
            let rows = try Self.outboxRows(db)
            let itemDeletes = rows.filter { $0.entity == SyncChangeEntity.playlistItem.rawValue && $0.op == SyncChangeOp.delete.rawValue }
            #expect(itemDeletes.count == 1)
            // v2：本地照记 delete（不上线）
            #expect(itemDeletes[0].rowKey == "\(playlist.slug)|item-1")
        }
    }

    @Test("folder-synced 歌单不入 outbox（本地扫描派生语义）")
    func folderPlaylistNotCaptured() throws {
        let (manager, dbQueue) = try Self.makeManager()
        // 手动建 folder 歌单（folder_path + is_folder_synced）——createFolderPlaylist
        // 需要 folder 存在，直接绕过用 createTables 已有的 folder 语义手动插入
        try dbQueue.write { db in
            let now = Int64(Date().timeIntervalSince1970)
            try db.execute(
                sql: """
                INSERT INTO playlist (slug, title, created_at, updated_at, last_played_at,
                                      folder_path, is_folder_synced)
                VALUES ('folder-1', 'Folder', ?, ?, 0, '/m/folder', 1)
                """,
                arguments: [now, now]
            )
        }
        let folderId = try manager.read { db in
            try Playlist.filter(Column("slug") == "folder-1").fetchOne(db)?.id
        }
        // 加歌（folder 歌单内容由扫描器驱动 → 不应触发 outbox）
        try dbQueue.write { db in
            try Self.insertTrack(db: db, stableId: "f-1")
        }
        try manager.addToPlaylist(playlistId: try #require(folderId), trackStableId: "f-1")
        try dbQueue.read { db in
            let rows = try Self.outboxRows(db)
            #expect(rows.isEmpty)
        }
    }

    // MARK: - 游标与增量

    @Test("游标默认 0；setCursor upsert；entries(after:) 增量；maxOutboxID")
    func cursorAndIncremental() throws {
        let (manager, _) = try Self.makeManager()
        let store = SyncChangeLogStore(database: manager)
        let peer = "peer-abc"

        #expect(try store.cursor(forPeer: peer) == 0)

        try manager.addToFavorites(trackStableId: "c1")
        try manager.addToFavorites(trackStableId: "c2")
        try manager.addToFavorites(trackStableId: "c3")

        #expect(try store.maxOutboxID() == 3)

        let firstBatch = try store.entries(after: 0)
        #expect(firstBatch.count == 3)

        // 推进游标到 2 → 再拉只有第 3 条
        try store.setCursor(forPeer: peer, lastOutboxID: 2)
        #expect(try store.cursor(forPeer: peer) == 2)
        let secondBatch = try store.entries(after: 2)
        #expect(secondBatch.count == 1)
        #expect(secondBatch[0].rowKey == "c3")

        // 覆盖推进（upsert 语义）
        try store.setCursor(forPeer: peer, lastOutboxID: 3)
        #expect(try store.cursor(forPeer: peer) == 3)
    }

    // MARK: - S1：分页游标（取批 + 本批末行 id）

    @Test("S1 契约：page 的 lastOutboxID = 本批末行；批外行不被越过；空批/越末尾不动游标")
    func pageCursorIsBatchTail() throws {
        let (manager, _) = try Self.makeManager()
        let store = SyncChangeLogStore(database: manager)
        try manager.addToFavorites(trackStableIds: (1 ... 5).map { "p\($0)" })

        let first = try store.page(after: 0, limit: 2)
        #expect(first.rows.map(\.id) == [1, 2])
        #expect(first.lastOutboxID == 2, "游标 = 本批实际末行（不是 outbox 末尾 5）")
        #expect(try store.maxOutboxID() == 5, "outbox 里仍有批外行")

        let second = try store.page(after: first.lastOutboxID, limit: 2)
        #expect(second.rows.map(\.id) == [3, 4])
        #expect(second.lastOutboxID == 4)

        let third = try store.page(after: second.lastOutboxID, limit: 2)
        #expect(third.rows.map(\.id) == [5])
        #expect(third.lastOutboxID == 5, "末页游标 = outbox 末尾")

        let empty = try store.page(after: 5, limit: 2)
        #expect(empty.rows.isEmpty)
        #expect(empty.lastOutboxID == 5, "无增量 → 不推进（保持传入的 cursor）")

        let beyond = try store.page(after: 99, limit: 2)
        #expect(beyond.rows.isEmpty)
        #expect(beyond.lastOutboxID == 99, "越过末尾也不回退游标")
    }
}
