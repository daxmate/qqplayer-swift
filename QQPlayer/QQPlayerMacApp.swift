//  QQPlayerMacApp.swift
//  QQPlayer
//
//  macOS app entry point (QQPlayerMac target only). The iOS app uses
//  QQPlayerApp.swift as its @main; this file must stay out of the iOS
//  QQPlayer target to avoid duplicate @main declarations.
//
import AppKit
import SwiftUI

/// Mac 主窗尺寸的唯一事实源（**只此一处**）。
///
/// 为什么集中：最小尺寸原先散在三处且互相打架 —— `MacLibraryView` 要 1000×640、
/// `MacLibraryAccessGate` 外层却给整窗 760×520，而 scene 上既无 `.windowResizability`
/// 也无 `.defaultSize`。外层 flexible frame 把窗口最小尺寸压到 760，内层三栏溢出后被
/// 窗口裁掉（左栏标签、右栏播放器控制条被切）——「设了 1000 却不生效」的形态。
enum MacMainWindowMetrics {
    /// 已授权（三栏主界面）的最小内容尺寸：sidebar 180 + content 320 之外，
    /// detail 播放页还要放得下封面/控制条，toolbar 也不能开始挤叠。
    static let minWidth: CGFloat = 1100
    static let minHeight: CGFloat = 720
    /// 首次启动（无历史 frame）时的窗口尺寸：比最小尺寸留出余量。
    static let defaultWidth: CGFloat = 1280
    static let defaultHeight: CGFloat = 800
    /// 未授权引导页的最小尺寸：只有单列内容，不需要按三栏宽度占屏。
    static let setupMinWidth: CGFloat = 820
    static let setupMinHeight: CGFloat = 560
}

/// 迷你模式点 Dock 图标 → 回主窗（收起迷你窗/歌词窗；主窗态下幂等无副作用）。
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动兜底：AppKit 会按上次保存的 frame 恢复窗口，历史上被拖到过小的用户会
        // 一直「继承」那个小窗；`.windowResizability(.contentMinSize)` 只约束之后的
        // 拖拽，管不到已恢复的 frame，所以这里主动撑一次。
        Self.clampLaunchMainWindowIfNeeded()

        // 启动瞬间 SwiftUI 常常还没把主窗建出来（WindowGroup 异步装配），直接取窗口会落空；
        // 所以主路径是「窗口成为 key」时再兜一次 —— 幂等：尺寸够大就直接返回。
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                MacAppDelegate.clampTitleMainWindowIfNeeded(window)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DesktopWindowsManager.shared.showMainWindow()
        return true
    }

    /// 启动时的主窗兜底：此刻通常只有主窗，但标题可能还没设上（未授权引导页没有
    /// navigationTitle）→ 判据与 `DesktopWindowsManager.findMainWindow` 对齐：
    /// 标题「QQPlayer」优先，退化为第一个可成为主窗的非 panel 窗口。
    /// 迷你窗 / 歌词窗 / 桌面浮窗都是 `NSPanel`，被 `!($0 is NSPanel)` 天然排除。
    private static func clampLaunchMainWindowIfNeeded() {
        guard let window = NSApp.windows.first(where: { !($0 is NSPanel) && $0.title == "QQPlayer" })
            ?? NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain })
        else { return }
        clampToMinimumSize(window)
    }

    /// became-key 路径：只认标题「QQPlayer」的主窗。不能退化到 `canBecomeMain` ——
    /// 设置窗也是普通窗口、也能成为 key，退化会把它撑到三栏主界面的最小尺寸。
    private static func clampTitleMainWindowIfNeeded(_ window: NSWindow) {
        guard !(window is NSPanel), window.title == "QQPlayer" else { return }
        clampToMinimumSize(window)
    }

    /// 只放大不缩小：内容小于 `MacMainWindowMetrics.minWidth/minHeight` 时撑到最小尺寸；
    /// 已够大直接返回（重复触发无副作用）。
    private static func clampToMinimumSize(_ window: NSWindow) {
        let minContentSize = NSSize(
            width: MacMainWindowMetrics.minWidth,
            height: MacMainWindowMetrics.minHeight
        )
        let contentRect = window.contentRect(forFrameRect: window.frame)
        guard contentRect.width < minContentSize.width || contentRect.height < minContentSize.height else {
            return
        }

        let targetContentSize = NSSize(
            width: max(contentRect.width, minContentSize.width),
            height: max(contentRect.height, minContentSize.height)
        )
        var targetFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: targetContentSize))
        // 锚点：保持左上角不动（标题栏位置不跳），只向右下扩。
        targetFrame.origin.x = window.frame.minX
        targetFrame.origin.y = window.frame.maxY - targetFrame.height
        window.setFrame(targetFrame, display: true)
    }
}

@main
struct QQPlayerMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var deleteSettings = DeleteSettings.load()

    /// 「静音」菜单项的勾选状态 ⇄ 引擎：勾选即静音，动作走与播放条/快捷键同一个 toggleMute 入口。
    @MainActor
    private static var muteBinding: Binding<Bool> {
        Binding(
            get: { PlayerEngine.shared.isMuted },
            set: { isMuted in
                guard isMuted != PlayerEngine.shared.isMuted else { return }
                PlayerEngine.shared.toggleMute()
            }
        )
    }

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
                // MAS 批 2B：退出时释放曲库根安全作用域（书签保留，下次启动再恢复）。
                MacLibraryRootAccess.shared.releaseAccess()
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
        // MAS 批 2B（2026-10-29）：沙盒下容器外曲库根默认不可读，必须先解析
        // security-scoped 书签开启作用域，再 ensureRootExists（否则 createDirectory 必失败，
        // 且后续扫描把「无权限」当「空库」）。状态由 `MacLibraryRootAccess` 唯一维护，
        // 门视图 `MacLibraryAccessGate` 读同一份。
        MacLibraryRootAccess.shared.refreshState()
        MacLibraryRoot.ensureRootExists()
        // M6 T1：局域网同步 Host 常驻监听——App 启动即开始（设置页只做控制面，
        // 生命周期归 SyncHostCenter）。“允许局域网设备连接”关掉时不启动。
        MainActor.assumeIsolated {
            SyncHostCenter.shared.start()
        }
    }

    var body: some Scene {
        WindowGroup {
            // MAS 批 2B：未授权曲库根时整窗换成授权引导（不进空库主页）。
            // 强调色：`AccentInjector` 在被观察的 body 内求值注入 `.tint` 与
            // `\.appAccentColor`（旧写法在 App body 里读静态值，换色后不重新求值 ——
            // 是「只有部分 UI 变色」的根因，2026-11-13 修复）。
            AccentInjector {
                MacLibraryAccessGate {
                    MacLibraryView()
                }
            }
            // macOS 26 (Tahoe) 上 unified 工具栏默认透明，sidebar 内容会延伸到
            // 标题栏区域、第一行与交通灯重叠。强制工具栏背景不透明后内容从标题栏下方开始。
            .toolbarBackground(.visible, for: .windowToolbar)
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
            // MAS 批 2B：曲库根授权状态（门视图 + 设置页读同一份）。
            .environment(MacLibraryRootAccess.shared)
            .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
                deleteSettings = DeleteSettings.load()
            }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        // 窗口最小尺寸由内容决定（三栏主界面 = MacMainWindowMetrics.minWidth×minHeight）。
        // 少了这条，macOS 只在首次给 defaultSize，之后用户能一路拖到内容被裁。
        .windowResizability(.contentMinSize)
        // 首次启动（无历史 frame）的窗口尺寸；有历史 frame 时由 MacAppDelegate 启动兜底修正。
        .defaultSize(width: MacMainWindowMetrics.defaultWidth, height: MacMainWindowMetrics.defaultHeight)
        // 设置：系统 Settings scene → App 菜单自动出现「Settings…」(⌘,)，
        // 打开独立设置窗口（macOS 惯例；主窗口 toolbar 不放设置按钮）
        Settings {
            // 强调色同主窗：走 `AccentInjector`（在可观察 body 内注入，换色即时生效）。
            AccentInjector {
                MacSettingsView()
            }
            // MAS 批 2B：设置页要读曲库根授权状态（独立场景，不继承主窗环境）。
            .environment(MacLibraryRootAccess.shared)
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
            // 播放（App 级音量，2026-11-13）：动作与播放条 / 全局快捷键共用 PlayerEngine 入口。
            // 菜单项故意不挂 .keyboardShortcut —— 组合键由 MacKeyboardShortcuts 的 NSEvent
            // 监听统一消费（匹配即 return nil）；两处都挂会让 ⌘↑ 一次加两档。
            CommandMenu("player_controls".localized) {
                Button("volume_up".localized) {
                    PlayerEngine.shared.adjustVolume(by: PlayerVolumeModel.step)
                }
                Button("volume_down".localized) {
                    PlayerEngine.shared.adjustVolume(by: -PlayerVolumeModel.step)
                }
                Divider()
                Toggle("mute".localized, isOn: Self.muteBinding)
            }
        }
    }
}
