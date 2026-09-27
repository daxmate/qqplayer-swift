//
//  MacLibraryView+Sidebar.swift
//  QQPlayer
//
//  `MacLibraryView` 的侧栏（2026-09-21 从 `MacLibraryView.swift` 纯搬家）：
//  分区/歌单选择、侧栏搜索框、曲库卡统计行。
//
//  2026-09-27：侧栏在「艺术家」下方直接列出自动歌单（`SmartPlaylistKind` 单一事实源）
//  与用户自建歌单（`Playlist` 表）；选择语义见 `QQPlayer/Services/MacLibrarySelection.swift`。
//
//  ⚠️ 可见性：被 `body` 或其它分区文件引用的成员为 internal（原 `private`）。
//
import SwiftUI

extension MacLibraryView {
    // MARK: - Sidebar

    /// 分片：跨文件可见（原 private）
    var sidebar: some View {
        VStack(spacing: DesignTokens.space0) {
            MacSearchField(text: $searchText)
            List(selection: $selection) {
                // 一级分区（歌曲 / 我喜欢 / 专辑 / 艺术家）
                ForEach(MacLibrarySection.allCases) { item in
                    Label(item.title, systemImage: item.icon)
                        .tag(MacLibrarySelection.section(item))
                }
                // 智能列表（自动歌单）：条目与顺序全部来自 `SmartPlaylistKind` 单一事实源
                Section {
                    ForEach(SmartPlaylistKind.allCases) { kind in
                        Label(
                            Localized.smartPlaylistTitle(kind),
                            systemImage: MacSmartPlaylistUILogic.iconName(for: kind)
                        )
                        .tag(MacLibrarySelection.smartPlaylist(kind))
                    }
                } header: {
                    Text("mac_sidebar_smart_playlists".localized)
                }
                // 我的列表（用户自建歌单）：标题行带「+ 新建」
                Section {
                    ForEach(playlists, id: \.id) { playlist in
                        if let id = playlist.id {
                            Label(playlist.title, systemImage: "list.bullet.rectangle")
                                .tag(MacLibrarySelection.userPlaylist(id))
                        }
                    }
                } header: {
                    HStack(spacing: DesignTokens.space4) {
                        Text("mac_sidebar_my_playlists".localized)
                        Spacer()
                        Button {
                            newPlaylistName = ""
                            showNewPlaylistAlert = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help(Localized.createNewPlaylist)
                        .accessibilityLabel(Localized.createNewPlaylist)
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: DesignTokens.space6) {
                if indexer.isIndexing {
                    ProgressView(value: indexer.indexingProgress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: .infinity)
                    Text(String(format: "indexing_progress".localized, indexer.tracksFound))
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Button {
                        // 手动刷新语义收紧（2026-09-03 复查 A4 反馈）：先立即用 DB
                        // 真值重载列表，再排队/启动扫描。之前只 start()——扫描被占用
                        // 或启动被吞时列表不重读 DB，用户观感"点刷新没反应"；若曲库
                        // 数据已被其它路径改掉（删除/回收站/iCloud），点一下立刻对齐。
                        reloadLibrary()
                        // 2026-09-02 A4 修复：dataless 自动补扫在跑时 start() 会被
                        // guard !isIndexing 静默吞掉 → 手动刷新"没反应"。改为排队：
                        // 扫描结束后由 onReceive(isIndexing) 补一次重扫
                        if indexer.isIndexing {
                            MacScanLogger.log("手动刷新时正在扫描，标记排队（rescanWhenIdle）")
                            rescanWhenIdle = true
                        } else {
                            indexer.start()
                        }
                    } label: {
                        Label("refresh_library".localized, systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .padding(DesignTokens.space8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("create_new_playlist".localized, isPresented: $showNewPlaylistAlert) {
            TextField("playlist_name_placeholder".localized, text: $newPlaylistName)
            Button("create".localized) { createPlaylistFromSidebar() }
            Button("cancel".localized, role: .cancel) {}
        }
        .alert("error".localized, isPresented: sidebarCreateErrorBinding) {
            Button(Localized.ok, role: .cancel) { sidebarCreateError = nil }
        } message: {
            Text(sidebarCreateError ?? "")
        }
    }

    // MARK: - 新建歌单（复用既有创建流程与唯一写入口）

    /// 侧栏「+ 新建」：唯一写入口仍是 `AppCoordinator.createPlaylist`
    /// （与 MacPlaylistListView / MacTrackListView / iOS 侧同一条路径，不另起一套）。
    private func createPlaylistFromSidebar() {
        let title = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            let playlist = try appCoordinator.createPlaylist(title: title)
            NotificationCenter.default.post(name: .playlistsChanged, object: nil)
            // 新建后直接选中它（playlists 由 .playlistsChanged → reloadLibrary 刷新）
            if let id = playlist.id {
                selection = .userPlaylist(id)
            }
        } catch {
            sidebarCreateError = "playlist_create_failed".localized(with: error.localizedDescription)
            AppLog.error(.ui, "❌ MacLibraryView sidebar createPlaylist failed: \(error)")
        }
    }

    /// 新建失败弹窗开关（与 MacPlaylistListView 同款：不再静默关闭）
    private var sidebarCreateErrorBinding: Binding<Bool> {
        Binding(
            get: { sidebarCreateError != nil },
            set: { if !$0 { sidebarCreateError = nil } }
        )
    }
}
