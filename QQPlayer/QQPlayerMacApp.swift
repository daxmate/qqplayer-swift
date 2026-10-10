//  QQPlayerMacApp.swift
//  QQPlayer
//
//  macOS app entry point (QQPlayerMac target only). The iOS app uses
//  QQPlayerApp.swift as its @main; this file must stay out of the iOS
//  QQPlayer target to avoid duplicate @main declarations.
//
import SwiftUI

/// 迷你模式点 Dock 图标 → 回主窗（收起迷你窗/歌词窗；主窗态下幂等无副作用）。
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DesktopWindowsManager.shared.showMainWindow()
        return true
    }
}

@main
struct QQPlayerMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var deleteSettings = DeleteSettings.load()

    init() {
        // 诊断基建：stderr + stdout 重定向落盘（print 走 stdout，Swift fatal 走 stderr），
        // 运行时报错/业务日志可离线读取（~/Library/Logs/QQPlayerMac/{stdout,stderr}.log）
        MacScanLogger.redirectStderr()
        MacScanLogger.redirectStdout()
        // 2026-10-10：macOS App 数据一次性迁出 ~/Documents → Application Support/QQPlayerMac。
        // **必须早于任何按旧 Documents 位置初始化的数据层**（ArtworkManager / StateManager /
        // 歌词缓存等；此刻各视图 singleton / AppServices 尚未构造）。
        // 只搬不删、冲突不覆盖、失败保留源下次重试；完成门置位后幂等跳过。
        // 放在 init 里「redirect 之后的第一件事」，早于本 init 里其余所有初始化。
        MacDocumentsStorageRelocation.run(
            dryRun: MacDocumentsStorageRelocation.dryRunRequested()
        )
        // 退出兑底保存：播放状态周期 30s 落盘一次，⌘Q 距上次保存不足 30s 会丢
        // 断点进度（web 版"页面关闭兑底"对齐，D 组恢复播放）——willTerminate 同步存一次。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            // willTerminate 在主线程回调且必须同步写完（Task 异步可能来不及落盘）
            MainActor.assumeIsolated {
                PlayerEngine.shared.savePlayerState()
            }
        }
        // D 组键盘快捷键（web shortcuts.ts 对齐）：App 内全局监听，启动即装。
        MacKeyboardShortcuts.install()
        // E3 桌面浮窗：监听设置变化并恢复上次显隐状态（默认关不弹；开启过则重启恢复）。
        DesktopWindowsManager.shared.start()
        // 曲库唯一地址（用户 2026-09-28 拍板）：启动时先确保曲库根存在。**必须早于
        // `SyncHostCenter.start()`** —— 监听一开就可能接会话，晚了的第一条连接会走
        // `handleSessionPhase(.ready)` → `MacSyncLibraryHost.attach` →
        // `SyncLocalLibraryProvider.attach` 首行 `fileExists(libraryRoot)` 判假 ⇒ 不接线
        // ⇒ `activeSession` 恒 nil ⇒ UI「设备在线，但同步面板报尚未连接」。
        // 放在这里（App init）而不是 `AppCoordinator.initialize()`：后者是 async、晚于本处，
        // 赶不上启动即监听的首条连接。
        MacLibraryRoot.ensureRootExists()
        // M6 T1：局域网同步 Host 常驻监听——App 启动即开始（设置页只做控制面，
        // 生命周期归 SyncHostCenter）。“允许局域网设备连接”关掉时不启动。
        MainActor.assumeIsolated {
            SyncHostCenter.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            MacLibraryView()
                // macOS 26 (Tahoe) 上 unified 工具栏默认透明，sidebar 内容会延伸到
                // 标题栏区域、第一行与交通灯重叠。强制工具栏背景不透明后内容从标题栏下方开始。
                .toolbarBackground(.visible, for: .windowToolbar)
                // 强调色：对齐 web 版 ACCENT_OPTIONS 预设，设置页切换后全局生效。
                // 值一律取 `MacAppearance.currentAccentColor`（唯一读取入口，M2）。
                .tint(MacAppearance.currentAccentColor)
                // App 强调色环境值（Color.accentColor 在 macOS 跟随系统而非 App tint）
                .environment(\.appAccentColor, MacAppearance.currentAccentColor)
                // 视图层单例收口（「下降预算」批 3a）：App 级叶子 store 的**唯一装配点**。
                // 纪律：视图层不得直连 `.shared`（棘轮 `ViewSharedSingletonContractTests`）；
                // 新增一个对象 = 在此与 `Settings` 根各登记一行。
                .environment(MacSearchAnythingState.shared)
                .environment(MacLibraryFactsStore.shared)
                // 桌面浮窗管理器（批 5b）；浮窗内容另由管理器手工 hosting 装配（见 MacDesktopWindowsManager）
                .environment(DesktopWindowsManager.shared)
                .environment(EQManager.shared)
                // 频谱分析器（批 6-1）：播放页视觉条按属性追踪驱动重绘
                .environment(MacSpectrumAnalyzer.shared)
                // 曲库索引器（批 6-2）：MacLibraryView 读 isIndexing/tracksFound 按属性追踪
                .environment(LibraryIndexer.shared)
                // 全局协调器（批 6-4）：Mac 视图的方法调用入口（收藏/歌单写操作）
                .environment(AppCoordinator.shared)
                // App 级无状态入口容器（批 3b・方案 A）：WhatsNewStore / StateManager / MacFolderMonitor
                .environment(AppServices.live)
                // 播放引擎（批 6-6）：Mac 视图（播放页 / 列表高亮 / 浮窗 / 卡拉OK 条）按属性追踪
                .environment(PlayerEngine.shared)
                .environment(KaraokeController.shared)
                // 同步三件（批 6-8）：`SyncHostCenter` / 装配自检事实 / 歌词补发事实迁 `@Observable`
                // ⇒ 同步面板（设置页与工具栏面板）、相关视图改环境注入。新增一个对象 = 三处都登记。
                .environment(SyncHostCenter.shared)
                .environment(SyncWiringFactsStore.shared)
                .environment(MacLyricsResendFactsStore.shared)
                .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
                    deleteSettings = DeleteSettings.load()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        // 设置：系统 Settings scene → App 菜单自动出现「Settings…」(⌘,)，
        // 打开独立设置窗口（macOS 惯例；主窗口 toolbar 不放设置按钮）
        Settings {
            MacSettingsView()
                .tint(MacAppearance.currentAccentColor)
                .environment(\.appAccentColor, MacAppearance.currentAccentColor)
                // 同 WindowGroup 根：Settings 是独立场景，不继承主窗环境（批 3a）。
                .environment(MacSearchAnythingState.shared)
                .environment(MacLibraryFactsStore.shared)
                .environment(DesktopWindowsManager.shared)
                .environment(EQManager.shared)
                .environment(MacSpectrumAnalyzer.shared)
                .environment(LibraryIndexer.shared)
                .environment(AppCoordinator.shared)
                .environment(AppServices.live)
                // 播放引擎（批 6-6）：Settings 是独立场景，不继承主窗环境
                .environment(PlayerEngine.shared)
                .environment(KaraokeController.shared)
                // 同步三件（批 6-8）：Settings 是独立场景，不继承主窗环境（同上一行原因）
                .environment(SyncHostCenter.shared)
                .environment(SyncWiringFactsStore.shared)
                .environment(MacLyricsResendFactsStore.shared)
        }
        // search anything（C 组②）：⌘K 唤起全屏搜索层（web SearchAnything 快捷键同键）
        .commands {
            CommandGroup(after: .toolbar) {
                Button {
                    MacSearchAnythingState.shared.isOpen.toggle()
                } label: {
                    Text("search_any_menu".localized)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}
