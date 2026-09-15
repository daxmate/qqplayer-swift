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
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        try manager.createTables()
        return manager
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
        try await Task.sleep(nanoseconds: 100_000_000)

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
}
