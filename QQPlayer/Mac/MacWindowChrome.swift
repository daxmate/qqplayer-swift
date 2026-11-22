//
//  MacWindowChrome.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  整窗毛玻璃时让**标题栏 / 工具栏背景透明**（让窗底的模糊封面透上来），关闭时还原。
//
//  API 选择（部署目标 macOS 14.0）：
//    - SwiftUI `toolbarBackground(.hidden, for: .windowToolbar)` 自 macOS 13 起可用，但已被
//      标记 deprecated（renamed: toolbarBackgroundVisibility），会用就吃 deprecation 警告；
//      新名 `toolbarBackgroundVisibility(_:for:)` 要 macOS 15.0 ⇒ 这里用 `#available` 分档。
//    - macOS 14 的退路是 AppKit：`titlebarAppearsTransparent` + `titlebarSeparatorStyle = .none`
//      + `toolbar.showsBaselineSeparator = false`（不动 windowStyle / 拖拽区 / 按钮位置）。
//

import AppKit
import SwiftUI

// MARK: - 窗口外观（AppKit）

/// 把窗口标题栏透明化开关挂到主窗 NSWindow 上；关闭时恢复取到的原值。
struct MacWindowChromeTransparency: NSViewRepresentable {
    /// true = 标题栏/工具栏背景透明（毛玻璃生效）
    let transparent: Bool

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        let transparent = transparent
        // 视图刚入窗时 window 还是 nil；下一轮 runloop 再取（常见 SwiftUI→AppKit 取值写法）
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            context.coordinator.apply(transparent: transparent, to: window)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.restore()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private weak var window: NSWindow?
        private var originalTitlebarTransparent: Bool?
        private var originalSeparatorStyle: NSTitlebarSeparatorStyle?
        private var originalToolbarBaseline: Bool?
        func apply(transparent: Bool, to window: NSWindow) {
            if self.window !== window {
                restore()
                self.window = window
            }
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
            // ⚠️ 不碰 styleMask：`.fullSizeContentView` 会让内容钻到标题栏/工具栏下面
            // （侧栏首项压红绿灯、中栏表头顶工具栏、封面被顶部裁掉）。标题栏玻璃效果
            // 只靠上面三项 + SwiftUI 的 toolbarBackgroundVisibility(.hidden) 就够。
        }

        /// 还原为接管前的值（关开关 / 视图移除都要走到这里）
        func restore() {
            guard let window else { return }
            if let value = originalTitlebarTransparent {
                window.titlebarAppearsTransparent = value
            }
            if let style = originalSeparatorStyle {
                window.titlebarSeparatorStyle = style
            }
            if let baseline = originalToolbarBaseline {
                window.toolbar?.showsBaselineSeparator = baseline
            }
            originalTitlebarTransparent = nil
            originalSeparatorStyle = nil
            originalToolbarBaseline = nil
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
