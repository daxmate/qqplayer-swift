//
//  MacSyncCenterView.swift
//  QQPlayer
//
//  局域网同步（S2, M6 T11, 2026-09-12）macOS **同步中心**——两个入口共用的唯一实现：
//  ①「设置 → 同步」（`MacSyncSettingsView`）② 主窗口工具栏「同步」面板
//  （`MacLibraryView.MacSyncPanel`）。两处**渲染同一个 View 类型**，不存在第二份实现
//  （「设置里一套、主界面一套」的行为漂移是封面解析散落多处的老教训）。
//
//  分区（自上而下）：
//  a. 配对批准卡（`SyncHostCenter.shared.pendingCard` 非空时置顶；批准/拒绝后刷新设备）
//  b. **设备区**（本次同步目标单选；已配对移动设备 + 在线/离线 + 短码）
//  c. `MacSyncRunSection`（方向 / 内容 / 执行 / 结果四区，原样复用，本文件不改其语义）
//  d. 本机身份与二维码（设备名 + Device ID + 二维码 + 刷新；QR 内容 = PairQRPayload）
//  e. 已配对设备管理（含撤销配对确认）
//
//  ⚠️ 回调唯一性：`SyncHostCenter.onDevicesChanged` 是**单槽**回调（后挂的顶掉先挂的）。
//  本视图是两个入口的共同实现 → 全 App 只有这里挂它；若在宿主（设置页/面板）另挂一处，
//  另一处就不会刷新。列表刷新一律走本文件的 `reloadDevices()`。
//
//  状态来源：监听生命周期归 App 级 `SyncHostCenter.shared`（App 启动即 start），
//  本视图只做控制面（读状态 / 展示批准卡 / 注册 QR nonce / 选目标 / 批准或拒绝）。
//  设备区的选中决策在 `SyncDeviceListModel`（纯逻辑，有单测），本文件不写判断。
//
//  macOS 13 兼容：不使用 macOS 14+ API（`onChange` 单参数闭包、`ContentUnavailableView`）。
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI

/// macOS 同步中心（设置页「同步」分类 + 工具栏同步面板共用）。
struct MacSyncCenterView: View {
    @State private var identity: SyncIdentity?
    @State private var identityError: String?
    @State private var qrPayload: PairQRPayload?
    @State private var qrImage: NSImage?
    @State private var devices: [PeerDevice] = []
    @State private var devicesError: String?
    /// 待撤销配对的设备（nil = 无待确认删除）
    @State private var pendingUnpair: PeerDevice?
    /// 设备区选中项（= 本次同步目标；存 peerID，选中决策见 `SyncDeviceListModel`）
    @State private var targetDeviceID: String?
    /// S2 接线：App 级 Host 监听中心（**同一个 shared 实例**，生命周期不归本视图）
    @ObservedObject private var hostCenter = SyncHostCenter.shared

    private let deviceStore = DeviceStore()

    /// 本机展示名（QR hostName 字段；Bonjour 友好名优先，回落到进程主机名）
    private var hostName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    var body: some View {
        Group {
            pairingApprovalSection
            deviceTargetSection
            // MARK: 同步操作四区（M6 T3：连接状态 / 方向 / 内容选择 / 执行 / 结果）
            MacSyncRunSection(hostCenter: hostCenter)
            identitySection
            pairedDevicesSection
        }
        .onAppear {
            loadIdentityIfNeeded()
            // 监听生命周期归 SyncHostCenter（App 启动即常驻）；本视图只挂控制面回调。
            // ⚠️ 单槽回调：整个 App 仅此一处挂接（两个入口共用本视图）。
            hostCenter.onDevicesChanged = { [self] in
                reloadDevices()
            }
            reloadDevices()
            // 展示首张 QR（identity 就绪才生成；nonce 注册见 refreshQR）
            refreshQR()
        }
        // 连接状态变化（移动端连上/断开）→ 重算在线态与默认选中
        .onChange(of: hostCenter.connectedPeer?.peerID) { _ in
            syncTargetSelection()
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
        .confirmationDialog(
            "sync_unpair_confirm_title".localized,
            isPresented: Binding(
                get: { pendingUnpair != nil },
                set: { if !$0 { pendingUnpair = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingUnpair
        ) { device in
            Button("sync_unpair".localized, role: .destructive) {
                unpair(device)
            }
            Button(Localized.cancel, role: .cancel) {}
        } message: { device in
            Text("sync_unpair_confirm_message".localized(with: SyncDeviceList.displayName(device)))
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
                .padding(.vertical, 4)
            } header: {
                Text("sync_pairing_request_header".localized)
            }
        }
    }

    // MARK: - b 设备区（本次同步目标）

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
                    .padding(.vertical, 6)
            } else {
                ForEach(rows) { row in
                    deviceTargetRow(row)
                }
            }
        } header: {
            Text("sync_devices_section".localized)
        } footer: {
            Text("sync_devices_footer".localized)
        }
    }

    /// 设备行：单选（勾 + 底色，与方向区/全曲库行同一视觉语言）。
    /// 离线行常显「怎么把它弄上线」提示——直接回答「为什么不能同步」。
    private func deviceTargetRow(_ row: SyncDeviceTargetRow) -> some View {
        let selected = targetDeviceID == row.peerID
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.displayName)
                        .fontWeight(selected ? .medium : .regular)
                    statusBadge(row)
                    if selected {
                        Text("sync_devices_target_badge".localized)
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
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

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { targetDeviceID = row.peerID }
    }

    private func statusBadge(_ row: SyncDeviceTargetRow) -> some View {
        Text(row.isOnline ? "sync_device_status_online".localized : "sync_device_status_offline".localized)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                (row.isOnline ? Color.green : Color.secondary).opacity(0.14),
                in: Capsule()
            )
    }

    // MARK: - d 本机身份与二维码

    @ViewBuilder
    private var identitySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
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

                HStack(alignment: .center, spacing: 20) {
                    if let qrImage {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 168, height: 168)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .frame(width: 168, height: 168)
                            .overlay(
                                Image(systemName: "qrcode")
                                    .font(.system(size: 40))
                                    .foregroundStyle(.secondary)
                            )
                    }

                    VStack(alignment: .leading, spacing: 8) {
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
                .padding(.top, 4)
            }
            .padding(.vertical, 4)
        } header: {
            Text("sync_identity_section".localized)
        } footer: {
            Text("sync_identity_footer".localized)
        }
    }

    // MARK: - e 已配对设备管理

    @ViewBuilder
    private var pairedDevicesSection: some View {
        Section {
            if devices.isEmpty {
                Text("sync_no_paired_devices".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
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
        HStack(spacing: 10) {
            Image(systemName: device.role == .host ? "macpro.gen3" : "iphone")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
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
        .padding(.vertical, 2)
    }

    private func roleBadge(_ role: PeerRole) -> some View {
        Text(role == .host ? "sync_role_host".localized : "sync_role_client".localized)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
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

    // MARK: - 数据

    private func loadIdentityIfNeeded() {
        guard identity == nil else { return }
        do {
            identity = try SyncIdentityStore().loadOrCreateIdentity()
        } catch {
            identityError = error.localizedDescription
        }
    }

    /// 生成新 nonce + 载荷并重绘二维码（每次调用换一张新码）。
    /// S2 接线：新码的 sessionNonce 同步注册进运行中的监听器（不注册则
    /// 客户端带签名 nonce 回连时验签无源 → 配对必被拒）。
    /// 监听器未运行（开关关闭 / 启动失败）时静默忽略（与旧行为一致）。
    @MainActor
    private func refreshQR() {
        guard let identity else { return }
        let payload = PairQRPayloadFactory.make(
            hostName: hostName,
            identity: identity,
            sessionNonce: SyncSessionNonce.makeNew()
        )
        do {
            let json = try SyncQRCodec.encode(payload)
            qrPayload = payload
            qrImage = SyncQRImageFactory.make(from: json)
            hostCenter.registerQRNonce(nonceBase64: payload.sessionNonce)
        } catch {
            identityError = error.localizedDescription
        }
    }

    private func reloadDevices() {
        do {
            devices = try deviceStore.all()
        } catch {
            devicesError = error.localizedDescription
        }
        syncTargetSelection()
    }

    /// 设备列表 / 连接状态变化后重算选中（在线优先、原选中仍在则保持）。
    private func syncTargetSelection() {
        targetDeviceID = SyncDeviceListModel.reconciledSelection(
            targetDeviceID,
            in: SyncDeviceListModel.rows(in: devices, onlinePeerID: hostCenter.connectedPeer?.peerID)
        )
    }

    private func unpair(_ device: PeerDevice) {
        do {
            try deviceStore.remove(peerID: device.peerID)
            reloadDevices()
        } catch {
            devicesError = error.localizedDescription
        }
    }
}

/// QR 码生成（CoreImage CIQRCodeGenerator，无新依赖；仅 macOS 展示用）。
enum SyncQRImageFactory {
    /// JSON 文本 → NSImage（4px/模块缩放到 ~520px 展示清晰）。
    static func make(from text: String, scale: CGFloat = 4) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

#Preview {
    Form {
        MacSyncCenterView()
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 640)
}
