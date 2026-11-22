//
//  MacWindowChrome.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  整窗毛玻璃时让**标题栏 / 工具栏背景透明**（让窗底的模糊封面透上来），关闭时还原；
//  同时把「标题栏 + 工具栏」的**实测高度 T** 上报给 SwiftUI，内容据此整体下移，
//  避免被红绿灯 / 工具栏压住（2026-11-22 用户拍板：方案 (a) 恢复通顶 + 补留白）。
//
//  API 选择（部署目标 macOS 14.0）：
//    - SwiftUI `toolbarBackground(.hidden, for: .windowToolbar)` 自 macOS 13 起可用，但已被
//      标记 deprecated（renamed: toolbarBackgroundVisibility），会用就吃 deprecation 警告；
//      新名 `toolbarBackgroundVisibility(_:for:)` 要 macOS 15.0 ⇒ 这里用 `#available` 分档。
//    - macOS 14 的退路是 AppKit：`titlebarAppearsTransparent` + `titlebarSeparatorStyle = .none`
//      + `toolbar.showsBaselineSeparator = false`。
//    - `.fullSizeContentView`：只有插入它，窗口背景（SwiftUI 画的模糊封面）才能延伸到标题栏；
//      代价是内容也从窗口顶边开始 ⇒ 必须补 T 的顶部留白（MacLibraryView 用 `.padding(.top, T)`）。
//
//  T 的来源：`window.frame.height - window.contentLayoutRect.height`（真实测量，不写常量）；
//  在 flags 生效后的下一轮 runloop 取，并在 resize / 进出全屏 / 换屏 / 成为 key 窗口时重取。
//  全屏（styleMask 含 .fullScreen）恒为 0 —— 全屏没有标题栏，内容不能留白。
//

import AppKit
import SwiftUI

// MARK: - 窗口外观（AppKit）

/// 把窗口标题栏透明化开关挂到主窗 NSWindow 上；关闭时恢复取到的原值。
/// 生效期间同时上报「标题栏 + 工具栏」实测高度（0 = 不需要留白）。
struct MacWindowChromeTransparency: NSViewRepresentable {
    /// true = 标题栏/工具栏背景透明（毛玻璃生效）
    let transparent: Bool
    /// 实测高度回调（pt）：玻璃生效时 = 标题栏 + 工具栏；关闭 / 全屏 = 0
    var onTitlebarHeightChange: (CGFloat) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowProbeView {
        let probe = WindowProbeView(frame: .zero)
        probe.onWindowChange = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return probe
    }

    func updateNSView(_ view: WindowProbeView, context: Context) {
        context.coordinator.configure(transparent: transparent, report: onTitlebarHeightChange)
        context.coordinator.attach(to: view.window)
    }

    /// 零尺寸探针：只用来「找到宿主窗口」并接收窗口变化通知的回跳（不绘制、不参与布局）。
    final class WindowProbeView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var window: NSWindow?
        private var transparent = false
        private var report: (CGFloat) -> Void = { _ in }

        private var originalTitlebarTransparent: Bool?
        private var originalSeparatorStyle: NSTitlebarSeparatorStyle?
        private var originalToolbarBaseline: Bool?
        /// 是否由本类插入的 `.fullSizeContentView`（还原时只在「是我们加的」情况下移除）
        private var didAddFullSizeContentView = false
        /// 已上报的高度（去重：同一值不重复驱动 SwiftUI 重排）
        private var lastReportedHeight: CGFloat = -1
        /// 上次应用的开关值（去重：避免每次 SwiftUI 更新都重设窗口外观/重测）
        private var lastAppliedTransparent: Bool?

        func configure(transparent: Bool, report: @escaping (CGFloat) -> Void) {
            self.transparent = transparent
            self.report = report
        }

        /// 绑定/切换宿主窗口，并按当前开关应用外观。
        func attach(to window: NSWindow?) {
            guard let window else {
                unobserve()
                restore()
                return
            }
            let windowChanged = self.window !== window
            if windowChanged {
                unobserve()
                restore()
                self.window = window
                lastReportedHeight = -1
                observe(window)
            }
            // SwiftUI 每次更新都会走到这里：只在「换窗口 / 开关变化」时才动 AppKit 与测量
            if windowChanged || lastAppliedTransparent != transparent {
                lastAppliedTransparent = transparent
                apply(transparent: transparent, to: window)
                scheduleMeasure()
            }
        }

        // MARK: 外观

        private func apply(transparent: Bool, to window: NSWindow) {
            guard transparent else {
                restore()
                return
            }
            if originalTitlebarTransparent == nil {
                originalTitlebarTransparent = window.titlebarAppearsTransparent
                originalSeparatorStyle = window.titlebarSeparatorStyle
                originalToolbarBaseline = window.toolbar?.showsBaselineSeparator
            }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.toolbar?.showsBaselineSeparator = false
            // 内容通到标题栏下方：窗口底（模糊封面）才能透到标题栏 / 工具栏区域
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
                didAddFullSizeContentView = true
            }
        }

        /// 还原为接管前的值（关开关 / 视图移除都要走到这里），并把留白归零。
        func restore() {
            if let window {
                if let value = originalTitlebarTransparent {
                    window.titlebarAppearsTransparent = value
                }
                if let style = originalSeparatorStyle {
                    window.titlebarSeparatorStyle = style
                }
                if let baseline = originalToolbarBaseline {
                    window.toolbar?.showsBaselineSeparator = baseline
                }
                if didAddFullSizeContentView {
                    window.styleMask.remove(.fullSizeContentView)
                }
            }
            didAddFullSizeContentView = false
            originalTitlebarTransparent = nil
            originalSeparatorStyle = nil
            originalToolbarBaseline = nil
            publish(0)
        }

        // MARK: 尺寸测量

        /// 实测「标题栏 + 工具栏」高度：窗口高度 − 内容布局区高度。
        /// 全屏没有标题栏（`contentLayoutRect` 与 frame 同高）→ 0；未插入 fullSizeContentView → 0。
        private func measure(in window: NSWindow) -> CGFloat {
            guard window.styleMask.contains(.fullSizeContentView) else { return 0 }
            guard !window.styleMask.contains(.fullScreen) else { return 0 }
            let height = window.frame.height - window.contentLayoutRect.height
            return height.isFinite ? max(height, 0) : 0
        }

        /// 布局落定后的下一轮 runloop 再测（刚改 styleMask 时 contentLayoutRect 还是旧值）。
        private func scheduleMeasure() {
            // 两跳：① 等 styleMask / 布局提交；② 等 AppKit 完成 resize / 全屏切换后的布局
            DispatchQueue.main.async { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window else { return }
                    self.publish(self.measure(in: window))
                }
            }
        }

        private func publish(_ height: CGFloat) {
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            AppLog.info(.ui, "[mac.titlebar] T=\(String(format: "%.1f", height)) fullScreen=\(window?.styleMask.contains(.fullScreen) == true)")
            report(height)
        }

        // MARK: 窗口变化通知

        private func observe(_ window: NSWindow) {
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didChangeScreenNotification,
                NSWindow.didBecomeKeyNotification,
            ]
            for name in names {
                center.addObserver(
                    self,
                    selector: #selector(windowDidChange),
                    name: name,
                    object: window
                )
            }
        }

        private func unobserve() {
            // 换窗口时必须先摘掉旧监听（deinit 之外唯一允许的摘除点，见 swiftlint 规则）
            // swiftlint:disable:next notification_center_detachment
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func windowDidChange() {
            guard let window, transparent else { return }
            _ = window
            scheduleMeasure()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

// MARK: - 标题栏留白探针（临时诊断）

/// 侧栏内容顶部的一次测量读数。
/// `contentTopY` = 探针在窗口坐标系里的 y；`safeTop` = 该处 SwiftUI 认为的顶部安全区。
struct MacTitlebarProbeReading: Equatable {
    var contentTopY: CGFloat
    var safeTop: CGFloat
}

/// 零高度探针：放在侧栏最顶部（内容顶），把实测位置回吐给 MacLibraryView 写诊断日志。
/// 只测量、不绘制、不占高度 → 对布局零影响。
struct MacTitlebarProbe: View {
    var onReading: (MacTitlebarProbeReading) -> Void

    var body: some View {
        Color.clear
            .frame(height: 0)
            .onGeometryChange(for: MacTitlebarProbeReading.self) { proxy in
                MacTitlebarProbeReading(
                    contentTopY: proxy.frame(in: .global).minY,
                    safeTop: proxy.safeAreaInsets.top
                )
            } action: { reading in
                onReading(reading)
            }
    }
}

// MARK: - 工具栏背景（SwiftUI，macOS 15+）

/// 工具栏背景可见性：macOS 15+ 走原生 `toolbarBackgroundVisibility`；
/// macOS 14 由上面 AppKit 的 titlebar 透明化覆盖（不调用已废弃 API，避免编译警告）。
private struct WindowToolbarBackgroundVisibility: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(hidden ? .hidden : .automatic, for: .windowToolbar)
        } else {
            content
        }
    }
}

extension View {
    /// 整窗毛玻璃生效时隐藏主窗工具栏背景（关闭时恢复系统默认）
    func macWindowToolbarBackgroundHidden(_ hidden: Bool) -> some View {
        modifier(WindowToolbarBackgroundVisibility(hidden: hidden))
    }
}
