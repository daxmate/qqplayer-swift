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
