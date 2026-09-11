//
//  SyncSettingsView.swift
//  QQPlayer
//
//  局域网同步（S2, M1-UI）iOS 同步设置页（docs §10 Client 侧）：
//  1. 本机 Device ID（短格式；本端是移动端身份，展示便于主机核对/手输反向配对）
//  2. 已配对主机列表（role == .host 的记录，可删除 = 撤销配对）
//  3. 添加入口：扫码（AVCaptureSession → receivedQR 流程）/ 手输 ID
//
//  数据源纯函数统一走 SyncDeviceList（行为单一事实源）：hosts 过滤 /
//  短 ID 展示；本页只做呈现与删除动作。
//

import SwiftUI

/// iOS 同步设置页。
struct SyncSettingsView: View {
    @State private var identity: SyncIdentity?
    @State private var identityError: String?
    @State private var hosts: [PeerDevice] = []
    @State private var loadError: String?
    @State private var pendingUnpair: PeerDevice?
    /// App 级被动同步中心（Mac 推送接收状态；T4/T5）
    @ObservedObject private var passiveSync = IOSPassiveSyncCenter.shared

    private let deviceStore = DeviceStore()

    var body: some View {
        settingsList
            .alert(
                "sync_load_failed_title".localized,
                isPresented: Binding(
                    get: { loadError != nil },
                    set: { if !$0 { loadError = nil } }
                )
            ) {
                Button(Localized.ok) {}
            } message: {
                Text(loadError ?? "")
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

    private var settingsList: some View {
        List {
            // MARK: 接收同步（Mac → 本机推送的落地状态）
            Section {
                passiveSyncRow
            } header: {
                Text("sync_passive_section".localized)
            } footer: {
                Text("sync_passive_footer".localized)
            }

            // MARK: 本机
            Section {
                if let identity {
                    LabeledContent("sync_this_device".localized) {
                        Text("sync_device_id_short".localized(with: shortID(identity.deviceID)))
                            .font(.system(.subheadline, design: .monospaced))
                            .textSelection(.enabled)
                    }
                } else if identityError != nil {
                    Text(identityError ?? "")
                        .font(.callout)
                        .foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            } header: {
                Text("sync_this_device_section".localized)
            } footer: {
                Text("sync_client_identity_footer".localized)
            }

            // MARK: 已配对主机
            Section {
                if hosts.isEmpty {
                    Text("sync_no_paired_hosts".localized)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hosts, id: \.peerID) { device in
                        hostRow(device)
                    }
                    .onDelete { offsets in
                        unpairHosts(at: offsets)
                    }
                }
            } header: {
                Text("sync_paired_hosts".localized)
            }

            // MARK: 添加主机
            Section {
                NavigationLink {
                    SyncQRScannerView()
                } label: {
                    Label("sync_scan_qr".localized, systemImage: "qrcode.viewfinder")
                }
                NavigationLink {
                    SyncManualEntryView()
                } label: {
                    Label("sync_manual_input".localized, systemImage: "keyboard")
                }
            } header: {
                Text("sync_add_host".localized)
            } footer: {
                Text("sync_add_host_footer".localized)
            }
        }
        .navigationTitle("sync_settings".localized)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadIdentityIfNeeded()
            reloadHosts()
            // 幂等：进页时确保被动端在跑（配对完成后也由此重新检查主机）
            passiveSync.start()
        }
    }

    // MARK: - 接收同步状态

    private var passiveSyncRow: some View {
        let presentation = IOSPassiveSyncPresenter.presentation(
            state: passiveSync.state,
            summary: passiveSync.summary,
            hasPairedHost: passiveSync.pairedHostCount > 0
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: presentation.symbol)
                    .font(.system(size: 20))
                    .foregroundStyle(passiveSync.state.isConnected ? Color.green : Color.secondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(localizedTitle(presentation))
                        .fontWeight(.medium)
                    if let detail = localizedDetail(presentation) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if presentation.canReconnect {
                    Button("sync_passive_reconnect".localized) {
                        passiveSync.reconnectNow()
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                }
            }

            if presentation.receivedFiles > 0 {
                Text("sync_passive_progress_received".localized(with: presentation.receivedFiles))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if presentation.lastBatchEntries > 0 {
                Text("sync_passive_progress_batch".localized(with: presentation.lastBatchEntries))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !presentation.failures.isEmpty {
                Text("sync_passive_progress_failures".localized(with: presentation.failures.count))
                    .font(.caption)
                    .foregroundStyle(.red)
                ForEach(Array(presentation.failures.prefix(3).enumerated()), id: \.offset) { _, failure in
                    Text(failureLine(failure))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func localizedTitle(_ presentation: IOSPassiveSyncPresentation) -> String {
        guard let arg = presentation.titleArg else { return presentation.titleKey.localized }
        return presentation.titleKey.localized(with: arg)
    }

    private func localizedDetail(_ presentation: IOSPassiveSyncPresentation) -> String? {
        guard let key = presentation.detailKey else { return nil }
        guard let arg = presentation.detailArg else { return key.localized }
        return key.localized(with: arg)
    }

    private func failureLine(_ failure: SyncPushFailure) -> String {
        let path = failure.relativePath.isEmpty ? "—" : failure.relativePath
        return "\(path) · \(IOSPassiveSyncPresenter.reasonKey(failure.reason).localized)"
    }

    // MARK: - 行

    private func hostRow(_ device: PeerDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "macpro.gen3")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(SyncDeviceList.displayName(device))
                    .fontWeight(.medium)
                Text(SyncDeviceList.shortIDText(device) ?? device.peerID)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                pendingUnpair = device
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
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

    private func reloadHosts() {
        do {
            hosts = SyncDeviceList.hosts(in: try deviceStore.all())
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func unpairHosts(at offsets: IndexSet) {
        for index in offsets where hosts.indices.contains(index) {
            unpair(hosts[index])
        }
    }

    private func unpair(_ device: PeerDevice) {
        do {
            try deviceStore.remove(peerID: device.peerID)
            reloadHosts()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func shortID(_ fullID: String) -> String {
        guard let parts = DeviceID.shortComparisonParts(fullID) else { return fullID }
        return "\(parts.first)…\(parts.last)"
    }
}

#Preview {
    NavigationView {
        SyncSettingsView()
    }
}
