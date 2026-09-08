//
//  MacSyncSettingsView.swift
//  QQPlayer
//
//  局域网同步（S2, M1-UI）macOS「同步」设置分类（Host 侧同步中心）：
//  1. 本机身份与二维码：设备名 + Device ID（分组展示）+ 二维码 + 刷新。
//     QR 内容 = PairQRPayload JSON（hostName = 本机名；sessionNonce 每次
//     展示新码重新生成）。⚠️ nonce 生命周期/过期归 PairingStateMachine
//     （M2a 起扫码方带 nonce 回来做防重放校验），本页只生成载荷不追踪。
//  2. 已配对设备：DeviceStore.all()（displayName + ID 短格式 + role +
//     最后在线），可删除（撤销配对 = 删除信任记录，确认后 remove）。
//  3. 配对请求批准卡片由 MacPairApprovalCardView 提供（可复用组件；
//     M2a 网络请求源接通前无真实触发路径，本页不实例化）。
//
//  入口：MacSettingsView 左导航「同步」分类（最小侵入：仅加 category）。
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI

/// macOS 同步中心设置页（QQPlayerMac target only）。
struct MacSyncSettingsView: View {
    @State private var identity: SyncIdentity?
    @State private var identityError: String?
    @State private var qrPayload: PairQRPayload?
    @State private var qrImage: NSImage?
    @State private var devices: [PeerDevice] = []
    @State private var devicesError: String?
    /// 待撤销配对的设备（nil = 无待确认删除）
    @State private var pendingUnpair: PeerDevice?

    private let deviceStore = DeviceStore()

    /// 本机展示名（QR hostName 字段；Bonjour 友好名优先，回落到进程主机名）
    private var hostName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    var body: some View {
        Form {
            // MARK: 本机身份与二维码
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

            // MARK: 已配对设备
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
        .formStyle(.grouped)
        .onAppear {
            loadIdentityIfNeeded()
            reloadDevices()
        }
        .alert(
            "sync_load_failed_title".localized,
            isPresented: Binding(
                get: { identityError != nil || devicesError != nil },
                set: { if !$0 { identityError = nil; devicesError = nil } }
            )
        ) {
            Button(Localized.ok) {}
        } message: {
            Text(identityError ?? devicesError ?? "")
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

    // MARK: - 行

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
            refreshQR()
        } catch {
            identityError = error.localizedDescription
        }
    }

    /// 生成新 nonce + 载荷并重绘二维码（每次调用换一张新码）。
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
    MacSyncSettingsView()
        .frame(width: 560, height: 640)
}
