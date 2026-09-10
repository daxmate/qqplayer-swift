import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var libraryIndexer = LibraryIndexer.shared

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
            .accentColor(settings.backgroundColorChoice.color)
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
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
                try DatabaseManager.shared.getAllTracks()
            }.value

            // Filter out incompatible formats when connected to CarPlay
            if SFBAudioEngineManager.shared.isCarPlayEnvironment {
                tracks = allTracks.filter { track in
                    let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
                    let incompatibleFormats = ["ogg", "opus", "dsf", "dff"]
                    return !incompatibleFormats.contains(ext)
                }
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

        // Wait for indexer to finish processing if it's currently running
        while libraryIndexer.isIndexing {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        await refreshLibrary()
        let trackCountAfter = tracks.count
        return (before: trackCountBefore, after: trackCountAfter)
    }

    @Sendable private func performRefresh() async -> (before: Int, after: Int) {
        let trackCountBefore = tracks.count

        // Wait for indexer to finish processing if it's currently running
        while libraryIndexer.isIndexing {
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
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
    @State private var hasPendingIndexRefresh = false

    /// 启动流程 sheet 决策：Tutorial 优先（首次引导）；Tutorial 不需要时检查
    /// 新功能弹窗（内部已排除首次启动）。两 sheet 不会同时置 true。
    private func checkStartupSheets() {
        if TutorialViewModel.shouldShowTutorial() {
            showTutorial = true
        } else if WhatsNewStore.shared.shouldShowCurrent() {
            showWhatsNew = true
            WhatsNewStore.shared.markSeen(WhatsNewContent.currentVersion)
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
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("TrackFound"))) { _ in
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
    @State private var settings = DeleteSettings.load()

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showTutorial) {
                TutorialView(onComplete: {
                    showTutorial = false
                    // 全新安装用户引导完成 = 已看过本版通告：记已读，避免 Tutorial 后
                    // 再弹 WhatsNew（下次升级才弹）
                    WhatsNewStore.shared.markSeen(WhatsNewContent.currentVersion)
                })
                .accentColor(settings.backgroundColorChoice.color)
            }
            .sheet(isPresented: $showWhatsNew) {
                WhatsNewView(onClose: {
                    showWhatsNew = false
                })
                .accentColor(settings.backgroundColorChoice.color)
            }
            .sheet(isPresented: $showPlaylistManagement) {
                PlaylistManagementView()
                    .accentColor(settings.backgroundColorChoice.color)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
                    .accentColor(settings.backgroundColorChoice.color)
            }
            .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
                settings = DeleteSettings.load()
            }

    }
}

#Preview {
    ContentView()
        .environmentObject(AppCoordinator.shared)
}
