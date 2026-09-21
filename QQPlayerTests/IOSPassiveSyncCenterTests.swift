//
//  IOSPassiveSyncCenterTests.swift
//  QQPlayerTests
//
//  M6 · T4/T5（2026-09-11）iOS 被动同步中心纯逻辑防回归（无网络 / 无 IO）：
//  - IOSPassiveReconnectLogic.targets：浏览结果 × 已配对主机 → 候选序列
//    （名称匹配优先 / 落单 endpoint 兜底 / 空输入）
//  - IOSPassiveReconnectPolicy：指数退避 + 封顶 + 次数上限（上限用尽 = 手动兜底）
//  - IOSPassiveSyncPresenter：状态与失败 → 文案 key + 账目数字 + 重连按钮可用性
//  - S2-T12（2026-09-13）数据同步端装配：`IOSPassiveDataSyncLogic` 游标键决策 +
//    ready 装配 / 无对端 hello 不装 / 拆除摘下（真会话夹具 + 内存库，无网络）
//

import Combine
import Foundation
import GRDB
import Network
import Testing

@testable import QQPlayer

/// 假索引状态源（前置门事实源）：不碰 DatabaseManager / LibraryIndexer 单例。
@MainActor
private final class FakeIndexingState: IndexingStateProviding {
    @Published var isIndexing: Bool
    @Published var hasReachedIndexingTerminalState: Bool

    init(isIndexing: Bool = false, hasReachedIndexingTerminalState: Bool = true) {
        self.isIndexing = isIndexing
        self.hasReachedIndexingTerminalState = hasReachedIndexingTerminalState
    }

    var isIndexingPublisher: AnyPublisher<Bool, Never> {
        $isIndexing.eraseToAnyPublisher()
    }

    var indexingTerminalStatePublisher: AnyPublisher<Void, Never> {
        $hasReachedIndexingTerminalState.map { _ in () }.eraseToAnyPublisher()
    }
}

struct IOSPassiveSyncCenterTests {
    // MARK: - 夹具

    private func makeHost(_ name: String) -> SyncDiscoveredHost {
        SyncDiscoveredHost(
            name: name,
            endpoint: .service(name: name, type: SyncBrowser.serviceType, domain: "", interface: nil)
        )
    }

    private func makePeer(_ id: String, name: String) -> PeerDevice {
        PeerDevice(
            peerID: id,
            peerPublicKey: "",
            displayName: name,
            role: .host,
            pairedAt: 0,
            lastSeenAt: 0,
            notes: nil
        )
    }

    // MARK: - 夹具（数据同步端装配用：真会话 + 内存库 + 临时曲库根）

    private func makeManager() throws -> DatabaseManager {
        try makeManagerAndQueue().0
    }

    /// 内存库 + 其 queue（host 侧夹具要用裸 SQL 写 track 行）。
    private func makeManagerAndQueue() throws -> (DatabaseManager, DatabaseQueue) {
        let queue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: queue)
        try manager.createTables()
        return (manager, queue)
    }

    /// host 侧夹具：一首手机上没有的歌（指纹 H-offmain）+ 一条收藏 → 接收侧「本地缺歌挂起」。
    /// （写成同步 helper：async 上下文里直接调 `queue.write` 会被 GRDB 的 async 重载接管，
    /// 那条重载要求 @Sendable 闭包且必须 await。）
    private func seedHostMissingTrackFavorite(_ queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO track (stable_id, title, path, content_hash) VALUES (?, ?, ?, ?)",
                arguments: ["host-track", "T", "/m/host-track.flac", "H-offmain"]
            )
            try SyncChangeLogStore.record(
                db,
                entity: .favorite,
                rowKey: "host-track",
                op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(SyncFavoriteSnapshot(trackStableId: "host-track")),
                updatedAtMs: 1000
            )
        }
    }

    private func makeTempRoot(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-ios-passive-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func makeCenter(
        _ manager: DatabaseManager,
        root: URL,
        indexingState: IndexingStateProviding = FakeIndexingState()
    ) -> IOSPassiveSyncCenter {
        IOSPassiveSyncCenter(
            deviceStore: DeviceStore(database: manager),
            libraryRoot: { root },
            database: manager,
            indexingState: indexingState
        )
    }

    // MARK: - 候选目标

    @Test("targets：只对已配对主机建目标（未配对端点不尝试），名称匹配者优先")
    func targetsPrefersNameMatch() {
        let targets = IOSPassiveReconnectLogic.targets(
            discovered: [makeHost("Mac-Studio"), makeHost("MacBook-Air")],
            pairedHosts: [makePeer("PEER-A", name: "MacBook-Air")]
        )
        // Mac-Studio 未配对 → 不产生目标：广播名不作凭据，也不拿未配对端点
        // 去撞 pinning（只会以 peerUntrusted 白连一次）
        #expect(targets.count == 1)
        #expect(targets.first == IOSPassiveSyncTarget(
            peerID: "PEER-A",
            hostName: "MacBook-Air",
            endpoint: makeHost("MacBook-Air").endpoint
        ))
    }

    @Test("targets：主机改名（无名称匹配）→ 剩余端点按发现顺序兜底，身份仍挂同一 peerID")
    func targetsFallsBackToLeftoverEndpoints() {
        let targets = IOSPassiveReconnectLogic.targets(
            discovered: [makeHost("Mac-Studio"), makeHost("Renamed-Mac")],
            pairedHosts: [makePeer("PEER-A", name: "MacBook-Air")]
        )
        #expect(targets.count == 2)
        #expect(targets.allSatisfy { $0.peerID == "PEER-A" })
        #expect(targets.map(\.hostName) == ["Mac-Studio", "Renamed-Mac"])
    }

    @Test("targets：名称匹配 case-insensitive（复用 SyncConnectLogic.matches 口径）")
    func targetsMatchesCaseInsensitively() {
        let targets = IOSPassiveReconnectLogic.targets(
            discovered: [makeHost("other-device"), makeHost("MACBOOK-AIR")],
            pairedHosts: [makePeer("PEER-A", name: "macbook-air")]
        )
        #expect(targets.first?.hostName == "MACBOOK-AIR")
    }

    @Test("targets：多台已配对主机各取自己的名称匹配，互不串台")
    func targetsPairsEachPeerWithItsOwnEndpoint() {
        let targets = IOSPassiveReconnectLogic.targets(
            discovered: [makeHost("Mac-One"), makeHost("Mac-Two")],
            pairedHosts: [makePeer("PEER-1", name: "Mac-One"), makePeer("PEER-2", name: "Mac-Two")]
        )
        #expect(targets.count == 2)
        #expect(targets[0].peerID == "PEER-1")
        #expect(targets[0].hostName == "Mac-One")
        #expect(targets[1].peerID == "PEER-2")
        #expect(targets[1].hostName == "Mac-Two")
    }

    @Test("targets：无已配对主机 → 空（被动端不主动连陌生设备）")
    func targetsWithoutPairedHostsIsEmpty() {
        #expect(IOSPassiveReconnectLogic.targets(
            discovered: [makeHost("Mac-Studio")],
            pairedHosts: []
        ).isEmpty)
    }

    @Test("targets：无浏览结果 → 空")
    func targetsWithoutDiscoveredHostsIsEmpty() {
        #expect(IOSPassiveReconnectLogic.targets(
            discovered: [],
            pairedHosts: [makePeer("PEER-A", name: "Mac-Studio")]
        ).isEmpty)
    }

    // MARK: - 重连退避

    @Test("退避：2/4/8/16/30（封顶 30），超过上限返回 nil")
    func reconnectBackoffSequence() {
        #expect(IOSPassiveReconnectPolicy.delayBeforeAttempt(1) == 2)
        #expect(IOSPassiveReconnectPolicy.delayBeforeAttempt(2) == 4)
        #expect(IOSPassiveReconnectPolicy.delayBeforeAttempt(3) == 8)
        #expect(IOSPassiveReconnectPolicy.delayBeforeAttempt(4) == 16)
        #expect(IOSPassiveReconnectPolicy.delayBeforeAttempt(5) == IOSPassiveReconnectPolicy.maxDelay)
        #expect(IOSPassiveReconnectPolicy.delayBeforeAttempt(6) == nil)
        #expect(IOSPassiveReconnectPolicy.delayBeforeAttempt(0) == nil)
        #expect(IOSPassiveReconnectPolicy.delayBeforeAttempt(-1) == nil)
    }

    // MARK: - 展示映射

    @Test("展示：无已配对主机 → 未配对文案，不显示重连")
    func presentationUnpaired() {
        let value = IOSPassiveSyncPresenter.presentation(
            state: .idle,
            summary: SyncLibraryPassiveSummary(),
            hasPairedHost: false
        )
        #expect(value.titleKey == "sync_passive_state_unpaired")
        #expect(value.canReconnect == false)
    }

    @Test("展示：已配对但未连接 → 未连接文案 + 可重连")
    func presentationIdleWithHost() {
        let value = IOSPassiveSyncPresenter.presentation(
            state: .idle,
            summary: SyncLibraryPassiveSummary(),
            hasPairedHost: true
        )
        #expect(value.titleKey == "sync_passive_state_idle")
        #expect(value.symbol == "wifi.slash")
        #expect(value.canReconnect)
    }

    @Test("展示：连接中（浏览 / 已选主机）文案与不可重连")
    func presentationConnecting() {
        let browsing = IOSPassiveSyncPresenter.presentation(
            state: .connecting(hostName: nil),
            summary: SyncLibraryPassiveSummary(),
            hasPairedHost: true
        )
        #expect(browsing.titleKey == "sync_passive_state_searching")
        #expect(browsing.canReconnect == false)

        let connecting = IOSPassiveSyncPresenter.presentation(
            state: .connecting(hostName: "Mac-Studio"),
            summary: SyncLibraryPassiveSummary(),
            hasPairedHost: true
        )
        #expect(connecting.titleKey == "sync_passive_state_connecting")
        #expect(connecting.titleArg == "Mac-Studio")
    }

    @Test("展示：已连接 → 主机名文案 + 不可重连")
    func presentationConnected() {
        let value = IOSPassiveSyncPresenter.presentation(
            state: .connected(hostName: "Mac-Studio", peerID: "PEER-A"),
            summary: SyncLibraryPassiveSummary(),
            hasPairedHost: true
        )
        #expect(value.titleKey == "sync_passive_state_connected")
        #expect(value.titleArg == "Mac-Studio")
        #expect(value.symbol == "checkmark.circle.fill")
        #expect(value.canReconnect == false)
    }

    @Test("展示：失败模型 → 文案 key（含细节透传）")
    func presentationFailures() {
        let notFound = IOSPassiveSyncPresenter.presentation(
            state: .failed(.connect(.hostNotFound(hostName: "Mac-Studio"))),
            summary: SyncLibraryPassiveSummary(),
            hasPairedHost: true
        )
        #expect(notFound.titleKey == "sync_passive_fail_not_found")
        #expect(notFound.titleArg == "Mac-Studio")
        #expect(notFound.canReconnect)

        let notFoundAnonymous = IOSPassiveSyncPresenter.presentation(
            state: .failed(.connect(.hostNotFound(hostName: nil))),
            summary: SyncLibraryPassiveSummary(),
            hasPairedHost: true
        )
        #expect(notFoundAnonymous.titleKey == "sync_passive_fail_not_found_generic")
        #expect(notFoundAnonymous.titleArg == nil)

        let timedOut = IOSPassiveSyncPresenter.presentation(
            state: .failed(.connect(.timedOut)),
            summary: SyncLibraryPassiveSummary(),
            hasPairedHost: true
        )
        #expect(timedOut.titleKey == "sync_passive_fail_timeout")

        let rejected = IOSPassiveSyncPresenter.presentation(
            state: .failed(.connect(.rejected(reason: "用户点拒绝"))),
            summary: SyncLibraryPassiveSummary(),
            hasPairedHost: true
        )
        #expect(rejected.titleKey == "sync_passive_fail_rejected")
        #expect(rejected.detailKey == "sync_passive_detail")
        #expect(rejected.detailArg == "用户点拒绝")

        let failed = IOSPassiveSyncPresenter.presentation(
            state: .failed(.connect(.connectionFailed(detail: nil))),
            summary: SyncLibraryPassiveSummary(),
            hasPairedHost: true
        )
        #expect(failed.titleKey == "sync_passive_fail_connection")
        #expect(failed.detailKey == nil)

        let identity = IOSPassiveSyncPresenter.presentation(
            state: .failed(.identityUnavailable),
            summary: SyncLibraryPassiveSummary(),
            hasPairedHost: true
        )
        #expect(identity.titleKey == "sync_passive_fail_identity")
    }

    @Test("展示：账目数字与失败清单原样透传")
    func presentationCarriesSummary() {
        let failure = SyncPushFailure(
            relativePath: "Music/a.flac",
            reason: SyncPushFailureReason.landFailed,
            detail: nil
        )
        var summary = SyncLibraryPassiveSummary()
        summary.landed = ["Music/a.flac", "Music/b.flac"]
        summary.failed = [failure]
        summary.announcedEntries = 3

        let value = IOSPassiveSyncPresenter.presentation(
            state: .connected(hostName: "Mac-Studio", peerID: "PEER-A"),
            summary: summary,
            hasPairedHost: true
        )
        #expect(value.receivedFiles == 2)
        #expect(value.lastBatchEntries == 3)
        #expect(value.failures == [failure])
    }

    // MARK: - 数据同步端装配（S2-T12）

    @Test("数据同步端决策：对端 Device ID 非空才用（空串 = 不装配，不写脏游标键）")
    func dataSyncPeerIDDecision() {
        #expect(IOSPassiveDataSyncLogic.dataSyncPeerID(peerDeviceID: "PEER-A") == "PEER-A")
        #expect(IOSPassiveDataSyncLogic.dataSyncPeerID(peerDeviceID: nil) == nil)
        #expect(IOSPassiveDataSyncLogic.dataSyncPeerID(peerDeviceID: "") == nil)
    }

    @MainActor
    @Test("会话 ready 装配：被动端 + 数据同步端同时挂上，游标键 = 对端 Device ID")
    func dataSyncAttachedOnReady() throws {
        let fixture = SessionFixture.pairedHandshake()
        let manager = try makeManager()
        let center = makeCenter(manager, root: try makeTempRoot("ready"))
        #expect(center.isDataSyncAttached == false)

        center.attachPassiveHost(to: fixture.clientSession)

        #expect(center.isDataSyncAttached)
        #expect(center.dataSyncPeerID == fixture.hostIdentity.deviceID)
    }

    @MainActor
    @Test("无对端 hello（未握手）→ 只挂被动端，不挂数据同步端")
    func dataSyncNotAttachedWithoutPeerHello() throws {
        let fixture = SessionFixture.make()
        let manager = try makeManager()
        let center = makeCenter(manager, root: try makeTempRoot("nohello"))

        center.attachPassiveHost(to: fixture.clientSession)

        #expect(center.isDataSyncAttached == false)
        #expect(center.dataSyncPeerID == nil)
    }

    @MainActor
    @Test("会话拆除 → 数据同步端随之摘下")
    func dataSyncDetachedOnTeardown() throws {
        let fixture = SessionFixture.pairedHandshake()
        let manager = try makeManager()
        let center = makeCenter(manager, root: try makeTempRoot("teardown"))
        center.attachPassiveHost(to: fixture.clientSession)
        #expect(center.isDataSyncAttached)

        center.stop()

        #expect(center.isDataSyncAttached == false)
        #expect(center.dataSyncPeerID == nil)
    }

    // MARK: - 数据同步端前置门（2026-09-15：索引未到终态不得发起/应答 changeLog 同步）

    @MainActor
    @Test("前置门：曲库索引未到终态 → 不装配数据同步端，且补发对账没跑（outbox 逐字不变）")
    func dataSyncGatedUntilIndexingTerminal() throws {
        let fixture = SessionFixture.pairedHandshake()
        let manager = try makeManager()
        // 安装后第一次冷启动的形状：业务行 / outbox 行在、track 表还是空的。
        // 这条 outbox 行引用的歌在 track 表查无（`s-gone`）——补发对账一旦跑，
        // 就会把它当「本地悬空」清掉，而那正是真机上 outbox 491 → 0 的形状。
        try manager.write { db in
            try SyncChangeLogStore.record(
                db,
                entity: .favorite,
                rowKey: "s-gone",
                op: .upsert,
                payloadJSON: nil,
                updatedAtMs: 1000
            )
        }
        let source = FakeIndexingState(isIndexing: false, hasReachedIndexingTerminalState: false)
        let center = makeCenter(manager, root: try makeTempRoot("gated"), indexingState: source)

        center.attachPassiveHost(to: fixture.clientSession)

        #expect(center.isDataSyncAttached == false, "索引未终态就不该装配帧 8/9 处理器")
        #expect(center.dataSyncPeerID == nil)
        let remaining = try manager.read { db in try SyncChangeLogRow.fetchAll(db) }
        #expect(
            remaining.map(\.rowKey) == ["s-gone"],
            "前置门没把补发对账挡住：outbox 行被当悬空清掉了（真机 outbox 491 → 0 的形状）"
        )
    }

    @MainActor
    @Test("前置门：索引终态到达 → 同一会话补装数据同步端（门只挡到终态为止）")
    func dataSyncAttachedWhenTerminalStateArrives() async throws {
        let fixture = SessionFixture.pairedHandshake()
        let manager = try makeManager()
        let source = FakeIndexingState(isIndexing: false, hasReachedIndexingTerminalState: false)
        let center = makeCenter(manager, root: try makeTempRoot("terminal"), indexingState: source)
        // 无已配对主机 → start() 只挂「终态事实」订阅，不建连接（不碰 Keychain / 网络）
        center.start()
        center.attachPassiveHost(to: fixture.clientSession)
        #expect(center.isDataSyncAttached == false)

        // 主扫跑完 → 终态事实翻转 → 订阅回调补装
        source.hasReachedIndexingTerminalState = true
        // 附带等待（**不是被测语义**：被测语义是「终态到达 → 同会话必须补装」）。
        // 原为 100ms 盲睡：CI 慢机器上回调很可能还没轮到 → 假红。改为**有界轮询**
        // （形状同 `SyncDataSyncCoreTests` 里已有的 deadline 轮询：不引入 sleep 猜测，
        // 真不补装时也只是晚 10s 报错，断言信息量不变）。
        let deadline = Date().addingTimeInterval(10)
        while !center.isDataSyncAttached, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        #expect(center.isDataSyncAttached, "终态到了却没补装 → 本次会话的播放数据同步永远不通")
        #expect(center.dataSyncPeerID == fixture.hostIdentity.deviceID)
    }

    // MARK: - 展示映射

    @Test("失败原因码 → 文案 key 映射（含兜底）")
    func failureReasonKeyMapping() {
        #expect(IOSPassiveSyncPresenter.reasonKey(SyncPushFailureReason.receiveFailed) == "sync_passive_reason_transfer")
        #expect(IOSPassiveSyncPresenter.reasonKey(SyncPushFailureReason.invalidPath) == "sync_passive_reason_path")
        #expect(IOSPassiveSyncPresenter.reasonKey(SyncPushFailureReason.landFailed) == "sync_passive_reason_save")
        #expect(IOSPassiveSyncPresenter.reasonKey("unknown_reason") == "sync_passive_reason_other")
    }

    // MARK: - 回归：会话队列回调的隔离断言（2026-09-20 真机闪退）

    /// 真机闪退（`QQPlayer-2026-09-20-0811/0812*.ips`：`EXC_BREAKPOINT` / SIGTRAP，队列
    /// `com.daxmate.qqplayer.sync.browser`）根因回归。
    ///
    /// 根因：`attachDataSync` 在 **@MainActor** 上下文里写回调闭包 → 非 Sendable 闭包
    /// **继承主线程隔离**（Swift 6 语义）；而 `SyncChangeLogPeer` 是在**会话队列**（NW 通道队列，
    /// 非主线程）**同步调用**这些回调的 → 闭包体内首次隔离访问（`groups.reduce { $0 + $1.count }`）
    /// 触发运行时 executor 断言 → SIGTRAP → App 直接退出（Mac 面板看是「同步完成」）。
    ///
    /// 触发条件（与真机逐条一致）：帧 9 从**非主线程**投递 + 分组**非空**——空批不会调用
    /// reduce 的闭包，故「推空批不崩、对端缺歌（挂起/未定位）必崩」。
    /// 修法（回调类型标 `@Sendable`）后：闭包不再继承隔离，同一路径必须跑完。
    @MainActor
    @Test("回归：帧 9 在会话队列（非主线程）送达时，生产回调不得触发隔离断言")
    func dataSyncCallbacksSurviveOffMainPush() async throws {
        let fixture = SessionFixture.pairedHandshake()
        let clientManager = try makeManager()
        let root = try makeTempRoot("offmain")
        let center = makeCenter(clientManager, root: root)
        center.attachPassiveHost(to: fixture.clientSession)
        #expect(center.isDataSyncAttached)

        // host 侧：一首手机上没有的歌（指纹 H-offmain）+ 一条收藏 → 接收侧「本地缺歌挂起」
        // ⇒ 分组非空（真机上正是这一路把 App 打崩）。
        let (hostManager, hostQueue) = try makeManagerAndQueue()
        try seedHostMissingTrackFavorite(hostQueue)
        let hostPeer = SyncChangeLogPeer(
            session: fixture.hostSession,
            store: SyncChangeLogStore(database: hostManager),
            applier: SyncChangeLogApplier(database: hostManager),
            peerID: fixture.clientIdentity.deviceID,
            libraryRoot: root
        )

        // 真机投递线程 = NW 通道队列（`com.daxmate.qqplayer.sync.browser`）；回环通道**同步投递**
        // ⇒ 接收侧 `handlePush` 就在本线程跑完（不在主线程）。
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue(label: "com.daxmate.qqplayer.sync.browser.test").async {
                _ = try? hostPeer.sendIncrement()
                continuation.resume()
            }
        }

        // 跑到这里 = 隔离断言没触发；挂起落库 = 非空分组那条分支真的走了。
        let pending = SyncChangeLogPendingStore(database: clientManager)
        #expect(try pending.pendingCount() == 1)
    }

    // MARK: - 形状契约：会话/网络队列回调必须 @Sendable（2026-09-20 真机闪退家族收口）

    /// 名录：文件 → 必须标 `@Sendable` 的**存储型闭包属性**（含回调、链式转发的 prior*、注入 seam）。
    ///
    /// 为什么是硬约束：这些属性都在**会话/网络队列**（NW 通道队列，非主线程）被同步调用；
    /// 类型不标 `@Sendable` 时，`@MainActor` 上下文里写的闭包会**继承主线程隔离**（Swift 6 语义）
    /// → 闭包体内首次隔离访问触发运行时 executor 断言 = EXC_BREAKPOINT / SIGTRAP = App 直接退出
    /// （2026-09-20 真机闪退；根因、崩溃栈与复现路径见上面那条回归用例）。
    /// 标在**属性类型**上而不是赋值处的字面量上，才拦得住所有赋值点（含将来新增的）。
    private static let sendableCallbackRoster: [String: [String]] = [
        "QQPlayer/Sync/SyncPeerSession.swift": [
            "onStateChange",
            "onClosed",
            "onApplicationFrame",
            "pairApprovalHandler",
        ],
        "QQPlayer/Sync/SyncPeerSession+Frames.swift": [
            "readCurrent",
            "install",
        ],
        "QQPlayer/Sync/SyncListener.swift": [
            "onStateUpdate",
            "onReady",
            "onStopped",
            "onSessionStateChange",
            "onSessionClosed",
            "pairApprovalHandler",
        ],
        "QQPlayer/Sync/SyncBrowser.swift": [
            "onResultsChanged",
            "onBrowseFailure",
        ],
        "QQPlayer/Sync/SyncFileReceiver.swift": [
            "onCompletion",
            "onAckSent",
            "partAlignmentHook",
            "priorAppHandler",
            "priorClosedHandler",
        ],
        "QQPlayer/Sync/SyncFileSender.swift": [
            "onCompletion",
            "priorAppHandler",
            "priorClosedHandler",
        ],
        "QQPlayer/Sync/SyncManifestPeer.swift": [
            "localManifestProvider",
            "localRootName",
            "onManifestReceived",
            "onDecodeFailure",
            "onProviderUnavailable",
        ],
        "QQPlayer/Sync/SyncPeerLibraryClient.swift": [
            "onUnexpectedResponse",
            "onDecodeFailure",
            "onSessionClosed",
        ],
        "QQPlayer/Sync/SyncPeerLibraryResponder.swift": [
            "catalogProvider",
            "onDecodeFailure",
            "onResponseSent",
        ],
        "QQPlayer/Sync/SyncLibraryFetchResponder.swift": [
            "contentHashProvider",
            "lyricsFileNameProvider",
            "computedChecksumProvider",
            "onResultSent",
            "onDecodeFailure",
        ],
        "QQPlayer/Sync/SyncChangeLogPeer.swift": [
            "onPullHandled",
            "onPushApplied",
            "onPushSuspended",
            "onPushUnresolved",
            "onPushIgnoredDeletes",
            "onPushAmbiguous",
            "onPushUnsupported",
            "onPushSkippedMissingParent",
            "onPushApplyFailed",
            "onDecodeFailure",
            "onIncrementSent",
            "onIncrementMissingIdentity",
            "onPullMissingIdentity",
            "priorAppHandler",
            "priorClosedHandler",
        ],
        "QQPlayer/Sync/SyncChangeLogApplier.swift": [
            "playbackPositionSink",
            "onPlaybackPositionUnsupported",
            "onSkippedMissingParent",
            "onRowApplyFailed",
        ],
        "QQPlayer/Sync/SyncLibraryPassiveHost.swift": [
            "membersProvider",
            "peerLibraryProvider",
            "priorAppHandler",
            "priorClosedHandler",
            "onFileLanded",
            "onBatchCompleted",
            "onFetchResult",
            "onProviderUnavailable",
            "fetchResultHandler",
            "providerUnavailableHandler",
        ],
        "QQPlayer/Sync/SyncLocalLibraryProvider.swift": [
            "onFetchResult",
            "onProviderUnavailable",
        ],
        "QQPlayer/Sync/SyncLibraryPushController.swift": [
            "onStateChange",
            "onFilePushed",
        ],
        "QQPlayer/Sync/SyncLibraryPullController.swift": [
            "priorAppHandler",
            "onStateChange",
            "onFileApplied",
        ],
        "QQPlayer/Sync/SyncLyricsResendController.swift": [
            "onStateChange",
        ],
        "QQPlayer/Sync/SyncCollectionSyncCoordinator.swift": [
            "onStateChange",
            "onFileTransferred",
            "onPeerManifestReceived",
        ],
        "QQPlayer/Sync/SyncDataSyncCoordinator.swift": [
            "onStateChange",
        ],
        "QQPlayer/Sync/SyncSessionModels.swift": [
            "now",
        ],
        "QQPlayer/Mac/MacSyncLibraryHost.swift": [
            "membersProvider",
            "onFetchResult",
            "fetchResultHandler",
        ],
        "QQPlayer/Services/IOSPassiveSyncCenter.swift": [],
    ]

    /// 该文件里「存储型闭包属性」声明**总数**基线（有意为之的摩擦：新增/删除闭包属性必须过这一关）。
    private static let sendableCallbackCounts: [String: Int] = [
        "QQPlayer/Sync/SyncPeerSession.swift": 4,
        "QQPlayer/Sync/SyncPeerSession+Frames.swift": 3,
        "QQPlayer/Sync/SyncListener.swift": 6,
        "QQPlayer/Sync/SyncBrowser.swift": 2,
        "QQPlayer/Sync/SyncFileReceiver.swift": 5,
        "QQPlayer/Sync/SyncFileSender.swift": 3,
        "QQPlayer/Sync/SyncManifestPeer.swift": 5,
        "QQPlayer/Sync/SyncPeerLibraryClient.swift": 3,
        "QQPlayer/Sync/SyncPeerLibraryResponder.swift": 3,
        "QQPlayer/Sync/SyncLibraryFetchResponder.swift": 5,
        "QQPlayer/Sync/SyncChangeLogPeer.swift": 15,
        "QQPlayer/Sync/SyncChangeLogApplier.swift": 4,
        "QQPlayer/Sync/SyncLibraryPassiveHost.swift": 10,
        "QQPlayer/Sync/SyncLocalLibraryProvider.swift": 7,
        "QQPlayer/Sync/SyncLibraryPushController.swift": 2,
        "QQPlayer/Sync/SyncLibraryPullController.swift": 3,
        "QQPlayer/Sync/SyncLyricsResendController.swift": 1,
        "QQPlayer/Sync/SyncCollectionSyncCoordinator.swift": 3,
        "QQPlayer/Sync/SyncDataSyncCoordinator.swift": 1,
        "QQPlayer/Sync/SyncSessionModels.swift": 1,
        "QQPlayer/Mac/MacSyncLibraryHost.swift": 3,
        "QQPlayer/Services/IOSPassiveSyncCenter.swift": 2,
    ]

    /// 经审计的豁免（逐条给理由；不许静默漏 —— 未登记也未豁免的闭包属性会直接报错）。
    private static let sendableCallbackExemptions: [String: [String: String]] = [
        "QQPlayer/Sync/SyncPeerSession+Frames.swift": [
            "removal": "内部管道：闭包捕获私有引用计数对象 Entry（非 Sendable），要标就得给 Entry 加 @unchecked Sendable = 本任务禁止的糊法；构造与调用都在本层非隔离调用栈内。",
        ],
        "QQPlayer/Sync/SyncLocalLibraryProvider.swift": [
            "sourceFiles": "值类型描述符字段：唯一生产构造点 = 非隔离的 live() 工厂，闭包捕获 FileManager（SDK 未标 Sendable）⇒ 标 @Sendable 只能靠 @unchecked 盒子或改运行时行为，两者都被本任务禁止。",
            "lyricsEntries": "同上（描述符字段，构造点在非隔离 live() 工厂）。",
            "contentHash": "同上（描述符字段，构造点在非隔离 live() 工厂）。",
            "lyricsFileName": "同上（描述符字段，构造点在非隔离 live() 工厂）。",
            "members": "同上（描述符字段，构造点在非隔离 live() 工厂）。",
        ],
        "QQPlayer/Services/IOSPassiveSyncCenter.swift": [
            "libraryRoot": "DI seam：调用点全在主线程（@MainActor 类内部装配），不出会话队列。",
            "clientName": "DI seam：调用点全在主线程（@MainActor 类内部装配），不出会话队列。",
        ],
    ]

    /// 行式扫描「存储型闭包属性」声明：形如 `[修饰符] var|let 名字: <含 -> 的类型>`。
    /// 剥注释（`//` 起始行不算）、不解析语法 —— 与结构预算棘轮同风格，够用且易核对。
    private static func closurePropertyDeclarations(in source: String) -> [(name: String, hasSendable: Bool)] {
        source.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
            let trimmed = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//"), trimmed.contains("->") else { return nil }
            let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard let keywordIndex = tokens.firstIndex(where: { $0 == "var" || $0 == "let" }),
                  keywordIndex + 1 < tokens.count
            else { return nil }
            let nameToken = tokens[keywordIndex + 1]
            guard nameToken.hasSuffix(":") else { return nil }
            return (name: String(nameToken.dropLast()), hasSendable: trimmed.contains("@Sendable"))
        }
    }

    /// 形状契约：**会话/网络队列回调必须 `@Sendable`**（全家族）。
    ///
    /// PR #12（`SyncChangeLogPeer` + `SyncLibraryPassiveHost`，真机闪退当场所修）只守住了两类；
    /// 本用例把同一口径扩到**全家族**：凡是「在会话/网络队列被调用」的存储型闭包属性，一律标在
    /// 属性类型上。判据三条：① 名录里的属性必须带 `@Sendable`；② 每个文件的闭包属性**计数**必须
    /// 与基线一致（增删都要过这一关）；③ 既不在名录也没豁免的闭包属性 = 红（防"新增回调漏标"）。
    /// 反向验证：撤掉任一名录属性的 `@Sendable` → 本用例当场变红（已在交办里做过）。
    @Test("形状契约：会话/网络队列回调声明必须 @Sendable（全家族；漏一处 = 真机闪退）")
    func sessionQueueCallbacksDeclareSendable() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let roster = Self.sendableCallbackRoster
        #expect(!roster.isEmpty && roster.count == Self.sendableCallbackCounts.count, "名录与计数基线必须成对且非空（fail-closed）")
        var scannedTotal = 0
        for (relativePath, expectedNames) in roster.sorted(by: { $0.key < $1.key }) {
            let source = try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
            let declarations = Self.closurePropertyDeclarations(in: source)
            let exemptions = Self.sendableCallbackExemptions[relativePath] ?? [:]
            scannedTotal += declarations.count
            #expect(
                declarations.count == Self.sendableCallbackCounts[relativePath],
                "\(relativePath) 存储型闭包属性数变了（\(declarations.count) ≠ \(Self.sendableCallbackCounts[relativePath] ?? -1)）：新增/删除闭包属性须同步本基线"
            )
            for declaration in declarations {
                if expectedNames.contains(declaration.name) {
                    #expect(
                        declaration.hasSendable,
                        "\(relativePath).\(declaration.name) 没标 @Sendable：它在会话/网络队列被调用，漏标 = iOS 上重新继承主线程隔离 = 真机闪退"
                    )
                } else if let reason = exemptions[declaration.name] {
                    #expect(!reason.isEmpty, "\(relativePath).\(declaration.name) 的豁免必须写明理由")
                } else {
                    Issue.record(
                        "\(relativePath).\(declaration.name) 是未登记的存储型闭包属性：要么标 @Sendable 并登记名录，要么写进豁免表（带理由）"
                    )
                }
            }
            for name in expectedNames where !declarations.contains(where: { $0.name == name }) {
                Issue.record("\(relativePath) 名录里的 \(name) 已不存在：删回调须同步名录")
            }
            for name in exemptions.keys where !declarations.contains(where: { $0.name == name }) {
                Issue.record("\(relativePath) 豁免表里的 \(name) 已不存在：删掉这条豁免")
            }
        }
        #expect(
            scannedTotal == Self.sendableCallbackCounts.values.reduce(0, +),
            "扫描面与基线不一致（一个文件没扫到 = 判据坏了）"
        )
    }
}
