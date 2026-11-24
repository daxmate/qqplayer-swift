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
///   `layer.isHidden` 都不生效），而内容就在它里面，删它会把内容一起带走。
///   所以做法是「**摘玻璃、不换列**」：内容先搬进铺满 wrapper 的普通容器，再把玻璃本体移进
///   一个隐藏的 1×1 裁剪容器 —— 玻璃不再参与绘制，而列仍保持 `.sidebar` behavior。
///   ⚠️ 不能换列：换掉第 0 个 item 会破坏 `NSTrackingSeparatorToolbarItem` / 统一标题栏的
///   右侧分区，工具栏按钮从最右跑到中间（实测数字见 `detachGlassPanel()` 注释）。
///   ⚠️ 也不能把玻璃删出视图树：列折叠/展开会重新激活指向它的约束，直接抛异常。
/// - **macOS 15 及更早**：侧栏材质来自 `.sidebar` 的 `NSVisualEffectView`（侧栏的兄弟视图），
///   整块隐藏即可；隐藏祖先会把内容一起抹掉，故只认非祖先的目标。
///
/// 开关关闭 / 视图离开窗口时**还原**（内容装回玻璃、玻璃装回原位置、材质可见性还原）。
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

        /// macOS 26+：摘下来的侧栏玻璃与「停放位」（都保持强引用，便于还原）
        private var parkedGlass: NSView?
        private var glassContent: NSView?
        private var glassHost: NSView?
        private var glassParking: NSView?
        private var glassWrapper: NSView?
        /// 防重入：`strip()` 在 `layout()` 里反复调用，摘除本身也会触发布局
        private var isDetachingGlass = false
        /// 摘除期间挂上的三组约束：切换前必须整组撤掉，否则反复开关玻璃会越攒越多
        private var hostConstraints: [NSLayoutConstraint] = []
        private var contentInHostConstraints: [NSLayoutConstraint] = []
        /// 装回时 content↔glass 的约束：留着给还原后的布局用，下一轮摘除前再撤
        private var contentInGlassConstraints: [NSLayoutConstraint] = []

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
                // 26+：不再有列级 `.sidebar` 材质（只剩行内选中胶囊），走「摘玻璃不换列」一条路。
                // 没有 NSSplitViewItem 包裹的 `.sidebar` List（如设置窗的侧栏）不满足摘玻璃前提
                // （找不到单层玻璃底板 / 无 wrapper）⇒ 退回隐藏 `.sidebar` 材质视图；
                // 主窗上该材质不存在，行为不变。
                if !detachGlassPanel() {
                    stripLegacySidebarMaterial()
                }
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

            if #available(macOS 26.0, *) {
                restoreGlassPanel()
            }
        }

        // MARK: - macOS 26+：摘掉侧栏玻璃底板（不换列，保住 .sidebar behavior）

        /// 把侧栏列里的 `NSGlassEffectView` 底板摘掉，内容搬到铺满 wrapper 的普通容器里。
        ///
        /// 为什么**不能换列**：`NSTrackingSeparatorToolbarItem` / 统一标题栏的右侧分区依赖
        /// 第 0 个 item 是 `.sidebar` behavior。换成普通 item 后标题栏几何整体垮掉
        /// （探针实测：窗口 1280 / 侧栏 210 时 `NSToolbarTitleView` 从 `{{214, 748}, {930, 52}}`
        /// 塌成 `{{92, 748}, {160, 52}}`，右侧 3 个按钮从 x=1144/1188/1232 移到 252/260/300 一带；
        /// 换回原 item 立即复原）。
        ///
        /// 为什么玻璃**留在视图树里**（藏进 1×1 隐藏容器）而不是删掉：列控制器折叠/展开时
        /// 会重新激活它自己那组指向玻璃的约束，玻璃一旦不在同一视图树里，
        /// `NSSplitViewItem._setCollapsed:` 直接抛 "Unable to activate constraint" 崩溃（实测）。
        @available(macOS 26.0, *)
        private func detachGlassPanel() -> Bool {
            if isDetachingGlass { return true }
            if let parked = parkedGlass, let parking = glassParking, parked.superview === parking {
                return true // 已经摘过且仍生效
            }

            isDetachingGlass = true
            defer { isDetachingGlass = false }

            restoreGlassPanel() // 列被重建过：旧状态先还原，再摘新的
            guard let glass = enclosingGlassPanel(), let wrapper = glass.superview,
                  let content = glass.contentView
            else { return false }

            // 上一轮还原时挂的 content↔glass 约束先撤掉，否则每开关一次就多 4 条
            NSLayoutConstraint.deactivate(contentInGlassConstraints)
            contentInGlassConstraints = []

            // 1) 内容搬进铺满 wrapper 的普通容器（先摘内容，绝不能让内容跟着玻璃走）
            let host = NSView()
            host.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(host)
            hostConstraints = [
                host.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                host.topAnchor.constraint(equalTo: wrapper.topAnchor),
                host.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            ]
            NSLayoutConstraint.activate(hostConstraints)
            content.removeFromSuperview()
            content.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(content)
            contentInHostConstraints = [
                content.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                content.topAnchor.constraint(equalTo: host.topAnchor),
                content.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ]
            NSLayoutConstraint.activate(contentInHostConstraints)

            // 2) 玻璃本体移进「隐藏的 1×1 裁剪容器」：不在 wrapper 里画，列约束却始终有效
            let parking = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            parking.autoresizingMask = []
            parking.wantsLayer = true
            parking.layer?.masksToBounds = true
            parking.isHidden = true
            wrapper.addSubview(parking)
            parking.addSubview(glass)

            wrapper.layoutSubtreeIfNeeded()

            parkedGlass = glass
            glassContent = content
            glassHost = host
            glassParking = parking
            glassWrapper = wrapper
            return true
        }

        /// 把玻璃与内容装回原位（玻璃对 wrapper 的约束一直挂着，无需重装）。
        @available(macOS 26.0, *)
        private func restoreGlassPanel() {
            guard let glass = parkedGlass, let content = glassContent,
                  let host = glassHost, let parking = glassParking, let wrapper = glassWrapper
            else { return }

            // 三组约束整组撤掉再装回，反复开关不累积
            NSLayoutConstraint.deactivate(hostConstraints)
            NSLayoutConstraint.deactivate(contentInHostConstraints)
            NSLayoutConstraint.deactivate(contentInGlassConstraints)
            hostConstraints = []
            contentInHostConstraints = []
            contentInGlassConstraints = []

            content.removeFromSuperview()
            glass.addSubview(content)
            content.translatesAutoresizingMaskIntoConstraints = false
            contentInGlassConstraints = [
                content.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
                content.topAnchor.constraint(equalTo: glass.topAnchor),
                content.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            ]
            NSLayoutConstraint.activate(contentInGlassConstraints)

            wrapper.addSubview(glass, positioned: .below, relativeTo: host)
            parking.removeFromSuperview()
            host.removeFromSuperview()
            wrapper.layoutSubtreeIfNeeded()

            parkedGlass = nil
            glassContent = nil
            glassHost = nil
            glassParking = nil
            glassWrapper = nil
        }

        /// 沿 superview 链找侧栏列自己的玻璃底板（SwiftUI 的侧栏内容就在它里面）。
        @available(macOS 26.0, *)
        private func enclosingGlassPanel() -> NSGlassEffectView? {
            var node = superview
            var depth = 0
            while let view = node, depth < 12 {
                if let glass = view as? NSGlassEffectView { return glass }
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
