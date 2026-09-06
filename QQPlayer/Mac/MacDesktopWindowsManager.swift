//
//  MacDesktopWindowsManager.swift
//  QQPlayer
//
//  桌面浮窗管理器（E3；QQPlayerMac target only）：迷你播放器窗 + 桌面歌词窗
//  两个 NSPanel 悬浮窗的生命周期、frame 记忆与显隐收敛。
//
//  单一事实源：窗口显隐 = DeleteSettings 开关（miniWindowEnabled /
//  desktopLyricEnabled）。设置页开关 / 菜单项 / 窗内关闭按钮都只写设置并 save()
//  → .qqplayerSettingsDidChange → 本管理器 reconcile() 统一收敛（启动恢复、
//  设置改动、窗内关闭走同一条路径，不重复实现）。
//
//  形态说明（v1 待用户确认）：对齐 web 双窗（迷你窗 + 桌面歌词两个独立小窗），
//  均为无边框 NSPanel：透明背景、置顶（.floating）、随窗口背景拖动、
//  canJoinAllSpaces + fullScreenAuxiliary（全屏 app 之上也可见）、非激活面板
//  （.nonactivatingPanel，点控件不抢前台 app 焦点）。关闭 = 隐藏不退出 app。
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

    /// 迷你窗/歌词窗当前显隐（菜单勾选态绑定；与 DeleteSettings 开关同步）
    @Published private(set) var isMiniVisible = false
    @Published private(set) var isLyricVisible = false

    private var miniPanel: NSPanel?
    private var lyricPanel: NSPanel?
    private var settingsObserver: NSObjectProtocol?
    private var moveObservers: [NSObjectProtocol] = []
    private var didStart = false

    private init() {}

    // MARK: - 生命周期

    /// App 启动调用一次：监听设置变化 + 按 DeleteSettings 恢复窗口
    /// （默认关不弹；用户开启过后下次启动自动恢复——任务拍板语义）。
    func start() {
        guard !didStart else { return }
        didStart = true
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .qqplayerSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reconcile()
            }
        }
        reconcile()
    }

    // MARK: - 公开开关（菜单/视图调用：只写 DeleteSettings，收敛交给 reconcile）

    func setMiniWindowEnabled(_ enabled: Bool) {
        var settings = DeleteSettings.load()
        guard settings.miniWindowEnabled != enabled else { return }
        settings.miniWindowEnabled = enabled
        settings.save()
    }

    func setDesktopLyricEnabled(_ enabled: Bool) {
        var settings = DeleteSettings.load()
        guard settings.desktopLyricEnabled != enabled else { return }
        settings.desktopLyricEnabled = enabled
        settings.save()
    }

    /// 唤起主窗口（迷你窗封面/标题/恢复按钮；找不到主窗时仅激活 app——
    /// SwiftUI WindowGroup 无公开 API 重建已关闭主窗，用户 Dock 点开即可）。
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = Self.findMainWindow() {
            window.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - 收敛（唯一映射设置 → 窗口显隐的地方）

    private func reconcile() {
        let settings = DeleteSettings.load()
        apply(.mini, visible: settings.miniWindowEnabled)
        apply(.lyric, visible: settings.desktopLyricEnabled)
    }

    private func apply(_ kind: PanelKind, visible: Bool) {
        // private(set) @Published 经 keyPath 下标赋值会撞 immutable 检查，直接 switch 赋值
        switch kind {
        case .mini:
            guard isMiniVisible != visible else { return }
            isMiniVisible = visible
        case .lyric:
            guard isLyricVisible != visible else { return }
            isLyricVisible = visible
        }
        if visible {
            show(kind)
        } else {
            panel(kind)?.orderOut(nil)
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
        let host = NSHostingView(rootView: rootView(for: kind))
        let panel = Self.makePanel(content: host, contentSize: kind.contentSize)
        switch kind {
        case .mini: miniPanel = panel
        case .lyric: lyricPanel = panel
        }
        let token = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        ) { [weak self, weak panel] _ in
            Task { @MainActor in
                guard let self, let panel else { return }
                UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: kind.frameKey)
            }
        }
        moveObservers.append(token)
        return panel
    }

    @ViewBuilder
    private func rootView(for kind: PanelKind) -> some View {
        switch kind {
        case .mini: MacMiniPlayerView()
        case .lyric: MacDesktopLyricView()
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

    /// 主窗口定位：WindowGroup 的标题为「QQPlayer」；找不到退化为第一个非 panel 主窗口
    private static func findMainWindow() -> NSWindow? {
        NSApp.windows.first { !($0 is NSPanel) && $0.title == "QQPlayer" }
            ?? NSApp.windows.first { !($0 is NSPanel) && $0.canBecomeMain }
    }
}
