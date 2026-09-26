//
//  SyncDevicePane.swift
//  QQPlayer
//
//  「设备」页（2026-09-26 批 B1「拆 Pane + 顶层两页」；QQPlayerMac target only）。
//
//  页面内容（用户 2026-09-26 拍板，低频/配置面）：
//   · 待批准请求（`pairingApprovalSection`，有请求时置顶）
//   · 本机身份与二维码（`identitySection`：本机名字 + Device ID + 二维码 + 刷新）
//   · 连接状态（`connectionSection`：已连对端行的状态/时长 + 「允许局域网连接」开关 + 监听提示）
//   · 已配对设备（`pairedDevicesSection`：在线态 / 最后在线 / 撤销配对）
//   · 本次同步目标（`deviceTargetSection`：单选；**本批仍是假控件**，真化属批 B2）
//
//  ⚠️ R3「设备只讲一次」：设备信息与配对操作**只出现在本页**，「同步」页不重复
//  （拆分前 A 连接状态区在同步四区之首，本批随设备语义整体迁到本页）。
//
//  ⚠️ R2「本批不修假控件」：`deviceTargetRow` 的 `onTapGesture { targetDeviceID = row.peerID }`
//  **逐字保留**（只写本地选中态，不驱动任何 model 调用）——本批只把它**搬进**本文件，
//  真化留批 B2。
//
//  ⚠️ 为什么本 Pane 是 `MacSyncRunSection` 的 extension 而不是独立 struct：三个
//  ViewModel 仍是 `ObservableObject`（`@Observable` 迁移未覆盖），子视图要拿活的重绘就得写
//  `@ObservedObject`/`@StateObject` → 命中 `ObservationMigrationContractTests` 的
// 「新增 (文件, 标记) 即红」棘轮。extension 是唯一零新增标记、零行为改变的拆法
//  （详见 `MacSyncView.swift` 文件头）。
//
//  可见性：只在本文件使用的成员仍保持 `private`；被 `body`（`MacSyncView.swift`）引用的
//  `devicePane` 为 internal。
//

import SwiftUI

extension MacSyncRunSection {
    // MARK: - 「设备」页

    var devicePane: some View {
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
                        reloadDevices()
                    },
                    onReject: {
                        hostCenter.rejectPending()
                        reloadDevices()
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
                            refreshQR()
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
    var connectionSection: some View {
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

    // MARK: - d 本次同步目标（批 B2 真化前：假控件，逐字保留现有行为）

    /// 行模型（过滤 + 在线态 + 短码，决策全在 `SyncDeviceListModel`）。
    private var deviceRows: [SyncDeviceTargetRow] {
        SyncDeviceListModel.rows(
            in: devices,
            onlinePeerID: hostCenter.connectedPeer?.peerID
        )
    }

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

    /// 设备行：单选（勾 + 底色，与方向区/全曲库行同一视觉语言）。
    /// 离线行常显「怎么把它弄上线」提示——直接回答「为什么不能同步」。
    private func deviceTargetRow(_ row: SyncDeviceTargetRow) -> some View {
        let selected = targetDeviceID == row.peerID
        return HStack(alignment: .top, spacing: DesignTokens.space10) {
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
        .onTapGesture { targetDeviceID = row.peerID }
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
