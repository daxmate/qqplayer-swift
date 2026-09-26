//
//  SyncDeviceListModelTests.swift
//  QQPlayerTests
//
//  M6 T11：macOS 同步「设备区」纯逻辑测试（QQPlayer/Services/SyncDeviceListModel.swift）。
//  覆盖：role 过滤（只列移动端）、在线匹配、默认选中（在线优先 / 无在线不选）、
//  列表刷新后的选中保持、短码（首组 … 末组 + 非规范 ID 回落）。
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncDeviceListModelTests {
    // MARK: - Fixture

    /// 规范 Device ID（真指纹编码，保证 shortComparisonParts 可用）。
    private static func makeID(_ byte: UInt8) -> String {
        DeviceID.make(fromPublicKeyData: Data(repeating: byte, count: 32))!
    }

    private static func device(
        peerID: String,
        displayName: String = "iPhone",
        role: PeerRole = .client
    ) -> PeerDevice {
        PeerDevice(
            peerID: peerID,
            peerPublicKey: Data(repeating: 7, count: 32).base64EncodedString(),
            displayName: displayName,
            role: role,
            pairedAt: 1_700_000_000,
            lastSeenAt: 1_700_000_000,
            notes: nil
        )
    }

    // MARK: - role 过滤

    @Test("设备区：只列移动端（role == .client），顺序与入参一致")
    func clientsFiltersHosts() {
        let hostID = Self.makeID(1)
        let aID = Self.makeID(2)
        let bID = Self.makeID(3)
        let devices = [
            Self.device(peerID: hostID, displayName: "MacBook Pro", role: .host),
            Self.device(peerID: aID, displayName: "iPhone A"),
            Self.device(peerID: bID, displayName: "iPhone B"),
        ]

        let clients = SyncDeviceListModel.clients(in: devices)
        #expect(clients.map(\.peerID) == [aID, bID])

        let rows = SyncDeviceListModel.rows(in: devices, onlinePeerID: nil)
        #expect(rows.map(\.peerID) == [aID, bID])
        #expect(rows.allSatisfy { !$0.isOnline })
    }

    @Test("设备区：只有主机记录（本机/其他 Mac）时列表为空")
    func clientsEmptyWhenOnlyHosts() {
        let devices = [Self.device(peerID: Self.makeID(9), displayName: "Mac", role: .host)]

        #expect(SyncDeviceListModel.clients(in: devices).isEmpty)
        #expect(SyncDeviceListModel.rows(in: devices, onlinePeerID: nil).isEmpty)
        #expect(SyncDeviceListModel.rows(in: devices, onlinePeerID: Self.makeID(9)).isEmpty)
    }

    // MARK: - 在线匹配

    @Test("设备区：在线 = 与 connectedPeer 同 ID；无连接 / 空 ID 恒离线")
    func rowsMarkOnlineByPeerID() {
        let aID = Self.makeID(4)
        let bID = Self.makeID(5)
        let devices = [Self.device(peerID: aID), Self.device(peerID: bID)]

        let online = SyncDeviceListModel.rows(in: devices, onlinePeerID: aID)
        #expect(online.map(\.isOnline) == [true, false])

        #expect(SyncDeviceListModel.rows(in: devices, onlinePeerID: nil).allSatisfy { !$0.isOnline })
        #expect(SyncDeviceListModel.rows(in: devices, onlinePeerID: "").allSatisfy { !$0.isOnline })
        // 已配对的移动端 ID 与对端不一致（如连的是别的机器）→ 全部离线
        #expect(SyncDeviceListModel.rows(in: devices, onlinePeerID: Self.makeID(6)).allSatisfy { !$0.isOnline })
    }

    // MARK: - 默认选中

    @Test("设备区：默认选中在线那台；无在线则不选")
    func defaultSelectionPrefersOnline() {
        let aID = Self.makeID(7)
        let bID = Self.makeID(8)
        let devices = [Self.device(peerID: aID), Self.device(peerID: bID)]

        let rows = SyncDeviceListModel.rows(in: devices, onlinePeerID: bID)
        #expect(SyncDeviceListModel.defaultSelection(in: rows) == bID)

        let offlineRows = SyncDeviceListModel.rows(in: devices, onlinePeerID: nil)
        #expect(SyncDeviceListModel.defaultSelection(in: offlineRows) == nil)
        #expect(SyncDeviceListModel.defaultSelection(in: []) == nil)
    }

    // MARK: - 刷新后的选中保持

    @Test("设备区：刷新后原选中仍在列表里就保持（即使暂时离线）")
    func reconciledSelectionKeepsExisting() {
        let aID = Self.makeID(10)
        let bID = Self.makeID(11)
        // 在线的是 B，但用户已手动选了 A（A 仍在线下）→ 保持 A
        let rows = SyncDeviceListModel.rows(
            in: [Self.device(peerID: aID), Self.device(peerID: bID)],
            onlinePeerID: bID
        )

        #expect(SyncDeviceListModel.reconciledSelection(aID, in: rows) == aID)
        #expect(SyncDeviceListModel.reconciledSelection(bID, in: rows) == bID)
    }

    @Test("设备区：原选中已消失（撤销配对）→ 回落在线那台；无在线则清空")
    func reconciledSelectionFallsBack() {
        let aID = Self.makeID(12)
        let bID = Self.makeID(13)
        let goneID = Self.makeID(14)
        let rows = SyncDeviceListModel.rows(
            in: [Self.device(peerID: aID), Self.device(peerID: bID)],
            onlinePeerID: bID
        )

        #expect(SyncDeviceListModel.reconciledSelection(goneID, in: rows) == bID)
        #expect(SyncDeviceListModel.reconciledSelection(nil, in: rows) == bID)

        let offlineRows = SyncDeviceListModel.rows(
            in: [Self.device(peerID: aID), Self.device(peerID: bID)],
            onlinePeerID: nil
        )
        #expect(SyncDeviceListModel.reconciledSelection(goneID, in: offlineRows) == nil)
        #expect(SyncDeviceListModel.reconciledSelection(nil, in: offlineRows) == nil)
    }

    // MARK: - 行展示

    @Test("设备区：短码取首组 … 末组；非规范 ID 回落全量分组格式")
    func rowShortCodeAndDisplayName() {
        let aID = Self.makeID(15)
        let rows = SyncDeviceListModel.rows(in: [Self.device(peerID: aID)], onlinePeerID: nil)
        let parts = DeviceID.shortComparisonParts(aID)
        #expect(rows.first?.shortCode == "\(parts?.first ?? "") … \(parts?.last ?? "")")

        let bogus = SyncDeviceListModel.rows(
            in: [Self.device(peerID: "not-a-device-id", displayName: "")],
            onlinePeerID: nil
        )
        #expect(bogus.first?.shortCode == DeviceID.formatted("not-a-device-id"))
        // 空展示名回落占位文案（非空），不显示空白行
        #expect(bogus.first?.displayName.isEmpty == false)
    }

    // MARK: - 批 B2：目标选择（期望目标 + 闸门）

    @Test("目标状态：选中且在线 → 可同步；展示名与行一致")
    func targetStatusOnline() {
        let aID = Self.makeID(20)
        let rows = SyncDeviceListModel.rows(
            in: [Self.device(peerID: aID, displayName: "iPhone A")],
            onlinePeerID: aID
        )

        let status = SyncDeviceTargetSelection(peerID: aID).status(in: rows)
        #expect(status.target == SyncDeviceTarget(peerID: aID, displayName: "iPhone A"))
        #expect(status.isTargetOnline)
        #expect(status.canSync)
        #expect(status.waitingName == nil)
        #expect(status.mismatch == nil)
    }

    @Test("目标状态：选中但离线 → 不可同步，并给出「等待 <名字> 上线」所需的名字")
    func targetStatusOffline() {
        let aID = Self.makeID(21)
        let bID = Self.makeID(22)
        // 在线的是 B，用户选的是 A（A 离线）
        let rows = SyncDeviceListModel.rows(
            in: [Self.device(peerID: aID, displayName: "iPhone A"), Self.device(peerID: bID, displayName: "iPhone B")],
            onlinePeerID: bID
        )

        let status = SyncDeviceTargetSelection(peerID: aID).status(in: rows)
        #expect(!status.isTargetOnline)
        #expect(!status.canSync)
        #expect(status.waitingName == "iPhone A")
    }

    @Test("目标状态：连上的 ≠ 所选 → 结构化错配（两边都带展示名，供「一键改用」）")
    func targetStatusMismatch() {
        let aID = Self.makeID(23)
        let bID = Self.makeID(24)
        let rows = SyncDeviceListModel.rows(
            in: [Self.device(peerID: aID, displayName: "iPhone A"), Self.device(peerID: bID, displayName: "iPhone B")],
            onlinePeerID: bID
        )

        let status = SyncDeviceTargetSelection(peerID: aID).status(in: rows)
        #expect(
            status.mismatch
                == SyncDeviceTargetMismatch(
                    selected: SyncDeviceTarget(peerID: aID, displayName: "iPhone A"),
                    connected: SyncDeviceTarget(peerID: bID, displayName: "iPhone B")
                )
        )

        // 选中就是连上的那台 → 无错配
        #expect(SyncDeviceTargetSelection(peerID: bID).status(in: rows).mismatch == nil)
        // 一台都没在线 → 无从谈起（不报错配）
        let offlineRows = SyncDeviceListModel.rows(in: [Self.device(peerID: aID)], onlinePeerID: nil)
        #expect(SyncDeviceTargetSelection(peerID: aID).status(in: offlineRows).mismatch == nil)
    }

    @Test("目标选择：未选 / 空串一律归一成「未选」；未选时目标状态为空态")
    func targetSelectionNormalizesEmpty() {
        let aID = Self.makeID(25)
        let rows = SyncDeviceListModel.rows(in: [Self.device(peerID: aID)], onlinePeerID: aID)

        #expect(SyncDeviceTargetSelection(peerID: nil) == .none)
        #expect(SyncDeviceTargetSelection(peerID: "") == .none)
        #expect(!SyncDeviceTargetSelection(peerID: "").isSelected)

        let status = SyncDeviceTargetSelection.none.status(in: rows)
        #expect(status.target == nil)
        #expect(!status.canSync)
        #expect(status.waitingName == nil)
        // 未选 ≠ 错配：没选时不断言「你要同步的是谁」
        #expect(status.mismatch == nil)
    }

    @Test("目标选择：所选设备已撤销配对 → 回落默认（在线那台）且可写回")
    func targetSelectionReconciles() {
        let aID = Self.makeID(26)
        let bID = Self.makeID(27)
        let goneID = Self.makeID(28)
        let rows = SyncDeviceListModel.rows(
            in: [Self.device(peerID: aID), Self.device(peerID: bID)],
            onlinePeerID: bID
        )

        #expect(SyncDeviceTargetSelection(peerID: aID).reconciled(in: rows).peerID == aID)
        #expect(SyncDeviceTargetSelection(peerID: goneID).reconciled(in: rows).peerID == bID)
        #expect(SyncDeviceTargetSelection.none.reconciled(in: rows).peerID == bID)
    }

    @Test("一键改用：把选择改成当前连上的那台；没连线时保持原选择")
    func adoptingConnectedPeer() {
        let aID = Self.makeID(29)
        let bID = Self.makeID(30)
        let rows = SyncDeviceListModel.rows(
            in: [Self.device(peerID: aID), Self.device(peerID: bID)],
            onlinePeerID: bID
        )

        #expect(SyncDeviceTargetSelection(peerID: aID).adoptingConnectedPeer(in: rows).peerID == bID)
        // 已选中连上的那台 → 幂等
        #expect(SyncDeviceTargetSelection(peerID: bID).adoptingConnectedPeer(in: rows).peerID == bID)

        let offlineRows = SyncDeviceListModel.rows(in: [Self.device(peerID: aID)], onlinePeerID: nil)
        #expect(SyncDeviceTargetSelection(peerID: aID).adoptingConnectedPeer(in: offlineRows).peerID == aID)
        #expect(SyncDeviceTargetSelection.none.adoptingConnectedPeer(in: offlineRows) == .none)
    }

    @Test("同步数据闸门：目标离线不可开始；目标在线/未选则沿用连接类判定")
    func dataSyncAvailability() {
        let aID = Self.makeID(31)
        let bID = Self.makeID(32)
        let rows = SyncDeviceListModel.rows(
            in: [Self.device(peerID: aID, displayName: "iPhone A"), Self.device(peerID: bID, displayName: "iPhone B")],
            onlinePeerID: bID
        )

        // 选了离线的 A（连上的却是 B）→ 「同步数据」也不可开始（不能默默打到 B）
        let mismatched = SyncDeviceTargetSelection(peerID: aID).status(in: rows)
        #expect(
            mismatched.dataSyncAvailability(isConnected: true, hasSession: true, isRunning: false)
                == .targetOffline
        )
        // 目标在线 + 连接 + 会话 → 可开始；运行中 → alreadyRunning
        let online = SyncDeviceTargetSelection(peerID: bID).status(in: rows)
        #expect(online.dataSyncAvailability(isConnected: true, hasSession: true, isRunning: false) == .ready)
        #expect(
            online.dataSyncAvailability(isConnected: true, hasSession: true, isRunning: true)
                == .alreadyRunning
        )
        // 未连接/无会话 → 沿用既有「未连接」文案分支
        #expect(
            online.dataSyncAvailability(isConnected: false, hasSession: false, isRunning: false)
                == .notConnected
        )
    }
}
