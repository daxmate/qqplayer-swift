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

// MARK: - 侧栏系统背板剥离（仅玻璃模式）

/// 玻璃模式下拆掉侧栏列自带的系统背板，让整窗玻璃（`MacWindowGlass`）原样透上来。
///
/// 两个世代两套背板，必须分开处理：
/// - **macOS 26+（Liquid Glass）**：侧栏整列被一个 `NSGlassEffectView` 包住
///   （`_NSSplitViewItemViewWrapper` → `NSGlassEffectView` → 内容），它按自己的规则取景加色，
///   盖在整窗玻璃上就是「一块不透明的米白面板 + 圆角硬边」。该视图由列控制器按
///   `NSSplitViewItem.behavior == .sidebar` 挂上，**隐藏无效**（实测 `isHidden` / `alphaValue` /
///   `layer.isHidden` 都不生效，只有移出视图树才停画），而内容就在它里面，删它会把内容一起带走。
///   所以做法是**换列**：把同一个 `viewController` 重新包成普通 `NSSplitViewItem`（非 sidebar 行为），
///   厚度 / 折叠 / 全高布局等属性逐项照抄 —— 内容、宽度、行高、内边距全部不动，只是不再挂玻璃。
/// - **macOS 15 及更早**：侧栏材质来自 `.sidebar` 的 `NSVisualEffectView`（侧栏的兄弟视图），
///   整块隐藏即可；隐藏祖先会把内容一起抹掉，故只认非祖先的目标。
///
/// 开关关闭 / 视图离开窗口时**还原**（列换回原 item、材质可见性还原）。只动可见性与列包装，
/// 不改 frame、不改内容、不碰 SwiftUI 布局。
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

    /// 探针视图：沿 superview 链定位侧栏背板并临时剥离。
    final class StripperView: NSView {
        /// macOS 15-：被隐藏的 `.sidebar` 材质视图
        private weak var strippedMaterial: NSVisualEffectView?
        private var materialWasHidden = false

        /// macOS 26+：换列用到的原 item / 新 item / 控制器（都保持强引用，便于还原）
        private var originalItem: NSSplitViewItem?
        private var replacementItem: NSSplitViewItem?
        private var splitController: NSSplitViewController?

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

        override func layout() {
            super.layout()
            strip()
        }

        func strip() {
            guard window != nil else { return }
            if #available(macOS 26.0, *) {
                // 26+：不再有列级 `.sidebar` 材质（只剩行内选中胶囊），只走「换列」一条路
                _ = restyleSidebarItem()
            } else {
                stripLegacySidebarMaterial()
            }
        }

        /// 还原到接管前的状态（幂等）。
        func restore() {
            if let target = strippedMaterial {
                target.isHidden = materialWasHidden
            }
            strippedMaterial = nil

            if let original = originalItem,
               let replacement = replacementItem,
               let controller = splitController,
               controller.splitViewItems.contains(where: { $0 === replacement }) {
                controller.removeSplitViewItem(replacement)
                controller.insertSplitViewItem(original, at: 0)
            }
            originalItem = nil
            replacementItem = nil
            splitController = nil
        }

        // MARK: - macOS 26+：换掉带 Liquid Glass 的 sidebar 列

        @available(macOS 26.0, *)
        private func restyleSidebarItem() -> Bool {
            if replacementItem != nil,
               let controller = splitController,
               controller.splitViewItems.first === replacementItem {
                return true // 已经换过且仍生效
            }
            guard let splitView = enclosingSplitView(),
                  let controller = splitView.delegate as? NSSplitViewController,
                  let item = controller.splitViewItems.first,
                  item.behavior == .sidebar
            else { return false }

            let replacement = NSSplitViewItem(viewController: item.viewController)
            replacement.minimumThickness = item.minimumThickness
            replacement.maximumThickness = item.maximumThickness
            replacement.preferredThicknessFraction = item.preferredThicknessFraction
            replacement.canCollapse = item.canCollapse
            replacement.collapseBehavior = item.collapseBehavior
            replacement.allowsFullHeightLayout = item.allowsFullHeightLayout
            replacement.titlebarSeparatorStyle = item.titlebarSeparatorStyle
            replacement.holdingPriority = item.holdingPriority
            replacement.isSpringLoaded = item.isSpringLoaded
            replacement.isCollapsed = item.isCollapsed

            originalItem = item
            replacementItem = replacement
            splitController = controller
            controller.removeSplitViewItem(item)
            controller.insertSplitViewItem(replacement, at: 0)
            return true
        }

        /// 沿 superview 链找侧栏所在的 `NSSplitView`（SwiftUI 的 NavigationSplitView 实现）。
        private func enclosingSplitView() -> NSSplitView? {
            var node = superview
            var depth = 0
            while let view = node, depth < 12 {
                if let split = view as? NSSplitView { return split }
                node = view.superview
                depth += 1
            }
            return nil
        }

        // MARK: - macOS 15-：`.sidebar` 材质视图

        private func stripLegacySidebarMaterial() {
            guard let target = enclosingSidebarMaterial() else { return }
            guard strippedMaterial !== target else { return }
            if let previous = strippedMaterial {
                previous.isHidden = materialWasHidden
            }
            materialWasHidden = target.isHidden
            target.isHidden = true
            strippedMaterial = target
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
