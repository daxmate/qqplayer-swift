//
//  SyncDevicePane.swift
//  QQPlayer
//
//  「设备」页（2026-09-26 批 B1「拆 Pane + 顶层两页」；批 D 改为独立 `struct`；QQPlayerMac target only）。
//
//  页面内容（用户 2026-09-26 拍板，低频/配置面）：
//   · 待批准请求（`pairingApprovalSection`，有请求时置顶）
//   · 本机身份与二维码（`identitySection`：本机名字 + Device ID + 二维码 + 刷新）
//   · 连接状态（`connectionSection`：已连对端行的状态/时长 + 「允许局域网连接」开关 + 监听提示）
//   · 已配对设备（`pairedDevicesSection`：在线态 / 最后在线 / 撤销配对）
//   · 本次同步目标（`deviceTargetSection`：单选真控件 + 目标状态行）
//
//  ⚠️ R3「设备只讲一次」：设备信息与配对操作**只出现在本页**，「同步」页不重复
//  （拆分前 A 连接状态区在同步四区之首，本批随设备语义整体迁到本页）。
//
//  ⚠️ 批 B2（2026-09-26）「设备选择真化」：`deviceTargetRow` 已从**假控件**
//  （裸 `onTapGesture` 只写本地态）改成**真控件**（Button + `.isSelected` 无障碍 trait）；
//  选择语义 = **期望目标 + 闸门**（目标离线 → 不可同步 + 「等待 <名字> 上线」；
//  连上的 ≠ 所选 → 明说 + 一键改用），判定全在 `SyncDeviceListModel` / `SyncUIStartGate`。
//
//  ⚠️ 批 D（2026-09-26）为什么 Pane 是**独立 struct**：三个 ViewModel 仍是
//  `ObservableObject`（`@Observable` 迁移尚未覆盖它们），子视图**不得**写
//  `@ObservedObject` / `@StateObject`（`ObservationMigrationContractTests` 是「新增
//  (文件, 标记) 即红」的棘轮）。做法 = **父 = 唯一观察者**：状态与 ViewModel 生命周期
//  **全在 `MacSyncRunSection`**；本 struct 只收「值输入 + 回调 / 绑定」，父 body 重算 ⇒
//  子拿到新值即重绘（需要写回的 `@State` 以 `@Binding` 下传，状态不搬家）。
//  本文件内**零** `@ObservedObject` / `@StateObject` / `@EnvironmentObject`。
//
//  可见性：`SyncDevicePane` 与共用目标状态行 `SyncTargetStatusBanner` 为 internal
//  （后者被 `MacSyncView+Run.swift` 的 D 执行区与 `SyncDataPane.swift` 复用）；
//  仅本文件使用的辅助成员保持 `private`。
//

import SwiftUI

/// 「设备」页（顶层页之一）。输入全部来自 `MacSyncRunSection`（唯一观察者）。
struct SyncDevicePane: View {
    /// 同步中心（待批准请求 / 启动错误 / 「允许局域网连接」开关；生命周期不归本视图）。
    let hostCenter: SyncHostCenter
    /// 执行侧（连接到的对端 / 监听态 / 已连时长 / 启动可用性）。
    let model: MacSyncRunViewModel
    /// 本机身份（nil = 尚未载入）。
    let identity: SyncIdentity?
    /// 本机二维码（identity 就绪才生成）。
    let qrImage: NSImage?
    /// 本机展示名（Bonjour 友好名优先，回落进程主机名）。
    let hostName: String
    /// App 强调色（读环境值）。
    let accentColor: Color
    /// 已配对设备列表。
    let devices: [PeerDevice]
    /// 目标行模型（过滤 + 在线态 + 短码；决策全在 `SyncDeviceListModel`）。
    let deviceRows: [SyncDeviceTargetRow]
    /// 本次同步目标状态（决策全在 `SyncDeviceListModel`；View 只渲染）。
    let syncTargetStatus: SyncDeviceTargetStatus
    /// 本次同步目标设备 ID（nil = 未选）。
    let targetDeviceID: String?

    // 父持有的本地态：本 struct 只以绑定读写（状态不搬家，生命周期仍在父）。
    @Binding var identityError: String?
    @Binding var devicesError: String?
    @Binding var pendingUnpair: PeerDevice?

    // 回调动词：全部落在父上，语义与拆分前逐字一致。
    let onReloadDevices: () -> Void
    let onRefreshQR: () -> Void
    let onSelectTarget: (String?) -> Void
    let onAdoptConnected: () -> Void
    let onUnpair: (PeerDevice) -> Void

    var body: some View {
        Group {
            pairingApprovalSection
            identitySection
            connectionSection
            pairedDevicesSection
            deviceTargetSection
        }
        .alert(
            "sync_load_failed_title".localized,
            isPresented: Binding(
                get: { identityError != nil || devicesError != nil || hostCenter.startError != nil },
                set: { if !$0 { identityError = nil; devicesError = nil; hostCenter.clearStartError() } }
            )
        ) {
            Button(Localized.ok) {}
        } message: {
            Text(identityError ?? devicesError ?? hostCenter.startError ?? "")
        }
    }

    // MARK: - a 配对请求批准（S2 接线：M2a 网络请求到达 → 批准卡）

    @ViewBuilder
    private var pairingApprovalSection: some View {
        if let pending = hostCenter.pendingCard {
            Section {
                MacPairApprovalCardView(
                    candidate: pending.makePeerCandidate(receivedAt: Date().timeIntervalSince1970),
                    onApprove: {
                        hostCenter.approvePending()
                        onReloadDevices()
                    },
                    onReject: {
                        hostCenter.rejectPending()
                        onReloadDevices()
                    }
                )
                .padding(.vertical, DesignTokens.space4)
            } header: {
                Text("sync_pairing_request_header".localized)
            }
        }
    }

    // MARK: - b 本机身份与二维码

    @ViewBuilder
    private var identitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: DesignTokens.space12) {
                LabeledContent("sync_this_device".localized) {
                    Text(hostName)
                        .fontWeight(.medium)
                }
                if let identity {
                    LabeledContent("sync_device_id".localized) {
                        Text(DeviceID.formatted(identity.deviceID))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }

                HStack(alignment: .center, spacing: DesignTokens.space20) {
                    if let qrImage {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 168, height: 168)
                    } else {
                        RoundedRectangle(cornerRadius: DesignTokens.radius8)
                            .fill(.quaternary)
                            .frame(width: 168, height: 168)
                            .overlay(
                                Image(systemName: "qrcode")
                                    .font(.system(size: DesignTokens.font40))
                                    .foregroundStyle(.secondary)
                            )
                    }

                    VStack(alignment: .leading, spacing: DesignTokens.space8) {
                        Text("sync_qr_scan_hint".localized)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            onRefreshQR()
                        } label: {
                            Label("sync_refresh_qr".localized, systemImage: "arrow.clockwise")
                        }
                        .disabled(identity == nil)
                    }
                }
                .padding(.top, DesignTokens.space4)
            }
            .padding(.vertical, DesignTokens.space4)
        } header: {
            Text("sync_identity_section".localized)
        } footer: {
            Text("sync_identity_footer".localized)
        }
    }

    // MARK: - c 连接状态区（原 `MacSyncView+Connection.swift` 的 A 区，随设备语义迁到本页）

    @ViewBuilder
    private var connectionSection: some View {
        // 2026-09-20 批 6-8：中心迁 `@Observable` 后视图改环境注入，`$hostCenter.…` 不再可用
        // （计算属性不可投影）⇒ 局部 `@Bindable`（与 MacEQSettingsView 同款既有写法），双向写回保留。
        @Bindable var center = hostCenter
        Section {
            if let peer = model.connectedPeer {
                connectedRow(peer)
            } else {
                Label(connectionHint, systemImage: "wifi.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Toggle("sync_run_allow_lan".localized, isOn: $center.allowsLANConnections)

            if !model.isListening {
                Text("sync_run_listener_off_hint".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("sync_run_connection_section".localized)
        }
    }

    private func connectedRow(_ peer: SyncConnectedPeer) -> some View {
        HStack(spacing: DesignTokens.space10) {
            Image(systemName: "iphone")
                .font(.system(size: DesignTokens.font18))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(peer.displayName.isEmpty ? "sync_unknown_device".localized : peer.displayName)
                    .fontWeight(.medium)
                HStack(spacing: DesignTokens.space10) {
                    if !peer.peerID.isEmpty {
                        Text("sync_device_id_short".localized(with: DeviceID.formatted(peer.peerID)))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if let duration = model.connectionDurationText {
                        Text("sync_run_connected_for".localized(with: duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .padding(.vertical, DesignTokens.space2)
    }

    /// 未连接提示：一台都没配对 vs 配对了但没连上，指引不同。
    private var connectionHint: String {
        model.startAvailability == .notPaired
            ? "sync_run_not_paired_hint".localized
            : "sync_run_not_connected_hint".localized
    }

    // MARK: - e 已配对设备管理

    @ViewBuilder
    private var pairedDevicesSection: some View {
        Section {
            if devices.isEmpty {
                Text("sync_no_paired_devices".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, DesignTokens.space6)
            } else {
                ForEach(devices, id: \.peerID) { device in
                    deviceRow(device)
                }
            }
        } header: {
            Text("sync_paired_devices".localized)
        }
    }

    private func deviceRow(_ device: PeerDevice) -> some View {
        HStack(spacing: DesignTokens.space10) {
            Image(systemName: device.role == .host ? "macpro.gen3" : "iphone")
                .font(.system(size: DesignTokens.font18))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                HStack(spacing: DesignTokens.space6) {
                    Text(SyncDeviceList.displayName(device))
                        .fontWeight(.medium)
                    roleBadge(device.role)
                }
                Text(SyncDeviceList.shortIDText(device) ?? device.peerID)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(lastSeenText(device))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Menu {
                Button(role: .destructive) {
                    pendingUnpair = device
                } label: {
                    Label("sync_unpair".localized, systemImage: "minus.circle")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, DesignTokens.space2)
    }

    private func roleBadge(_ role: PeerRole) -> some View {
        Text(role == .host ? "sync_role_host".localized : "sync_role_client".localized)
            .font(.caption2)
            .padding(.horizontal, DesignTokens.space6)
            .padding(.vertical, DesignTokens.space2)
            .background(role == .host ? Color.blue.opacity(0.14) : Color.green.opacity(0.14), in: Capsule())
    }

    /// 最后在线文案：从未成功连接（lastSeenAt == pairedAt，M2 起才刷新）
    /// 显示「配对于 …」，否则显示相对时间。
    private func lastSeenText(_ device: PeerDevice) -> String {
        let lastSeen = Date(timeIntervalSince1970: TimeInterval(device.lastSeenAt))
        if device.lastSeenAt == device.pairedAt {
            let paired = Date(timeIntervalSince1970: TimeInterval(device.pairedAt))
            return "sync_paired_at_format".localized(with: paired.formatted(date: .abbreviated, time: .shortened))
        }
        return "sync_last_seen_format".localized(with: lastSeen.formatted(.relative(presentation: .named)))
    }

    // MARK: - d 本次同步目标（批 B2：真控件 + 期望目标/闸门语义）

    @ViewBuilder
    private var deviceTargetSection: some View {
        Section {
            let rows = deviceRows
            if rows.isEmpty {
                Label("sync_devices_empty".localized, systemImage: "iphone.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, DesignTokens.space6)
            } else {
                SyncTargetStatusBanner(status: syncTargetStatus, onAdoptConnected: onAdoptConnected)
                ForEach(rows) { row in
                    deviceTargetRow(row)
                }
            }
        } header: {
            // 页面本身已叫「设备」⇒ 本区标题用「本次同步目标」（既有 key），避免同名重复
            Text("sync_devices_target_badge".localized)
        } footer: {
            Text("sync_devices_footer".localized)
        }
    }

    /// 设备行：**真控件**（批 B2）——选中语义由控件（Button + `.isSelected` 无障碍 trait）
    /// 表达，可键盘焦点/激活；不再用裸 `onTapGesture`（那个既无控件语义也无无障碍语义）。
    /// 离线行常显「怎么把它弄上线」提示——直接回答「为什么不能同步」。
    private func deviceTargetRow(_ row: SyncDeviceTargetRow) -> some View {
        let selected = targetDeviceID == row.peerID
        return Button {
            onSelectTarget(row.peerID)
        } label: {
            HStack(alignment: .top, spacing: DesignTokens.space10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: DesignTokens.space2) {
                    HStack(spacing: DesignTokens.space6) {
                        Text(row.displayName)
                            .fontWeight(selected ? .medium : .regular)
                        statusBadge(row)
                        if selected {
                            Text("sync_devices_target_badge".localized)
                                .font(.caption2)
                                .foregroundStyle(accentColor)
                        }
                    }
                    Text(row.shortCode)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if !row.isOnline {
                        Text("sync_device_offline_hint".localized)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer(minLength: DesignTokens.space0)
            }
            .padding(.vertical, DesignTokens.space4)
            .padding(.horizontal, DesignTokens.space6)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.radius6)
                    .fill(selected ? accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 选中语义交给无障碍：VoiceOver 读得出「这一行是选中的目标」（行内文字已含在线态/
        // 离线提示，不再重复加 hint 避免双重朗读）。
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func statusBadge(_ row: SyncDeviceTargetRow) -> some View {
        Text(row.isOnline ? "sync_device_status_online".localized : "sync_device_status_offline".localized)
            .font(.caption2)
            .padding(.horizontal, DesignTokens.space6)
            .padding(.vertical, DesignTokens.space2)
            .background(
                (row.isOnline ? Color.green : Color.secondary).opacity(0.14),
                in: Capsule()
            )
    }
}

/// 目标状态行（**唯一渲染实现**，三处共用：设备页目标区 / 传歌执行区 / 播放数据动作区）：
///  · 「连上的 ≠ 所选」→ 明说 + 一键改用（不为静默改选）
///  · 选了设备但不在线 → 「等待 <名字> 上线」（直接回答「为什么不能同步」）
/// 判定全在 `SyncDeviceTargetStatus`（纯逻辑），文案/配色属于本层；
/// `onAdoptConnected` 是父的动作（唯一写入口仍在下层）。
struct SyncTargetStatusBanner: View {
    /// 目标状态（决策来自 `SyncDeviceListModel`）。
    let status: SyncDeviceTargetStatus
    /// 「一键改用当前连上的设备」动作（落在父上）。
    let onAdoptConnected: () -> Void

    var body: some View {
        if let mismatch = status.mismatch {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.space8) {
                Label(
                    "sync_target_mismatch_format".localized(
                        with: mismatch.connected.displayName,
                        mismatch.selected.displayName
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

                Button("sync_target_switch".localized(with: mismatch.connected.displayName)) {
                    onAdoptConnected()
                }
                .font(.callout)
                .fixedSize()
            }
            .padding(.vertical, DesignTokens.space2)
        } else if let waitingName = status.waitingName {
            Label("sync_target_waiting".localized(with: waitingName), systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, DesignTokens.space2)
        }
    }
}
