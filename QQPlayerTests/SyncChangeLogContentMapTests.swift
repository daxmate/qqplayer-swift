//
//  SyncChangeLogContentMapTests.swift
//  QQPlayerTests
//
//  S2 M4-2a 跨端歌曲引用映射（content_hash ↔ 本地 stableId）测试：
//  - 双向解析：stableId → content_hash / content_hash → stableId（有/无指纹/不存在）
//  - 发送侧：outbox 行 → wire entry 填 contentHash（引用歌曲的实体填；歌单/未知歌/
//    无指纹 = nil；线上 row_key 保持发送端本地键）
//  - 接收侧本地化：命中映射 → row_key 与 payload 歌曲引用改写成**本地 stableId**；
//    歌单行（不引用歌曲）→ 降级透传；本地无此歌 → 挂起；**引用歌曲但没有可用身份
//    键（contentHash nil/空）→ 未定位（不落库、不挂起）**（2026-09-14 身份缺口包）
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

    /// play_history 行数。
    private static func playHistoryCount(_ queue: DatabaseQueue) throws -> Int {
        try queue.read { db in try PlayHistoryEntry.fetchCount(db) }
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

    @Test("接收侧：本地无此歌 → 挂起（保留远端行）；引用歌曲无身份键 → 未定位；歌单行 → 透传")
    func localizeSuspendsDegradesAndMarksUnresolved() throws {
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

        // 引用歌曲但没有可用身份键（contentHash nil）→ 未定位：不落库也不挂起
        // （落库会写出 JOIN track 永不匹配的孤儿业务行；挂起又缺 content_hash 当键）
        let legacyEntry = SyncChangeLogWireEntry(
            id: 22, entity: SyncChangeEntity.favorite.rawValue, rowKey: "host-legacy",
            op: SyncChangeOp.upsert.rawValue, updatedAtMs: 21,
            contentHash: nil, payloadJSON: nil
        )
        guard case .unresolved(let reason, let unresolvedRow) = try mapper.localize(legacyEntry) else {
            Issue.record("引用歌曲但无身份键应判未定位")
            return
        }
        #expect(reason == .missingIdentityKey)
        #expect(unresolvedRow.rowKey == "host-legacy") // 未定位分支保留远端行（诊断用），不改写
        #expect(unresolvedRow.id == 22)
        #expect(unresolvedRow.entity == SyncChangeEntity.favorite.rawValue) // 行模型未被改写（顺序无关）

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
        #expect(playlistRow.entity == SyncChangeEntity.playlist.rawValue)

        // 歌单没有身份键（nil/空）照样透传：无歌曲引用就无需跨端身份
        for hash in [String?.none, ""] {
            let entry = SyncChangeLogWireEntry(
                id: 24, entity: SyncChangeEntity.playlist.rawValue, rowKey: "mix2",
                op: SyncChangeOp.upsert.rawValue, updatedAtMs: 23,
                contentHash: hash, payloadJSON: nil
            )
            guard case .passThrough = try mapper.localize(entry) else {
                Issue.record("歌单行（contentHash=\(hash ?? "nil")）应透传")
                return
            }
        }

        // 未知实体（未来版本加的新实体）：无歌曲引用概念 → 仍透传（不因未知识别就丢数据）
        let unknownEntry = SyncChangeLogWireEntry(
            id: 25, entity: "future_entity", rowKey: "x",
            op: SyncChangeOp.upsert.rawValue, updatedAtMs: 24,
            contentHash: nil, payloadJSON: nil
        )
        guard case .passThrough = try mapper.localize(unknownEntry) else {
            Issue.record("未知实体应透传")
            return
        }
    }

    @Test("handlePush：缺身份键的 play_history 行 → 不落库（也不挂起），未定位计数回调收到 1")
    func handlePushSkipsUnresolvedRows() throws {
        let harness = try makeHarness()
        let unresolvedBox = IntBox()
        let appliedBox = IntBox()
        harness.clientPeer.onPushUnresolved = { unresolvedBox.value = $0 }
        harness.clientPeer.onPushApplied = { appliedBox.value = $0 }

        // host：歌在本地但**指纹为空** → wire entry 拿不到 contentHash（发送侧欠账）
        try harness.hostQueue.write { db in
            try Self.insertTrack(db, stableId: "host-track", contentHash: nil)
        }
        let history = SyncPlayHistorySnapshot(trackStableId: "host-track", playedAt: 1700, playDurationMs: 3000)
        try harness.hostQueue.write { db in
            try SyncChangeLogStore.record(
                db, entity: .playHistory, rowKey: history.rowKey, op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(history), updatedAtMs: 1000
            )
        }

        try harness.clientPeer.sendPull()

        #expect(try Self.playHistoryCount(harness.clientQueue) == 0, "缺身份键的行不落库（否则是不可见的孤儿行）")
        #expect(unresolvedBox.value == 1, "未定位计数可观测（面板据此披露）")
        #expect(appliedBox.value == 0, "未落库 → 应用计数 0")
        #expect(
            try SyncChangeLogPendingStore(database: harness.clientManager).pendingCount() == 0,
            "不挂起（挂起键 = content_hash，这里没有）"
        )
        #expect(try harness.clientStore.cursor(forPeer: harness.clientPeer.peerID) == 1, "游标照常推进：不留重发死循环")
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

    // MARK: - T15b 出站悬空引用对账修复

    /// 修复前后业务表的逐字快照（「不误伤」断言用）：只比内容，不比自增 id。
    private static func businessSnapshot(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            var out: [String] = []
            for row in try PlayHistoryEntry.fetchAll(db) {
                out.append("ph|\(row.trackStableId)|\(row.playedAt)|\(row.playDurationMs)")
            }
            for row in try Favorite.fetchAll(db) {
                out.append("fav|\(row.trackStableId)")
            }
            for row in try PlaylistItem.fetchAll(db) {
                out.append("pi|\(row.playlistId)|\(row.position)|\(row.trackStableId)")
            }
            return out.sorted()
        }
    }

    @Test("T15b 悬空对账：play_history 按 played_at 命中 → outbox 引用改写，wire 不再缺身份键")
    func danglingRepairRewritesPlayHistoryByPlayedAt() throws {
        let (manager, queue) = try Self.makeManager()
        let playedAt: Int64 = 1_700_000_000_000
        try queue.write { db in
            // 当前曲目（容器路径变化后重新派生的 stableId，有行有指纹）
            try Self.insertTrack(db, stableId: "s-new", contentHash: "hash-new")
            // 业务播放历史：事件时间不变、指向当前 stableId
            try PlayHistoryEntry(trackStableId: "s-new", playedAt: playedAt, playDurationMs: 1000).insert(db)
            // outbox 悬空行：引用已失效的旧 stableId（track 表查无此歌）
            try SyncChangeLogStore.record(
                db,
                entity: .playHistory,
                rowKey: "s-old|\(playedAt)",
                op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(
                    SyncPlayHistorySnapshot(trackStableId: "s-old", playedAt: playedAt, playDurationMs: 1000)
                ),
                updatedAtMs: 2000
            )
        }

        let repair = try SyncChangeLogDanglingRepair(database: manager).run()
        #expect(repair.repaired == 1)
        #expect(repair.cleaned == 0)
        #expect(repair.skipped == 0)

        let rows = try queue.read { db in try SyncChangeLogRow.fetchAll(db) }
        #expect(rows.count == 1)
        #expect(rows[0].rowKey == "s-new|\(playedAt)")
        let payload = try SyncSnapshotCodec.decode(SyncPlayHistorySnapshot.self, from: rows[0].payloadJSON)
        #expect(payload.trackStableId == "s-new")

        // 真的能被同步出去：修好后 wire 取数不再缺身份键（对端因此能定位并落库）
        let batch = try SyncChangeLogMapper(database: manager).wireEntriesDetailed(rows)
        #expect(batch.missingIdentity.isEmpty)
        #expect(batch.entries.map(\.contentHash) == ["hash-new"])
    }

    @Test("T15b 悬空对账：不可修复的悬空行（favorite / playlist_item / 对不上账的 play_history）→ 清理 + 计数")
    func danglingRepairCleansUnrepairableRows() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            try Self.insertTrack(db, stableId: "s-live", contentHash: "hash-live")
            // 悬空 favorite：没有可靠对账键
            try SyncChangeLogStore.record(
                db, entity: .favorite, rowKey: "s-gone", op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(SyncFavoriteSnapshot(trackStableId: "s-gone")),
                updatedAtMs: 1000
            )
            // 悬空 playlist_item：没有可靠对账键
            try SyncChangeLogStore.record(
                db, entity: .playlistItem, rowKey: "pl|s-gone", op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(
                    SyncPlaylistItemSnapshot(playlistSlug: "pl", position: 0, trackStableId: "s-gone")
                ),
                updatedAtMs: 1000
            )
            // 悬空 play_history：本端 play_history 表里没有同 played_at 的行 → 对不上账
            try SyncChangeLogStore.record(
                db, entity: .playHistory, rowKey: "s-gone|123", op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(
                    SyncPlayHistorySnapshot(trackStableId: "s-gone", playedAt: 123, playDurationMs: 0)
                ),
                updatedAtMs: 1000
            )
            // 引用有效的行（非悬空）：不参与修复，必须原样保留
            try SyncChangeLogStore.record(
                db, entity: .favorite, rowKey: "s-live", op: .upsert, payloadJSON: nil, updatedAtMs: 1000
            )
        }

        let repair = try SyncChangeLogDanglingRepair(database: manager).run()
        #expect(repair.repaired == 0)
        #expect(repair.cleaned == 3)
        #expect(repair.skipped == 0)

        let remaining = try queue.read { db in try SyncChangeLogRow.fetchAll(db) }
        #expect(remaining.map(\.rowKey) == ["s-live"])
    }

    @Test("T15b 悬空对账：幂等——再跑一遍零改动、零计数，outbox 逐字不变")
    func danglingRepairIsIdempotent() throws {
        let (manager, queue) = try Self.makeManager()
        let playedAt: Int64 = 1_700_000_000_001
        try queue.write { db in
            try Self.insertTrack(db, stableId: "s-cur", contentHash: "hash-cur")
            try PlayHistoryEntry(trackStableId: "s-cur", playedAt: playedAt, playDurationMs: 500).insert(db)
            try SyncChangeLogStore.record(
                db, entity: .playHistory, rowKey: "s-dead|\(playedAt)", op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(
                    SyncPlayHistorySnapshot(trackStableId: "s-dead", playedAt: playedAt, playDurationMs: 500)
                ),
                updatedAtMs: 3000
            )
            try SyncChangeLogStore.record(
                db, entity: .favorite, rowKey: "s-dead", op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(SyncFavoriteSnapshot(trackStableId: "s-dead")),
                updatedAtMs: 3000
            )
        }
        let repair = SyncChangeLogDanglingRepair(database: manager)
        let first = try repair.run()
        #expect(first.repaired == 1)
        #expect(first.cleaned == 1)
        let afterFirst = try queue.read { db in try SyncChangeLogRow.fetchAll(db) }

        let second = try repair.run()
        #expect(second == SyncChangeLogDanglingRepair.Report())
        #expect(second.didChange == false)
        let afterSecond = try queue.read { db in try SyncChangeLogRow.fetchAll(db) }
        #expect(afterSecond == afterFirst)
    }

    @Test("T15b 悬空对账：不误伤——业务行（play_history / favorite / playlist_item）行数与内容逐字不变")
    func danglingRepairLeavesBusinessRowsUntouched() throws {
        let (manager, queue) = try Self.makeManager()
        let playedAt: Int64 = 1_700_000_000_002
        try queue.write { db in
            try Self.insertTrack(db, stableId: "s-keep", contentHash: "hash-keep")
            // 业务行：全部指向有效曲目（修复只该动 outbox，不碰这些）
            try PlayHistoryEntry(trackStableId: "s-keep", playedAt: playedAt, playDurationMs: 700).insert(db)
            try Favorite(trackStableId: "s-keep").insert(db)
            try Playlist(
                id: nil,
                slug: "pl",
                title: "PL",
                createdAt: 1,
                updatedAt: 1,
                lastPlayedAt: 0,
                folderPath: nil,
                isFolderSynced: false,
                lastFolderSync: nil,
                customCoverImagePath: nil
            ).insert(db)
            let playlistID = try Playlist.filter(Column("slug") == "pl").fetchOne(db)?.id ?? 0
            try PlaylistItem(playlistId: playlistID, position: 0, trackStableId: "s-keep").insert(db)
            // 悬空 outbox 行（各实体一份）：只该清/改 outbox 侧
            try SyncChangeLogStore.record(
                db, entity: .favorite, rowKey: "s-dead", op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(SyncFavoriteSnapshot(trackStableId: "s-dead")),
                updatedAtMs: 4000
            )
            try SyncChangeLogStore.record(
                db, entity: .playlistItem, rowKey: "pl|s-dead", op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(
                    SyncPlaylistItemSnapshot(playlistSlug: "pl", position: 1, trackStableId: "s-dead")
                ),
                updatedAtMs: 4000
            )
            try SyncChangeLogStore.record(
                db, entity: .playHistory, rowKey: "s-dead|\(playedAt)", op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(
                    SyncPlayHistorySnapshot(trackStableId: "s-dead", playedAt: playedAt, playDurationMs: 700)
                ),
                updatedAtMs: 4000
            )
        }
        let before = try Self.businessSnapshot(queue)
        #expect(before.count == 3)

        let repair = try SyncChangeLogDanglingRepair(database: manager).run()
        // 悬空 play_history 被 played_at 命中（与业务行同 played_at）→ 修复；另两条清理
        #expect(repair.repaired == 1)
        #expect(repair.cleaned == 2)

        let after = try Self.businessSnapshot(queue)
        #expect(after == before)
    }

    // MARK: - T15b-2 本地真值 → outbox 对账补发

    /// 造一个歌单（返回 id）；`folderSynced` = true 模拟 folder-synced 歌单。
    /// 其余字段可显式指定（“载荷与业务行逐字一致”断言用）。
    private static func insertPlaylist(
        _ db: Database,
        slug: String,
        folderSynced: Bool = false,
        title: String? = nil,
        createdAt: Int64 = 1,
        updatedAt: Int64 = 1,
        lastPlayedAt: Int64 = 0,
        customCoverImagePath: String? = nil
    ) throws -> Int64 {
        try Playlist(
            id: nil,
            slug: slug,
            title: title ?? slug.uppercased(),
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastPlayedAt: lastPlayedAt,
            folderPath: folderSynced ? "/local/folder" : nil,
            isFolderSynced: folderSynced,
            lastFolderSync: nil,
            customCoverImagePath: customCoverImagePath
        ).insert(db)
        return try Playlist.filter(Column("slug") == slug).fetchOne(db)?.id ?? 0
    }

    /// 歌单业务行的逐字快照（“只动 outbox、不碰业务行”断言用；Playlist 不是 Equatable）。
    private static func playlistSnapshot(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try Playlist.order(Column("slug")).fetchAll(db).map {
                "\($0.slug)|\($0.title)|\($0.createdAt)|\($0.updatedAt)|\($0.lastPlayedAt)"
                    + "|\($0.folderPath ?? "-")|\($0.isFolderSynced)|\($0.lastFolderSync ?? -1)"
                    + "|\($0.customCoverImagePath ?? "-")"
            }
        }
    }

    /// outbox 的「实体|行键」列表（按 id 升序）。
    private static func outboxKeys(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try SyncChangeLogRow.order(Column("id")).fetchAll(db).map { "\($0.entity)|\($0.rowKey)" }
        }
    }

    @Test("T15b-2 补发：业务表现有收藏/歌单成员/播放历史而 outbox 缺行 → 补进 outbox 且不再缺身份键")
    func reconcileEmitsLocalTruthIntoOutbox() throws {
        let (manager, queue) = try Self.makeManager()
        let playedAt: Int64 = 1_700_000_100_000
        try queue.write { db in
            try Self.insertTrack(db, stableId: "s-live", contentHash: "hash-live")
            try Favorite(trackStableId: "s-live").insert(db)
            let playlistID = try Self.insertPlaylist(db, slug: "pl")
            try PlaylistItem(playlistId: playlistID, position: 0, trackStableId: "s-live").insert(db)
            try PlayHistoryEntry(trackStableId: "s-live", playedAt: playedAt, playDurationMs: 900).insert(db)
        }

        let report = try SyncChangeLogDanglingRepair(database: manager).run()
        #expect(report.emitted == 4)
        #expect(report.emittedWithoutIdentity == 0)
        #expect(report.skippedLocalDangling == 0)
        #expect(
            try Self.outboxKeys(queue).sorted()
                == [
                    "favorite|s-live",
                    "play_history|s-live|\(playedAt)",
                    "playlist|pl",
                    "playlist_item|pl|s-live",
                ].sorted()
        )

        // 真的能同步出去：补发的四条都不缺身份键（否则对端会按「未定位」丢弃）
        let rows = try queue.read { db in try SyncChangeLogRow.order(Column("id")).fetchAll(db) }
        let batch = try SyncChangeLogMapper(database: manager).wireEntriesDetailed(rows)
        #expect(batch.missingIdentity.isEmpty)
        // 歌单结构行不引用歌曲 → 线上 contentHash = nil（对端按「不引用歌曲」透传，不是缺口）
        #expect(batch.entries.map(\.contentHash) == [nil, "hash-live", "hash-live", "hash-live"])
    }

    @Test("T15b-2 补发：幂等——再跑一遍零改动、零计数，outbox 逐字不变")
    func reconcileIsIdempotent() throws {
        let (manager, queue) = try Self.makeManager()
        let playedAt: Int64 = 1_700_000_100_001
        try queue.write { db in
            try Self.insertTrack(db, stableId: "s-live", contentHash: "hash-live")
            try Favorite(trackStableId: "s-live").insert(db)
            try PlayHistoryEntry(trackStableId: "s-live", playedAt: playedAt, playDurationMs: 900).insert(db)
        }

        let repair = SyncChangeLogDanglingRepair(database: manager)
        let first = try repair.run()
        #expect(first.emitted == 2)
        let afterFirst = try queue.read { db in try SyncChangeLogRow.fetchAll(db) }

        let second = try repair.run()
        #expect(second == SyncChangeLogDanglingRepair.Report())
        #expect(second.didChange == false)
        let afterSecond = try queue.read { db in try SyncChangeLogRow.fetchAll(db) }
        #expect(afterSecond == afterFirst)
    }

    @Test("T15b-2 补发：本地悬空不补（只计数）；缺指纹照补并计数（对端应披露为未定位）")
    func reconcileSkipsLocalDanglingAndCountsMissingIdentity() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            // 有 track 行但指纹为空 = 缺指纹（T13/T14 口径：照发，对端未定位）
            try Self.insertTrack(db, stableId: "s-nohash", contentHash: nil)
            try Favorite(trackStableId: "s-nohash").insert(db)
            // 本地悬空：收藏指向的歌在 track 表查无
            try Favorite(trackStableId: "s-ghost").insert(db)
        }

        let report = try SyncChangeLogDanglingRepair(database: manager).run()
        #expect(report.emitted == 1)
        #expect(report.emittedWithoutIdentity == 1)
        #expect(report.skippedLocalDangling == 1)
        #expect(try Self.outboxKeys(queue) == ["favorite|s-nohash"])
    }

    @Test("T15b-2 补发：悬空行被清掉后按业务表补回（「清完就永远同步不出去」的修复）")
    func reconcileReemitsAfterDanglingCleanup() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            try Self.insertTrack(db, stableId: "s-live", contentHash: "hash-live")
            try Favorite(trackStableId: "s-live").insert(db)
            // 引用已失效的旧 stableId（容器路径变化前的键）——T15b 只清不补，这里验证 T15b-2 会补回
            try SyncChangeLogStore.record(
                db, entity: .favorite, rowKey: "s-dead", op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(SyncFavoriteSnapshot(trackStableId: "s-dead")),
                updatedAtMs: 5000
            )
        }

        let report = try SyncChangeLogDanglingRepair(database: manager).run()
        #expect(report.cleaned == 1)
        #expect(report.emitted == 1)
        #expect(try Self.outboxKeys(queue) == ["favorite|s-live"])
    }

    @Test("T15b-2 补发：folder-synced 歌单成员不入跨端同步（与写入侧同一口径）")
    func reconcileSkipsFolderSyncedPlaylistItems() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            try Self.insertTrack(db, stableId: "s-live", contentHash: "hash-live")
            let folderPlaylistID = try Self.insertPlaylist(db, slug: "folder-pl", folderSynced: true)
            try PlaylistItem(playlistId: folderPlaylistID, position: 0, trackStableId: "s-live").insert(db)
        }

        let report = try SyncChangeLogDanglingRepair(database: manager).run()
        #expect(report.emitted == 0)
        #expect(try Self.outboxKeys(queue).isEmpty)
    }

    @Test("T15b-2 补发：手动歌单结构行补进 outbox——行键 = slug、载荷可解码且与业务行逐字一致")
    func reconcileEmitsPlaylistStructure() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            // 注意：**不插任何 track 行**——歌单结构不引用歌曲，补发不依赖曲库。
            _ = try Self.insertPlaylist(
                db,
                slug: "my-pl",
                title: "My Playlist",
                createdAt: 111,
                updatedAt: 222,
                lastPlayedAt: 333,
                customCoverImagePath: "/covers/x.png"
            )
        }

        let report = try SyncChangeLogDanglingRepair(database: manager).run()
        #expect(report.emitted == 1)
        // 结构行不做身份判定：两个身份类计数必须保持为 0
        #expect(report.emittedWithoutIdentity == 0)
        #expect(report.skippedLocalDangling == 0)

        let rows = try queue.read { db in try SyncChangeLogRow.fetchAll(db) }
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.entity == SyncChangeEntity.playlist.rawValue)
        #expect(row.op == SyncChangeOp.upsert.rawValue)
        #expect(row.rowKey == "my-pl")

        // 载荷可解码，且与业务行逐字一致
        let payload = try SyncSnapshotCodec.decode(SyncPlaylistSnapshot.self, from: row.payloadJSON)
        #expect(payload.rowKey == row.rowKey)
        let business = try #require(
            try queue.read { db in try Playlist.filter(Column("slug") == "my-pl").fetchOne(db) }
        )
        #expect(payload.slug == business.slug)
        #expect(payload.title == business.title)
        #expect(payload.createdAt == business.createdAt)
        #expect(payload.updatedAt == business.updatedAt)
        #expect(payload.lastPlayedAt == business.lastPlayedAt)
        #expect(payload.folderPath == business.folderPath)
        #expect(payload.isFolderSynced == business.isFolderSynced)
        #expect(payload.lastFolderSync == business.lastFolderSync)
        #expect(payload.customCoverImagePath == business.customCoverImagePath)

        // 线上不发身份键噪音（歌单行不引用歌曲 → contentHash nil，但不是「缺身份键」）
        let batch = try SyncChangeLogMapper(database: manager).wireEntriesDetailed(rows)
        #expect(batch.missingIdentity.isEmpty)
        #expect(batch.entries.map(\.contentHash) == [nil])
    }

    @Test("T15b-2 补发：歌单补发幂等——再跑一遍零改动零计数，outbox 与业务行逐字不变")
    func reconcilePlaylistIsIdempotent() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            _ = try Self.insertPlaylist(db, slug: "my-pl", title: "My Playlist", updatedAt: 222)
            _ = try Self.insertPlaylist(db, slug: "other-pl", title: "Other")
        }

        let repair = SyncChangeLogDanglingRepair(database: manager)
        let first = try repair.run()
        #expect(first.emitted == 2)
        let afterFirst = try queue.read { db in try SyncChangeLogRow.fetchAll(db) }
        let businessBefore = try Self.playlistSnapshot(queue)

        let second = try repair.run()
        #expect(second == SyncChangeLogDanglingRepair.Report())
        #expect(second.didChange == false)
        let afterSecond = try queue.read { db in try SyncChangeLogRow.fetchAll(db) }
        #expect(afterSecond == afterFirst)
        // 只动 sync_outbox：业务行零改动
        #expect(try Self.playlistSnapshot(queue) == businessBefore)
    }

    @Test("T15b-2 补发：folder-synced 歌单结构行不入跨端同步（与写入侧同一口径）")
    func reconcileSkipsFolderSyncedPlaylists() throws {
        let (manager, queue) = try Self.makeManager()
        try queue.write { db in
            _ = try Self.insertPlaylist(db, slug: "folder-pl", folderSynced: true)
        }

        let report = try SyncChangeLogDanglingRepair(database: manager).run()
        #expect(report.emitted == 0)
        #expect(report == SyncChangeLogDanglingRepair.Report())
        #expect(try Self.outboxKeys(queue).isEmpty)
    }

    // MARK: - 矩阵守护（静态契约 + 行为，2026-09-15）
    //
    // 目的：把 `docs/sync-matrix.md` 的「实体 × 能力」矩阵变成**CI 能守的断言**——
    // 新增实体 / 新消费点漏一层（没分类 / 没补发 / 没计数）时这里直接红，
    // 而不是等真机“测到哪发现修到哪”。

    @Test("矩阵契约：每个 `SyncChangeEntity` 都必须被显式分类（新增 case 必须做决定）")
    func matrixContractEveryEntityIsClassified() throws {
        // 声明表 = 本仓库当前事实（与 `v1Synced`、docs/sync-matrix.md §0 一致；改实体清单就要改这里）
        let synced: Set<SyncChangeEntity> = [.favorite, .playHistory, .playlist, .playlistItem]
        let gatedSynced: [SyncChangeEntity: String] = [
            .playbackPosition: "跳端续播：默认关闭的独立开关门控（捕获/落点见 PlaybackPositionCapture 一套）",
        ]

        #expect(
            Set(SyncChangeEntity.v1Synced) == synced,
            "v1Synced 与矩阵声明表不一致：改实体清单要同时更新声明表与 docs/sync-matrix.md"
        )
        for entity in SyncChangeEntity.allCases {
            let classified = synced.contains(entity) || gatedSynced[entity] != nil
            #expect(
                classified,
                "\(entity.rawValue) 未分类：新实体必须显式声明「参与同步 / 开关门控同步 / 不同步+理由」"
            )
        }
        #expect(
            synced.union(gatedSynced.keys) == Set(SyncChangeEntity.allCases),
            "分类必须覆盖全部 case（新增 case 漏分类时这里红）"
        )
    }

    @Test("矩阵契约：补发要覆盖所有「本地载体是业务表」的同步实体")
    func matrixContractReconcileCoversTableBackedEntities() throws {
        // 事实：favorite / play_history / playlist / playlist_item 的本地载体都是 DB 行 →
        // 必须能从业务表重建 outbox 行（否则 outbox 机制之前产生的行永不同步：2026-09-14 收藏事故）
        let tableBacked: Set<SyncChangeEntity> = [.favorite, .playHistory, .playlist, .playlistItem]
        #expect(
            Set(SyncChangeLogDanglingRepair.reconcilableEntities) == tableBacked,
            "补发清单与「表载体同步实体」不一致：新增表载体实体必须同时接进 reconcileLocalTruth"
        )
        // 载体不是 DB 行的实体不得进补发表（playback_position = UserDefaults 载体）
        #expect(
            SyncChangeLogDanglingRepair.reconcilableEntities.contains(.playbackPosition) == false,
            "载体不是业务表的实体没有「从表重建」语义，不能挂在补发入口上"
        )
    }

    @Test("矩阵契约：引用歌曲的同步实体缺身份键时逐条记账（不得静默丢）")
    func matrixContractMissingIdentityIsCountedForEveryTrackScopedEntity() throws {
        let (manager, _) = try Self.makeManager()
        // 本端没有这些歌 → 发送侧必须逐条记「缺身份键」（对端会按「未定位」披露）
        let rows: [SyncChangeLogRow] = [
            SyncChangeLogRow(entity: .favorite, rowKey: "ghost", op: .upsert, updatedAtMs: 1),
            SyncChangeLogRow(entity: .playHistory, rowKey: "ghost|1000", op: .upsert, updatedAtMs: 1),
            SyncChangeLogRow(entity: .playlistItem, rowKey: "pl|ghost", op: .upsert, updatedAtMs: 1),
        ]

        let batch = try SyncChangeLogMapper(database: manager).wireEntriesDetailed(rows)

        #expect(
            batch.missingIdentity.count == rows.count,
            "引用歌曲的实体缺身份键时必须逐条记账（静默丢 = 对端只能默默丢掉）"
        )
        #expect(batch.entries.allSatisfy { $0.contentHash == nil })
    }
}

/// 闭包捕获用的小盒子（避免在 @MainActor 测试里捕获可变局部变量）。
private final class IntBox: @unchecked Sendable {
    var value = 0
}

private extension SyncEntryLocalization {
    /// 非挂起 / 非未定位分支的行（两者返回 nil，便于 #require 断言）。
    var mappedRow: SyncChangeLogRow? {
        switch self {
        case .mapped(let row), .passThrough(let row):
            return row
        case .suspended, .unresolved:
            return nil
        }
    }
}
