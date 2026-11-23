//
//  MacWindowGlassChrome.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  整窗玻璃「通到标题栏」的窗口 chrome（2026-11-22 用户拍板）：
//    - 玻璃生效时把主窗变成「内容铺满整窗、标题栏透明」的形态，窗底的模糊封面才能
//      一直铺到标题栏 / 工具栏背后（整窗一块，而不是只在三栏内容区里一块）；
//    - 关闭开关 / 视图离开窗口 / 切到迷你窗（NSPanel）时**逐项还原**成接管前的值。
//
//  只动四项窗口属性（全部记录原值）：
//    styleMask（只在「是我们加的」时才移除 .fullSizeContentView）
//    titlebarAppearsTransparent / isOpaque / backgroundColor
//
//  ⚠️ 不碰布局：不做任何间距 / 安全区补偿，不改工具栏样式 / 按钮位置。
//     正文仍在系统安全区内，只有玻璃那一层背景忽略安全区（见 MacWindowGlassLayer）。
//

import AppKit
import SwiftUI

// MARK: - 生效状态（判定点与窗口内容根之间）

/// 「整窗玻璃是否生效」的共享状态。
///
/// 为什么需要它：工具栏背景必须由**窗口内容根**给出（`QQPlayerMacApp` 的 WindowGroup），
/// 而「玻璃是否生效」只有 `MacLibraryView` 判定得了（开关 + 当前曲目有封面 + 未开降低透明度）。
/// 组合根拿不到封面 ⇒ 判定点写入、内容根只读，不在两处各判一遍（同一语义只有一处实现）。
@MainActor
@Observable
final class MacWindowGlassChromeState {
    /// 组合根唯一装配点（场景根 `.environment(MacWindowGlassChromeState.shared)`）；
    /// 视图层一律走 `@Environment`，不直连 `.shared`（见 ViewSharedSingletonContractTests）。
    static let shared = MacWindowGlassChromeState()

    var isActive = false
}

/// 窗口内容根：按玻璃生效与否切换工具栏背景可见性。
/// - 玻璃生效：`.hidden`，窗底模糊封面透到标题栏背后；
/// - 否则：`.visible`，保住 macOS 26 上「侧栏内容不钻进标题栏、不压交通灯」的既有修复。
struct MacWindowChromeToolbarBackground: ViewModifier {
    @Environment(MacWindowGlassChromeState.self) private var state

    func body(content: Content) -> some View {
        content.toolbarBackground(state.isActive ? .hidden : .visible, for: .windowToolbar)
    }
}

// MARK: - 窗口 chrome

/// 把「标题栏透明化 + 内容铺满整窗」挂到主窗上；`active == false` 或视图卸载时还原。
struct MacWindowGlassChrome: NSViewRepresentable {
    /// 玻璃是否生效（开关 + 有封面 + 未开降低透明度，判定唯一入口 PlayerGlassBackground）
    let active: Bool

    func makeNSView(context: Context) -> ChromeApplier {
        ChromeApplier()
    }

    func updateNSView(_ view: ChromeApplier, context: Context) {
        view.apply(active: active)
    }

    static func dismantleNSView(_ view: ChromeApplier, coordinator: ()) {
        view.restore()
    }

    /// 只写窗口属性、不画任何东西的探针视图。
    final class ChromeApplier: NSView {
        private var pendingActive = false
        private var appliedWindow: NSWindow?
        /// 是否由本类插入的 `.fullSizeContentView`（还原时只在「是我们加的」情况下移除）
        private var didAddFullSizeContentView = false
        private var originalTitlebarAppearsTransparent = false
        private var originalIsOpaque = true
        private var originalBackgroundColor: NSColor?
        /// 上一次实际应用的玻璃状态（nil = 本视图还没接管过；只用来识别「翻转」这个时刻）
        private var lastAppliedActive: Bool?

        /// 纯属性探针：不能参与命中测试，否则会挡住窗口内容的点击。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 离开窗口（切迷你窗 / 场景重建）就先还原，避免把外观留在后台窗口上
            guard window != nil else {
                // 离开窗口：外观还原，且下一次挂载按「首次接管」处理（不误判成翻转）
                lastAppliedActive = nil
                restore()
                return
            }
            apply(active: pendingActive)
        }

        func apply(active: Bool) {
            pendingActive = active
            guard let window else { return }
            // 主窗以外的窗口（设置窗 / 浮窗 / 迷你窗与桌面歌词的 NSPanel）一律不碰
            guard !(window is NSPanel) else {
                restore()
                return
            }
            // 翻转时刻要补一次工具栏重排：开玻璃（.hidden）和关玻璃（.visible）两个方向都需要，
            // 所以放在 restore() 之前（见 rebuildToolbarBackgroundPlatters）。
            let didFlip = lastAppliedActive != nil && lastAppliedActive != active
            lastAppliedActive = active
            if didFlip {
                rebuildToolbarBackgroundPlatters(in: window)
            }
            guard active else {
                restore()
                return
            }
            if appliedWindow !== window {
                restore()
                appliedWindow = window
                originalTitlebarAppearsTransparent = window.titlebarAppearsTransparent
                originalIsOpaque = window.isOpaque
                originalBackgroundColor = window.backgroundColor
            }
            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
                didAddFullSizeContentView = true
            }
        }

        /// 状态翻转后补一次工具栏重排，让玻璃胶囊按**新**的共享背景可见性重建。
        ///
        /// 为什么需要：`ToolbarContent.sharedBackgroundVisibility` 只更新 SwiftUI 侧的数据，
        /// `NSToolbar` 不会为已经建好的 item viewer 重建背景胶囊（`NSToolbarPlatterView`）。
        /// 真机表现：冷启动时封面还没就绪 ⇒ `isWindowGlassActive == false`，胶囊按 `.visible`
        /// 建好；随后状态翻成 `.hidden`，4 个按钮仍然带着底色，点一次折叠侧栏（工具栏整体
        /// 重排）才消失。反向同理：关开关后胶囊也不会自己回来。
        ///
        /// 做法：把工具栏 `displayMode` 设成另一档、紧接着设回原值——同一回合内完成，最终值
        /// 不变，只逼 NSToolbar 重排一次并按当前值重建胶囊。只动这一个公开属性，不碰布局 /
        /// 内容 / 自定义。
        ///
        /// 为什么跳两次主队列：SwiftUI 的工具栏更新晚于视图更新，一次跳转拿到的还是旧值
        /// （/tmp 探针实测：单次跳转失败，两次稳定；胶囊计数归零/恢复、按钮 frame 与「一开始
        /// 就是该状态」逐项一致）。
        private func rebuildToolbarBackgroundPlatters(in window: NSWindow) {
            DispatchQueue.main.async { [weak window] in
                DispatchQueue.main.async { [weak window] in
                    guard let window, let toolbar = window.toolbar else { return }
                    let mode = toolbar.displayMode
                    toolbar.displayMode = mode == .iconOnly ? .iconAndLabel : .iconOnly
                    toolbar.displayMode = mode
                }
            }
        }

        /// 逐项还原成接管前的值（关开关 / 卸载 / 换窗口都要走到这里；幂等）。
        func restore() {
            defer {
                appliedWindow = nil
                didAddFullSizeContentView = false
                originalBackgroundColor = nil
            }
            guard let window = appliedWindow else { return }
            window.titlebarAppearsTransparent = originalTitlebarAppearsTransparent
            window.isOpaque = originalIsOpaque
            if let originalBackgroundColor {
                window.backgroundColor = originalBackgroundColor
            }
            if didAddFullSizeContentView {
                window.styleMask.remove(.fullSizeContentView)
            }
        }
    }
}
