//
//  IOSPassiveSyncCenterTests.swift
//  QQPlayerTests
//
//  M6 · T4/T5（2026-09-11）iOS 被动同步中心纯逻辑防回归（无网络 / 无 IO）：
//  - IOSPassiveReconnectLogic.targets：浏览结果 × 已配对主机 → 候选序列
//    （名称匹配优先 / 落单 endpoint 兜底 / 空输入）
//  - IOSPassiveReconnectPolicy：指数退避 + 封顶 + 次数上限（上限用尽 = 手动兜底）
//  - IOSPassiveSyncPresenter：状态与失败 → 文案 key + 账目数字 + 重连按钮可用性
//

import Foundation
import Network
import Testing

@testable import QQPlayer

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

    // MARK: - 候选目标

    @Test("targets：名称匹配的已配对主机排前，落单 endpoint 兜底在后")
    func targetsPrefersNameMatch() {
        let targets = IOSPassiveReconnectLogic.targets(
            discovered: [makeHost("Mac-Studio"), makeHost("MacBook-Air")],
            pairedHosts: [makePeer("PEER-A", name: "MacBook-Air")]
        )
        #expect(targets.count == 2)
        #expect(targets.first == IOSPassiveSyncTarget(
            peerID: "PEER-A",
            hostName: "MacBook-Air",
            endpoint: makeHost("MacBook-Air").endpoint
        ))
        #expect(targets.last?.hostName == "Mac-Studio")
        #expect(targets.last?.peerID == "PEER-A")
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

    @Test("失败原因码 → 文案 key 映射（含兜底）")
    func failureReasonKeyMapping() {
        #expect(IOSPassiveSyncPresenter.reasonKey(SyncPushFailureReason.receiveFailed) == "sync_passive_reason_transfer")
        #expect(IOSPassiveSyncPresenter.reasonKey(SyncPushFailureReason.invalidPath) == "sync_passive_reason_path")
        #expect(IOSPassiveSyncPresenter.reasonKey(SyncPushFailureReason.landFailed) == "sync_passive_reason_save")
        #expect(IOSPassiveSyncPresenter.reasonKey("unknown_reason") == "sync_passive_reason_other")
    }
}
