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
    /// 本机展示名（进入页面/保存后从 `LocalDeviceNameStore` 刷新；用户可改）
    @State private var deviceName = ""
    @State private var hosts: [PeerDevice] = []
    @State private var loadError: String?
    @State private var pendingUnpair: PeerDevice?
    /// App 级被动同步中心（Mac 推送接收状态；T4/T5）
    /// 2026-09-19 批 2：由组合根（`QQPlayerApp`）环境注入，不再直连 `.shared`。
    @Environment(IOSPassiveSyncCenter.self) private var passiveSync
    /// 运行时装配自检事实（L5：本端声明的能力真的装配上了吗；缺口 = 0 时面板空态）
    /// 2026-09-20 批 6-8：迁 `@Observable` ⇒ 改环境注入（组合根 `QQPlayerApp` 装配，与 passiveSync 同款）。
    @Environment(SyncWiringFactsStore.self) private var wiringFacts
    /// 歌单自定义封面读取失败的登记（INV-22 另一半：读不到必须计数并上屏）。
    @Environment(PlaylistCoverLoadFailuresStore.self) private var coverFailures
    /// 2026-09-19 批 4：无状态服务入口（组合根 `AppServices` 注入）
    @Environment(AppServices.self) private var services

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

            // MARK: 同步数据（帧 8/9）账目 —— 手机侧也能看见「同步了什么 / 丢了多少」（2026-09-15）
            Section {
                // 装配自检（L5）：缺口 > 0 才显示一行；缺口 = 0 = 空态（判定全在纯逻辑里）。
                if let wiringRow = SyncWiringSelfCheckPresenter.gapRow(wiringFacts.gaps) {
                    wiringSelfCheckRow(wiringRow)
                }
                if passiveSync.dataSummary.hasSessionData {
                    dataSyncSummaryRows
                } else {
                    Text("sync_run_data_result_none".localized)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("sync_run_data_section".localized)
            } footer: {
                Text("sync_run_data_description".localized)
            }

            // MARK: 本机
            Section {
                // 本机名称（用户可改；改的是握手 hello 携带的展示名 → Mac 设备列表显示名）
                NavigationLink {
                    SyncDeviceNameEditorView(initialName: deviceName, store: services.localDeviceName) {
                        deviceName = services.localDeviceName.name
                    }
                } label: {
                    LabeledContent("sync_device_name".localized) {
                        Text(deviceName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
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

            // MARK: 跳端续播（播放位置）——与 Mac 同步面板**同一个设置项**（默认关）
            //
            // 2026-09-15：开关只有面板入口时，手机端读到的永远是默认值（关）——
            // 于是「开一台 = 单向」成为默认事实。这里补上 iOS 入口，两端都开才真正双向。
            // 绑定直接读写 `DeleteSettings`（无本地 @State），避免双源不同步。
            Section {
                Toggle(
                    "sync_run_playback_position_toggle".localized,
                    isOn: Binding(
                        get: { DeleteSettings.load().syncPlaybackPositionEnabled },
                        set: { newValue in
                            var settings = DeleteSettings.load()
                            settings.syncPlaybackPositionEnabled = newValue
                            settings.save()
                        }
                    )
                )
            } footer: {
                Text("sync_run_playback_position_help".localized)
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
            // 本机名称：每次进页都从 store 取值（编辑页返回也走这里刷新）
            deviceName = services.localDeviceName.name
            // 幂等：进页时确保被动端在跑（配对完成后也由此重新检查主机）
            passiveSync.start()
        }
    }

    // MARK: - 装配自检（L5）

    /// 装配自检行：一行说明「缺了什么 / 影响什么」（缺失能力名列表来自探针本地化文案）。
    /// View 不做任何判断——行要不要出现、缺几项，全部来自 `SyncWiringSelfCheckPresenter`。
    private func wiringSelfCheckRow(_ row: SyncWiringSelfCheckPresenter.GapRow) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.space4) {
            Text(row.labelKey.localized(with: row.count))
                .font(.callout)
                .foregroundStyle(.orange)
            Text(row.hintKey.localized(with: row.probeLabelKeys.map { $0.localized }.joined(separator: ", ")))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 数据同步账目（帧 8/9）

    /// 手机侧的同步数据账目：正常计数行 + 缺口行（纯逻辑在 `IOSPassiveDataSyncPresenter`，可单测）。
    /// 复用 Mac 面板已有的 key，不新增文案。
    @ViewBuilder
    private var dataSyncSummaryRows: some View {
        let summary = passiveSync.dataSummary
        ForEach(
            Array(IOSPassiveDataSyncPresenter.countRows(summary).enumerated()),
            id: \.offset
        ) { _, row in
            LabeledContent(row.labelKey.localized) {
                Text("\(row.count)")
                    .foregroundStyle(.secondary)
            }
        }
        ForEach(
            Array(IOSPassiveDataSyncPresenter.gapRows(summary).enumerated()),
            id: \.offset
        ) { _, row in
            VStack(alignment: .leading, spacing: DesignTokens.space4) {
                LabeledContent(row.labelKey.localized) {
                    Text("\(row.count)")
                        .foregroundStyle(.orange)
                }
                if let hintKey = row.hintKey {
                    Text(hintKey.localized(with: row.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        // 按实体披露（INV-18 后半句）：只出计数 > 0 的 (结果, 实体) 行——正常实体不占行。
        // 数字与顺序全部来自唯一投影 `SyncEntityOutcomeDisclosure`（UI 不自算、不枚举实体）。
        let entityRows = SyncEntityOutcomeDisclosure.rows(summary.tally)
        if !entityRows.isEmpty {
            Text(SyncEntityOutcomeDisclosure.breakdownTitleKey.localized)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(Array(entityRows.enumerated()), id: \.offset) { _, row in
                LabeledContent(SyncEntityOutcomeDisclosure.rowLabel(row)) {
                    Text("\(row.count)")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - 接收同步状态

    private var passiveSyncRow: some View {
        let presentation = IOSPassiveSyncPresenter.presentation(
            state: passiveSync.state,
            summary: passiveSync.summary,
            hasPairedHost: passiveSync.pairedHostCount > 0
        )
        return VStack(alignment: .leading, spacing: DesignTokens.space8) {
            HStack(spacing: DesignTokens.space12) {
                Image(systemName: presentation.symbol)
                    .font(.system(size: DesignTokens.font20))
                    .foregroundStyle(passiveSync.state.isConnected ? Color.green : Color.secondary)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: DesignTokens.space2) {
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
            // F2 对齐歌词（2026-09-16）：丢弃 / 保留本端 必须计数上屏。
            // 行与文案 key 全部来自唯一投影 `SyncEntityOutcomeDisclosure.lyricsRows`（UI 不自算）。
            let lyricsRows = SyncEntityOutcomeDisclosure.lyricsRows(
                discarded: passiveSync.summary.discardedLyrics.count,
                pendingResend: 0,
                keptLocal: passiveSync.summary.keptLocalLyrics.count
            )
            if !lyricsRows.isEmpty {
                Text(SyncEntityOutcomeDisclosure.lyricsSectionTitleKey.localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(lyricsRows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: DesignTokens.space4) {
                        LabeledContent(row.labelKey.localized(with: row.count)) {
                            Text("\(row.count)")
                                .foregroundStyle(row.isGap ? Color.orange : Color.secondary)
                        }
                        if let hintKey = row.hintKey {
                            Text(hintKey.localized(with: row.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            // 歌单自定义封面读不到（INV-22 另一半，2026-09-16）：一行说明 + 说明文案。
            // 数字与文案 key 全部来自唯一投影 `SyncEntityOutcomeDisclosure.coverRows`（UI 不自算）。
            let coverRows = SyncEntityOutcomeDisclosure.coverRows(unavailable: coverFailures.count)
            if !coverRows.isEmpty {
                Text(SyncEntityOutcomeDisclosure.coverSectionTitleKey.localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(coverRows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: DesignTokens.space4) {
                        LabeledContent(row.labelKey.localized(with: row.count)) {
                            Text("\(row.count)")
                                .foregroundStyle(row.isGap ? Color.orange : Color.secondary)
                        }
                        if let hintKey = row.hintKey {
                            Text(hintKey.localized(with: row.count))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
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
        .padding(.vertical, DesignTokens.space2)
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
        HStack(spacing: DesignTokens.space12) {
            Image(systemName: "macpro.gen3")
                .font(.system(size: DesignTokens.font20))
                .foregroundStyle(.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: DesignTokens.space2) {
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
        .padding(.vertical, DesignTokens.space2)
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
    // Preview 是组合根之外的第二个合法装配点（App 根注入不覆盖画布）→ 显式装配。
    // 代价：这两行占棘轮预算（预算账本见 QQPlayerTests/Fixtures/shared-singleton-budget-plan.md）。
    .environment(IOSPassiveSyncCenter.shared)
    .environment(PlaylistCoverLoadFailuresStore.shared)
    // 批 6-8：装配自检事实 store 迁 `@Observable` ⇒ 本页改环境注入，预览需显式装配。
    .environment(SyncWiringFactsStore.shared)
}
