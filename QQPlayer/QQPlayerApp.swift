//
//  QQPlayerApp.swift
//  QQPlayer
//
//  Created by CLQ on 28/08/2025.
//

import AVFoundation
import Intents
import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handle intent: INIntent, completionHandler: @escaping (INIntentResponse) -> Void) {
        if let playMediaIntent = intent as? INPlayMediaIntent {
            Task { @MainActor in
                await AppCoordinator.shared.handleSiriPlaybackIntent(playMediaIntent, completion: completionHandler)
            }
        } else if let addMediaIntent = intent as? INAddMediaIntent {
            Task { @MainActor in
                await AppCoordinator.shared.handleSiriAddMediaIntent(addMediaIntent, completion: completionHandler)
            }
        } else {
            completionHandler(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Set up Siri vocabulary and media context
        setupSiriIntegration()
        return true
    }

    private func setupSiriIntegration() {
        // INVocabulary 需要 com.apple.developer.siri entitlement。无该 entitlement
        // 的进程（模拟器、CI 无签名构建 CODE_SIGNING_ALLOWED=NO）调用
        // INVocabulary.shared() 会抛 NSInternalInconsistencyException 直接崩溃
        // （dispatch_once 块内异常无法被 @try/@catch 捕获）。xcodebuild test 环境
        // 与模拟器直接跳过（iOS 无公开 API 校验自身 entitlement，SecTask 系 macOS
        // 专有；真机付费签名构建 entitlement 生效，不受影响）。
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        #if !targetEnvironment(simulator)

            // Donate vocabulary on every OS version: Siri keeps routing by-name
            // media requests through the legacy SiriKit extension even on iOS 27
            // with assistant schemas registered, so the old recognizer still
            // needs playlist/artist names.
            DispatchQueue.global(qos: .userInitiated).async {
                // Set up vocabulary for playlists, artists, and albums
                Task { @MainActor in
                    do {
                        // Playlist vocabulary
                        let playlists = try AppCoordinator.shared.databaseManager.getAllPlaylists()
                        var playlistVocabulary = playlists.map { $0.title }

                        // Add French playlist generic terms to help recognition
                        playlistVocabulary.append(contentsOf: [
                            "ma playlist", "ma liste de lecture", "mes playlists",
                            "liste de lecture", "playlist", "playlists",
                            "Liked Songs", "Favorites", "Favourites", "Favoris",
                        ])

                        let playlistNames = NSOrderedSet(array: playlistVocabulary)
                        INVocabulary.shared().setVocabularyStrings(playlistNames, of: .mediaPlaylistTitle)
                        print("✅ Set up vocabulary for \(playlistNames.count) playlist terms")

                    } catch {
                        print("❌ Failed to set up vocabulary: \\(error)")
                    }
                }

                // Create media user context
                let context = INMediaUserContext()
                Task { @MainActor in
                    do {
                        let trackCount = try AppCoordinator.shared.databaseManager.getAllTracks().count
                        context.numberOfLibraryItems = trackCount
                        context.subscriptionStatus = .notSubscribed // Since this is a local music app
                        context.becomeCurrent()
                    } catch {
                        print("❌ Failed to set up media context: \\(error)")
                    }
                }
            }
        #endif
    }
}

@main
struct QQPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appCoordinator = AppCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if #available(iOS 26.0, *) {
            AppIntentsDependencies.register()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appCoordinator)
                .task {
                    DatabaseSuspensionCoordinator.shared.start()
                    await appCoordinator.initialize()
                    #if canImport(MediaIntents)
                        if #available(iOS 27.0, *) {
                            SpotlightLibraryIndexer.shared.activate()
                        }
                    #endif
                    await createiCloudContainerPlaceholder()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.didEnterBackgroundNotification)) { _ in
                    handleDidEnterBackground()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.willEnterForegroundNotification)) { _ in
                    handleWillEnterForeground()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.willDeactivateNotification)) { _ in
                    handleWillResignActive()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIScene.didActivateNotification)) { notification in
                    // iOS 26 已知问题：CarPlay 场景连接/断开等 scene 切换后，主窗口
                    // 的 safe area insets 可能不刷新（需旋转或后台切换才恢复），导致
                    // safeAreaInset(edge: .bottom) 内容（迷你播放条）残留在错误 y 位置
                    // （如屏幕中部）。延迟强制主窗口重新布局以纠正几何。
                    // 仅处理 UIWindowScene（排除 CarPlay 模板场景自身）。
                    guard notification.object is UIWindowScene else { return }
                    refreshLayoutAfterSceneChange()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CarPlaySceneDidDisconnect"))) { _ in
                    // CarPlay 断开但手机场景未重新激活时（didActivate 可能不触发）的兜底
                    refreshLayoutAfterSceneChange()
                }
                .onOpenURL { url in
                    handleOpenURL(url)
                }
                // 局域网同步（M6·T4）：Mac 是唯一发起方，本端只在前台保持回连
                // 并应答/接收（App 级被动同步中心，与扫码流程无关）。
                .onChange(of: scenePhase) { _, phase in
                    handleScenePhase(phase)
                }
                .onContinueUserActivity("com.daxmate.qqplayer.play") { userActivity in
                    handleSiriIntent(userActivity)
                }
        }
    }

    /// iOS 26 scene 切换后 safe-area 不刷新的 workaround：延迟强制主窗口重新布局。
    /// CarPlay 连接/断开会触发 scene 激活状态变化，SwiftUI 的 safeAreaInset 内容
    /// （迷你播放条）可能因此残留在错误位置（如屏幕中部）。等 scene 几何稳定后
    /// 强制 layout 一次即可纠正；幂等、无动画副作用。
    @MainActor
    private func refreshLayoutAfterSceneChange() {
        Task { @MainActor in
            // 等 scene 激活完成、窗口几何/safe area 最终确定后再刷（实测即时刷会过早）
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3s
            guard !Task.isCancelled else { return }
            print("🔄 Scene change detected - forcing main window layout refresh (safe-area workaround)")
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene,
                      windowScene.activationState == .foregroundActive else { continue }
                for window in windowScene.windows {
                    window.setNeedsLayout()
                    window.layoutIfNeeded()
                    window.rootViewController?.view.setNeedsLayout()
                    window.rootViewController?.view.layoutIfNeeded()
                }
            }
        }
    }

    /// 局域网同步被动端跟随 App 前后台：前台回连、后台断开（唯一生命周期入口，
    /// 不依赖扫码流程）。
    private func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            IOSPassiveSyncCenter.shared.start()
        case .background:
            IOSPassiveSyncCenter.shared.stop()
        case .inactive:
            break // 瞬时中断（控制中心/来电横幅）不拆会话
        @unknown default:
            break
        }
    }

    private func handleDidEnterBackground() {
        print("🔍 DIAGNOSTIC - backgroundTimeRemaining:", UIApplication.shared.backgroundTimeRemaining)

        // Configure audio for background playback - critical for SFBAudioEngine stability
        Task { @MainActor in
            // Don't touch audio session if interrupted by alarm/call
            guard !PlayerEngine.shared.isAudioSessionInterrupted else {
                print("🎧 Audio session interrupted - skipping background optimization")
                return
            }

            // Optimize SFBAudioEngine for lock screen stability.
            // Only when SFB is actually in use - on CarPlay / native playback,
            // reconfiguring the session here stops AVAudioEngine mid-playback.
            if PlayerEngine.shared.isPlaying && PlayerEngine.shared.isUsingSFBEngine {
                await optimizeSFBAudioForBackground()
            }

            // Stop ALL high-frequency UI timers when backgrounded to prevent
            // SwiftUI redraws from spiking CPU and triggering the iOS watchdog kill.
            PlayerEngine.shared.suspendUITimersForBackground()
        }
    }

    private func handleWillEnterForeground() {
        // Restart timers when foregrounding
        Task { @MainActor in
            // Restore audio configuration and all UI timers
            if PlayerEngine.shared.isPlaying && PlayerEngine.shared.isUsingSFBEngine {
                await optimizeSFBAudioForForeground()
            }
            PlayerEngine.shared.resumeUITimersForForeground()

            // Check for new shared files and refresh library
            await LibraryIndexer.shared.copyFilesFromSharedContainer()

            // Only auto-scan if it's been a long time since last scan
            if !LibraryIndexer.shared.isIndexing {
                let settings = DeleteSettings.load()
                if shouldPerformAutoScan(lastScanDate: settings.lastLibraryScanDate) {
                    print("🔄 Foreground: Starting library scan (been a while since last scan)")
                    LibraryIndexer.shared.start()
                } else {
                    print("⏭️ Foreground: Skipping auto-scan (use manual sync button)")
                }
            }
        }
    }

    private func shouldPerformAutoScan(lastScanDate: Date?) -> Bool {
        // If never scanned before, definitely scan
        guard let lastScanDate = lastScanDate else {
            print("🆕 Never scanned before - will perform scan")
            return true
        }

        // Check if it's been more than 1 hour since last scan
        let hoursSinceLastScan = Date().timeIntervalSince(lastScanDate) / 3600
        let shouldScan = hoursSinceLastScan >= 1.0

        if shouldScan {
            print("⏰ Last scan was \(String(format: "%.1f", hoursSinceLastScan)) hours ago - will scan")
        } else {
            print("⏰ Last scan was \(String(format: "%.1f", hoursSinceLastScan)) hours ago - skipping")
        }

        return shouldScan
    }

    private func handleWillResignActive() {
        guard PlayerEngine.shared.isPlaying else {
            releaseAudioSessionIfIdle()
            print("🎧 QQPlayer is not playing - leaving audio focus with the current app")
            return
        }

        // Don't re-grab the audio session if we're being interrupted by an alarm or call
        guard !PlayerEngine.shared.isAudioSessionInterrupted else {
            print("🎧 Audio session interrupted (alarm/call) - skipping session keepalive")
            return
        }

        // Re-assert the session as we background. Do NOT call setCategory here:
        // changing category/options on a live session forces an audio hardware
        // reconfiguration that stops AVAudioEngine mid-playback (CarPlay pauses
        // every time the phone locks).
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            print("🎧 Session keepalive on resign active - success")
        } catch {
            print("❌ Session keepalive fail:", error)
        }
    }

    private func releaseAudioSessionIfIdle() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("ℹ️ Audio session was already inactive or could not be released: \(error)")
        }
    }

    private func handleOpenURL(_ url: URL) {
        print("🔗 Received URL: \(url.absoluteString)")

        guard url.scheme == "qqplayer" else {
            print("❌ Unknown URL scheme: \(url.scheme ?? "nil")")
            return
        }

        Task { @MainActor in
            switch url.host {
            case "refresh":
                print("📁 URL triggered library refresh - this is a manual refresh so always scan")
                await LibraryIndexer.shared.copyFilesFromSharedContainer()
                if !LibraryIndexer.shared.isIndexing {
                    LibraryIndexer.shared.start()
                }

            case "playlist":
                // Extract playlist ID from path
                let playlistId = url.pathComponents.dropFirst().joined(separator: "/")
                print("📋 Widget: Opening playlist - \(playlistId)")

                // Navigate to playlist
                if let playlistIdInt = Int64(playlistId) {
                    do {
                        let playlists = try appCoordinator.databaseManager.getAllPlaylists()
                        if let playlist = playlists.first(where: { $0.id == playlistIdInt }) {
                            // Post notification to navigate to playlist
                            NotificationCenter.default.post(
                                name: NSNotification.Name("NavigateToPlaylist"),
                                object: nil,
                                userInfo: ["playlistId": playlistIdInt]
                            )
                            print("✅ Widget: Navigating to playlist \(playlist.title)")
                        }
                    } catch {
                        print("❌ Widget: Failed to find playlist: \(error)")
                    }
                }

            default:
                print("⚠️ Unknown URL host: \(url.host ?? "nil")")
            }
        }
    }

    private func handleSiriIntent(_ userActivity: NSUserActivity) {
        print("🎤 Received Siri intent: \(userActivity.activityType)")
        Task { @MainActor in
            await appCoordinator.handleSiriPlayIntent(userActivity: userActivity)
        }
    }

    private func createiCloudContainerPlaceholder() async {
        guard let iCloudURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            print("❌ iCloud Drive not available")
            return
        }

        let documentsURL = iCloudURL.appendingPathComponent("Documents")
        let placeholderURL = documentsURL.appendingPathComponent(".qqplayer_placeholder")

        do {
            // Create Documents directory if it doesn't exist
            try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true, attributes: nil)

            // Create placeholder file if it doesn't exist
            if !FileManager.default.fileExists(atPath: placeholderURL.path) {
                let placeholderText = "This folder contains music files for QQPlayer.\nPlace your FLAC files here to add them to your library."
                try placeholderText.write(to: placeholderURL, atomically: true, encoding: .utf8)
                print("✅ Created iCloud Drive placeholder file to ensure folder visibility")
            }
        } catch {
            print("❌ Failed to create iCloud Drive placeholder: \(error)")
        }
    }

    // MARK: - SFBAudioEngine Background Optimization

    private func optimizeSFBAudioForBackground() async {
        print("🔒 Optimizing SFBAudioEngine for background/lock screen")

        // Increase buffer size significantly for background stability.
        // Do NOT call setCategory here - changing category/options on a live
        // session forces a hardware reconfiguration that stops playback.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setPreferredIOBufferDuration(0.100) // 100ms buffer for lock screen
            print("✅ Increased buffer to 100ms for lock screen stability")
        } catch {
            print("⚠️ Failed to increase buffer for background: \(error)")
        }
    }

    private func optimizeSFBAudioForForeground() async {
        print("🔓 Restoring SFBAudioEngine for foreground")

        // Restore normal buffer size.
        // Do NOT call setCategory here - changing category/options on a live
        // session forces a hardware reconfiguration that stops playback.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setPreferredIOBufferDuration(0.040) // Back to 40ms
            print("✅ Restored buffer to 40ms for foreground")
        } catch {
            print("⚠️ Failed to restore buffer for foreground: \(error)")
        }
    }
}
