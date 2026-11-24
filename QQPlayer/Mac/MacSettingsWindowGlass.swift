//
//  MacSettingsWindowGlass.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  设置窗「整窗玻璃」原型（2026-11-24）：
//    - 设置窗（⌘,）整体做成一整块半透明玻璃：窗口背景清空 + 标题栏透明 + 内容铺满整窗，
//      底下垫一层 NSVisualEffectView（.behindWindow）采样「窗口背后的屏幕内容」——
//      设置窗浮在主窗上时透出的就是主窗的封面玻璃，视觉上像同一块玻璃；
//    - 生效判定与主窗同一套语义：开关开 + 未开系统「降低透明度」（唯一实现见
//      `PlayerGlassBackground`）。不生效时逐项还原窗口属性，设置窗保持完全现状；
//    - 设置窗内部**不叠第二层材质**：侧栏复用 `MacSidebarMaterialStripper`，
//      各分类页的 Form / List 底走 `macSettingsGlassListBackground()`（设置窗作用域环境值，
//      不向主窗 / 工具栏面板泄露）。
//
//  ⚠️ 只动窗口外观与背景层，不改布局：栏宽 / 行高 / 字号 / padding 一律不动。
//

import AppKit
import SwiftUI

// MARK: - 材质 / 雾面档位（原型期集中在这里，改档只改这一段）

private enum MacSettingsGlassTuning {
    /// 材质候选（按需换一行即可挑效果）：
    /// - `.underWindowBackground`（当前）：系统窗口底材质，最中性，透出背后窗口的整体明暗；
    /// - `.sidebar`：更亮一档，整窗更像「侧栏玻璃」；
    /// - `.hudWindow`：更暗、雾更重，桌面上浅色内容多时更稳。
    static let material: NSVisualEffectView.Material = .underWindowBackground

    /// 采样时机：`.behindWindow` = 采样窗口背后的屏幕内容（主窗玻璃生效时就是主窗）。
    static let blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    /// 材质常驻：不随窗口激活状态淡出，避免点开设置窗时闪一帧。
    static let state: NSVisualEffectView.State = .active

    /// 雾面不透明度（0 = 只用系统材质；0.10–0.20 提高正文可读性）。
    static let scrimOpacity: CGFloat = 0.10
}

// MARK: - 设置窗作用域的环境值

private struct MacSettingsGlassActiveKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// 设置窗玻璃是否生效（只在设置窗场景注入；主窗 / 面板仍读 `macWindowGlassActive`）。
    var macSettingsGlassActive: Bool {
        get { self[MacSettingsGlassActiveKey.self] }
        set { self[MacSettingsGlassActiveKey.self] = newValue }
    }
}

/// 设置窗内的 List / Form 让路给整窗玻璃（语义同 `macGlassListBackground`，键不同：
/// 主窗的 `macWindowGlassActive` 会一并影响工具栏面板等共享视图，不能混用）。
struct MacSettingsGlassListBackground: ViewModifier {
    @Environment(\.macSettingsGlassActive) private var isActive

    func body(content: Content) -> some View {
        content.scrollContentBackground(isActive ? .hidden : .automatic)
    }
}

extension View {
    /// 设置窗内的页面 / 列表底让路（唯一入口，见 `MacSettingsGlassListBackground`）。
    func macSettingsGlassListBackground() -> some View {
        modifier(MacSettingsGlassListBackground())
    }
}

// MARK: - 设置窗（及其 sheet）根

/// 设置窗根（以及设置窗内 sheet 根）的装配：挂玻璃底 + 注入设置窗作用域环境值。
struct MacSettingsGlassScene: ViewModifier {
    /// 「封面毛玻璃背景」开关（键与默认值的唯一来源见 `PlayerGlassBackground`）
    @AppStorage(PlayerGlassBackground.storageKey) private var glassEnabled = PlayerGlassBackground.enabledByDefault
    /// 系统「降低透明度」：开启时回落设置窗原样
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// 生效判定仍走唯一实现；设置窗没有「当前曲目封面」这个前置条件 ⇒ hasArtwork 传 true。
    private var isActive: Bool {
        PlayerGlassBackground.isActive(
            isEnabled: glassEnabled,
            hasArtwork: true,
            reduceTransparency: reduceTransparency
        )
    }

    func body(content: Content) -> some View {
        content
            .background {
                // 玻璃只铺在 background 这一层，且只允许它越界到安全区（标题栏）；
                // 正文仍由系统安全区决定位置：不 padding、不改布局。
                MacSettingsWindowGlass(active: isActive)
                    .ignoresSafeArea()
            }
            .environment(\.macSettingsGlassActive, isActive)
    }
}

extension View {
    /// 设置窗整窗玻璃（含窗口 chrome）；关开关 / 卸载时自动还原。
    func macSettingsGlassScene() -> some View {
        modifier(MacSettingsGlassScene())
    }
}

// MARK: - 窗口配置 + 玻璃底

/// 把设置窗变成「透明窗 + 背后材质」；失效 / 卸载时逐项还原。
///
/// 只动四项窗口属性（全部记录原值）：styleMask（只移除「是我们加的」.fullSizeContentView）、
/// titlebarAppearsTransparent / isOpaque / backgroundColor。
struct MacSettingsWindowGlass: NSViewRepresentable {
    /// 玻璃是否生效（开关 + 未开「降低透明度」，判定唯一入口见 `MacSettingsGlassScene`）
    let active: Bool

    func makeNSView(context: Context) -> GlassHostView {
        GlassHostView()
    }

    func updateNSView(_ view: GlassHostView, context: Context) {
        view.apply(active: active)
    }

    static func dismantleNSView(_ view: GlassHostView, coordinator: ()) {
        view.restore()
    }

    /// 只画背景、不接收任何点击 / 滚动的宿主视图。
    final class GlassHostView: NSView {
        private let effectView = NSVisualEffectView()
        private let scrimView = ScrimView()
        /// 最近一次 SwiftUI 给的状态（视图先于窗口出现时，等 `viewDidMoveToWindow` 补用）
        private var pendingActive = false
        /// 已接管的窗口（弱引用：窗口关闭后自然置 nil，不阻止释放）
        private weak var appliedWindow: NSWindow?
        /// 是否由本类插入的 `.fullSizeContentView`（还原时只移除「是我们加的」）
        private var didAddFullSizeContentView = false
        private var originalTitlebarAppearsTransparent = false
        private var originalIsOpaque = true
        private var originalBackgroundColor: NSColor?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.backgroundColor = NSColor.clear.cgColor

            effectView.material = MacSettingsGlassTuning.material
            effectView.blendingMode = MacSettingsGlassTuning.blendingMode
            effectView.state = MacSettingsGlassTuning.state
            effectView.autoresizingMask = [.width, .height]
            effectView.isHidden = true
            addSubview(effectView)

            scrimView.autoresizingMask = [.width, .height]
            scrimView.isHidden = true
            addSubview(scrimView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// 纯背景层：不能挡住侧栏行 / 表单控件的点击与滚动。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            effectView.frame = bounds
            scrimView.frame = bounds
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 离开窗口（关设置窗 / 场景重建）：先还原外观，别把透明留在已关闭的窗口上
            guard window != nil else {
                restore()
                return
            }
            apply(active: pendingActive)
        }

        func apply(active: Bool) {
            pendingActive = active
            guard let window else { return }
            guard active else {
                restore()
                return
            }

            if appliedWindow !== window {
                // 换窗口（设置窗 ⇄ sheet 窗）前先把旧窗口还原，避免属性残留
                restore()

                appliedWindow = window
                originalTitlebarAppearsTransparent = window.titlebarAppearsTransparent
                originalIsOpaque = window.isOpaque
                originalBackgroundColor = window.backgroundColor
                didAddFullSizeContentView = false
            }

            window.titlebarAppearsTransparent = true
            window.isOpaque = false
            window.backgroundColor = .clear
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
                didAddFullSizeContentView = true
            }

            effectView.isHidden = false
            scrimView.isHidden = MacSettingsGlassTuning.scrimOpacity <= 0
        }

        /// 逐项还原成接管前的值（关开关 / 卸载 / 关窗口都要走到这里；幂等）。
        func restore() {
            if let window = appliedWindow {
                window.titlebarAppearsTransparent = originalTitlebarAppearsTransparent
                window.isOpaque = originalIsOpaque
                if let originalBackgroundColor {
                    window.backgroundColor = originalBackgroundColor
                }
                if didAddFullSizeContentView {
                    window.styleMask.remove(.fullSizeContentView)
                }
            }
            appliedWindow = nil
            didAddFullSizeContentView = false
            originalBackgroundColor = nil
            effectView.isHidden = true
            scrimView.isHidden = true
        }
    }

    /// 统一雾面：跟随系统外观切亮 / 暗（材质本身已随外观，这里只补一点点提高可读性）。
    private final class ScrimView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            updateColor()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var isOpaque: Bool { false }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColor()
        }

        private func updateColor() {
            let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let base: NSColor = isDark ? .black : .white
            layer?.backgroundColor = base.withAlphaComponent(MacSettingsGlassTuning.scrimOpacity).cgColor
        }
    }
}
