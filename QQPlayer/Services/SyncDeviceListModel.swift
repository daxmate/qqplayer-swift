//
//  SyncDeviceListModel.swift
//  QQPlayer
//
//  M6（T11，2026-09-12）macOS「同步」**设备区**纯逻辑（iOS + Mac 共享 Core）：
//  已配对移动设备（role == .client）过滤 → 行模型（展示名 / 短码 / 在线态）→
//  默认选中与列表刷新后的选中保持。
//
//  为什么单独成文件：设备区跨两个入口（设置页 / 工具栏面板），且「选中哪台」
//  是**决策**而不是绘制——按仓库纪律（行为有单一事实源：决策上收、执行下沉、
//  决策逻辑必须可测）放共享 Services/，View 里只渲染不判断。
//
//  依赖：`PeerDevice`（Sync/）+ `SyncDeviceList` 展示名/短码 + `DeviceID` 展示格式，
//  均为既有纯类型；本文件无 IO、无 SwiftUI、无 GRDB 读写。
//
//  ⚠️ v1 语义：同一时刻只支持单会话在线（连接恒由移动端发起），本模型只回答
//  「列表怎么排、哪台高亮」，不改协议、不做多会话。
//
//  ⚠️ 2026-09-26 批 B2「设备选择真化」：选中设备 = **期望目标 + 闸门**（显式声明，
//  不再靠「谁在线」隐式决定）。新增的三件事仍然是**纯函数**、且**只有这一份实现**：
//   · `SyncDeviceTargetSelection`：选择的类型边界（不再让裸 `String?` 在 View 里传）
//   · `SyncDeviceTargetStatus`：目标是谁 / 在不在线 / **连上的与所选是否不符** / 能否同步
//   · `SyncDeviceTargetMismatch`：不符时的结构化事实（谁连上了、期望的是谁）
//  View 只渲染这些结论 + 挂动作；可否开始同步的合成判定在 `SyncUIStartGate`（同族纯逻辑）。
//

import Foundation

/// 设备区一行（View 只渲染，不做任何判断）。
struct SyncDeviceTargetRow: Equatable, Identifiable {
    /// 设备 Device ID（全量）；单选项标识
    let peerID: String
    /// 展示名（空名已由 `SyncDeviceList.displayName` 回落到占位文案）
    let displayName: String
    /// 展示用短码（首组 … 末组；非规范 ID 回落全量分组格式）
    let shortCode: String
    /// 是否有活动会话（`SyncHostCenter.connectedPeer.peerID` 命中本行）
    let isOnline: Bool

    var id: String { peerID }
}

/// 本次同步的**目标设备**（有名字的类型边界）：跨「决策 / 渲染 / 文案」传递时
/// 不再裸传 Device ID —— 裸字符串会在 View 里被比较、被拼接，容易长出第二套判断。
struct SyncDeviceTarget: Equatable, Sendable {
    /// 设备 Device ID（全量）
    let peerID: String
    /// 展示名（已由 `SyncDeviceList.displayName` 回落到占位文案）
    let displayName: String
}

/// 「**连上的 ≠ 所选**」的结构化判定（批 B2）：不为静默改选、也不在 View 里比 ID，
/// 而是把事实交给 UI —— 「当前连着 B，你要同步的是 A」+ 一键改用 B。
struct SyncDeviceTargetMismatch: Equatable, Sendable {
    /// 用户所选（期望）目标
    let selected: SyncDeviceTarget
    /// 当前实际连上的对端
    let connected: SyncDeviceTarget
}

/// 本次同步目标的状态（批 B2 的唯一决策）：目标是谁 / 在不在线 / 与当前连接是否错配。
/// 只描述事实，不产生文案（文案属于 UI 层，见仓库纪律）。
struct SyncDeviceTargetStatus: Equatable, Sendable {
    /// 期望目标（nil = 还没选）
    let target: SyncDeviceTarget?
    /// 期望目标此刻是否在线
    let isTargetOnline: Bool
    /// 连上的 ≠ 所选（nil = 一致 / 无从谈起）
    let mismatch: SyncDeviceTargetMismatch?

    /// 未选目标（也没有可用的连线事实）。
    static let none = SyncDeviceTargetStatus(target: nil, isTargetOnline: false, mismatch: nil)

    /// 能否据此发起同步：**选中设备 = 唯一合法同步目标**（有目标且目标在线）。
    var canSync: Bool { target != nil && isTargetOnline }

    /// 「等待 **<名字>** 上线」里的名字（nil = 不适用：没选目标 / 目标已在线）。
    var waitingName: String? {
        guard let target, !isTargetOnline else { return nil }
        return target.displayName
    }

    /// 「同步数据」入口的可用性（批 B2）：与传歌**同一个目标语义** —— 选中设备在线才能动；
    /// 连上的不是所选时不能在 UI 上装作没事地同步到别人。
    /// 判定顺序：目标闸门（`SyncUIStartGate.targetBlock`，唯一实现）→ 连接/会话 → 运行中 → 可开始。
    /// 为什么放在这里而不是 `SyncUIState.swift`：那是「传歌开始闸门」的地盘，
    /// 本文件是批 B2（设备选择）的唯一决策层；两者共用同一个目标闸门函数。
    func dataSyncAvailability(
        isConnected: Bool,
        hasSession: Bool,
        isRunning: Bool
    ) -> SyncUIStartAvailability {
        if let blocked = SyncUIStartGate.targetBlock(self) { return blocked }
        if !isConnected || !hasSession { return .notConnected }
        if isRunning { return .alreadyRunning }
        return .ready
    }
}

/// 目标选择（调用方持有的类型边界：`peerID == nil` = 未选）。
/// 选择本身是状态（可持久化），**所有判定**都经过它委托给 `SyncDeviceListModel` 的纯函数。
struct SyncDeviceTargetSelection: Equatable, Sendable {
    /// 所选设备 Device ID（nil / 空串 = 未选）
    let peerID: String?

    init(peerID: String?) {
        self.peerID = (peerID?.isEmpty == false) ? peerID : nil
    }

    /// 未选。
    static let none = SyncDeviceTargetSelection(peerID: nil)

    /// 是否已选一台设备。
    var isSelected: Bool { peerID != nil }

    /// 目标状态判定（纯函数）：目标是谁 / 在不在线 / 连上的与所选是否不符。
    func status(in rows: [SyncDeviceTargetRow]) -> SyncDeviceTargetStatus {
        let targetRow = peerID.flatMap { id in rows.first { $0.peerID == id } }
        let target = targetRow.map { SyncDeviceTarget(peerID: $0.peerID, displayName: $0.displayName) }
        let connectedRow = rows.first(where: \.isOnline)

        var mismatch: SyncDeviceTargetMismatch?
        if let target, let connectedRow, connectedRow.peerID != target.peerID {
            mismatch = SyncDeviceTargetMismatch(
                selected: target,
                connected: SyncDeviceTarget(peerID: connectedRow.peerID, displayName: connectedRow.displayName)
            )
        }
        return SyncDeviceTargetStatus(
            target: target,
            isTargetOnline: targetRow?.isOnline ?? false,
            mismatch: mismatch
        )
    }

    /// 列表刷新后的对账：原选中仍在列表里 → 保持（即使它此刻离线，用户的选择不丢）；
    /// 原选中已消失（撤销配对）→ 回落默认（在线那台 / 未选）。
    func reconciled(in rows: [SyncDeviceTargetRow]) -> SyncDeviceTargetSelection {
        SyncDeviceTargetSelection(peerID: SyncDeviceListModel.reconciledSelection(peerID, in: rows))
    }

    /// 「一键改用」：把选择改成**当前连上的那台**（没连线 = 原选择不变）。
    /// 唯一用途 = 「连上的 ≠ 所选」提示里的动作（把期望目标改成现实）。
    func adoptingConnectedPeer(in rows: [SyncDeviceTargetRow]) -> SyncDeviceTargetSelection {
        guard let connected = rows.first(where: \.isOnline) else { return self }
        return SyncDeviceTargetSelection(peerID: connected.peerID)
    }
}

/// macOS 同步「设备区」纯逻辑：过滤移动端 / 在线匹配 / 默认与保持选中。
enum SyncDeviceListModel {
    /// 移动端设备（role == .client）。顺序保持入参顺序
    /// （`DeviceStore.all()` 已按 displayName + peerID 稳定排序 → 列表顺序稳定）。
    static func clients(in devices: [PeerDevice]) -> [PeerDevice] {
        devices.filter { $0.role == .client }
    }

    /// 行模型：已过滤 role == .client + 标注在线态。
    static func rows(in devices: [PeerDevice], onlinePeerID: String?) -> [SyncDeviceTargetRow] {
        clients(in: devices).map { device in
            SyncDeviceTargetRow(
                peerID: device.peerID,
                displayName: SyncDeviceList.displayName(device),
                shortCode: SyncDeviceList.shortIDText(device) ?? DeviceID.formatted(device.peerID),
                isOnline: isOnline(device, onlinePeerID: onlinePeerID)
            )
        }
    }

    /// 在线判定：本设备是不是当前已连接的对端（无连接 / 空 ID 恒离线）。
    static func isOnline(_ device: PeerDevice, onlinePeerID: String?) -> Bool {
        guard let onlinePeerID, !onlinePeerID.isEmpty else { return false }
        return device.peerID == onlinePeerID
    }

    /// 默认选中：在线那台（多台在线取第一台）；**无在线则不选**（nil）。
    static func defaultSelection(in rows: [SyncDeviceTargetRow]) -> String? {
        rows.first(where: \.isOnline)?.peerID
    }

    /// 列表刷新后的选中保持：原选中仍在列表里 → 保持（即使它此刻离线，用户的选择不丢）；
    /// 原选中已消失（撤销配对）→ 回落默认（在线那台 / nil）。
    static func reconciledSelection(_ current: String?, in rows: [SyncDeviceTargetRow]) -> String? {
        if let current, rows.contains(where: { $0.peerID == current }) {
            return current
        }
        return defaultSelection(in: rows)
    }
}
