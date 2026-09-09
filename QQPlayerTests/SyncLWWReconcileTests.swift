//
//  SyncLWWReconcileTests.swift
//  QQPlayerTests
//
//  S2 M4-1 LWW 对账纯逻辑 + 应用器测试：
//  - representative：同键多行取 updated_at 最大（平局取 id 最大）
//  - merge：远端独有键全应用；同键时间序大者胜；平局 delete 压 upsert、
//    upsert vs upsert 本端胜、delete vs delete 不应用；本端更新则不应用
//  - SyncChangeLogApplier：favorite/play_history/playlist/playlist_item 的
//    upsert/delete 落本地业务表（含幂等：重复应用不炸、delete 无对象跳过）
//
//  fixture 走 DatabaseManager.init(dbWriter:) + createTables()（内存库真实路径）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

struct SyncLWWReconcileTests {
    // MARK: - 工具

    private static func row(
        id: Int64? = nil,
        entity: SyncChangeEntity = .favorite,
        rowKey: String,
        op: SyncChangeOp = .upsert,
        updatedAtMs: Int64
    ) -> SyncChangeLogRow {
        SyncChangeLogRow(
            id: id,
            entity: entity,
            rowKey: rowKey,
            op: op,
            updatedAtMs: updatedAtMs,
            payloadJSON: nil
        )
    }

    // MARK: - representative

    @Test("representative：同键多行取 updated_at 最大，平局取 id 最大")
    func representative() {
        let rows = [
            Self.row(id: 1, rowKey: "k", updatedAtMs: 100),
            Self.row(id: 2, rowKey: "k", updatedAtMs: 300),
            Self.row(id: 3, rowKey: "k", updatedAtMs: 200),
        ]
        let rep = SyncLWWReconcile.representative(of: rows)
        #expect(rep?.id == 2)

        let tie = [
            Self.row(id: 1, rowKey: "k", updatedAtMs: 100),
            Self.row(id: 9, rowKey: "k", updatedAtMs: 100),
        ]
        #expect(SyncLWWReconcile.representative(of: tie)?.id == 9)

        #expect(SyncLWWReconcile.representative(of: []) == nil)
    }

    // MARK: - merge

    @Test("远端独有键 → 全部应用（含 delete：无本地对象时应用层幂等跳过）")
    func remoteOnlyKeysApplied() {
        let remote = [
            Self.row(id: 10, rowKey: "a", updatedAtMs: 500),
            Self.row(id: 11, rowKey: "b", op: .delete, updatedAtMs: 600),
        ]
        let result = SyncLWWReconcile.merge(localRows: [], remoteRows: remote)
        #expect(result.applyRemote.count == 2)
        #expect(result.localWins.isEmpty)
    }

    @Test("同键时间序大者胜：远端更新 → 应用远端；本端更新 → 不应用")
    func sameKeyNewerWins() {
        let local = [Self.row(id: 1, rowKey: "k", updatedAtMs: 1000)]
        // 远端更新
        let remoteNewer = [Self.row(id: 20, rowKey: "k", updatedAtMs: 2000)]
        let newer = SyncLWWReconcile.merge(localRows: local, remoteRows: remoteNewer)
        #expect(newer.applyRemote.count == 1)
        #expect(newer.applyRemote[0].id == 20)
        #expect(newer.localWins.isEmpty)

        // 本端更新 → 不应用远端
        let remoteOlder = [Self.row(id: 21, rowKey: "k", updatedAtMs: 500)]
        let older = SyncLWWReconcile.merge(localRows: local, remoteRows: remoteOlder)
        #expect(older.applyRemote.isEmpty)
        #expect(older.localWins.count == 1)
        #expect(older.localWins[0].id == 1)
    }

    @Test("平局规则：delete 压 upsert（显式删除意图）；upsert vs upsert 本端胜；delete vs delete 不应用")
    func tieRules() {
        // delete vs upsert（同 updated_at）→ delete 胜（应用远端 delete）
        let localUpsert = [Self.row(id: 1, rowKey: "k", op: .upsert, updatedAtMs: 500)]
        let remoteDelete = [Self.row(id: 20, rowKey: "k", op: .delete, updatedAtMs: 500)]
        let deleteWins = SyncLWWReconcile.merge(localRows: localUpsert, remoteRows: remoteDelete)
        #expect(deleteWins.applyRemote.count == 1)
        #expect(deleteWins.applyRemote[0].op == SyncChangeOp.delete.rawValue)

        // upsert vs upsert 同时间 → 本端胜（避免乒乓）
        let remoteUpsert = [Self.row(id: 21, rowKey: "k", op: .upsert, updatedAtMs: 500)]
        let upsertTie = SyncLWWReconcile.merge(localRows: localUpsert, remoteRows: remoteUpsert)
        #expect(upsertTie.applyRemote.isEmpty)
        #expect(upsertTie.localWins.count == 1)

        // delete vs delete 同时间 → 本端胜（不应用，无对象可删）
        let localDelete = [Self.row(id: 1, rowKey: "k", op: .delete, updatedAtMs: 500)]
        let remoteDeleteTie = [Self.row(id: 20, rowKey: "k", op: .delete, updatedAtMs: 500)]
        let deleteTie = SyncLWWReconcile.merge(localRows: localDelete, remoteRows: remoteDeleteTie)
        #expect(deleteTie.applyRemote.isEmpty)
    }

    @Test("同键远端批多行：取 updated_at 最大的一行代表参与比较")
    func remoteGroupRepresentative() {
        let local = [Self.row(id: 1, rowKey: "k", updatedAtMs: 1000)]
        let remoteGroup = [
            Self.row(id: 30, rowKey: "k", updatedAtMs: 500),
            Self.row(id: 31, rowKey: "k", updatedAtMs: 2500),
        ]
        let result = SyncLWWReconcile.merge(localRows: local, remoteRows: remoteGroup)
        #expect(result.applyRemote.count == 1)
        #expect(result.applyRemote[0].id == 31)
    }

    // MARK: - Applier（favorite）

    @Test("Applier favorite：upsert 落行可重复应用；delete 删行且无对象时跳过")
    func applierFavorite() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        let applier = SyncChangeLogApplier(database: manager)

        let upsert = SyncChangeLogRow(
            entity: .favorite, rowKey: "t1", op: .upsert, updatedAtMs: 100,
            payloadJSON: try SyncSnapshotCodec.encode(SyncFavoriteSnapshot(trackStableId: "t1"))
        )
        #expect(try applier.apply([upsert]) == 1)
        #expect(try applier.apply([upsert]) == 1) // 幂等（replace）

        try dbQueue.read { db in
            let count = try Favorite.fetchCount(db)
            #expect(count == 1)
        }

        let delete = SyncChangeLogRow(
            entity: .favorite, rowKey: "t1", op: .delete, updatedAtMs: 200, payloadJSON: nil
        )
        #expect(try applier.apply([delete]) == 1)
        let favCount = try dbQueue.read { db in try Favorite.fetchCount(db) }
        #expect(favCount == 0)
        // 无对象可删 → false（不算失败，不算应用）
        #expect(try applier.apply([delete]) == 0)
    }

    // MARK: - Applier（play_history）

    @Test("Applier play_history：无本地行插入，同 (track, played_at) 行更新时长；delete 删匹配行")
    func applierPlayHistory() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        let applier = SyncChangeLogApplier(database: manager)

        func snapshot(_ duration: Int64, playedAt: Int64 = 1000) throws -> SyncChangeLogRow {
            SyncChangeLogRow(
                entity: .playHistory,
                rowKey: "hist-1|\(playedAt)",
                op: .upsert,
                updatedAtMs: playedAt,
                payloadJSON: try SyncSnapshotCodec.encode(SyncPlayHistorySnapshot(
                    trackStableId: "hist-1", playedAt: playedAt, playDurationMs: duration
                ))
            )
        }

        // 远端插入（本地无此行）→ INSERT
        #expect(try applier.apply([try snapshot(5000)]) == 1)
        try dbQueue.read { db in
            let row = try PlayHistoryEntry.fetchOne(db)
            #expect(row?.playDurationMs == 5000)
        }

        // 同 (track, played_at) 再推新时长 → UPDATE（不重复插行）
        #expect(try applier.apply([try snapshot(8000)]) == 1)
        try dbQueue.read { db in
            let count = try PlayHistoryEntry.fetchCount(db)
            #expect(count == 1)
            let row = try PlayHistoryEntry.fetchOne(db)
            #expect(row?.playDurationMs == 8000)
        }

        // delete → 删匹配行
        let delete = SyncChangeLogRow(
            entity: .playHistory, rowKey: "hist-1|1000", op: .delete, updatedAtMs: 9000, payloadJSON: nil
        )
        #expect(try applier.apply([delete]) == 1)
        let historyCount = try dbQueue.read { db in try PlayHistoryEntry.fetchCount(db) }
        #expect(historyCount == 0)
    }

    // MARK: - Applier（playlist + playlist_item）

    @Test("Applier playlist：按 slug upsert（存在更新/缺失插入）；delete 删行（级联 items）")
    func applierPlaylist() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        let applier = SyncChangeLogApplier(database: manager)

        let now: Int64 = 1000
        let snapshot = SyncPlaylistSnapshot(
            slug: "mix", title: "Mix", createdAt: now, updatedAt: now, lastPlayedAt: 0,
            folderPath: nil, isFolderSynced: false, lastFolderSync: nil, customCoverImagePath: nil
        )
        let upsert = SyncChangeLogRow(
            entity: .playlist, rowKey: "mix", op: .upsert, updatedAtMs: now,
            payloadJSON: try SyncSnapshotCodec.encode(snapshot)
        )
        #expect(try applier.apply([upsert]) == 1)
        let playlistId = try manager.read { db in
            try Playlist.filter(Column("slug") == "mix").fetchOne(db)?.id
        }
        #expect(playlistId != nil)

        // item upsert（歌单已存在 → 插入）
        let item = SyncPlaylistItemSnapshot(playlistSlug: "mix", position: 1, trackStableId: "t1")
        let itemUpsert = SyncChangeLogRow(
            entity: .playlistItem, rowKey: item.rowKey, op: .upsert, updatedAtMs: now,
            payloadJSON: try SyncSnapshotCodec.encode(item)
        )
        #expect(try applier.apply([itemUpsert]) == 1)
        try dbQueue.read { db in
            let count = try PlaylistItem.fetchCount(db)
            #expect(count == 1)
        }

        // playlist delete → 删歌单（FK cascade 删 items）
        let delete = SyncChangeLogRow(
            entity: .playlist, rowKey: "mix", op: .delete, updatedAtMs: 2000, payloadJSON: nil
        )
        // delete 需要 payload（按 slug 查行）——捕获侧 delete 带快照，这里补快照
        let deleteWithSnapshot = SyncChangeLogRow(
            entity: .playlist, rowKey: "mix", op: .delete, updatedAtMs: 2000,
            payloadJSON: try SyncSnapshotCodec.encode(snapshot)
        )
        #expect(try applier.apply([delete, deleteWithSnapshot]) == 1)
        let playlistCount = try dbQueue.read { db in try Playlist.fetchCount(db) }
        let itemCount = try dbQueue.read { db in try PlaylistItem.fetchCount(db) }
        #expect(playlistCount == 0)
        #expect(itemCount == 0)
    }
}
