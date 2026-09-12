//
//  MacDesktopWindowsManager.swift
//  QQPlayer
//
//  桌面浮窗管理器（E3→v2；QQPlayerMac target only）：迷你播放器窗 + 桌面歌词窗
//  两个 NSPanel 悬浮窗的生命周期、frame 记忆与显隐收敛。
//
//  v2 语义（用户 2026-09-06 拍板，主窗 ⇄ 迷你模式互斥）：
//  - 主窗态：歌词在主窗内面板，不存在桌面歌词。
//  - 迷你模式：主窗工具栏迷你按钮进入——主窗收起（orderOut），弹迷你窗 +
//    桌面歌词窗（是否带歌词窗看 DeleteSettings.miniLyricsEnabled）。
//  - 迷你窗内：点封面 = 返回主窗（收迷你窗 + 歌词窗，恢复主窗）；歌词按钮
//    toggle miniLyricsEnabled（只影响歌词窗）。
//  - 设置页「显示迷你窗按钮」只决定主窗工具栏入口可见性，不直接开关窗口；
//    窗口显隐是瞬态——启动恒回主窗态，不自动弹窗（去掉 v1 重启恢复弹窗语义）。
//  - 显隐收敛：歌词窗显隐 = 迷你模式激活 && miniLyricsEnabled；迷你窗显隐 =
//    迷你模式激活。设置变化（miniLyricsEnabled）走 .qqplayerSettingsDidChange →
//    reconcile()，与窗内按钮同一条路径，不重复实现。
//
//  形态说明（v1→v2）：原双窗独立共存改为互斥模式切换（web 迷你窗语义对齐：
//  迷你模式是主窗的收起态，桌面歌词是迷你模式的歌词补位）。两窗均为无边框 NSPanel：
//  透明背景、置顶（.floating）、随窗口背景拖动、canJoinAllSpaces +
//  fullScreenAuxiliary（全屏 app 之上也可见）、非激活面板（.nonactivatingPanel，
//  点控件不抢前台 app 焦点）。
//
import AppKit
import SwiftUI

@MainActor
final class DesktopWindowsManager: ObservableObject {
    static let shared = DesktopWindowsManager()

    /// 窗种类（frame key / 默认落点 / 内容尺寸按种类区分）
    private enum PanelKind {
        case mini
        case lyric

        var frameKey: String {
            switch self {
            case .mini: return "DesktopWindows.miniFrame"
            case .lyric: return "DesktopWindows.lyricFrame"
            }
        }

        var contentSize: NSSize {
            switch self {
            case .mini: return NSSize(width: 372, height: 140)
            case .lyric: return NSSize(width: 520, height: 170)
            }
        }
    }

    /// 迷你模式激活（迷你窗可见；主窗此时收起）。
    @Published private(set) var isMiniActive = false
    /// 桌面歌词窗显隐（仅迷你模式中可为 true；mini 窗歌词按钮点亮态绑定）。
    @Published private(set) var isLyricVisible = false
    /// 模式状态机（决策单一事实源；isMiniActive/isLyricVisible 与之恒镜像，UI 绑定用）
    private var mode = DesktopWindowModeState()

    private var miniPanel: NSPanel?
    private var lyricPanel: NSPanel?
    /// 各浮窗的 hosting view（强调色设置变化时重建 rootView 刷新）
    private var panelHosts: [PanelKind: NSHostingView<AnyView>] = [:]
    /// 当前已注入浮窗的强调色 key（变化时重建 rootView）
    private var lastInjectedAccentName: String?
    private var settingsObserver: NSObjectProtocol?
    private var moveObservers: [NSObjectProtocol] = []
    private var didStart = false

    private init() {}

    // MARK: - 生命周期

    /// App 启动调用一次：监听设置变化并收敛歌词窗显隐。
    /// （v2：启动恒回主窗态，不自动弹迷你窗/歌词窗——显隐是瞬态操作。）
    func start() {
        guard !didStart else { return }
        didStart = true
        lastInjectedAccentName = DeleteSettings.load().accentColorName
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .qqplayerSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reconcile()
            }
        }
    }

    // MARK: - 模式切换（主窗 ⇄ 迷你）

    /// 进入迷你模式：收起主窗，弹迷你窗 + 桌面歌词窗（看 miniLyricsEnabled）。
    func enterMiniMode() {
        guard mode.enterMini() else { return }
        isMiniActive = mode.isMiniActive
        hideMainWindow()
        show(.mini)
        reconcile()
    }

    /// 返回主窗（迷你窗封面/标题点击、Dock 重开）：收迷你窗 + 歌词窗，恢复主窗。
    /// 幂等：主窗态调用仅激活 + 前置主窗，无副作用。
    func showMainWindow() {
        if mode.showMainWindow() {
            isMiniActive = false
            isLyricVisible = false
            panel(.mini)?.orderOut(nil)
            panel(.lyric)?.orderOut(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = Self.findMainWindow() {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// 迷你模式内桌面歌词开关（mini 窗歌词按钮 / 设置页开关共用：只写设置，收敛交给 reconcile）。
    func setMiniLyricsEnabled(_ enabled: Bool) {
        var settings = DeleteSettings.load()
        guard settings.miniLyricsEnabled != enabled else { return }
        settings.miniLyricsEnabled = enabled
        settings.save()
    }

    // MARK: - 收敛（歌词窗显隐 = 迷你模式激活 && miniLyricsEnabled）

    private func reconcile() {
        refreshPanelRootViews()
        let settings = DeleteSettings.load()
        guard mode.reconcile(miniLyricsEnabled: settings.miniLyricsEnabled) else { return }
        isLyricVisible = mode.isLyricVisible
        if isLyricVisible {
            show(.lyric)
        } else {
            panel(.lyric)?.orderOut(nil)
        }
    }

    /// 浮窗是手动 NSHostingView，不继承 App 场景（WindowGroup/Settings）的
    /// .environment(\\.appAccentColor)/.tint 注入 → 强调色需在此显式注入；
    /// **重建条件只有强调色**（2026-09-12 审计 L3：原注释写「设置变化重建 rootView」
    /// 与实现不符——其余设置项由浮窗内部自订阅 .qqplayerSettingsDidChange 刷新，
    /// 不需要重建整个 rootView；这里只负责强调色。
    private func refreshPanelRootViews() {
        let accentName = DeleteSettings.load().accentColorName
        guard accentName != lastInjectedAccentName else { return }
        lastInjectedAccentName = accentName
        for (kind, host) in panelHosts {
            host.rootView = AnyView(rootView(for: kind))
        }
    }

    private func show(_ kind: PanelKind) {
        let panel = ensurePanel(kind)
        let frame = usableFrame(for: kind)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    // MARK: - Panel 创建

    private func panel(_ kind: PanelKind) -> NSPanel? {
        switch kind {
        case .mini: return miniPanel
        case .lyric: return lyricPanel
        }
    }

    private func ensurePanel(_ kind: PanelKind) -> NSPanel {
        if let existing = panel(kind) { return existing }
        let host = NSHostingView(rootView: AnyView(rootView(for: kind)))
        panelHosts[kind] = host
        let panel = Self.makePanel(content: host, contentSize: kind.contentSize)
        switch kind {
        case .mini: miniPanel = panel
        case .lyric: lyricPanel = panel
        }
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak panel] _ in
            Task { @MainActor in
                guard let panel else { return }
                UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: kind.frameKey)
            }
        }
        // 观察者从不显式移除（2026-09-12 审计 L3 核实）：面板 isReleasedWhenClosed=false
        // 且 ensurePanel 每 kind 只建一次 → 观察者与面板同生共死，数量有界，无泄漏。
        moveObservers.append(token)
        return panel
    }

    @ViewBuilder
    private func rootView(for kind: PanelKind) -> some View {
        switch kind {
        case .mini:
            // 迷你窗控件（播放键/歌词点亮态）跟随 App 强调色：NSPanel 内容不继承
            // App 场景注入，accent 在此显式注入（设置改动经 refreshPanelRootViews 重建）
            let accent = MacAppearance.accentColor(forKey: DeleteSettings.load().accentColorName)
            MacMiniPlayerView()
                .environment(\.appAccentColor, accent)
                .tint(accent)
        case .lyric:
            MacDesktopLyricView()
        }
    }

    /// 无边框透明置顶非激活面板（web 双窗壳语义：不抢焦点、全空间可见、背景拖动）。
    private static func makePanel(content: NSView, contentSize: NSSize) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        content.frame = NSRect(origin: .zero, size: contentSize)
        content.autoresizingMask = [.width, .height]
        panel.contentView = content
        return panel
    }

    // MARK: - Frame 恢复（多屏安全）

    private func savedFrame(_ kind: PanelKind) -> CGRect? {
        guard let string = UserDefaults.standard.string(forKey: kind.frameKey) else { return nil }
        let frame = NSRectFromString(string)
        return frame == .zero ? nil : frame
    }

    /// 已存 frame 须在当前屏幕组可见（拔掉外接屏后不把窗口丢到看不见的地方）：
    /// 与任一屏幕可见区相交 ≥ 80x60 才算可用，否则回落默认位置；最后钳回锚点屏。
    private func usableFrame(for kind: PanelKind) -> CGRect {
        let anchor = anchorScreen()
        let visible = anchor.visibleFrame
        var frame: CGRect
        if let saved = savedFrame(kind), Self.isUsableOnCurrentScreens(saved) {
            frame = saved
        } else {
            frame = Self.defaultFrame(for: kind, on: visible)
        }
        frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
        frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
        return frame
    }

    private static func isUsableOnCurrentScreens(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            let intersection = screen.visibleFrame.intersection(frame)
            return intersection.width >= 80 && intersection.height >= 60
        }
    }

    private static func defaultFrame(for kind: PanelKind, on visible: NSRect) -> CGRect {
        let origin: NSPoint
        switch kind {
        case .mini:
            // 迷你窗：锚点屏右下角（Dock 上方）
            origin = NSPoint(x: visible.maxX - kind.contentSize.width - 24, y: visible.minY + 24)
        case .lyric:
            // 歌词窗：锚点屏顶部居中（菜单栏下方）
            origin = NSPoint(x: visible.midX - kind.contentSize.width / 2, y: visible.maxY - kind.contentSize.height - 60)
        }
        return NSRect(origin: origin, size: kind.contentSize)
    }

    /// 锚点屏：优先主窗口所在屏，其次 NSScreen.main
    private func anchorScreen() -> NSScreen {
        if let window = Self.findMainWindow(), let screen = window.screen {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    /// 收起主窗（进入迷你模式时；orderOut 非 close，SwiftUI WindowGroup 状态保留）
    private func hideMainWindow() {
        guard let window = Self.findMainWindow() else { return }
        window.orderOut(nil)
    }

    /// 主窗口定位：WindowGroup 的标题为「QQPlayer」；找不到退化为第一个非 panel 主窗口
    private static func findMainWindow() -> NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) && $0.title == "QQPlayer" }
            ?? NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }
    }
}
