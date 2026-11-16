//
//  MacSyncView+Content.swift
//  QQPlayer
//
//  `MacSyncRunSection` 的 C 内容选择区（2026-09-19 从 `MacSyncView.swift` 纯搬家，
//  零行为/UI 变化）：对端概要行、内容模式（曲库/歌单/智能源）、智能源与歌单分组、
//  曲目列表行、加载/失败行、选择合计与二次确认文案投影。
//
//  T10 语义（2026-09-12）不变：内容面板随**方向**切数据源——上传 = 本端 Mac，
//  下载 = 对端 iPhone；未选方向时只显示引导。
//  纪律不变：本文件只做展示——内容源/选项/选择集/合计全来自 `MacSyncContentModel`
//  （纯逻辑，有单测），View 里不写判断。
//
//  ⚠️ 可见性：被 `body` 或其它分区文件引用的成员为 internal（原 `private`）；
//  仅本文件内使用的辅助成员仍保持 `private`。
//

import SwiftUI

extension MacSyncRunSection {
    // MARK: - C 内容选择区（随方向切数据源）

    @ViewBuilder
    var selectionSection: some View {
        Section {
            if !content.hasDirection {
                // 方向未选：**不显示任何一端的内容**（T10 核心修复点）。
                Label("sync_run_direction_hint".localized, systemImage: "arrow.up.arrow.down.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if content.needsPeerConnection {
                Label("sync_run_peer_needs_connection".localized, systemImage: "wifi.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                emptySelectionGuide
                if content.source == .peer {
                    peerSummaryRow
                }
                contentModePicker
                switch content.selectionMode {
                case .library:
                    libraryRow
                case .playlists:
                    playlistList
                case .tracks:
                    trackList
                }
                selectionTotals
            }
        } header: {
            Text(contentHeader)
        } footer: {
            Text("sync_run_selection_footer".localized)
        }
    }

    // MARK: - 空态引导（P1a：未选内容时给行动入口，替掉死胡同）

    /// 已选方向、但还没选任何内容时的引导卡（内容区顶部）。
    /// ⚠️ 只做**导航**：两个按钮都走现有路径 ——
    /// ① 「同步全曲库」= 现有 `modeBinding`（同一份二次确认，不新写确认框）；
    /// ② 「挑几首歌」= 现有模式切换（搜索框在 `trackList` 里已有）。
    /// 不新增任何统计数字、不显示假数据；未选方向时仍走上面的方向引导，不被本卡覆盖。
    @ViewBuilder
    private var emptySelectionGuide: some View {
        if content.selectionSummary.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.space10) {
                Label("sync_empty_title".localized, systemImage: "tray")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: DesignTokens.space10) {
                    Button("sync_empty_library_action".localized) {
                        modeBinding.wrappedValue = .library
                    }
                    .buttonStyle(.borderedProminent)
                    Button("sync_empty_tracks_action".localized) {
                        modeBinding.wrappedValue = .tracks
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.vertical, DesignTokens.space4)
        }
    }

    /// 内容区标题标明**内容来自哪一端**（用户反馈的错配点，标题就写清楚）。
    private var contentHeader: String {
        switch content.source {
        case .local: return "sync_run_selection_section_local".localized
        case .peer: return "sync_run_selection_section_peer".localized
        case .none: return "sync_run_selection_section".localized
        }
    }

    /// 对端曲库摘要（懒加载列表的替代：只放一行「N 首 · 约 X GB」）。
    @ViewBuilder
    private var peerSummaryRow: some View {
        HStack(spacing: DesignTokens.space8) {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
            if let facts = content.peerFacts {
                Text("sync_peer_summary".localized(with: peerName, facts.trackCount, facts.sizeText))
                    .font(.callout)
            } else if content.summaryState.isLoading {
                Text("sync_peer_summary_loading".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                // 摘要拿不到不阻塞列表（占位即可；列表自己有失败态 + 重试）。
                Text("sync_peer_summary_unknown".localized(with: peerName))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignTokens.space0)
        }
        .padding(.vertical, DesignTokens.space2)
    }

    /// 对端显示名（空则回落通用「iPhone」）。
    private var peerName: String {
        let name = model.connectedPeer?.displayName.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "sync_run_direction_download_target".localized : name
    }

    @ViewBuilder
    private var contentModePicker: some View {
        Picker("", selection: modeBinding) {
            Text("sync_run_mode_library".localized).tag(SyncUISelectionMode.library)
            Text("sync_run_mode_playlists".localized).tag(SyncUISelectionMode.playlists)
            Text("sync_run_mode_tracks".localized).tag(SyncUISelectionMode.tracks)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// 模式切换：全曲库先弹二次确认，用户在确认框里点头才真正切过去。
    private var modeBinding: Binding<SyncUISelectionMode> {
        Binding(
            get: { content.selectionMode },
            set: { mode in
                switch mode {
                case .library:
                    libraryWidePreview = content.libraryWidePreview()
                    showLibraryWideConfirm = true
                case .playlists:
                    content.setPlaylistsMode()
                case .tracks:
                    content.setTracksMode()
                }
            }
        )
    }

    private var libraryRow: some View {
        let selected = content.selection.isLibraryWide
        let summary = content.selectionSummary
        return HStack(spacing: DesignTokens.space10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(libraryRowTitle)
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
        .padding(.vertical, DesignTokens.space2)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !selected else { return }
            libraryWidePreview = content.libraryWidePreview()
            showLibraryWideConfirm = true
        }
    }

    /// 全曲库行标题：下载方向明确写「iPhone 的全部歌曲」（避免又看成本端曲库）。
    private var libraryRowTitle: String {
        content.source == .peer
            ? "sync_run_library_row_title_peer".localized(with: peerName)
            : "sync_run_library_row_title".localized
    }

    @ViewBuilder
    private var playlistList: some View {
        switch content.playlistState {
        case .idle, .loading:
            loadingRow("sync_run_playlists_loading")
        case let .failed(error):
            failureRow(error)
        case .loaded:
            if content.playlistOptions.isEmpty, smartSources.isEmpty {
                Text("sync_run_playlists_empty".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: DesignTokens.space8) {
                    smartSourceGroup
                    playlistGroup
                }
            }
        }
    }

    /// 自动歌单来源（最近添加 / 最近播放 / 常听排行）。
    ///
    /// P1b（2026-11-16）起**允许整组勾选**，语义是**快照**：勾上的那一刻把该源当时的
    /// 曲目展开成相对路径存进 `SyncCollectionSelection.playlistBundle`，之后源的动态
    /// 变化**不跟随**（用户拍板：动态 → 快照）。行内「已选 n/N」的 n = 快照条数、
    /// N = 该源当前曲目数，两者不等就说明源变了而快照没变；「快照」徽标提示这份选择
    /// 已定版。仍保留「挑选歌曲」入口（要精挑细选就走单曲级）。
    private var smartSources: [SyncBrowseSourceOption] {
        content.browseSources.filter(\.isSmart)
    }

    @ViewBuilder
    private var smartSourceGroup: some View {
        let sources = smartSources
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text("sync_source_smart_group".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(sources) { option in
                    HStack(spacing: DesignTokens.space8) {
                        Toggle(isOn: smartSourceBinding(option.ref)) {
                            HStack(spacing: DesignTokens.space8) {
                                Image(systemName: smartIconName(option))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                Text(option.title)
                                Text("smart_songs_count".localized(with: option.trackCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                smartSnapshotBadge(option)
                            }
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: DesignTokens.space0)
                        pickTracksButton(option.ref)
                    }
                }
                if let notice = content.smartSourceNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var playlistGroup: some View {
        if !content.playlistOptions.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                if !smartSources.isEmpty {
                    Text("sync_run_mode_playlists".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(content.playlistOptions) { option in
                    HStack(spacing: DesignTokens.space8) {
                        Toggle(isOn: playlistBinding(option.id)) {
                            HStack(spacing: DesignTokens.space8) {
                                Text(option.title)
                                Text("sync_run_songs_count".localized(with: option.trackCount))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                // 2026-11-16 P0：勾选后行内即时反馈（不新增文案键）。
                                if content.selectedPlaylistIDs.contains(option.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(accentColor)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                        Spacer(minLength: DesignTokens.space0)
                        if let ref = SyncBrowseSourceRef.parse(id: option.id) {
                            pickTracksButton(ref)
                        }
                    }
                }
            }
        }
    }

    /// 自动歌单行的图标（复用播放列表页卡片同一套决策）。
    private func smartIconName(_ option: SyncBrowseSourceOption) -> String {
        guard let kind = option.ref.smartKind else { return "music.note.list" }
        return MacSmartPlaylistUILogic.iconName(for: kind.smartPlaylistKind)
    }

    /// 智能源整组勾选的绑定（同款 checkbox；勾上 = 按当时曲目写快照）。
    private func smartSourceBinding(_ ref: SyncBrowseSourceRef) -> Binding<Bool> {
        Binding(
            get: { content.isSmartSourceSelected(ref.id) },
            set: { isOn in
                guard isOn != content.isSmartSourceSelected(ref.id) else { return }
                content.toggleSmartSource(ref)
            }
        )
    }

    /// 已选快照徽标：勾上才显示「已选 n/N」+「快照」。
    /// n/N 不等 = 源后来变了而快照没变（这正是「不跟随」的可见凭据）。
    @ViewBuilder
    private func smartSnapshotBadge(_ option: SyncBrowseSourceOption) -> some View {
        if content.isSmartSourceSelected(option.id) {
            Text(
                "sync_run_smart_selected".localized(
                    with: content.smartSnapshotCount(forSource: option.id),
                    option.trackCount
                )
            )
            .font(.caption)
            .foregroundStyle(accentColor)
            Text("sync_run_smart_snapshot_badge".localized)
                .font(.caption2)
                .padding(.horizontal, DesignTokens.space6)
                .padding(.vertical, DesignTokens.space2)
                .background(Color.gray.opacity(0.14), in: Capsule())
                .foregroundStyle(.secondary)
        }
    }

    /// 下钻入口：切到单曲级 + 把该来源设为当前来源（已勾选的歌全部保留）。
    private func pickTracksButton(_ ref: SyncBrowseSourceRef) -> some View {
        Button("sync_run_pick_tracks".localized) {
            content.pickTracks(in: ref)
        }
        .buttonStyle(.link)
        .font(.caption)
    }

    private func playlistBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { content.selectedPlaylistIDs.contains(id) },
            set: { isOn in
                guard isOn != content.selectedPlaylistIDs.contains(id) else { return }
                content.togglePlaylist(id)
            }
        )
    }

    /// 单曲级「来源」选择（全部曲库 / 收藏 / 自动歌单 / 真实歌单）——用户 2026-09-13
    /// 反馈「要一首一首搜索」的正面解法：先选来源，再在来源内搜索 / 翻页挑歌。
    /// 只做展示：选项、当前值、切换动作全部来自 `MacSyncContentModel`。
    @ViewBuilder
    private var sourcePicker: some View {
        if content.browseSources.count > 1 {
            HStack(spacing: DesignTokens.space8) {
                Text("sync_source_label".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Picker("", selection: sourceBinding) {
                    ForEach(content.browseSources) { option in
                        Text(sourceOptionTitle(option)).tag(option.ref)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                Spacer(minLength: DesignTokens.space0)
            }
        }
    }

    private var sourceBinding: Binding<SyncBrowseSourceRef> {
        Binding(
            get: { content.browseSource },
            set: { content.selectBrowseSource($0) }
        )
    }

    /// 下拉项文案：来源名 + 曲目数（与歌单行同一口径的「%d 首」）。
    private func sourceOptionTitle(_ option: SyncBrowseSourceOption) -> String {
        "\(option.title) · " + "smart_songs_count".localized(with: option.trackCount)
    }

    @ViewBuilder
    private var trackList: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space6) {
            sourcePicker
            TextField("sync_run_track_search_placeholder".localized, text: $content.trackQuery)
                .textFieldStyle(.roundedBorder)
                .onChange(of: content.trackQuery) { _, _ in
                    searchTask?.cancel()
                    searchTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: SyncUIContentLimits.searchDebounceNanoseconds)
                        guard !Task.isCancelled else { return }
                        content.applySearch()
                    }
                }

            if content.trackOptions.isEmpty {
                Text(
                    content.isLoadingTracks
                        ? "sync_run_tracks_loading".localized
                        : "sync_run_tracks_empty".localized
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DesignTokens.space2) {
                        ForEach(Array(content.trackOptions.enumerated()), id: \.element.id) { index, option in
                            trackRow(option)
                                .onAppear {
                                    // 滚到底自动续页（懒加载；对端分页取下一页）。
                                    guard index == content.trackOptions.count - 1 else { return }
                                    content.loadMoreTracks()
                                }
                        }
                    }
                }
                .frame(maxHeight: 240)

                if content.isLoadingTracks {
                    ProgressView()
                        .controlSize(.small)
                } else if content.hasMoreTracks {
                    Button("sync_run_tracks_load_more".localized) {
                        content.loadMoreTracks()
                    }
                }
            }

            if let error = content.tracksState.failure, error.isUserVisibleFailure {
                failureRow(error)
            }
        }
    }

    private func trackRow(_ option: SyncUITrackOption) -> some View {
        Toggle(isOn: trackBinding(option.relativePath)) {
            HStack(spacing: DesignTokens.space8) {
                VStack(alignment: .leading, spacing: DesignTokens.space2) {
                    // 曲目行是「渲染出来的歌曲文本」（含对端曲库）→ 按 UI 语言归一字形；
                    // 勾选/传输仍用 relativePath（原始字段，不受显示层影响）
                    Text(DisplayScriptNormalizer.display(option.title))
                    if let artist = option.artistName, !artist.isEmpty {
                        Text(DisplayScriptNormalizer.display(artist))
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

    private func trackBinding(_ relativePath: String) -> Binding<Bool> {
        Binding(
            get: { content.selectedTrackPaths.contains(relativePath) },
            set: { isOn in
                guard isOn != content.selectedTrackPaths.contains(relativePath) else { return }
                content.toggleTrack(relativePath)
            }
        )
    }

    /// 加载中一行。
    private func loadingRow(_ key: String) -> some View {
        HStack(spacing: DesignTokens.space8) {
            ProgressView()
                .controlSize(.small)
            Text(key.localized)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, DesignTokens.space2)
    }

    /// 失败一行（原因 + 重试）。
    private func failureRow(_ error: SyncUIPeerContentError) -> some View {
        HStack(spacing: DesignTokens.space8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(error.messageKey.localized)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("sync_peer_retry".localized) {
                content.retryPeerContent()
            }
        }
        .padding(.vertical, DesignTokens.space2)
    }

    /// 2026-11-16 P0：合计 / 空态文案已上移到固定执行底栏（`syncActionBar`），
    /// 这里只留「大小下界 / 歌单已失效」这类**辅助提示**，避免与底栏同屏重复。
    @ViewBuilder
    private var selectionTotals: some View {
        let summary = content.selectionSummary
        if !summary.isEmpty, summary.isBytesPartial || !summary.unknownPlaylistIDs.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.space2) {
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
            .padding(.top, DesignTokens.space2)
        }
    }

    /// 选择合计文案（底栏唯一渲染来源）：全曲库 / 歌单 / 单曲三态皆走既有键与
    /// `summary.sizeText`，不另造数字与格式化。
    var selectionTotalText: String {
        let summary = content.selectionSummary
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

}
