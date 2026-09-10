//
//  SyncChangeLogContentMapTests.swift
//  QQPlayerTests
//
//  S2 M4-2a 跨端歌曲引用映射（content_hash ↔ 本地 stableId）测试：
//  - 双向解析：stableId → content_hash / content_hash → stableId（有/无指纹/不存在）
//  - 发送侧：outbox 行 → wire entry 填 contentHash（引用歌曲的实体填；歌单/未知歌/
//    无指纹 = nil；线上 row_key 保持发送端本地键）
//  - 接收侧本地化：命中映射 → row_key 与 payload 歌曲引用改写成**本地 stableId**；
//    无 contentHash（老 peer）/ 歌单行 → 降级透传；本地无此歌 → 挂起
//  - 跨端 roundtrip：A 的 stableId → wire contentHash → B 映射回本地 stableId 落地
//  - 挂起 + 歌到达后重放（upsertTrack 钩子）/ 重放幂等 / 本端更新时本端胜
//  - sync_pending_change 新表迁移幂等
//
//  fixture：DatabaseManager(dbWriter:) 内存库 + SyncPeerSessionTestSupport 双 ready 回环。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

@MainActor
struct SyncChangeLogContentMapTests {
    // MARK: - Fixture

    private static func makeManager() throws -> (DatabaseManager, DatabaseQueue) {
        let queue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: queue)
        try manager.createTables()
        return (manager, queue)
    }

    private static func insertTrack(
        _ db: Database,
        stableId: String,
        contentHash: String?,
        title: String = "T"
    ) throws {
        try db.execute(
            sql: "INSERT INTO track (stable_id, title, path, content_hash) VALUES (?, ?, ?, ?)",
            arguments: [stableId, title, "/m/\(stableId).flac", contentHash]
        )
    }

    /// 入库用 Track 值（content_hash 显式给：upsertTrack 不会再去碰文件，测试不落盘）。
    private static func makeTrack(stableId: String, contentHash: String?) -> Track {
        Track(
            id: nil,
            stableId: stableId,
            albumId: nil,
            artistId: nil,
            title: "T-\(stableId)",
            genre: nil,
            trackNo: nil,
            discNo: nil,
            durationMs: nil,
            sampleRate: nil,
            bitDepth: nil,
            channels: nil,
            path: "/m/\(stableId).flac",
            fileSize: nil,
            modificationDate: nil,
            contentHash: contentHash,
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil,
            hasEmbeddedArt: false
        )
    }

    /// 双 ready 会话 + host/client 各自内存库 + 双 SyncChangeLogPeer（强持有，见 M4-1 教训）。
    private struct PeerHarness {
        let fixture: SessionFixture
        let hostQueue: DatabaseQueue
        let clientQueue: DatabaseQueue
        let hostManager: DatabaseManager
        let clientManager: DatabaseManager
        let hostStore: SyncChangeLogStore
        let clientStore: SyncChangeLogStore
        let hostPeer: SyncChangeLogPeer
        let clientPeer: SyncChangeLogPeer
    }

    private func makeHarness() throws -> PeerHarness {
        let fixture = SessionFixture.pairedHandshake()
        let hostQueue = try DatabaseQueue()
        let hostManager = DatabaseManager(dbWriter: hostQueue)
        try hostManager.createTables()
        let clientQueue = try DatabaseQueue()
        let clientManager = DatabaseManager(dbWriter: clientQueue)
        try clientManager.createTables()
        let hostStore = SyncChangeLogStore(database: hostManager)
        let clientStore = SyncChangeLogStore(database: clientManager)
        let hostPeer = SyncChangeLogPeer(
            session: fixture.hostSession,
            store: hostStore,
            applier: SyncChangeLogApplier(database: hostManager),
            peerID: fixture.clientIdentity.deviceID
        )
        let clientPeer = SyncChangeLogPeer(
            session: fixture.clientSession,
            store: clientStore,
            applier: SyncChangeLogApplier(database: clientManager),
            peerID: fixture.hostIdentity.deviceID
        )
        return PeerHarness(
            fixture: fixture,
            hostQueue: hostQueue,
            clientQueue: clientQueue,
            hostManager: hostManager,
            clientManager: clientManager,
            hostStore: hostStore,
            clientStore: clientStore,
            hostPeer: hostPeer,
            clientPeer: clientPeer
        )
    }

    /// host 侧记一条收藏变更（模拟 addToFavorites 的 outbox 形态）。
    private static func recordHostFavorite(
        _ queue: DatabaseQueue,
        stableId: String,
        updatedAtMs: Int64
    ) throws {
        try queue.write { db in
            try SyncChangeLogStore.record(
                db,
                entity: .favorite,
                rowKey: stableId,
                op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(SyncFavoriteSnapshot(trackStableId: stableId)),
                updatedAtMs: updatedAtMs
            )
        }
    }

    /// favorite 行数（row.
    private static func favoriteCount(_ queue: DatabaseQueue) throws -> Int {
        try queue.read { db in try Favorite.fetchCount(db) }
    }

    /// 指定歌曲的 favorite 行数。
    private static func favoriteCount(_ queue: DatabaseQueue, stableId: String) throws -> Int {
        try queue.read { db in
            try Favorite.filter(Column("track_stable_id") == stableId).fetchCount(db)
        }
    }

    // MARK: - 迁移

    @Test("sync_pending_change 新表迁移幂等：重复 createTables 不炸，列契约齐")
    func pendingTableMigrationIdempotent() throws {
        let (manager, _) = try Self.makeManager()
        try manager.createTables()
        try manager.read { db in
            #expect(try db.tableExists("sync_pending_change"))
            let columns = try db.columns(in: "sync_pending_change").map(\.name)
            for expected in ["id", "entity", "row_key", "remote_row_key", "op", "updated_at", "payload_json"] {
                #expect(columns.contains(expected))
            }
        }
    }

    // MARK: - 双向解析

    @Test("解析：stableId → content_hash / content_hash → stableId；无指纹与不存在的行 = nil")
    func resolverMapsBothDirections() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            try Self.insertTrack(db, stableId: "s-hash", contentHash: "hash-A")
            try Self.insertTrack(db, stableId: "s-nohash", contentHash: nil)
        }
        let resolver = SyncContentHashResolver(database: manager)

        #expect(try resolver.contentHash(forTrackStableId: "s-hash") == "hash-A")
        #expect(try resolver.contentHash(forTrackStableId: "s-nohash") == nil)
        #expect(try resolver.contentHash(forTrackStableId: "ghost") == nil)
        #expect(try resolver.contentHash(forTrackStableId: "") == nil)

        #expect(try resolver.trackStableId(forContentHash: "hash-A") == "s-hash")
        #expect(try resolver.trackStableId(forContentHash: "hash-missing") == nil)
        #expect(try resolver.trackStableId(forContentHash: "s-nohash") == nil)
        #expect(try resolver.trackStableId(forContentHash: "") == nil)
    }

    @Test("解析：同 content_hash 多行取 id 最小（确定性，两端同解）")
    func resolverPicksDeterministicRowForDuplicateHash() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            try Self.insertTrack(db, stableId: "dup-first", contentHash: "hash-dup")
            try Self.insertTrack(db, stableId: "dup-second", contentHash: "hash-dup")
        }
        let resolver = SyncContentHashResolver(database: manager)
        #expect(try resolver.trackStableId(forContentHash: "hash-dup") == "dup-first")
    }

    // MARK: - 发送侧

    @Test("发送侧：wire entry 按歌曲引用填 contentHash；歌单行/未知歌/无指纹 = nil，row_key 不改写")
    func wireEntryFillsContentHash() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            try Self.insertTrack(db, stableId: "host-1", contentHash: "hash-1")
            try Self.insertTrack(db, stableId: "host-nohash", contentHash: nil)
        }
        let mapper = SyncChangeLogMapper(database: manager)
        let rows = [
            SyncChangeLogRow(entity: .favorite, rowKey: "host-1", op: .upsert, updatedAtMs: 1),
            SyncChangeLogRow(entity: .favorite, rowKey: "host-nohash", op: .upsert, updatedAtMs: 2),
            SyncChangeLogRow(entity: .favorite, rowKey: "host-ghost", op: .upsert, updatedAtMs: 3),
            SyncChangeLogRow(entity: .playlist, rowKey: "mix", op: .upsert, updatedAtMs: 4),
            SyncChangeLogRow(entity: .playHistory, rowKey: "host-1|1700", op: .upsert, updatedAtMs: 5),
            SyncChangeLogRow(entity: .playlistItem, rowKey: "mix|host-1", op: .upsert, updatedAtMs: 6),
            SyncChangeLogRow(entity: .playbackPosition, rowKey: "host-1", op: .upsert, updatedAtMs: 7),
            SyncChangeLogRow(entity: .favorite, rowKey: "host-1", op: .delete, updatedAtMs: 8),
        ]
        let entries = try mapper.wireEntries(rows)

        #expect(entries[0].contentHash == "hash-1")
        #expect(entries[1].contentHash == nil) // 本端该歌还没指纹
        #expect(entries[2].contentHash == nil) // 本端没这首歌
        #expect(entries[3].contentHash == nil) // 歌单不引用歌曲
        #expect(entries[4].contentHash == "hash-1") // 播放历史：row_key 左段
        #expect(entries[5].contentHash == "hash-1") // 歌单项：row_key 右段
        #expect(entries[6].contentHash == "hash-1") // 播放位置：row_key
        #expect(entries[7].contentHash == "hash-1") // delete 同样带映射键
        // v1 线上 row_key 仍是发送端本地键（接收端靠 contentHash 本地化）
        #expect(entries.map(\.rowKey) == rows.map(\.rowKey))
        // 远端 outbox id 原样带给对端（merge 排序键）
        #expect(entries[7].id == rows[7].id ?? 0)
    }

    @Test("发送侧：row_key 形态不符时回落读 payload 的 track_stable_id")
    func wireEntryFallsBackToPayload() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            try Self.insertTrack(db, stableId: "host-2", contentHash: "hash-2")
        }
        let mapper = SyncChangeLogMapper(database: manager)
        let history = SyncPlayHistorySnapshot(trackStableId: "host-2", playedAt: 42, playDurationMs: 1000)
        let rows = [
            // 播放历史 row_key 少了时间戳段（异常形态）→ 回落 payload
            SyncChangeLogRow(
                entity: .playHistory,
                rowKey: "host-2",
                op: .upsert,
                updatedAtMs: 1,
                payloadJSON: try SyncSnapshotCodec.encode(history)
            ),
        ]
        let entries = try mapper.wireEntries(rows)
        #expect(entries[0].contentHash == "hash-2")
    }

    // MARK: - 接收侧本地化

    @Test("接收侧：命中映射 → row_key 与 payload 歌曲引用改写成本地 stableId")
    func localizeRewritesToLocalStableId() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            try Self.insertTrack(db, stableId: "local-1", contentHash: "hash-1")
        }
        let mapper = SyncChangeLogMapper(database: manager)

        // favorite（无载荷）
        let favoriteEntry = SyncChangeLogWireEntry(
            id: 11, entity: SyncChangeEntity.favorite.rawValue, rowKey: "host-1",
            op: SyncChangeOp.upsert.rawValue, updatedAtMs: 10,
            contentHash: "hash-1", payloadJSON: nil
        )
        let favorite = try #require(try mapper.localize(favoriteEntry).mappedRow)
        #expect(favorite.rowKey == "local-1")
        #expect(favorite.id == 11) // 保留远端 outbox id

        // play_history（载荷含 track_stable_id，时长保留）
        let history = SyncPlayHistorySnapshot(trackStableId: "host-1", playedAt: 1700, playDurationMs: 3000)
        let historyEntry = SyncChangeLogWireEntry(
            id: 12, entity: SyncChangeEntity.playHistory.rawValue, rowKey: history.rowKey,
            op: SyncChangeOp.upsert.rawValue, updatedAtMs: 11,
            contentHash: "hash-1", payloadJSON: try SyncSnapshotCodec.encode(history)
        )
        let historyRow = try #require(try mapper.localize(historyEntry).mappedRow)
        #expect(historyRow.rowKey == "local-1|1700")
        let rewrittenHistory = try SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: historyRow.payloadJSON)
        #expect(rewrittenHistory.trackStableId == "local-1")
        #expect(rewrittenHistory.playDurationMs == 3000)

        // playlist_item（歌单 slug 段不动，歌段本地化）
        let item = SyncPlaylistItemSnapshot(playlistSlug: "mix", position: 2, trackStableId: "host-1")
        let itemEntry = SyncChangeLogWireEntry(
            id: 13, entity: SyncChangeEntity.playlistItem.rawValue, rowKey: item.rowKey,
            op: SyncChangeOp.upsert.rawValue, updatedAtMs: 12,
            contentHash: "hash-1", payloadJSON: try SyncSnapshotCodec.encode(item)
        )
        let itemRow = try #require(try mapper.localize(itemEntry).mappedRow)
        #expect(itemRow.rowKey == "mix|local-1")
        let rewrittenItem = try SyncSnapshotCodec.decode(SyncPlaylistItemSnapshot.self, from: itemRow.payloadJSON)
        #expect(rewrittenItem.trackStableId == "local-1")
        #expect(rewrittenItem.playlistSlug == "mix")
        #expect(rewrittenItem.position == 2)

        // playback_position（row_key 即歌键）
        let position = SyncPlaybackPositionSnapshot(trackStableId: "host-1", positionMs: 500, updatedAtMs: 12)
        let positionEntry = SyncChangeLogWireEntry(
            id: 14, entity: SyncChangeEntity.playbackPosition.rawValue, rowKey: "host-1",
            op: SyncChangeOp.upsert.rawValue, updatedAtMs: 13,
            contentHash: "hash-1", payloadJSON: try SyncSnapshotCodec.encode(position)
        )
        let positionRow = try #require(try mapper.localize(positionEntry).mappedRow)
        #expect(positionRow.rowKey == "local-1")
        let rewrittenPosition = try SyncSnapshotCodec.decode(
            SyncPlaybackPositionSnapshot.self, from: positionRow.payloadJSON
        )
        #expect(rewrittenPosition.trackStableId == "local-1")
        #expect(rewrittenPosition.positionMs == 500)

        // delete（无载荷）：只是 row_key 改写
        let deleteEntry = SyncChangeLogWireEntry(
            id: 15, entity: SyncChangeEntity.favorite.rawValue, rowKey: "host-1",
            op: SyncChangeOp.delete.rawValue, updatedAtMs: 14,
            contentHash: "hash-1", payloadJSON: nil
        )
        let deleteRow = try #require(try mapper.localize(deleteEntry).mappedRow)
        #expect(deleteRow.rowKey == "local-1")
        #expect(deleteRow.op == SyncChangeOp.delete.rawValue)
        #expect(deleteRow.payloadJSON == nil)
    }

    @Test("接收侧：本地无此歌 → 挂起（保留远端行）；无 contentHash / 歌单行 → 降级透传")
    func localizeSuspendsAndDegrades() throws {
        let (manager, _) = try Self.makeManager()
        let mapper = SyncChangeLogMapper(database: manager)

        // 本地库空空：hash 映射不到 → 挂起
        let suspendedEntry = SyncChangeLogWireEntry(
            id: 21, entity: SyncChangeEntity.favorite.rawValue, rowKey: "host-1",
            op: SyncChangeOp.upsert.rawValue, updatedAtMs: 20,
            contentHash: "hash-unknown", payloadJSON: nil
        )
        let suspended = try mapper.localize(suspendedEntry)
        guard case .suspended(let hash, let remoteRow) = suspended else {
            Issue.record("本地无此歌应挂起，实际 \(suspended)")
            return
        }
        #expect(hash == "hash-unknown")
        #expect(remoteRow.rowKey == "host-1") // 挂起行保持远端键
        #expect(remoteRow.id == 21)

        // 无 contentHash（M4-1 老 peer / 无指纹）→ 降级透传（按远端键应用）
        let legacyEntry = SyncChangeLogWireEntry(
            id: 22, entity: SyncChangeEntity.favorite.rawValue, rowKey: "host-legacy",
            op: SyncChangeOp.upsert.rawValue, updatedAtMs: 21,
            contentHash: nil, payloadJSON: nil
        )
        guard case .passThrough(let legacyRow) = try mapper.localize(legacyEntry) else {
            Issue.record("无 contentHash 应降级透传")
            return
        }
        #expect(legacyRow.rowKey == "host-legacy")

        // 歌单行（不引用歌曲）→ 透传，即便对端误带 contentHash 也不改写
        let playlistEntry = SyncChangeLogWireEntry(
            id: 23, entity: SyncChangeEntity.playlist.rawValue, rowKey: "mix",
            op: SyncChangeOp.upsert.rawValue, updatedAtMs: 22,
            contentHash: "hash-unknown", payloadJSON: nil
        )
        guard case .passThrough(let playlistRow) = try mapper.localize(playlistEntry) else {
            Issue.record("歌单行应透传")
            return
        }
        #expect(playlistRow.rowKey == "mix")
    }

    // MARK: - 跨端 roundtrip

    @Test("跨端 roundtrip：host 收藏 → wire contentHash → client 映射回本地 stableId 落地")
    func crossDeviceRoundtrip() throws {
        let harness = try makeHarness()

        // host：歌曲（stableId host-track，指纹 H1）+ 收藏 + 播放历史
        try harness.hostQueue.write { db in
            try Self.insertTrack(db, stableId: "host-track", contentHash: "H1")
        }
        try Self.recordHostFavorite(harness.hostQueue, stableId: "host-track", updatedAtMs: 1000)

        // client：同一首歌，但本地 stableId 不同（stableId 由本地路径派生）
        try harness.clientQueue.write { db in
            try Self.insertTrack(db, stableId: "client-track", contentHash: "H1")
        }

        try harness.clientPeer.sendPull()

        #expect(try Self.favoriteCount(harness.clientQueue, stableId: "client-track") == 1)
        #expect(try Self.favoriteCount(harness.clientQueue, stableId: "host-track") == 0)
        #expect(try harness.clientStore.cursor(forPeer: harness.clientPeer.peerID) == 1)
        #expect(try SyncChangeLogPendingStore(database: harness.clientManager).pendingCount() == 0)
        // host 端 outbox 只被应答读取，游标未被污染
        #expect(try harness.hostStore.cursor(forPeer: harness.clientPeer.peerID) == 0)
    }

    @Test("挂起 + 歌到达后重放：client 尚无此歌 → 挂起；upsertTrack 带 content_hash → 自动补上")
    func suspendThenReplayOnTrackArrival() throws {
        let harness = try makeHarness()
        let suspendedBox = IntBox()
        harness.clientPeer.onPushSuspended = { suspendedBox.value = $0 }

        try harness.hostQueue.write { db in
            try Self.insertTrack(db, stableId: "host-track", contentHash: "H2")
        }
        try Self.recordHostFavorite(harness.hostQueue, stableId: "host-track", updatedAtMs: 1000)

        try harness.clientPeer.sendPull()

        // 本地无此歌 → 不落地，但挂起（数据不丢），游标照常推进
        let pendingStore = SyncChangeLogPendingStore(database: harness.clientManager)
        #expect(try Self.favoriteCount(harness.clientQueue) == 0)
        #expect(try pendingStore.pendingCount() == 1)
        let pending = try #require(try pendingStore.rows(forContentHash: "H2").first)
        #expect(pending.entity == SyncChangeEntity.favorite.rawValue)
        #expect(pending.rowKey == "H2") // 挂起键 = content_hash
        #expect(pending.remoteRowKey == "host-track")
        #expect(pending.updatedAtMs == 1000)
        #expect(try harness.clientStore.cursor(forPeer: harness.clientPeer.peerID) == 1)
        #expect(suspendedBox.value == 1)

        // 歌曲到位：入库（带 content_hash）触发重放
        try harness.clientManager.upsertTrack(Self.makeTrack(stableId: "client-track", contentHash: "H2"))

        #expect(try Self.favoriteCount(harness.clientQueue, stableId: "client-track") == 1)
        #expect(try Self.favoriteCount(harness.clientQueue, stableId: "host-track") == 0)
        #expect(try pendingStore.pendingCount() == 0)
    }

    @Test("重放幂等：挂起清空后再重放 = 空操作，不产生重复行")
    func replayIsIdempotent() throws {
        let harness = try makeHarness()
        try harness.hostQueue.write { db in
            try Self.insertTrack(db, stableId: "host-track", contentHash: "H4")
        }
        try Self.recordHostFavorite(harness.hostQueue, stableId: "host-track", updatedAtMs: 1000)
        try harness.clientPeer.sendPull()
        #expect(try SyncChangeLogPendingStore(database: harness.clientManager).pendingCount() == 1)

        try harness.clientManager.upsertTrack(Self.makeTrack(stableId: "client-track", contentHash: "H4"))
        // 第二次重放：无挂起行可处理
        let replayed = try SyncChangeLogReplay.replay(contentHash: "H4", database: harness.clientManager)
        #expect(replayed == 0)
        #expect(try Self.favoriteCount(harness.clientQueue) == 1)
        #expect(try SyncChangeLogPendingStore(database: harness.clientManager).pendingCount() == 0)
    }

    @Test("重放走 LWW：本端同键更新（updated_at 更大）→ 本端胜，挂起行清理且不覆盖")
    func replayKeepsLocalWinner() throws {
        let harness = try makeHarness()
        try harness.hostQueue.write { db in
            try Self.insertTrack(db, stableId: "host-track", contentHash: "H5")
        }
        try Self.recordHostFavorite(harness.hostQueue, stableId: "host-track", updatedAtMs: 1000)
        try harness.clientPeer.sendPull()
        #expect(try SyncChangeLogPendingStore(database: harness.clientManager).pendingCount() == 1)

        // 本端先有该歌 + 同键更新的本地事实（user 之后又改过）→ 重放应本端胜
        try harness.clientQueue.write { db in
            try Self.insertTrack(db, stableId: "client-track", contentHash: "H5")
            try SyncChangeLogStore.record(
                db, entity: .favorite, rowKey: "client-track", op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(SyncFavoriteSnapshot(trackStableId: "client-track")),
                updatedAtMs: 9000
            )
        }
        let replayed = try SyncChangeLogReplay.replay(contentHash: "H5", database: harness.clientManager)
        #expect(replayed == 0) // 本端胜：无远端行应用
        // 已消费的挂起行清理（本端事实会向对端收敛）
        #expect(try SyncChangeLogPendingStore(database: harness.clientManager).pendingCount() == 0)
        // 本端 outbox 事实未被改写（重放不写业务行的场景：这里本地并无 favorite 行）
        #expect(try Self.favoriteCount(harness.clientQueue) == 0)
    }

    @Test("挂起幂等：同一远端事实重复推来只留一行挂起")
    func pendingSuspendIsIdempotent() throws {
        let (manager, queue) = try Self.makeManager()
        let pendingStore = SyncChangeLogPendingStore(database: manager)
        let row = SyncChangeLogRow(
            entity: .favorite, rowKey: "host-track", op: .upsert, updatedAtMs: 1000, payloadJSON: nil
        )
        try pendingStore.suspend(row, contentHash: "H6")
        try pendingStore.suspend(row, contentHash: "H6")
        #expect(try pendingStore.pendingCount() == 1)

        // 更旧的远端事实不应覆盖较新的挂起行
        let older = SyncChangeLogRow(
            entity: .favorite, rowKey: "host-track", op: .delete, updatedAtMs: 900, payloadJSON: nil
        )
        try pendingStore.suspend(older, contentHash: "H6")
        let rows = try pendingStore.rows(forContentHash: "H6")
        #expect(rows.count == 1)
        #expect(rows[0].op == SyncChangeOp.upsert.rawValue)
        #expect(rows[0].updatedAtMs == 1000)
        // 队列无关：另一首歌的挂起行互不影响
        let stored = try queue.read { db in try SyncPendingChangeRow.fetchCount(db) }
        #expect(stored == 1)
    }
}

// MARK: - 测试辅助

/// 闭包捕获用的小盒子（避免在 @MainActor 测试里捕获可变局部变量）。
private final class IntBox: @unchecked Sendable {
    var value = 0
}

private extension SyncEntryLocalization {
    /// 非挂起分支的行（挂起分支返回 nil，便于 #require 断言）。
    var mappedRow: SyncChangeLogRow? {
        switch self {
        case .mapped(let row), .passThrough(let row):
            return row
        case .suspended:
            return nil
        }
    }
}
