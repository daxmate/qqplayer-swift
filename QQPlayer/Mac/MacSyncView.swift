//
//  MacSyncView.swift
//  QQPlayer
//
//  M6（T3，2026-09-11）macOS「同步」页 —— **同步操作四区**（QQPlayerMac target only）：
//  A 连接状态区 / B 内容选择区（三级）/ C 执行区 / D 结果区（最近一次）。
//
//  与 `MacSyncSettingsView` 的分工：那个文件是同步页的**壳**（配对批准卡 / 本机身份
//  与二维码 / 已配对设备），本文件只补上「真的把歌同步过去」的操作面，由前者在
//  `Form` 内渲染（`MacSyncRunSection`）。⚠️ 新增内容一律放这里，别把 340 行的壳继续吹大。
//
//  纪律：本文件**只做展示**——能不能开始 / 现在什么阶段 / 进度多少 / 结果怎么算，
//  全部来自 `MacSyncRunViewModel` + `SyncUIState`（纯逻辑，有单测）。View 里不写判断。
//
//  macOS 13 兼容：不使用 macOS 14+ API（`onChange` 单参数闭包、不用
//  `ContentUnavailableView`）。
//

import SwiftUI

/// 同步操作四区（在 `MacSyncSettingsView` 的 `Form` 内渲染）。
struct MacSyncRunSection: View {
    @ObservedObject var hostCenter: SyncHostCenter
    @StateObject private var model: MacSyncRunViewModel

    /// 全曲库二次确认（Q4 决策：全库必须确认）。
    @State private var showLibraryWideConfirm = false
    /// 二次确认文案里的规模（弹框时现算）。
    @State private var libraryWidePreview: SyncUISelectionSummary = .empty
    /// 失败清单展开态。
    @State private var showFailures = false
    /// 单曲搜索防抖任务。
    @State private var searchTask: Task<Void, Never>?

    /// ⚠️ 默认值是 `nil` 而不是 `.shared`：View 的 init 是非隔离上下文，
    /// 默认实参里直接引用 `@MainActor` 的 `.shared` 会报隔离错报（Swift 6 下是错误）
    /// （与 `MacSyncRunViewModel` 同一处理）。
    @MainActor
    init(hostCenter: SyncHostCenter? = nil) {
        let center = hostCenter ?? .shared
        _hostCenter = ObservedObject(wrappedValue: center)
        _model = StateObject(wrappedValue: MacSyncRunViewModel(hostCenter: center))
    }

    var body: some View {
        Group {
            connectionSection
            selectionSection
            runSection
            resultSection
        }
        .onAppear { model.onAppear() }
        .onDisappear {
            searchTask?.cancel()
            model.onDisappear()
        }
        .confirmationDialog(
            "sync_run_library_confirm_title".localized,
            isPresented: $showLibraryWideConfirm,
            titleVisibility: .visible
        ) {
            Button("sync_run_library_confirm_action".localized) {
                model.setLibraryWide()
            }
            Button(Localized.cancel, role: .cancel) {}
        } message: {
            Text(
                "sync_run_library_confirm_message".localized(
                    with: libraryWidePreview.sizeText,
                    libraryWidePreview.trackCount
                )
            )
        }
        .alert(
            "sync_load_failed_title".localized,
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button(Localized.ok) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    // MARK: - A 连接状态区

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            if let peer = model.connectedPeer {
                connectedRow(peer)
            } else {
                Label(connectionHint, systemImage: "wifi.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Toggle("sync_run_allow_lan".localized, isOn: $hostCenter.allowsLANConnections)

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
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName.isEmpty ? "sync_unknown_device".localized : peer.displayName)
                    .fontWeight(.medium)
                HStack(spacing: 10) {
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
        .padding(.vertical, 2)
    }

    /// 未连接提示：一台都没配对 vs 配对了但没连上，指引不同。
    private var connectionHint: String {
        model.startAvailability == .notPaired
            ? "sync_run_not_paired_hint".localized
            : "sync_run_not_connected_hint".localized
    }

    // MARK: - B 内容选择区

    @ViewBuilder
    private var selectionSection: some View {
        Section {
            Picker("", selection: modeBinding) {
                Text("sync_run_mode_library".localized).tag(SyncUISelectionMode.library)
                Text("sync_run_mode_playlists".localized).tag(SyncUISelectionMode.playlists)
                Text("sync_run_mode_tracks".localized).tag(SyncUISelectionMode.tracks)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch model.selectionMode {
            case .library:
                libraryRow
            case .playlists:
                playlistList
            case .tracks:
                trackList
            }

            selectionTotals
        } header: {
            Text("sync_run_selection_section".localized)
        } footer: {
            Text("sync_run_selection_footer".localized)
        }
    }

    /// 模式切换：全曲库先弹二次确认，用户在确认框里点头才真正切过去。
    private var modeBinding: Binding<SyncUISelectionMode> {
        Binding(
            get: { model.selectionMode },
            set: { mode in
                switch mode {
                case .library:
                    libraryWidePreview = model.libraryWidePreview()
                    showLibraryWideConfirm = true
                case .playlists:
                    model.setPlaylistsMode()
                case .tracks:
                    model.setTracksMode()
                }
            }
        )
    }

    private var libraryRow: some View {
        let selected = model.selection.isLibraryWide
        let summary = model.selectionSummary
        return HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("sync_run_library_row_title".localized)
                Text(
                    selected
                        ? "sync_run_library_row_detail".localized(with: summary.trackCount, summary.sizeText)
                        : "sync_run_library_row_hint".localized
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !selected else { return }
            libraryWidePreview = model.libraryWidePreview()
            showLibraryWideConfirm = true
        }
    }

    @ViewBuilder
    private var playlistList: some View {
        if model.playlistOptions.isEmpty {
            Text("sync_run_playlists_empty".localized)
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.playlistOptions) { option in
                    Toggle(isOn: playlistBinding(option.id)) {
                        HStack(spacing: 8) {
                            Text(option.title)
                            Spacer()
                            Text("sync_run_songs_count".localized(with: option.trackCount))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private func playlistBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedPlaylistIDs.contains(id) },
            set: { isOn in
                guard isOn != model.selectedPlaylistIDs.contains(id) else { return }
                model.togglePlaylist(id)
            }
        )
    }

    @ViewBuilder
    private var trackList: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("sync_run_track_search_placeholder".localized, text: $model.trackQuery)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.trackQuery) { _ in
                    searchTask?.cancel()
                    searchTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        model.reloadTracks(reset: true)
                    }
                }

            if model.trackOptions.isEmpty {
                Text(
                    model.isLoadingTracks
                        ? "sync_run_tracks_loading".localized
                        : "sync_run_tracks_empty".localized
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(model.trackOptions) { option in
                            Toggle(isOn: trackBinding(option.relativePath)) {
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(option.title)
                                        if let artist = option.artistName, !artist.isEmpty {
                                            Text(artist)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if let size = option.fileSize, size > 0 {
                                        Text(SyncUISizeText.humanReadable(bytes: size))
                                            .font(.caption)
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }
                .frame(maxHeight: 240)

                if model.hasMoreTracks {
                    Button("sync_run_tracks_load_more".localized) {
                        model.reloadTracks(reset: false)
                    }
                }
            }
        }
    }

    private func trackBinding(_ relativePath: String) -> Binding<Bool> {
        Binding(
            get: { model.selectedTrackPaths.contains(relativePath) },
            set: { isOn in
                guard isOn != model.selectedTrackPaths.contains(relativePath) else { return }
                model.toggleTrack(relativePath)
            }
        )
    }

    @ViewBuilder
    private var selectionTotals: some View {
        let summary = model.selectionSummary
        VStack(alignment: .leading, spacing: 2) {
            if summary.isEmpty {
                Text("sync_run_selection_empty".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(selectionTotalText)
                    .font(.callout)
                    .fontWeight(.medium)
                if summary.isBytesPartial {
                    Text("sync_run_selection_partial_size".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !summary.unknownPlaylistIDs.isEmpty {
                    Text("sync_run_unknown_playlists".localized(with: summary.unknownPlaylistIDs.count))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.top, 2)
    }

    private var selectionTotalText: String {
        let summary = model.selectionSummary
        if summary.isLibraryWide {
            return "sync_run_selection_total_library".localized(with: summary.trackCount, summary.sizeText)
        }
        if summary.playlistCount > 0 {
            return "sync_run_selection_total_playlists".localized(
                with: summary.playlistCount,
                summary.trackCount,
                summary.sizeText
            )
        }
        return "sync_run_selection_total_tracks".localized(with: summary.trackCount, summary.sizeText)
    }

    // MARK: - C 执行区

    @ViewBuilder
    private var runSection: some View {
        Section {
            HStack(spacing: 12) {
                if model.phase.isBusy {
                    Button("sync_run_cancel".localized, role: .destructive) {
                        model.cancelSync()
                    }
                } else {
                    Button("sync_run_start".localized) {
                        model.startSync()
                    }
                    .disabled(!model.startAvailability.canStart)
                }

                Text(phaseText)
                    .font(.callout)
                    .foregroundStyle(model.failureText == nil ? Color.secondary : Color.red)

                Spacer()
            }

            if model.phase.isBusy {
                ProgressView(value: model.progress.isDeterminate ? model.progress.fraction : nil)
                Text(progressText)
                    .font(.callout)
                if let path = model.progress.currentPath {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let failure = model.failureText, !model.phase.isBusy {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.phase.isBusy, let reason = availabilityHint {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("sync_run_execute_section".localized)
        }
    }

    /// 阶段文案（非失败态）。
    private var phaseText: String {
        switch model.phase {
        case .disconnected: return "sync_run_phase_disconnected".localized
        case .idle: return "sync_run_phase_idle".localized
        case .planning: return "sync_run_progress_planning".localized
        case .pushing, .pulling: return progressText
        case .done: return "sync_run_progress_done".localized
        case .failed: return model.failureText ?? ""
        }
    }

    /// 传输计数文案（"正在推送 37/128"）。
    private var progressText: String {
        let progress = model.progress
        switch progress.direction {
        case .push:
            return "sync_run_progress_push".localized(with: progress.clampedCompleted, progress.total)
        case .pull:
            return "sync_run_progress_pull".localized(with: progress.clampedCompleted, progress.total)
        case .none:
            return "sync_run_progress_planning".localized
        }
    }

    /// 不能开始的原因（可开始 / 同步中 = nil）。
    private var availabilityHint: String? {
        switch model.startAvailability {
        case .ready, .alreadyRunning:
            return nil
        case .notPaired:
            return "sync_run_reason_not_paired".localized
        case .notConnected:
            return "sync_run_reason_not_connected".localized
        case .libraryUnavailable:
            return "sync_run_reason_library_unavailable".localized
        case .emptySelection:
            return "sync_run_reason_empty_selection".localized
        }
    }

    // MARK: - D 结果区

    @ViewBuilder
    private var resultSection: some View {
        Section {
            if let report = model.reportSummary {
                if report.isEmptySelection {
                    Text("sync_run_result_empty_selection".localized)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 24) {
                        metric("sync_run_result_pushed".localized, report.pushedCount, .primary)
                        metric("sync_run_result_pulled".localized, report.pulledCount, .primary)
                        metric("sync_run_result_skipped".localized, report.skippedCount, .secondary)
                        metric(
                            "sync_run_result_failed".localized,
                            report.failedCount,
                            report.failedCount > 0 ? .red : .secondary
                        )
                        Spacer()
                    }
                    .padding(.vertical, 2)

                    if report.unresolvedCount > 0 {
                        Text("sync_run_result_unresolved".localized(with: report.unresolvedCount))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !report.unknownPlaylistIDs.isEmpty {
                        Text("sync_run_unknown_playlists".localized(with: report.unknownPlaylistIDs.count))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if report.failedCount > 0 {
                        failureDisclosure(report)
                    }
                }
            } else {
                Text("sync_run_result_none".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text("sync_run_result_no_deletion".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("sync_run_result_section".localized)
        }
    }

    private func metric(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
    }

    private func failureDisclosure(_ report: SyncUIReportSummary) -> some View {
        DisclosureGroup(
            isExpanded: $showFailures,
            content: {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(report.failedItems) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: item.isPush ? "arrow.up.circle" : "arrow.down.circle")
                                .foregroundStyle(.red)
                            Text(item.relativePath.isEmpty ? item.reason : item.relativePath)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(SyncUIFailureReasonText.key(for: item.reason).localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            },
            label: {
                Text("sync_run_result_failures_header".localized(with: report.failedCount))
                    .font(.callout)
            }
        )
    }
}

#Preview {
    Form {
        MacSyncRunSection()
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 720)
}
