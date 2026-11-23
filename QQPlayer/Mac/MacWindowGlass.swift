//
//  MacWindowGlass.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  整窗玻璃底（最小实现，2026-11-22 重做）：
//    - 窗口底 = 当前封面模糊图（复用 `ArtworkBlurBackground` + `ArtworkBlurCache` 预渲染）
//      + 一层**均匀**雾面（浅色 white 0.62 / 深色 black 0.36，按 colorScheme），保证前景可读；
//    - `macWindowGlassActive` 环境值：侧栏 / 中栏 / 歌词面板读它决定「要不要去掉自己的底」，
//      避免每个视图各读一遍设置开关（开关语义唯一入口仍是 PlayerGlassBackground）。
//
//  ⚠️ 本文件负责「窗口底」「生效状态」以及**玻璃模式下的侧栏材质剥离**（只减色）：
//     不碰布局 / 栏宽 / 行高 / 字号。窗口 chrome（标题栏）另见 `MacWindowGlassChrome`。
//

import AppKit
import SwiftUI

// MARK: - 生效状态（环境值）

private struct MacWindowGlassActiveKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// 整窗玻璃是否生效（由 MacLibraryView 顶层注入一次）
    var macWindowGlassActive: Bool {
        get { self[MacWindowGlassActiveKey.self] }
        set { self[MacWindowGlassActiveKey.self] = newValue }
    }
}

// MARK: - 列表 / 表格让路

/// 玻璃生效时清掉 List / Table 自带的系统内容底色，让窗底玻璃透出；
/// 关闭时 .automatic = 改动前外观。
/// 必须直接贴在 List / Table 上：只靠宿主祖先声明时，Table 内容底实测仍有残留不透明度。
struct MacGlassListBackground: ViewModifier {
    @Environment(\.macWindowGlassActive) private var isActive

    func body(content: Content) -> some View {
        content.scrollContentBackground(isActive ? .hidden : .automatic)
    }
}

extension View {
    /// 页面 / 表格底让路给整窗玻璃（唯一入口，见 MacGlassListBackground）。
    func macGlassListBackground() -> some View {
        modifier(MacGlassListBackground())
    }
}

// MARK: - 窗口底

/// 整窗背景：模糊封面 + 外观自适应雾面。调用方负责判定「开关 / 有封面 / 降低透明度」。
struct MacWindowGlass: View {
    let artwork: ArtworkImage?
    let cacheKey: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ArtworkBlurBackground(artwork: artwork, cacheKey: cacheKey)
            scrimColor
        }
        // 不铺到安全区外：调用方用 `.background` 贴在三栏内容区上，标题栏保持系统原样
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var scrimColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.36) : Color.white.opacity(0.62)
    }
}

// MARK: - 侧栏系统材质剥离（仅玻璃模式）

/// 玻璃模式下关掉宿主侧栏自带的 `.sidebar` 材质视图：
/// 它按「窗口背后」（桌面壁纸）取景，会在整窗玻璃上盖出一块色阶不同的矩形 —— 正是
/// 「一块一块」的来源。只改可见性，不删视图、不改 frame、不碰布局。
///
/// 只在玻璃生效时被挂进视图树；开关关闭 / 视图离开窗口时移除并**还原原值**。
struct MacSidebarMaterialStripper: NSViewRepresentable {
    func makeNSView(context: Context) -> StripperView {
        StripperView()
    }

    func updateNSView(_ view: StripperView, context: Context) {
        view.strip()
    }

    static func dismantleNSView(_ view: StripperView, coordinator: ()) {
        view.restore()
    }

    /// 探针视图：沿 superview 链找侧栏材质视图并临时隐藏。
    final class StripperView: NSView {
        private weak var stripped: NSVisualEffectView?
        private var originalHidden = false

        /// 纯背景探针：不能参与命中测试（否则会挡住侧栏行的点击 / 拖拽）。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                restore()
            } else {
                strip()
            }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            strip()
        }

        func strip() {
            guard window != nil else { return }
            guard let target = enclosingSidebarMaterial() else { return }
            guard stripped !== target else { return }
            restore()
            originalHidden = target.isHidden
            target.isHidden = true
            stripped = target
        }

        /// 还原成接管前的可见性（视图卸载 / 开关关闭都要走到这里）。
        func restore() {
            if let stripped {
                stripped.isHidden = originalHidden
            }
            stripped = nil
        }

        /// 只认 `.sidebar` 材质的 NSVisualEffectView，且必须**不是本视图的祖先**——
        /// 在祖先上做隐藏会把侧栏内容一起抹掉。找不到就什么都不做（保守：宁可不改也不错改）。
        private func enclosingSidebarMaterial() -> NSVisualEffectView? {
            var node = superview
            var depth = 0
            while let view = node, depth < 10 {
                for sub in view.subviews {
                    guard let effect = sub as? NSVisualEffectView, effect.material == .sidebar else { continue }
                    guard !isDescendant(of: effect) else { continue }
                    return effect
                }
                node = view.superview
                depth += 1
            }
            return nil
        }
    }
}
