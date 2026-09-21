//  MacLibraryView.swift
//  QQPlayer
//
//  macOS main window: NavigationSplitView with a library sidebar, a track
//  list (or album/artist/playlist grid), and the player detail page.
//  QQPlayerMac target only — kept out of the iOS target via pbxproj
//  membership exceptions.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct MacLibraryView: View {
    /// 分片：跨文件可见（原 private）
    @Environment(AppCoordinator.self) var appCoordinator
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    @Environment(\.appAccentColor) private var appAccentColor
    /// 官方打开设置窗口的入口（macOS 14+ `OpenSettingsAction`；替代已失效的私有 selector）。
    /// 分片：跨文件可见（原 private）
    @Environment(\.openSettings) var openSettings
    /// 分片：跨文件可见（原 private）
    @Environment(PlayerEngine.self) var player
    /// 分片：跨文件可见（原 private）
    @Environment(LibraryIndexer.self) var indexer
    /// search anything 开关（⌘K 命令；2026-09-19 批 3a 起由 Mac 组合根注入，读 `isOpen` 按属性追踪）
    @Environment(MacSearchAnythingState.self) private var searchAnythingState
    /// 曲库卡事实（批 3a：同上，由 Mac 组合根注入）
    /// 分片：跨文件可见（原 private）
    @Environment(MacLibraryFactsStore.self) var libraryFacts
    /// 分片：跨文件可见（原 private）
    @Environment(AppServices.self) var services
    /// 桌面浮窗管理器（批 5b：Mac 组合根注入；迷你模式入口按钮直调方法，不读属性）
    @Environment(DesktopWindowsManager.self) private var desktopWindows

    /// 分片：跨文件可见（原 private）
    @State var section: MacLibrarySection = .tracks
    /// 分片：跨文件可见（原 private）
    @State var tracks: [Track] = []
    /// 分片：跨文件可见（原 private）
    @State var likedTracks: [Track] = []
    /// 外观三态（工具栏月亮按钮循环切换，初值含旧 forceDarkMode 迁移推导）
    /// 分片：跨文件可见（原 private）
    @State var theme: AppearanceTheme = AppearanceTheme.resolved(
        raw: DeleteSettings.load().appearanceTheme,
        forceDarkMode: DeleteSettings.load().forceDarkMode
    )
    /// 设置（工具栏迷你按钮可见性 = showMiniWindowButton，设置改动即时刷新）
    @State private var deleteSettings = DeleteSettings.load()
    /// 分片：跨文件可见（原 private）
    @State var albums: [Album] = []
    /// 分片：跨文件可见（原 private）
    @State var artists: [Artist] = []
    /// 分片：跨文件可见（原 private）
    @State var playlists: [Playlist] = []
    /// 分片：跨文件可见（原 private）
    @State var loadError: String?
    /// 分片：跨文件可见（原 private）
    @State var selectedAlbum: Album?
    /// 分片：跨文件可见（原 private）
    @State var selectedArtist: Artist?
    /// 分片：跨文件可见（原 private）
    @State var albumTracks: [Track] = []
    /// 分片：跨文件可见（原 private）
    @State var artistTracks: [Track] = []
    /// 分片：跨文件可见（原 private）
    @State var selectedTrackId: String?
    /// 专辑/歌手详情 sheet 开关（上收自 MacAlbumGridView/MacArtistListView；支持歌曲右键「进专辑/进歌手」触发）
    /// 分片：跨文件可见（原 private）
    @State var showAlbumSheet = false
    /// 分片：跨文件可见（原 private）
    @State var showArtistSheet = false
    /// 新功能通告（启动时版本变化弹一次，对齐 iOS ContentView 挂载）
    @State private var showWhatsNew = false
    /// 在线搜索下载面板（C 组①：web 版 /api/online/* 对齐，sheet 形态）
    @State private var showOnlineSearch = false

    /// 同步面板（主窗口工具栏入口；同步只能由桌面端发起——用户 2026-09-11 拍板）
    @State private var showSyncPanel = false
    /// 曲库文件夹在扫描中变更 → 索引结束后自动补扫
    /// 分片：跨文件可见（原 private）
    @State var rescanWhenIdle = false
    /// 索引中增量刷新任务（防抖）
    @State private var libraryRefreshTask: Task<Void, Never>?
    /// 曲库全量重载任务句柄（审计 M2：四表读移出主线程，prev 同名任务作废）
    /// 分片：跨文件可见（原 private）
    @State var libraryLoadTask: Task<Void, Never>?
    /// 文件拖入导入（web 版拖拽对齐，B 组）：拖拽悬停高亮 + 完成后 toast
    @State private var isDropTargeted = false
    @State private var importToast: String?
    @State private var importToastTask: Task<Void, Never>?

    // Search state (sidebar search field + grouped results)
    /// 分片：跨文件可见（原 private）
    @State var searchText = ""
    /// 分片：跨文件可见（原 private）
    @State var debouncedSearchText = ""
    /// 分片：跨文件可见（原 private）
    @State var searchResults = MacSearchResults()
    @State private var debounceTask: Task<Void, Never>?
    /// 分片：跨文件可见（原 private）
    @State var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            contentList
                .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 600)
        } detail: {
            MacPlayerView(
                track: player.currentTrack,
                artistName: currentArtistName,
                isPlaying: player.isPlaying,
                duration: player.duration,
                playbackTime: player.progress.playbackTime,
                onPlayPause: togglePlayPause,
                onNext: { Task { await player.nextTrack(autoplay: true) } },
                onPrevious: { Task { await player.previousTrack(autoplay: true) } },
                onSeek: { time in
                    Task { await player.seek(to: time) }
                }
            )
        }
        .navigationTitle("QQPlayer")
        .frame(minWidth: 1000, minHeight: 640)
        .toolbar {
            // 迷你模式入口（v2：主窗 ⇄ 迷你互斥，仅主窗态可见此按钮；
            // 可见性 = 设置「迷你窗与桌面歌词」分类开关）
            ToolbarItem {
                if deleteSettings.showMiniWindowButton {
                    Button {
                        desktopWindows.enterMiniMode()
                    } label: {
                        Image(systemName: "pip.enter")
                    }
                    .help("enter_mini_mode".localized)
                }
            }
            ToolbarItem {
                Button {
                    cycleTheme()
                } label: {
                    Image(systemName: themeIconName)
                }
                .help(Localized.appearanceTheme)
            }
            ToolbarItem {
                Button {
                    showOnlineSearch = true
                } label: {
                    Image(systemName: "icloud.and.arrow.down")
                }
                .help("online_search_title".localized)
            }
            // 局域网同步入口（重要功能常驻主界面；同步只能由桌面端发起）
            ToolbarItem {
                Button {
                    showSyncPanel = true
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .help("sync_run_panel_title".localized)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            deleteSettings = DeleteSettings.load()
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(onClose: {
                services.whatsNew.markSeen(WhatsNewContent.currentVersion)
                showWhatsNew = false
            })
        }
        .sheet(isPresented: $showOnlineSearch) {
            MacOnlineSearchView()
        }
        // ⚠️ 尺寸在 MacSyncPanel 内部受控（高度必须放得下屏幕，否则关面板会把主窗下移）
        .sheet(isPresented: $showSyncPanel) {
            MacSyncPanel()
        }
        // search anything（C 组②）：⌘K/菜单唤起的主窗内全屏搜索浮层（与侧栏搜索共存）
        .overlay {
            if searchAnythingState.isOpen {
                MacSearchAnythingLayer(
                    onPlayLocal: { playSearchSongs($0, queue: $1) },
                    onPlayArtist: playArtist,
                    onPlayAlbum: playAlbum,
                    onOpenSettings: openSettingsRow,
                    artistNameResolver: { resolveArtistName(for: $0) }
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: searchAnythingState.isOpen)
        .task {
            reloadLibrary()
            if !indexer.isIndexing {
                indexer.start()
            }
            player.ensureRemoteCommandsSetup()
            // 启动即应用全局外观（NSApp.appearance，设置窗口等所有窗口跟随）
            applyMacAppearance()
            // 新功能通告：当前版本未读过则弹（升级场景）；全新安装也会弹一次
            if services.whatsNew.shouldShowCurrent() {
                showWhatsNew = true
            }
            // FSEvents 实时监控（web 版 watchdog 对齐，2026-09-03 B 组）：
            // 曲库文件夹内容变化（增删改/改名）→ 去抖 2s → 自动重扫。
            // 监控根 = 当前配置文件夹集合；设置页增删文件夹后重启（下方通知）。
            startFolderMonitoring()
            // 恢复上次播放状态（队列顺序 + 当前曲目，不自动播放）——B 组
            // 队列持久化闭环：moveQueueItems/remove 后 savePlayerState 落盘
            // queueTrackIds，冷启动经 restoreUIStateOnly 按键匹配还原队列顺序。
            // 放在 reloadLibrary 之后保证 DB 曲目可查（restore 只认已入库 stableId）。
            await player.restoreUIStateOnly()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.libraryFolderContentChanged)) { _ in
            // FSEvents 事件（已 2s 去抖，main 线程投递）→ 与 LibraryFoldersChanged
            // 同款语义：reload 立即对齐 DB + 启动/排队重扫
            MacScanLogger.log("LibraryFolderContentChanged received, isIndexing=\(indexer.isIndexing)")
            reloadLibrary()
            if indexer.isIndexing {
                rescanWhenIdle = true
            } else {
                indexer.start()
            }
        }
        .onChange(of: indexer.isIndexing) { _, isIndexing in
            if !isIndexing {
                reloadLibrary()
                if !debouncedSearchText.isEmpty {
                    performSearch(query: debouncedSearchText)
                }
                // 曲库文件夹在扫描中变更：索引结束后补一次重扫
                if rescanWhenIdle {
                    rescanWhenIdle = false
                    indexer.start()
                }
            }
        }
        .onChange(of: indexer.tracksFound) { _, _ in
            // 索引中增量刷新：新解析完成的歌陆续出现在列表，不让用户干等
            // （防抖 1.5s，避免每首歌都全量 reload）
            libraryRefreshTask?.cancel()
            guard indexer.isIndexing else { return }
            libraryRefreshTask = Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
                reloadLibrary()
            }
        }
        .onChange(of: searchText) { _, newValue in
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                guard !Task.isCancelled else { return }
                debouncedSearchText = newValue
                performSearch(query: newValue)
            }
        }
        .onDisappear {
            debounceTask?.cancel()
            searchTask?.cancel()
            libraryRefreshTask?.cancel()
            libraryLoadTask?.cancel()
            services.folderMonitor.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.favoritesChanged)) { _ in
            // 收藏变化后刷新“我喜欢的音乐”列表（含正在展示时的实时移除）
            reloadLikedTracks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            // 设置页改了主题/强调色后同步工具栏按钮状态（双向同步）
            let settings = DeleteSettings.load()
            theme = AppearanceTheme.resolved(
                raw: settings.appearanceTheme,
                forceDarkMode: settings.forceDarkMode
            )
            applyMacAppearance()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.playlistsChanged)) { _ in
            // 歌单管理（新建/重命名/删除/增删曲目）后刷新歌单列表与自动歌单计数
            reloadLibrary()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.libraryNeedsRefresh)) { _ in
            // iOS 同款标准通知：曲目删除/移动后整库重载（与 PlaylistsChanged 双通道，
            // 2026-09-02 A4 用户反馈删除后曲库不刷新——deleteTrack 后必须重拉 tracks）
            reloadLibrary()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.libraryFoldersChanged)) { _ in
            // 设置页「音乐库」添加/移除文件夹后重扫曲库（reconcile 自动清理旧目录曲目）。
            // 若正在扫描，start() 会被 guard 吞掉 → 标记等索引结束自动补扫。
            MacScanLogger.log("LibraryFoldersChanged received, isIndexing=\(indexer.isIndexing)")
            // 监控根变化 → 重启 FSEvents（旧根目录已不在监听集合）
            startFolderMonitoring()
            reloadLibrary()
            if indexer.isIndexing {
                rescanWhenIdle = true
            } else {
                indexer.start()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.libraryScanCriteriaChanged)) { _ in
            // 设置页「文件类型」改动后重扫曲库（取消的格式由 reconcile 收尾移除，
            // 与 LibraryFoldersChanged 同款排队语义：扫描中则标记等索引结束补扫）。
            MacScanLogger.log("libraryScanCriteriaChanged received, isIndexing=\(indexer.isIndexing)")
            reloadLibrary()
            if indexer.isIndexing {
                rescanWhenIdle = true
            } else {
                indexer.start()
            }
        }
        // 文件拖入导入（web 版拖拽对齐，B 组）：
        // 全窗口 drop 目标——Finder 音频文件拖进窗口任意位置 → 复制入曲库
        .onDrop(
            of: [UTType.fileURL],
            isTargeted: $isDropTargeted
        ) { providers in
            handleDroppedFiles(providers)
            return true
        }
        .overlay {
            if isDropTargeted {
                dropTargetHint
            } else if let importToast {
                importToastLabel(importToast)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.libraryImportFinished)) { note in
            // 导入完成 toast（web 版 toast 对齐；歌单行 drop 复用同一通知）
            let count = (note.userInfo?["count"] as? Int) ?? 0
            let skipped = (note.userInfo?["skipped"] as? Int) ?? 0
            // 审计 D2：跳过数以前写而不读（用户只看到「已导入 0 首」）→ 上屏
            if count > 0, skipped > 0 {
                showImportToast(Localized.dragImportPartial(imported: count, skipped: skipped))
            } else {
                showImportToast(Localized.dragImportSuccess(count: count))
            }
        }
        // 曲库加载失败上屏（审计 M6：loadError 以前只写不读 → 用户只看到空曲库）
        .alert("error".localized, isPresented: libraryLoadErrorBinding) {
            Button(Localized.ok, role: .cancel) { loadError = nil }
        } message: {
            Text(loadError ?? "")
        }
    }

    // MARK: - 文件拖入导入（B 组）

    /// 拖拽悬停提示（web 版遮罩语义的轻量版）。
    private var dropTargetHint: some View {
        RoundedRectangle(cornerRadius: DesignTokens.radius12)
            .strokeBorder(appAccentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
            .padding(DesignTokens.space12)
            .overlay {
                Text(Localized.dragImportHint)
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, DesignTokens.space16)
                    .padding(.vertical, DesignTokens.space10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.radius8))
            }
            .allowsHitTesting(false)
    }

    private func importToastLabel(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .padding(.horizontal, DesignTokens.space12)
            .padding(.vertical, DesignTokens.space8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.gray.opacity(0.3), lineWidth: 1))
            .padding(.bottom, DesignTokens.space40)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    /// 分片：跨文件可见（原 private）
    func showImportToast(_ message: String) {
        importToastTask?.cancel()
        withAnimation { importToast = message }
        importToastTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { importToast = nil }
        }
    }

}
