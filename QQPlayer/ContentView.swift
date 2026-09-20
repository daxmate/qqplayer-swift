import SwiftUI

struct ContentView: View {
    @Environment(AppCoordinator.self) private var appCoordinator
    @Environment(AppServices.self) private var services
    @Environment(LibraryIndexer.self) private var libraryIndexer

    @State private var tracks: [Track] = []
    @State private var selectedTab = 0
    @State private var refreshTimer: Timer?
    @State private var showTutorial = false
    @State private var showWhatsNew = false
    @State private var showPlaylistManagement = false
    @State private var showSettings = false
    @State private var settings = DeleteSettings.load()

    var body: some View {
        mainContent
            .background(.clear)
            .accentColor(accentColor)
            // App 强调色环境值（iOS 唯一注入点，2026-09-15 I1）：值来自 8 色 iOS 名单
            // `IOSAppearance`（输入 = 唯一配色字段 `settings.accentColorName`，2026-09-17 字段层收口）；
            // 视图统一读 @Environment(\.appAccentColor)，不再直读 settings。
            .environment(\.appAccentColor, accentColor)
            .onAppear {
                AppearanceResolver.apply(forceDark: settings.forceDarkMode)
            }
            .modifier(LifecycleModifier(
                appCoordinator: appCoordinator,
                libraryIndexer: libraryIndexer,
                refreshTimer: $refreshTimer,
                showTutorial: $showTutorial,
                showWhatsNew: $showWhatsNew,
                onRefresh: refreshLibrary
            ))
            .modifier(SheetModifier(
                appCoordinator: appCoordinator,
                showTutorial: $showTutorial,
                showWhatsNew: $showWhatsNew,
                showPlaylistManagement: $showPlaylistManagement,
                showSettings: $showSettings
            ))
    }

    /// 当前强调色。唯一取数入口 = `IOSAppearance`（8 色名单），唯一字段 = `accentColorName`
    /// （2026-09-17 设置字段层收口：不再有 `backgroundColorChoice`）。
    private var accentColor: Color { IOSAppearance.accentColor(forKey: settings.accentColorName) }

    private var mainContent: some View {
        LibraryView(
            tracks: tracks,
            showTutorial: $showTutorial,
            showPlaylistManagement: $showPlaylistManagement,
            showSettings: $showSettings,
            onRefresh: performRefresh,
            onManualSync: performManualSync
        )
        .safeAreaInset(edge: .bottom) {
            MiniPlayerView()
                .background(.clear)
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
            Task {
                await refreshLibrary()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
            AppearanceResolver.apply(forceDark: settings.forceDarkMode)
        }
    }

    @Sendable private func refreshLibrary() async {
        do {
            let allTracks = try await Task.detached(priority: .userInitiated) {
                // 视图层只读查询的唯一入口（LibraryReads），不直连 DatabaseManager
                try LibraryReads.allTracks()
            }.value

            // CarPlay 连接时剔除不兼容格式：判据与名单的唯一实现在 CarPlayTrackFilter
            if CarPlayTrackFilter.isActive {
                tracks = CarPlayTrackFilter.filtered(allTracks)
                print("🚗 CarPlay: Filtered \(allTracks.count - tracks.count) incompatible tracks")
            } else {
                tracks = allTracks
            }
        } catch {
            print("Failed to refresh library: \(error)")
        }
    }

    @Sendable private func performManualSync() async -> (before: Int, after: Int) {
        let trackCountBefore = tracks.count
        await appCoordinator.manualSync()

        // 等索引跑完（IndexingGate = 唯一实现，无忙等；超时兜底不阻塞用户）
        if await IndexingGate.waitUntilIdle(libraryIndexer) == .timedOut {
            print("⏱️ ContentView: indexing wait timed out — refreshing anyway")
        }

        await refreshLibrary()
        let trackCountAfter = tracks.count
        return (before: trackCountBefore, after: trackCountAfter)
    }

    @Sendable private func performRefresh() async -> (before: Int, after: Int) {
        let trackCountBefore = tracks.count

        // 等索引跑完（IndexingGate = 唯一实现，无忙等；超时兜底不阻塞用户）
        if await IndexingGate.waitUntilIdle(libraryIndexer) == .timedOut {
            print("⏱️ ContentView: indexing wait timed out — refreshing anyway")
        }

        await refreshLibrary()
        let trackCountAfter = tracks.count
        return (before: trackCountBefore, after: trackCountAfter)
    }

}

struct LifecycleModifier: ViewModifier {
    let appCoordinator: AppCoordinator
    let libraryIndexer: LibraryIndexer
    @Binding var refreshTimer: Timer?
    @Binding var showTutorial: Bool
    @Binding var showWhatsNew: Bool
    let onRefresh: @Sendable () async -> Void
    @Environment(AppServices.self) private var services
    @State private var hasPendingIndexRefresh = false

    /// 启动流程 sheet 决策：Tutorial 优先（首次引导）；Tutorial 不需要时检查
    /// 新功能弹窗（内部已排除首次启动）。两 sheet 不会同时置 true。
    private func checkStartupSheets() {
        if TutorialViewModel.shouldShowTutorial() {
            showTutorial = true
        } else if services.whatsNew.shouldShowCurrent() {
            showWhatsNew = true
            services.whatsNew.markSeen(WhatsNewContent.currentVersion)
        }
    }

    func body(content: Content) -> some View {
        content
            .task {
                if appCoordinator.isInitialized {
                    await onRefresh()
                    checkStartupSheets()
                }
            }
            .onChange(of: appCoordinator.isInitialized) { _, isInitialized in
                if isInitialized {
                    Task {
                        await onRefresh()
                        checkStartupSheets()
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .trackFound)) { _ in
                if libraryIndexer.isIndexing {
                    hasPendingIndexRefresh = true
                } else {
                    Task { await onRefresh() }
                }
            }
            .onChange(of: libraryIndexer.isIndexing) { _, isIndexing in
                if isIndexing {
                    refreshTimer?.invalidate()
                    refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                        Task { @MainActor in
                            guard hasPendingIndexRefresh else { return }
                            hasPendingIndexRefresh = false
                            await onRefresh()
                        }
                    }
                } else {
                    refreshTimer?.invalidate()
                    refreshTimer = nil
                    hasPendingIndexRefresh = false
                    Task { await onRefresh() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                // Save player state when app goes to background
                appCoordinator.playerEngine.savePlayerState()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
                // Save player state when app is terminated
                appCoordinator.playerEngine.savePlayerState()
            }
    }
}

struct SheetModifier: ViewModifier {
    let appCoordinator: AppCoordinator
    @Binding var showTutorial: Bool
    @Binding var showWhatsNew: Bool
    @Binding var showPlaylistManagement: Bool
    @Binding var showSettings: Bool
    @Environment(AppServices.self) private var services
    @State private var settings = DeleteSettings.load()

    /// 当前强调色（同 ContentView：唯一取数 = `IOSAppearance`，唯一字段 = `accentColorName`）
    private var accentColor: Color { IOSAppearance.accentColor(forKey: settings.accentColorName) }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showTutorial) {
                TutorialView(onComplete: {
                    showTutorial = false
                    // 全新安装用户引导完成 = 已看过本版通告：记已读，避免 Tutorial 后
                    // 再弹 WhatsNew（下次升级才弹）
                    services.whatsNew.markSeen(WhatsNewContent.currentVersion)
                })
                .accentColor(accentColor)
            }
            .sheet(isPresented: $showWhatsNew) {
                WhatsNewView(onClose: {
                    showWhatsNew = false
                })
                .accentColor(accentColor)
            }
            .sheet(isPresented: $showPlaylistManagement) {
                PlaylistManagementView()
                    .accentColor(accentColor)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .accentColor(accentColor)
            }
            .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
                settings = DeleteSettings.load()
            }

    }
}

#Preview {
    ContentView()
        .environment(AppCoordinator.shared)
}
