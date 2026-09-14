//
//  SyncDataSyncCoreTests.swift
//  QQPlayerTests
//
//  S2-T12 独立「同步数据」核心层测试（收藏 / 播放历史 / 歌单结构；与文件传输解耦）：
//  - pushCursor（sync_push_cursor）：默认 0 / upsert 推进 / 不串 peer / 与拉取游标互不干扰
//  - sendIncrement（帧 9 主动推增量）：推增量→对端落库（contentHash 本地化）；过滤 delete
//    （同键本批末行是 delete 时更早 upsert 也不上线）；超过 maxPerBatch 分批（每批末行 id
//    作游标）；成功后推进 pushCursor；重推幂等（第二次 0 条且不发帧）
//  - SyncDataSyncCoordinator：正常路径账目（pushed/applied/suspended/ignored 各自正确）；
//    空增量不发帧；peerID 为空 → 立即失败且不写脏游标；对端无应答 → 超时 finished + 失败原因；
//    帧 9 里的 delete 计入 ignoredDeletes
//
//  fixture：SyncPeerSessionTestSupport 双 ready 回环 + 两端各自内存 GRDB 库
//  （同 SyncChangeLogContentMapTests / SyncPlaybackCarryTests 既有做法，不新造基础设施）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

@MainActor
struct SyncDataSyncCoreTests {
    // MARK: - Fixture

    private struct Pair {
        let fixture: SessionFixture
        let hostQueue: DatabaseQueue
        let clientQueue: DatabaseQueue
        let hostManager: DatabaseManager
        let clientManager: DatabaseManager
        let hostStore: SyncChangeLogStore
        let clientStore: SyncChangeLogStore

        var clientID: String { fixture.clientIdentity.deviceID }
        var hostID: String { fixture.hostIdentity.deviceID }
    }

    private func makePair() throws -> Pair {
        let fixture = SessionFixture.pairedHandshake()
        let hostQueue = try DatabaseQueue()
        let hostManager = DatabaseManager(dbWriter: hostQueue)
        try hostManager.createTables()
        let clientQueue = try DatabaseQueue()
        let clientManager = DatabaseManager(dbWriter: clientQueue)
        try clientManager.createTables()
        return Pair(
            fixture: fixture,
            hostQueue: hostQueue,
            clientQueue: clientQueue,
            hostManager: hostManager,
            clientManager: clientManager,
            hostStore: SyncChangeLogStore(database: hostManager),
            clientStore: SyncChangeLogStore(database: clientManager)
        )
    }

    /// 会话侧 changeLog 处理器（⚠️ 测试必须强持有：它以 [weak self] 挂接会话回调）。
    private func makePeer(_ session: SyncPeerSession, manager: DatabaseManager, peerID: String) -> SyncChangeLogPeer {
        SyncChangeLogPeer(
            session: session,
            store: SyncChangeLogStore(database: manager),
            applier: SyncChangeLogApplier(database: manager),
            peerID: peerID
        )
    }

    private static func insertTrack(
        _ queue: DatabaseQueue,
        stableId: String,
        contentHash: String?
    ) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO track (stable_id, title, path, content_hash) VALUES (?, ?, ?, ?)",
                arguments: [stableId, "T-\(stableId)", "/m/\(stableId).flac", contentHash]
            )
        }
    }

    /// 记一条收藏 outbox 变更（模拟业务写点：业务行 + outbox 同事务）。
    private static func recordFavorite(
        _ queue: DatabaseQueue,
        rowKey: String,
        op: SyncChangeOp = .upsert,
        updatedAtMs: Int64
    ) throws {
        try queue.write { db in
            try SyncChangeLogStore.record(
                db,
                entity: .favorite,
                rowKey: rowKey,
                op: op,
                payloadJSON: op == .upsert
                    ? try SyncSnapshotCodec.encode(SyncFavoriteSnapshot(trackStableId: rowKey))
                    : nil,
                updatedAtMs: updatedAtMs
            )
        }
    }

    private static func favoriteIDs(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in
            try String.fetchAll(db, sql: "SELECT track_stable_id FROM favorite ORDER BY track_stable_id")
        }
    }

    private static func countRows(_ queue: DatabaseQueue, table: String) throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    // MARK: - 推送游标（sync_push_cursor）

    @Test("sync_push_cursor 新表迁移幂等：重复 createTables 不炸，列契约齐")
    func pushCursorTableMigrationIdempotent() throws {
        let pair = try makePair()
        try pair.hostManager.createTables() // 第二遍：IF NOT EXISTS 幂等
        try pair.hostQueue.read { db in
            #expect(try db.tableExists("sync_push_cursor"))
            let columns = try db.columns(in: "sync_push_cursor").map(\.name)
            #expect(columns.contains("peer_id"))
            #expect(columns.contains("last_outbox_id"))
        }
    }

    @Test("推送游标：默认 0 / upsert 推进 / 不串其它 peer / 与拉取游标互不干扰")
    func pushCursorDefaultsAdvanceAndUpsert() throws {
        let pair = try makePair()
        let peer = "peer-a"

        #expect(try pair.hostStore.pushCursor(forPeer: peer) == 0, "无记录 = 0")

        try pair.hostStore.setPushCursor(forPeer: peer, lastOutboxID: 3)
        #expect(try pair.hostStore.pushCursor(forPeer: peer) == 3)

        try pair.hostStore.setPushCursor(forPeer: peer, lastOutboxID: 7) // upsert 覆盖
        #expect(try pair.hostStore.pushCursor(forPeer: peer) == 7)
        #expect(try pair.hostStore.pushCursor(forPeer: "peer-b") == 0, "别的 peer 不受影响")

        // 两个方向相反：同 peer 的拉取游标与推送游标各自独立
        try pair.hostStore.setCursor(forPeer: peer, lastOutboxID: 2)
        #expect(try pair.hostStore.cursor(forPeer: peer) == 2)
        #expect(try pair.hostStore.pushCursor(forPeer: peer) == 7, "拉取游标写入不得污染推送游标")
    }

    // MARK: - sendIncrement

    @Test("sendIncrement：推增量 → 对端按 contentHash 落库 + 双端游标各自推进；重推 0 条不发帧")
    func sendIncrementPushesAndRepushesIdempotently() throws {
        let pair = try makePair()
        let responder = makePeer(pair.fixture.clientSession, manager: pair.clientManager, peerID: pair.hostID)
        let pusher = makePeer(pair.fixture.hostSession, manager: pair.hostManager, peerID: pair.clientID)
        let pushFrames = CounterBox()
        responder.onPushApplied = { _ in pushFrames.increment() }

        // 两端同一首歌（指纹相同、本地 stableId 不同）
        try Self.insertTrack(pair.hostQueue, stableId: "host-a", contentHash: "H-a")
        try Self.insertTrack(pair.clientQueue, stableId: "client-a", contentHash: "H-a")
        try Self.recordFavorite(pair.hostQueue, rowKey: "host-a", updatedAtMs: 1000)

        let first = try pusher.sendIncrement()
        #expect(first == 1, "计数 = 本端 outbox 增量行数")
        #expect(try pair.hostStore.pushCursor(forPeer: pair.clientID) == 1)
        #expect(try Self.favoriteIDs(pair.clientQueue) == ["client-a"], "contentHash 本地化：落到对端自己的 stableId")
        #expect(try pair.clientStore.cursor(forPeer: pair.hostID) == 1, "对端拉取游标随帧 9 推进")
        #expect(pushFrames.value == 1)

        let second = try pusher.sendIncrement()
        #expect(second == 0, "重推幂等：无新增量 = 0 条")
        #expect(pushFrames.value == 1, "空增量不发帧")
        #expect(try pair.hostStore.pushCursor(forPeer: pair.clientID) == 1, "游标不回退也不前跳")
        #expect(try pair.clientStore.cursor(forPeer: pair.hostID) == 1)
    }

    @Test("sendIncrement：过滤 delete——同键本批末行是 delete 时其更早 upsert 也不上线")
    func sendIncrementFiltersDeletes() throws {
        let pair = try makePair()
        let responder = makePeer(pair.fixture.clientSession, manager: pair.clientManager, peerID: pair.hostID)
        let pusher = makePeer(pair.fixture.hostSession, manager: pair.hostManager, peerID: pair.clientID)
        _ = responder // 强持有

        for suffix in ["a", "b"] {
            try Self.insertTrack(pair.hostQueue, stableId: "host-\(suffix)", contentHash: "H-\(suffix)")
            try Self.insertTrack(pair.clientQueue, stableId: "client-\(suffix)", contentHash: "H-\(suffix)")
        }
        // id1 upsert A / id2 delete A（同键）/ id3 upsert B
        try Self.recordFavorite(pair.hostQueue, rowKey: "host-a", updatedAtMs: 1000)
        try Self.recordFavorite(pair.hostQueue, rowKey: "host-a", op: .delete, updatedAtMs: 2000)
        try Self.recordFavorite(pair.hostQueue, rowKey: "host-b", updatedAtMs: 3000)

        let sent = try pusher.sendIncrement()
        #expect(sent == 3, "计数含被过滤的 delete 行（同 handlePull 计数口径）")
        #expect(try Self.favoriteIDs(pair.clientQueue) == ["client-b"], "同键 delete 之前的 upsert 不上线（否则对端复活已删状态）")
        #expect(try pair.hostStore.pushCursor(forPeer: pair.clientID) == 3, "游标越过整批（含永不上线的 delete）")

        // 再来一批纯 delete：不得卡死重推（游标必须能继续越过）
        try Self.recordFavorite(pair.hostQueue, rowKey: "host-b", op: .delete, updatedAtMs: 4000)
        let second = try pusher.sendIncrement()
        #expect(second == 1)
        #expect(try pair.hostStore.pushCursor(forPeer: pair.clientID) == 4)
        #expect(try Self.favoriteIDs(pair.clientQueue) == ["client-b"], "删除不跨端传播：对端收藏不被删")
        #expect(try pusher.sendIncrement() == 0, "越过 delete 后不再重推")
    }

    @Test("sendIncrement：超过 maxPerBatch 分批，每批 lastOutboxID = 该批实际末行 id")
    func sendIncrementBatchesWithPerBatchCursor() throws {
        let pair = try makePair()
        let responder = makePeer(pair.fixture.clientSession, manager: pair.clientManager, peerID: pair.hostID)
        let pusher = makePeer(pair.fixture.hostSession, manager: pair.hostManager, peerID: pair.clientID)
        let perFrameCursors = IntListBox()
        let clientStore = pair.clientStore
        let hostID = pair.hostID
        // 对端每收一帧 9，记下它此刻记下的拉取游标（= 该帧携带的 lastOutboxID）
        responder.onPushApplied = { _ in
            perFrameCursors.append(Int((try? clientStore.cursor(forPeer: hostID)) ?? -1))
        }

        for index in 1 ... 5 {
            try Self.insertTrack(pair.hostQueue, stableId: "host-\(index)", contentHash: "H-\(index)")
            try Self.insertTrack(pair.clientQueue, stableId: "client-\(index)", contentHash: "H-\(index)")
            try Self.recordFavorite(pair.hostQueue, rowKey: "host-\(index)", updatedAtMs: Int64(1000 + index))
        }

        let sent = try pusher.sendIncrement(maxPerBatch: 2)
        #expect(sent == 5)
        #expect(perFrameCursors.values == [2, 4, 5], "分批：每批游标 = 本批末行 id（不是 outbox 全局末尾）")
        #expect(try pair.hostStore.pushCursor(forPeer: pair.clientID) == 5, "全部批次成功后才推进到末批末行")
        #expect(try Self.favoriteIDs(pair.clientQueue).count == 5)
    }

    // MARK: - 编排器

    @Test("coordinator：一次推 + 一次拉，账目逐项正确")
    func coordinatorNormalPathLedger() throws {
        let pair = try makePair()
        let responder = makePeer(pair.fixture.clientSession, manager: pair.clientManager, peerID: pair.hostID)

        // 本端（host）两条收藏 → 推出去
        for suffix in ["a", "b"] {
            try Self.insertTrack(pair.hostQueue, stableId: "host-\(suffix)", contentHash: "H-\(suffix)")
            try Self.insertTrack(pair.clientQueue, stableId: "client-\(suffix)", contentHash: "H-\(suffix)")
            try Self.recordFavorite(pair.hostQueue, rowKey: "host-\(suffix)", updatedAtMs: 1000)
        }
        // 对端（client）两条：一条本端有对应歌（applied），一条本端没有（suspended——
        // 对端带得出 contentHash，本端映射不到本地 stableId）
        try Self.insertTrack(pair.hostQueue, stableId: "host-c", contentHash: "H-c")
        try Self.insertTrack(pair.clientQueue, stableId: "client-c", contentHash: "H-c")
        try Self.insertTrack(pair.clientQueue, stableId: "client-x", contentHash: "H-x")
        try Self.recordFavorite(pair.clientQueue, rowKey: "client-c", updatedAtMs: 2000)
        try Self.recordFavorite(pair.clientQueue, rowKey: "client-x", updatedAtMs: 3000)

        let phases = PhaseListBox()
        let coordinator = SyncDataSyncCoordinator(
            session: pair.fixture.hostSession,
            database: pair.hostManager,
            peerID: pair.clientID
        )
        coordinator.onStateChange = { phases.append($0) }
        coordinator.start()

        #expect(coordinator.phase == .finished)
        let report = coordinator.report
        #expect(report.pushedEntries == 2, "本端 outbox 两行全推出去")
        #expect(report.appliedEntries == 1, "对端推来的行里 1 行本地化后落库")
        #expect(report.suspendedEntries == 1, "本地缺歌的那行挂起（不丢）")
        #expect(report.ignoredDeletes == 0)
        #expect(report.failureMessage == nil)
        #expect(report.isFinished)
        #expect(phases.values == [.pushing, .pulling, .finished], "阶段上报：推 → 拉 → 收尾")

        // 两端业务表各自的落地结果
        #expect(try Self.favoriteIDs(pair.clientQueue) == ["client-a", "client-b"])
        #expect(try Self.favoriteIDs(pair.hostQueue) == ["host-c"])
        #expect(try pair.hostStore.pushCursor(forPeer: pair.clientID) == 2)
        #expect(try pair.hostStore.cursor(forPeer: pair.clientID) == 2, "拉取游标 = 对端本批末行")
        #expect(try pair.clientStore.cursor(forPeer: pair.hostID) == 2)
        _ = responder
    }

    @Test("coordinator：缺身份键账目——拉取侧未定位 + 推送侧缺指纹各自计数，且不提前收尾")
    func coordinatorCountsMissingIdentity() throws {
        let pair = try makePair()
        let responder = makePeer(pair.fixture.clientSession, manager: pair.clientManager, peerID: pair.hostID)
        _ = responder

        // 本端（host）：歌在本地但**指纹为空** → 推出去的行缺身份键（对端定位不了）
        try Self.insertTrack(pair.hostQueue, stableId: "host-nohash", contentHash: nil)
        try Self.recordFavorite(pair.hostQueue, rowKey: "host-nohash", updatedAtMs: 1000)
        // 对端（client）：同样指纹为空 → 它推来的行本端也定位不到（未落库）
        try Self.insertTrack(pair.clientQueue, stableId: "client-nohash", contentHash: nil)
        try Self.recordFavorite(pair.clientQueue, rowKey: "client-nohash", updatedAtMs: 2000)

        let phases = PhaseListBox()
        let coordinator = SyncDataSyncCoordinator(
            session: pair.fixture.hostSession,
            database: pair.hostManager,
            peerID: pair.clientID
        )
        coordinator.onStateChange = { phases.append($0) }
        coordinator.start()

        #expect(coordinator.phase == .finished)
        let report = coordinator.report
        #expect(report.pushedEntries == 1)
        #expect(report.pushedMissingIdentityEntries == 1, "本端发出去的那行缺身份键")
        #expect(report.unresolvedEntries == 1, "对端推来的那行缺身份键 → 未落库（未定位）")
        #expect(report.appliedEntries == 0)
        #expect(report.suspendedEntries == 0, "缺身份键不挂起（挂起键 = content_hash）")
        #expect(report.ignoredDeletes == 0)
        #expect(report.failureMessage == nil)
        // 推送侧计数回调不得把编排提前收尾：仍要走完 推 → 拉 → 收尾
        #expect(phases.values == [.pushing, .pulling, .finished], "实际：\(phases.values)")
        // 两端业务表都不得出现引用不存在歌曲的孤儿行
        #expect(try Self.favoriteIDs(pair.hostQueue).isEmpty)
        #expect(try Self.favoriteIDs(pair.clientQueue).isEmpty)
        // 游标照常推进（不因缺身份键而重发死循环）
        #expect(try pair.hostStore.pushCursor(forPeer: pair.clientID) == 1)
        #expect(try pair.hostStore.cursor(forPeer: pair.clientID) == 1)
    }

    @Test("coordinator：空增量不发帧；peerID 缺省取握手得到的对端 Device ID")
    func coordinatorEmptyIncrementSendsNoFrame() throws {
        let pair = try makePair()
        let responder = makePeer(pair.fixture.clientSession, manager: pair.clientManager, peerID: pair.hostID)
        let pushFrames = CounterBox()
        responder.onPushApplied = { _ in pushFrames.increment() }

        // peerID 缺省：取 session.peerHelloValue.deviceID（= 对端 client ID）
        let coordinator = SyncDataSyncCoordinator(session: pair.fixture.hostSession, database: pair.hostManager)
        coordinator.start()

        #expect(coordinator.phase == .finished)
        #expect(coordinator.report.pushedEntries == 0)
        #expect(coordinator.report.failureMessage == nil, "对端应答了空批（帧 8 必有应答）")
        #expect(pushFrames.value == 0, "空增量不发帧")
        #expect(try Self.countRows(pair.hostQueue, table: "sync_push_cursor") == 0, "空增量不动游标（不留空键）")
    }

    @Test("coordinator：帧 9 里的 delete 被忽略并计入 ignoredDeletes（删除不跨端传播）")
    func coordinatorCountsIgnoredDeletes() throws {
        let pair = try makePair()
        let responder = makePeer(pair.fixture.clientSession, manager: pair.clientManager, peerID: pair.hostID)
        _ = responder

        let coordinator = SyncDataSyncCoordinator(
            session: pair.fixture.hostSession,
            database: pair.hostManager,
            peerID: pair.clientID
        )
        coordinator.start()
        #expect(coordinator.report.isFinished)

        // 模拟旧版本对端直接推来 delete（绕过本端发送侧过滤）
        let payload = SyncChangeLogPushPayload(
            entries: [
                SyncChangeLogWireEntry(
                    id: 1, entity: SyncChangeEntity.favorite.rawValue, rowKey: "ghost",
                    op: SyncChangeOp.delete.rawValue, updatedAtMs: 1,
                    contentHash: nil, payloadJSON: nil
                ),
            ],
            lastOutboxID: 1
        )
        try pair.fixture.clientSession.sendApplicationFrame(
            type: .changeLogPush,
            payload: try JSONEncoder().encode(payload)
        )

        #expect(coordinator.report.ignoredDeletes == 1)
        #expect(coordinator.report.appliedEntries == 0)
        #expect(try Self.favoriteIDs(pair.hostQueue).isEmpty, "忽略 delete：不删本地行")

        // 再来一帧（两条 delete）：账目**累加**（不是覆盖）
        let second = SyncChangeLogPushPayload(
            entries: ["ghost-a", "ghost-b"].map {
                SyncChangeLogWireEntry(
                    id: 2, entity: SyncChangeEntity.favorite.rawValue, rowKey: $0,
                    op: SyncChangeOp.delete.rawValue, updatedAtMs: 2,
                    contentHash: nil, payloadJSON: nil
                )
            },
            lastOutboxID: 2
        )
        try pair.fixture.clientSession.sendApplicationFrame(
            type: .changeLogPush,
            payload: try JSONEncoder().encode(second)
        )
        #expect(coordinator.report.ignoredDeletes == 3)
        #expect(coordinator.report.appliedEntries == 0)
    }

    @Test("coordinator：peerID 为空 → 立即 finished + failureMessage，不写脏游标")
    func coordinatorMissingPeerIDFailsFast() throws {
        let pair = try makePair()

        let blank = SyncDataSyncCoordinator(
            session: pair.fixture.hostSession,
            database: pair.hostManager,
            peerID: "   "
        )
        blank.start()
        #expect(blank.phase == .finished)
        #expect(blank.report.isFinished)
        #expect(blank.report.failureMessage != nil)
        #expect(try Self.countRows(pair.hostQueue, table: "sync_push_cursor") == 0, "不得拿空串当游标键写脏数据")

        // 未握手会话（peerHelloValue = nil）→ 同样立即失败
        let naked = SessionFixture.make()
        let unresolved = SyncDataSyncCoordinator(session: naked.hostSession, database: pair.hostManager)
        unresolved.start()
        #expect(unresolved.phase == .finished)
        #expect(unresolved.report.failureMessage != nil)
        #expect(try Self.countRows(pair.hostQueue, table: "sync_push_cursor") == 0)
    }

    @Test("coordinator：对端无应答 → 超时 finished + failureMessage")
    func coordinatorTimeoutFinishesWithFailure() async throws {
        let pair = try makePair()
        // 故意不建对端处理器：帧 8 发出去没人应答
        try Self.insertTrack(pair.hostQueue, stableId: "host-a", contentHash: "H-a")
        try Self.recordFavorite(pair.hostQueue, rowKey: "host-a", updatedAtMs: 1000)

        let coordinator = SyncDataSyncCoordinator(
            session: pair.fixture.hostSession,
            database: pair.hostManager,
            peerID: pair.clientID
        )
        coordinator.start(timeout: 0.2)

        #expect(coordinator.report.pushedEntries == 1, "推送先跑完（推不需要对端应答）")
        #expect(coordinator.phase == .pulling, "发完帧 8 等应答")

        let deadline = Date().addingTimeInterval(3)
        while !coordinator.report.isFinished, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(coordinator.phase == .finished)
        #expect(coordinator.report.failureMessage != nil, "超时必须有可读原因，不静默挂死")
        #expect(coordinator.report.isFinished)
    }

    // MARK: - 跨端续播开关（2026-09-14：默认关；关 = 不上报也不接受播放位置）

    /// 单端内存库（applier 用例不需要双端会话）。
    private func makeManager() throws -> DatabaseManager {
        let queue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: queue)
        try manager.createTables()
        return manager
    }

    /// 一条 playback_position 远端胜出行（row_key = 歌键；payload = 快照）。
    private static func playbackPositionRow(rowKey: String) throws -> SyncChangeLogRow {
        SyncChangeLogRow(
            entity: .playbackPosition,
            rowKey: rowKey,
            op: .upsert,
            updatedAtMs: 1000,
            payloadJSON: try SyncSnapshotCodec.encode(
                SyncPlaybackPositionSnapshot(trackStableId: rowKey, positionMs: 500, updatedAtMs: 1000)
            )
        )
    }

    /// 本端 outbox 记一条播放位置（发送方向，用于端到端账目用例）。
    private static func recordPlaybackPosition(
        _ queue: DatabaseQueue,
        rowKey: String,
        updatedAtMs: Int64
    ) throws {
        try queue.write { db in
            try SyncChangeLogStore.record(
                db,
                entity: .playbackPosition,
                rowKey: rowKey,
                op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(
                    SyncPlaybackPositionSnapshot(trackStableId: rowKey, positionMs: 500, updatedAtMs: updatedAtMs)
                ),
                updatedAtMs: updatedAtMs
            )
        }
    }

    /// 真 UserDefaults 用例的保存/恢复（键名与 `DeleteSettings.load()` 内部一致）。
    private func withSettingsBackup(_ body: () throws -> Void) rethrows {
        let backup = UserDefaults.standard.data(forKey: "DeleteSettings")
        defer {
            if let backup {
                UserDefaults.standard.set(backup, forKey: "DeleteSettings")
            } else {
                UserDefaults.standard.removeObject(forKey: "DeleteSettings")
            }
        }
        try body()
    }

    @Test("开关：旧数据（无 syncPlaybackPositionEnabled）→ false；save/load 往返 true")
    func playbackPositionSwitchDefaultsOffAndRoundTrips() throws {
        // 1) 旧设置文件（JSON 里没有这个 key）必须解出「关」，且不得解码失败
        let legacy = try JSONDecoder().decode(DeleteSettings.self, from: Data("{}".utf8))
        #expect(legacy.syncPlaybackPositionEnabled == false)

        // 2) 写 true → load 回来 true（真 UserDefaults；测后恢复原值，不污染其它用例）
        try withSettingsBackup {
            var settings = DeleteSettings.load()
            settings.syncPlaybackPositionEnabled = true
            settings.save()
            #expect(DeleteSettings.load().syncPlaybackPositionEnabled, "写 true 后 load 回来必须是 true")
        }
    }

    @Test("applier：开关关 → 不落点、不计「已应用」，未支持回调收到 1")
    func applierSkipsPlaybackPositionWhenSwitchOff() throws {
        let manager = try makeManager()
        var applier = SyncChangeLogApplier(database: manager, playbackPositionSyncEnabled: false)
        let sinkCalls = CounterBox()
        let unsupported = CounterBox()
        applier.playbackPositionSink = { _ in sinkCalls.increment() }
        applier.onPlaybackPositionUnsupported = { unsupported.increment() }

        let applied = try applier.apply([try Self.playbackPositionRow(rowKey: "t-1")])

        #expect(applied == 0, "关：这条没落到任何本地位置，不得计入「已应用」（INV-20）")
        #expect(unsupported.value == 1, "必须计数上屏（面板披露）")
        #expect(sinkCalls.value == 0, "关 = 不落点，sink 不得被调")
    }

    @Test("applier：开关开 + 注入落点 → 调 sink、计「已应用」、不报未支持")
    func applierAppliesPlaybackPositionWithSink() throws {
        let manager = try makeManager()
        var applier = SyncChangeLogApplier(database: manager, playbackPositionSyncEnabled: true)
        let sinkCalls = CounterBox()
        let unsupported = CounterBox()
        applier.playbackPositionSink = { _ in sinkCalls.increment() }
        applier.onPlaybackPositionUnsupported = { unsupported.increment() }

        let applied = try applier.apply([try Self.playbackPositionRow(rowKey: "t-1")])

        #expect(applied == 1)
        #expect(sinkCalls.value == 1)
        #expect(unsupported.value == 0)
    }

    @Test("applier：开关开但落点未接 → 计未支持、不计「已应用」")
    func applierSkipsPlaybackPositionWithoutSink() throws {
        let manager = try makeManager()
        var applier = SyncChangeLogApplier(database: manager, playbackPositionSyncEnabled: true)
        let unsupported = CounterBox()
        applier.onPlaybackPositionUnsupported = { unsupported.increment() }

        let applied = try applier.apply([try Self.playbackPositionRow(rowKey: "t-1")])

        #expect(applied == 0, "无落点实现 = 这条没落地，不得计入「已应用」")
        #expect(unsupported.value == 1)
    }

    @Test("端到端：开关关（默认）→ 对端推来的播放位置不计「应用」，计入未支持")
    func coordinatorCountsUnsupportedPlaybackPosition() throws {
        let pair = try makePair()
        let responder = makePeer(pair.fixture.clientSession, manager: pair.clientManager, peerID: pair.hostID)
        _ = responder

        // 两端同一首歌（contentHash 一致 → 能本地化）；对端 outbox 有该歌的播放位置
        try Self.insertTrack(pair.hostQueue, stableId: "host-1", contentHash: "H-1")
        try Self.insertTrack(pair.clientQueue, stableId: "client-1", contentHash: "H-1")
        try Self.recordPlaybackPosition(pair.clientQueue, rowKey: "client-1", updatedAtMs: 1000)

        // 显式置「关」（= 默认值）并在结束后恢复原值：不依赖本机设置、也不污染它
        try withSettingsBackup {
            var settings = DeleteSettings.load()
            settings.syncPlaybackPositionEnabled = false
            settings.save()

            let coordinator = SyncDataSyncCoordinator(
                session: pair.fixture.hostSession,
                database: pair.hostManager,
                peerID: pair.clientID
            )
            coordinator.start()

            #expect(coordinator.phase == .finished)
            let report = coordinator.report
            #expect(report.appliedEntries == 0, "播放位置没落地 → 不得虚报「已应用」（INV-20）")
            #expect(report.unsupportedEntries == 1, "未落地的播放位置行必须计数上屏")
            #expect(report.failureMessage == nil)
        }
    }
}

// MARK: - 测试辅助（闭包捕获盒子；避免在 @MainActor 测试里捕获可变局部变量）

private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

private final class IntListBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int] = []

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: Int) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class PhaseListBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SyncDataSyncPhase] = []

    var values: [SyncDataSyncPhase] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ phase: SyncDataSyncPhase) {
        lock.lock()
        storage.append(phase)
        lock.unlock()
    }
}
