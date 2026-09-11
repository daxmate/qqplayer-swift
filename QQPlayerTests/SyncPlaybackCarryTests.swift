//
//  SyncPlaybackCarryTests.swift
//  QQPlayerTests
//
//  R3b 播放数据「跟歌走」测试（GRDB 侧生产实现；无模拟器 harness 覆盖纯逻辑与编排，
//  见 scripts/sync-harness/main.swift ㉘-㉛）：
//  - DB facts：track 路径 → (stableId, content_hash)；outbox 按行键引用取该歌的行
//    （复用 SyncTrackReference 单一事实源，favorite / play_history / playlist_item）
//  - 推送方向端到端：Mac 携带 → 设备 SyncChangeLogPeer 收帧 → 本地化（content_hash
//    → 设备 stableId）→ LWW → 落库（favorite / play_history）
//  - 本地缺歌挂起不丢：设备还没入库该歌 → 挂起（sync_pending_change），歌入库后重放
//  - 删除不传播：同键 upsert→delete 的批次不上线（帧都不发）
//  - 拉取方向：帧 8 请求 → 对端应答帧 9 → 本端落库
//  - 条目 → 线上 entry 映射（字段一一对应）
//
//  fixture：SyncPeerSessionTestSupport 双 ready 回环 + 两端各自内存 GRDB 库。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

@MainActor
struct SyncPlaybackCarryTests {
    // MARK: - Fixture

    private struct CarryHarness {
        let fixture: SessionFixture
        let macRoot: URL
        let deviceRoot: URL
        let macManager: DatabaseManager
        let deviceManager: DatabaseManager
        let macCarry: SyncPlaybackCarryPeer
        /// ⚠️ 强持有：对端 peer 以 [weak self] 挂接会话，弃之则永不应答/接收。
        let devicePeer: SyncChangeLogPeer
        let deviceStore: SyncChangeLogStore
    }

    private func makeHarness(deviceTracks: [(String, String, String)] = []) throws -> CarryHarness {
        let fixture = SessionFixture.pairedHandshake()
        let macRoot = try Self.makeRoot("carry-mac")
        let deviceRoot = try Self.makeRoot("carry-device")

        let macQueue = try DatabaseQueue()
        let macManager = DatabaseManager(dbWriter: macQueue)
        try macManager.createTables()
        let deviceQueue = try DatabaseQueue()
        let deviceManager = DatabaseManager(dbWriter: deviceQueue)
        try deviceManager.createTables()

        for (stableId, contentHash, relative) in deviceTracks {
            try Self.insertTrack(deviceManager, stableId: stableId, contentHash: contentHash, root: deviceRoot, relative: relative)
        }

        let deviceStore = SyncChangeLogStore(database: deviceManager)
        let devicePeer = SyncChangeLogPeer(
            session: fixture.clientSession,
            store: deviceStore,
            applier: SyncChangeLogApplier(database: deviceManager),
            peerID: fixture.hostIdentity.deviceID
        )
        let macCarry = SyncPlaybackCarryPeer(
            session: fixture.hostSession,
            libraryRoot: macRoot,
            peerID: fixture.clientIdentity.deviceID,
            database: macManager
        )
        return CarryHarness(
            fixture: fixture,
            macRoot: macRoot,
            deviceRoot: deviceRoot,
            macManager: macManager,
            deviceManager: deviceManager,
            macCarry: macCarry,
            devicePeer: devicePeer,
            deviceStore: deviceStore
        )
    }

    // MARK: - 辅助

    private static func makeRoot(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncPlaybackCarryTests-\(tag)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func insertTrack(
        _ manager: DatabaseManager,
        stableId: String,
        contentHash: String?,
        root: URL,
        relative: String,
        title: String = "T"
    ) throws {
        let path = root.appendingPathComponent(relative).path
        try manager.write { db in
            try db.execute(
                sql: "INSERT INTO track (stable_id, title, path, content_hash) VALUES (?, ?, ?, ?)",
                arguments: [stableId, title, path, contentHash]
            )
        }
    }

    /// 本端写一条 outbox 变更（模拟业务写入点；测试不关心是否与业务行同事务）。
    private static func record(
        _ manager: DatabaseManager,
        entity: SyncChangeEntity,
        rowKey: String,
        op: SyncChangeOp,
        payloadJSON: String? = nil,
        updatedAtMs: Int64
    ) throws {
        let store = SyncChangeLogStore(database: manager)
        try store.record(entity: entity, rowKey: rowKey, op: op, payloadJSON: payloadJSON, updatedAtMs: updatedAtMs)
    }

    private static func historyPayload(stableId: String, playedAt: Int64, durationMs: Int64) throws -> String {
        try SyncSnapshotCodec.encode(
            SyncPlayHistorySnapshot(trackStableId: stableId, playedAt: playedAt, playDurationMs: durationMs)
        )
    }

    private static func playlistItemPayload(slug: String, stableId: String, position: Int) throws -> String {
        try SyncSnapshotCodec.encode(
            SyncPlaylistItemSnapshot(playlistSlug: slug, position: position, trackStableId: stableId)
        )
    }

    // MARK: - DB facts

    @Test("DB facts：相对路径 → (stableId, content_hash)；outbox 按行键引用只取该歌的行")
    func databaseFactsResolveTrackAndPlaybackRows() throws {
        let harness = try makeHarness()
        try Self.insertTrack(
            harness.macManager, stableId: "s-a", contentHash: "h-a",
            root: harness.macRoot, relative: "Album/a.flac"
        )
        try Self.insertTrack(
            harness.macManager, stableId: "s-b", contentHash: "h-b",
            root: harness.macRoot, relative: "Album/b.flac"
        )
        try Self.record(harness.macManager, entity: .favorite, rowKey: "s-a", op: .upsert, updatedAtMs: 10)
        try Self.record(
            harness.macManager, entity: .playHistory, rowKey: "s-a|1700000000000", op: .upsert,
            payloadJSON: try Self.historyPayload(stableId: "s-a", playedAt: 1_700_000_000_000, durationMs: 1_234),
            updatedAtMs: 11
        )
        try Self.record(
            harness.macManager, entity: .playlistItem, rowKey: "p1|s-a", op: .upsert,
            payloadJSON: try Self.playlistItemPayload(slug: "p1", stableId: "s-a", position: 3),
            updatedAtMs: 12
        )
        try Self.record(harness.macManager, entity: .favorite, rowKey: "s-b", op: .upsert, updatedAtMs: 13)
        try Self.record(harness.macManager, entity: .playlist, rowKey: "p1", op: .upsert, updatedAtMs: 14)

        let facts = SyncPlaybackCarryDatabaseFacts(database: harness.macManager, libraryRoot: harness.macRoot)
        let factA = facts.trackFact(atRelativePath: "Album/a.flac")
        #expect(factA?.stableId == "s-a")
        #expect(factA?.contentHash == "h-a")
        #expect(facts.trackFact(atRelativePath: "Album/missing.flac") == nil)
        #expect(facts.trackFact(atRelativePath: "../escape.flac") == nil)

        let rowsA = facts.playbackRows(forTrackStableId: "s-a")
        #expect(rowsA.map(\.entity) == [
            SyncChangeEntity.favorite.rawValue,
            SyncChangeEntity.playHistory.rawValue,
            SyncChangeEntity.playlistItem.rawValue,
        ])
        #expect(rowsA.map(\.outboxID) == rowsA.map(\.outboxID).sorted(), "按 outbox 序返回")
        #expect(rowsA.allSatisfy { $0.rowKey != "p1" }, "歌单结构行（非歌维度）不算歌的播放数据")
        #expect(facts.playbackRows(forTrackStableId: "s-b").map(\.rowKey) == ["s-b"], "只取该歌的行")
        #expect(facts.playbackRows(forTrackStableId: "").isEmpty, "空 stableId 直接空结果")
    }

    // MARK: - 推送方向端到端

    @Test("推送方向端到端：Mac 携带 → 设备落库（content_hash 本地化 + 既有 LWW/Applier）")
    func carryPushAppliesOnDevice() throws {
        let harness = try makeHarness(deviceTracks: [("d-a", "h-a", "Album/a.flac")])
        try Self.insertTrack(
            harness.macManager, stableId: "s-a", contentHash: "h-a",
            root: harness.macRoot, relative: "Album/a.flac"
        )
        try Self.record(harness.macManager, entity: .favorite, rowKey: "s-a", op: .upsert, updatedAtMs: 100)
        try Self.record(
            harness.macManager, entity: .playHistory, rowKey: "s-a|1700000000000", op: .upsert,
            payloadJSON: try Self.historyPayload(stableId: "s-a", playedAt: 1_700_000_000_000, durationMs: 4_242),
            updatedAtMs: 101
        )

        let plan = try harness.macCarry.carryPush(transferredPaths: ["Album/a.flac"], peerEntries: [])

        #expect(plan.carriedPaths == ["Album/a.flac"])
        #expect(plan.entries.count == 2)
        #expect(plan.entries.allSatisfy { $0.contentHash == "h-a" }, "身份键 = 歌曲 content_hash")

        // 设备侧：本地 stableId 与 Mac 不同（d-a vs s-a），靠 content_hash 本地化
        let favorites = try harness.deviceManager.read { db in try Favorite.fetchAll(db) }
        #expect(favorites.map(\.trackStableId) == ["d-a"], "收藏落到设备本地 stableId")
        let history = try harness.deviceManager.read { db in try PlayHistoryEntry.fetchAll(db) }
        #expect(history.map(\.trackStableId) == ["d-a"])
        #expect(history.first?.playDurationMs == 4_242)

        // 帧 9 的游标口径（与既有应答一致；v1 设备游标惰性，见 SyncPlaybackCarryPeer 文件头）
        let cursor = try harness.deviceStore.cursor(forPeer: harness.fixture.hostIdentity.deviceID)
        let maxOutboxID = try harness.deviceStore.maxOutboxID()
        let macMaxOutboxID = try SyncChangeLogStore(database: harness.macManager).maxOutboxID()
        #expect(maxOutboxID == 0)
        #expect(cursor == macMaxOutboxID)
    }

    @Test("本地缺歌挂起不丢：设备未入库该歌 → 挂起；入库后重放应用")
    func carryPushSuspendsUntilSongArrives() throws {
        let harness = try makeHarness() // 设备还没有这首歌（歌正随传输过来）
        try Self.insertTrack(
            harness.macManager, stableId: "s-a", contentHash: "h-a",
            root: harness.macRoot, relative: "Album/a.flac"
        )
        try Self.record(harness.macManager, entity: .favorite, rowKey: "s-a", op: .upsert, updatedAtMs: 200)

        let plan = try harness.macCarry.carryPush(transferredPaths: ["Album/a.flac"], peerEntries: [])
        #expect(plan.entries.count == 1)

        let pendingStore = SyncChangeLogPendingStore(database: harness.deviceManager)
        let pendingAfterPush = try pendingStore.pendingCount()
        let deviceFavoriteCount = try harness.deviceManager.read { db in try Favorite.fetchCount(db) }
        #expect(pendingAfterPush == 1, "本地缺歌 → 挂起（不丢）")
        #expect(deviceFavoriteCount == 0, "未落库到设备")

        // 歌入库（content_hash 已写）→ 重放
        try Self.insertTrack(
            harness.deviceManager, stableId: "d-a", contentHash: "h-a",
            root: harness.deviceRoot, relative: "Album/a.flac"
        )
        let applied = try SyncChangeLogReplay.replay(contentHash: "h-a", database: harness.deviceManager)
        let pendingAfterReplay = try pendingStore.pendingCount()
        #expect(applied == 1)
        #expect(pendingAfterReplay == 0, "重放后挂起清空")
        let favorites = try harness.deviceManager.read { db in try Favorite.fetchAll(db) }
        #expect(favorites.map(\.trackStableId) == ["d-a"], "重放落到设备本地 stableId")
    }

    @Test("删除不传播：同键 upsert→delete → 携带批次为空、帧都不发")
    func carryNeverSendsDeletes() throws {
        let harness = try makeHarness(deviceTracks: [("d-a", "h-a", "Album/a.flac")])
        try Self.insertTrack(
            harness.macManager, stableId: "s-a", contentHash: "h-a",
            root: harness.macRoot, relative: "Album/a.flac"
        )
        try Self.record(harness.macManager, entity: .favorite, rowKey: "s-a", op: .upsert, updatedAtMs: 300)
        try Self.record(harness.macManager, entity: .favorite, rowKey: "s-a", op: .delete, updatedAtMs: 301)

        let plan = try harness.macCarry.carryPush(transferredPaths: ["Album/a.flac"], peerEntries: [])
        let deviceFavoriteCount = try harness.deviceManager.read { db in try Favorite.fetchCount(db) }
        let deviceCursor = try harness.deviceStore.cursor(forPeer: harness.fixture.hostIdentity.deviceID)
        #expect(plan.entries.isEmpty, "delete 不上线（含批次抑制：更早的 upsert 也不带）")
        #expect(plan.skippedNoPlaybackData == ["Album/a.flac"])
        #expect(deviceFavoriteCount == 0, "设备侧无收藏")
        #expect(deviceCursor == 0, "未发帧，游标不动")
    }

    @Test("两端共有才带：对端没有该 content_hash → 不携带")
    func carrySkipsUnpairedSongs() throws {
        let harness = try makeHarness()
        try Self.insertTrack(
            harness.macManager, stableId: "s-a", contentHash: "h-a",
            root: harness.macRoot, relative: "Album/a.flac"
        )
        try Self.record(harness.macManager, entity: .favorite, rowKey: "s-a", op: .upsert, updatedAtMs: 400)

        // 对端 manifest 里没有该指纹，且传输路径里的歌在本端也未指纹/不存在
        let plan = try harness.macCarry.carryPush(
            transferredPaths: ["Album/a.flac", "Album/unknown.flac", "@lyrics/h-a.json"],
            peerEntries: [ManifestEntry(relativePath: "Other/x.flac", size: 1, mtimeMs: 0, contentHash: "h-other")]
        )
        #expect(plan.entries.isEmpty)
        #expect(plan.skippedNotPaired == ["Album/a.flac"], "对端 manifest 未含该指纹（且非本轮传输 → 不并入）")
        #expect(plan.skippedUnknownPath == ["Album/unknown.flac"])
        #expect(plan.lyricsPathsIgnored == ["@lyrics/h-a.json"])
    }

    // MARK: - 拉取方向

    @Test("拉取方向：帧 8 请求 → 对端应答帧 9 → 本端落库（也是 content_hash 本地化）")
    func carryPullAppliesLocally() throws {
        let harness = try makeHarness()
        // 设备侧这首歌 + 它的播放数据（设备 stableId = d-b）
        try Self.insertTrack(
            harness.deviceManager, stableId: "d-b", contentHash: "h-b",
            root: harness.deviceRoot, relative: "Album/b.flac"
        )
        try Self.record(harness.deviceManager, entity: .favorite, rowKey: "d-b", op: .upsert, updatedAtMs: 500)
        try Self.record(
            harness.deviceManager, entity: .playHistory, rowKey: "d-b|1700000000001", op: .upsert,
            payloadJSON: try Self.historyPayload(stableId: "d-b", playedAt: 1_700_000_000_001, durationMs: 77),
            updatedAtMs: 501
        )
        // 本端（Mac）刚刚拉到这首歌 → 本地 stableId = s-b
        try Self.insertTrack(
            harness.macManager, stableId: "s-b", contentHash: "h-b",
            root: harness.macRoot, relative: "Album/b.flac"
        )

        let plan = try harness.macCarry.carryPull(transferredPaths: ["Album/b.flac"], peerEntries: [])
        #expect(plan.carriedPaths == ["Album/b.flac"], "请求范围 = 两端共有的歌")
        #expect(plan.entries.isEmpty, "拉取方向本端不发条目")

        let favorites = try harness.macManager.read { db in try Favorite.fetchAll(db) }
        #expect(favorites.map(\.trackStableId) == ["s-b"], "对端数据落到本端本地 stableId")
        let history = try harness.macManager.read { db in try PlayHistoryEntry.fetchAll(db) }
        #expect(history.first?.playDurationMs == 77)
    }

    // MARK: - 映射

    @Test("条目 → 线上 entry：字段一一对应（id/entity/rowKey/op/updatedAtMs/contentHash/payload）")
    func wireEntryMappingIsFieldwiseIdentity() {
        let entry = SyncPlaybackCarryEntry(
            outboxID: 9,
            entity: SyncChangeEntity.playHistory.rawValue,
            rowKey: "s-a|123",
            op: SyncChangeOp.upsert.rawValue,
            updatedAtMs: 456,
            contentHash: "h-a",
            payloadJSON: "{\"x\":1}"
        )
        let wire = SyncPlaybackCarryPeer.wireEntry(entry)
        #expect(wire.id == 9)
        #expect(wire.entity == entry.entity)
        #expect(wire.rowKey == "s-a|123")
        #expect(wire.op == SyncChangeOp.upsert.rawValue)
        #expect(wire.updatedAtMs == 456)
        #expect(wire.contentHash == "h-a")
        #expect(wire.payloadJSON == "{\"x\":1}")
        #expect(entry.reconciliationKey.hasPrefix("play_history"), "对账键 = entity + row_key")
    }
}
