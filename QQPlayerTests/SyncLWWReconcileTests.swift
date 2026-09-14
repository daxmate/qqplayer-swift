//
//  SyncLWWReconcileTests.swift
//  QQPlayerTests
//
//  S2 M4-1 LWW 对账纯逻辑 + 应用器测试：
//  - representative：同键多行取 updated_at 最大（平局取 id 最大）
//  - merge：远端独有键全应用；同键时间序大者胜；平局 delete 压 upsert、
//    upsert vs upsert 本端胜、delete vs delete 不应用；本端更新则不应用
//  - SyncChangeLogApplier：favorite/play_history/playlist/playlist_item 的
//    upsert 落本地业务表（含幂等：重复应用不炸）；v2（2026-09-10 §12b-7）删除不跨端
//    传播 → delete 在应用层入口被丢弃（不删本地行），断言方向相应改为"被忽略"；
//    引用歌曲的实体落库前先查本地 `track` 行（2026-09-14 身份缺口包）：不存在 → 跳过，
//    不写出 JOIN track 永不匹配的孤儿业务行
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
        // 注：v2（§12b-7）起 wire 层的 delete 已在上游（SyncChangeLogPeer）被拦，
        // 此断言锁的是 merge 纯函数本身对 delete 行的处理规则（不再有生产路径会走到）。
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

    /// 本地 `track` 表插一行（引用歌曲的业务行只有能 JOIN 上它才会被应用）。
    private static func insertTrack(_ db: Database, stableId: String) throws {
        try db.execute(
            sql: "INSERT INTO track (stable_id, title, path) VALUES (?, ?, ?)",
            arguments: [stableId, "T-\(stableId)", "/m/\(stableId).flac"]
        )
    }

    // MARK: - Applier（favorite）

    @Test("Applier favorite：upsert 落行可重复应用；delete 被忽略（不删本地行）")
    func applierFavorite() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        let applier = SyncChangeLogApplier(database: manager)
        // 本端有这首歌（收藏只有能 JOIN 上 track 才会在列表里出现）
        try dbQueue.write { db in try Self.insertTrack(db, stableId: "t1") }

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

        // v2（§12b-7）：删除不跨端传播——delete 行在应用层入口被丢弃，本地行保留
        let delete = SyncChangeLogRow(
            entity: .favorite, rowKey: "t1", op: .delete, updatedAtMs: 200, payloadJSON: nil
        )
        #expect(try applier.apply([delete]) == 0) // 不算应用
        let favCount = try dbQueue.read { db in try Favorite.fetchCount(db) }
        #expect(favCount == 1) // 本地收藏行未被删
        // 重复应用同样忽略（幂等）
        #expect(try applier.apply([delete]) == 0)
        #expect(try dbQueue.read { db in try Favorite.fetchCount(db) } == 1)
    }

    // MARK: - Applier（play_history）

    @Test("Applier play_history：无本地行插入，同 (track, played_at) 行更新时长；delete 被忽略（不删本地行）")
    func applierPlayHistory() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        let applier = SyncChangeLogApplier(database: manager)
        try dbQueue.write { db in try Self.insertTrack(db, stableId: "hist-1") }

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

        // v2（§12b-7）：delete 被忽略 → 本地播放历史行保留
        let delete = SyncChangeLogRow(
            entity: .playHistory, rowKey: "hist-1|1000", op: .delete, updatedAtMs: 9000, payloadJSON: nil
        )
        #expect(try applier.apply([delete]) == 0)
        let historyCount = try dbQueue.read { db in try PlayHistoryEntry.fetchCount(db) }
        #expect(historyCount == 1)
    }

    // MARK: - Applier（playlist + playlist_item）

    @Test("Applier playlist：按 slug upsert（存在更新/缺失插入）；delete 被忽略（歌单与 items 都保留）")
    func applierPlaylist() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        let applier = SyncChangeLogApplier(database: manager)
        try dbQueue.write { db in try Self.insertTrack(db, stableId: "t1") }

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

        // v2（§12b-7）：delete 被忽略 → 歌单与 items 都保留（不再有跨端删除级联）
        let delete = SyncChangeLogRow(
            entity: .playlist, rowKey: "mix", op: .delete, updatedAtMs: 2000, payloadJSON: nil
        )
        let deleteWithSnapshot = SyncChangeLogRow(
            entity: .playlist, rowKey: "mix", op: .delete, updatedAtMs: 2000,
            payloadJSON: try SyncSnapshotCodec.encode(snapshot)
        )
        #expect(try applier.apply([delete, deleteWithSnapshot]) == 0)
        let playlistCount = try dbQueue.read { db in try Playlist.fetchCount(db) }
        let itemCount = try dbQueue.read { db in try PlaylistItem.fetchCount(db) }
        #expect(playlistCount == 1)
        #expect(itemCount == 1)
    }

    // MARK: - Applier 身份兜底（2026-09-14 身份缺口包）

    @Test("Applier 身份兜底：引用不存在曲目的 favorite / play_history / playlist_item 一律跳过，歌入库后可落")
    func applierSkipsRowsWithoutLocalTrack() throws {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        let applier = SyncChangeLogApplier(database: manager)

        let favorite = SyncChangeLogRow(
            entity: .favorite, rowKey: "ghost", op: .upsert, updatedAtMs: 1,
            payloadJSON: try SyncSnapshotCodec.encode(SyncFavoriteSnapshot(trackStableId: "ghost"))
        )
        let history = SyncChangeLogRow(
            entity: .playHistory, rowKey: "ghost|1000", op: .upsert, updatedAtMs: 1,
            payloadJSON: try SyncSnapshotCodec.encode(SyncPlayHistorySnapshot(
                trackStableId: "ghost", playedAt: 1000, playDurationMs: 5000
            ))
        )
        let playlist = SyncChangeLogRow(
            entity: .playlist, rowKey: "mix", op: .upsert, updatedAtMs: 1,
            payloadJSON: try SyncSnapshotCodec.encode(SyncPlaylistSnapshot(
                slug: "mix", title: "Mix", createdAt: 1, updatedAt: 1, lastPlayedAt: 0,
                folderPath: nil, isFolderSynced: false, lastFolderSync: nil, customCoverImagePath: nil
            ))
        )
        let item = SyncChangeLogRow(
            entity: .playlistItem, rowKey: "mix|ghost", op: .upsert, updatedAtMs: 1,
            payloadJSON: try SyncSnapshotCodec.encode(SyncPlaylistItemSnapshot(
                playlistSlug: "mix", position: 1, trackStableId: "ghost"
            ))
        )

        // 本地没有这首歌 → 三条引用歌曲的行都跳过（每行独立事务，互不影响）
        #expect(try applier.apply([favorite, history, item]) == 0)
        // 歌单（不引用歌曲）照常落库，不受影响
        #expect(try applier.apply([playlist]) == 1)
        // 闭包内不写 #expect(try …)（Swift Testing 宏限制）；先取值再断言
        let (favoriteCount, historyCount, itemCount, playlistCount) = try dbQueue.read { db in
            (
                try Favorite.fetchCount(db),
                try PlayHistoryEntry.fetchCount(db),
                try PlaylistItem.fetchCount(db),
                try Playlist.fetchCount(db)
            )
        }
        #expect(favoriteCount == 0, "不得写出孤儿收藏行")
        #expect(historyCount == 0, "不得写出孤儿播放历史行")
        #expect(itemCount == 0, "不得写出孤儿歌单项行")
        #expect(playlistCount == 1, "歌单结构无歌曲引用，照常同步")

        // 歌入库（指纹回填 / 同步到位）→ 同一条行可落（不永久丢数据）
        try dbQueue.write { db in try Self.insertTrack(db, stableId: "ghost") }
        #expect(try applier.apply([favorite, history, item]) == 3)
        let (favoriteAfter, historyAfter, itemAfter) = try dbQueue.read { db in
            (
                try Favorite.fetchCount(db),
                try PlayHistoryEntry.fetchCount(db),
                try PlaylistItem.fetchCount(db)
            )
        }
        #expect(favoriteAfter == 1)
        #expect(historyAfter == 1)
        #expect(itemAfter == 1)
    }
}
