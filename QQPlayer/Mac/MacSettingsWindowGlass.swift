//
//  MacSettingsWindowGlass.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  设置窗「整窗玻璃」—— v2（2026-11-24）：与主窗**同一套封面模糊底**。
//
//    - v1 做法是「透明窗 + NSVisualEffectView(.behindWindow)」去采样窗口背后的屏幕内容：
//      设置窗浮在主窗上时，采到的是主窗那层已被 62% 白雾盖过的画面 ⇒ 雾上加雾，整窗发灰、
//      看不到封面颜色（用户真机截图反馈）。故 v2 不再采样背后，改为**设置窗自己铺同一套配方**：
//      `MacWindowGlass(artwork:cacheKey:)`（封面模糊 + 外观自适应均匀雾面），与主窗逐像素同源；
//    - 生效判定与主窗同一套语义：开关开 + 未开系统「降低透明度」（唯一实现见
//      `PlayerGlassBackground`）。不生效时逐项还原窗口属性，设置窗保持完全现状；
//    - 设置窗只保留窗口层（标题栏透明 + 内容铺满整窗）的接管与逐项还原；
//      背景**只允许一层**（MacWindowGlass），不再叠任何 system material / 雾面视图；
//    - 内部**不叠第二层材质**：侧栏复用 `MacSidebarMaterialStripper`，
//      各分类页的 Form / List 底走 `macSettingsGlassListBackground()`（设置窗作用域环境值，
//      不向主窗 / 工具栏面板泄露）。
//
//  ⚠️ 只动窗口外观与背景层，不改布局：栏宽 / 行高 / 字号 / padding 一律不动。
//

import AppKit
import SwiftUI

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

// MARK: - 设置窗内的输入框

/// 设置窗内的输入框（TextField / SecureField）外观。
///
/// 玻璃生效：`.plain` + 低透明度纯色底 + 细描边，与整窗玻璃同调。
/// 刻意**不叠 material**——输入框面积小，再引一层模糊采样会「雾上加雾」（v1 教训）；
/// 浅色档 0.38、深色档 0.12，深色下不能出现白块。
/// 不生效：维持原生 `.roundedBorder`，其余一切不加（与改造前逐像素一致）。
struct MacSettingsGlassField: ViewModifier {
    @Environment(\.macSettingsGlassActive) private var isActive
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if isActive {
            let shape = RoundedRectangle(cornerRadius: DesignTokens.radius6, style: .continuous)
            content
                .textFieldStyle(.plain)
                .padding(.horizontal, DesignTokens.space8)
                .padding(.vertical, DesignTokens.space4)
                .background(shape.fill(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.38)))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        } else {
            content.textFieldStyle(.roundedBorder)
        }
    }
}

extension View {
    /// 设置窗内的输入框统一挂这个（唯一入口，见 `MacSettingsGlassField`）。
    func macSettingsGlassField() -> some View {
        modifier(MacSettingsGlassField())
    }
}

// MARK: - 设置窗（及其 sheet）根

/// 设置窗根（以及设置窗内 sheet 根）的装配：铺「同一套封面模糊底」+ 窗口 chrome + 注入环境值。
struct MacSettingsGlassScene: ViewModifier {
    /// 「封面毛玻璃背景」开关（键与默认值的唯一来源见 `PlayerGlassBackground`）
    @AppStorage(PlayerGlassBackground.storageKey) private var glassEnabled = PlayerGlassBackground.enabledByDefault
    /// 系统「降低透明度」：开启时回落设置窗原样
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// 当前曲目（窗口底的封面来源，同主窗 `MacLibraryView`）
    @Environment(PlayerEngine.self) private var player
    @Environment(AppServices.self) private var services

    /// 当前曲目封面（窗口底的来源）
    @State private var artwork: ArtworkImage?
    @State private var artworkTrackId: String?

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
                if isActive {
                    // 与主窗同一配方：封面模糊 + 外观自适应雾面（`MacWindowGlass`）。
                    // 只允许这一层越界到安全区（标题栏）；正文仍由系统安全区决定位置：不 padding、不改布局。
                    MacWindowGlass(artwork: artwork, cacheKey: artworkTrackId)
                        .ignoresSafeArea()
                }
            }
            // 窗口 chrome（标题栏透明 + 内容铺满整窗）：与玻璃同条件生效，关闭逐项还原
            .background { MacSettingsWindowGlass(active: isActive) }
            .environment(\.macSettingsGlassActive, isActive)
            // 跟随曲目切歌拉封面（切歌后旧结果丢弃，见 `loadArtwork`）
            .task(id: player.currentTrack?.stableId) {
                await loadArtwork()
            }
    }

    /// 拉取当前曲目封面（切歌后旧结果丢弃）——与 `MacLibraryView.loadWindowArtwork()` 同一路径。
    private func loadArtwork() async {
        guard let track = player.currentTrack else {
            artwork = nil
            artworkTrackId = nil
            return
        }
        let trackId = track.stableId
        let image = await services.artworkManager.getArtwork(for: track)
        guard player.currentTrack?.stableId == trackId else { return }
        artwork = image
        artworkTrackId = trackId
    }
}

extension View {
    /// 设置窗整窗玻璃（含窗口 chrome）；关开关 / 卸载时自动还原。
    func macSettingsGlassScene() -> some View {
        modifier(MacSettingsGlassScene())
    }
}

// MARK: - 窗口配置

/// 把设置窗变成「内容铺满整窗 + 标题栏透明」，让 SwiftUI 那层封面模糊底一直铺到标题栏背后；
/// 失效 / 卸载时逐项还原。
///
/// 只动四项窗口属性（全部记录原值）：styleMask（只移除「是我们加的」.fullSizeContentView）、
/// titlebarAppearsTransparent / isOpaque / backgroundColor。
/// 背景内容不在这里画（唯一一层见 `MacWindowGlass`）。
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

    /// 只写窗口属性、不画任何东西的宿主视图。
    final class GlassHostView: NSView {
        /// 最近一次 SwiftUI 给的状态（视图先于窗口出现时，等 `viewDidMoveToWindow` 补用）
        private var pendingActive = false
        /// 已接管的窗口（弱引用：窗口关闭后自然置 nil，不阻止释放）
        private weak var appliedWindow: NSWindow?

        /// 接管前的原值（逐项还原用）
        private var originalTitlebarAppearsTransparent = false
        private var originalIsOpaque = true
        private var originalBackgroundColor: NSColor?
        /// `.fullSizeContentView` 是否为「我们加的」（只在是我们加的情况下移除）
        private var didAddFullSizeContentView = false

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
        }

        /// 逐项还原成接管前的值（幂等：没接管过也安全）。
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
        }
    }
}

// MARK: - 设置窗专用：AppKit 背板兜底剥离

/// 设置窗专用兜底：把系统给侧栏 / 标题栏铺的 AppKit 背板临时摘掉，
/// 让设置窗自己那层封面模糊底（`MacWindowGlass`）露出来。
///
/// 与主窗的 `MacSidebarMaterialStripper` 分家：主窗必须保住
/// `NSSplitViewItem.behavior == .sidebar`（换列会破坏工具栏右分区），只能摘玻璃板；
/// 设置窗侧栏是普通 SwiftUI `List(.sidebar)`，没有列语义，直接隐藏背板视图即可。
///
/// 只动三类「底」，全部记录原值、失效 / 卸载 / 换窗口时逐项还原（幂等）：
/// - `NSVisualEffectView`：`.sidebar` / `.underWindowBackground` / `.headerView` → `isHidden = true`；
///   `.contentBackground` 明令不碰（那是右侧分组面板的底，用户认可现状）。
/// - macOS 26+ `NSGlassEffectView` → `isHidden = true`（设置窗目前实测没有，留作系统换代兜底）。
/// - `NSScrollView` / `NSClipView` → `drawsBackground = false`；`documentView` 是
///   `NSTableView`（含 `NSOutlineView`）时 `backgroundColor = .clear`。
///
/// 遍历放在 `layout()`（AppKit 布局次数有限，不是逐帧），`isStripping` 防重入；
/// 已记录目标只重放状态，不重复记录原值（否则会把「我们隐藏后的值」当成原值，还原不回去）。
struct MacSettingsBackdropStripper: NSViewRepresentable {
    /// 玻璃是否生效（判定唯一入口见 `MacSettingsGlassScene`）
    let active: Bool

    func makeNSView(context: Context) -> StripperView {
        StripperView()
    }

    func updateNSView(_ view: StripperView, context: Context) {
        view.apply(active: active)
    }

    static func dismantleNSView(_ view: StripperView, coordinator: ()) {
        view.restore()
    }

    /// 只改背板属性、不画任何东西的宿主视图。
    final class StripperView: NSView {
        /// 需要隐藏的材质：只减侧栏 / 标题栏的底
        private static let strippedMaterials: [NSVisualEffectView.Material] = [
            .sidebar, .underWindowBackground, .headerView,
        ]

        private var pendingActive = false
        /// 已接管的窗口（弱引用：窗口关闭后自然置 nil，不阻止释放）
        private weak var appliedWindow: NSWindow?
        /// 接管前的原值记录
        private var adjustments: [Adjustment] = []
        /// 防重入：`layout()` 里会反复进来，改属性本身也可能触发布局
        private var isStripping = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 离开窗口（关设置窗 / 场景重建）：先还原，别把透明留在已关闭的窗口上
            guard window != nil else {
                restore()
                return
            }
            apply(active: pendingActive)
        }

        override func layout() {
            super.layout()
            stripIfNeeded()
        }

        func apply(active: Bool) {
            pendingActive = active
            guard active else {
                restore()
                return
            }
            stripIfNeeded()
        }

        /// 逐项还原成接管前的值（幂等：没接管过也安全）。
        func restore() {
            for adjustment in adjustments.reversed() {
                adjustment.revert()
            }
            adjustments.removeAll()
            appliedWindow = nil
        }

        // MARK: - 剥离 / 重放

        private func stripIfNeeded() {
            guard pendingActive, !isStripping, let window else { return }
            isStripping = true
            defer { isStripping = false }

            if appliedWindow !== window {
                // 换窗口（设置窗被重建）前先把旧窗口还原，避免属性残留
                restore()
                appliedWindow = window
            }
            guard let root = window.contentView else { return }
            strip(in: root)
        }

        private func strip(in view: NSView) {
            adjustIfNeeded(view)
            for subview in view.subviews {
                strip(in: subview)
            }
        }

        private func adjustIfNeeded(_ view: NSView) {
            // 已记录过的目标：只重放状态（系统可能在重建后又把 hidden / 底色写回来）
            if let index = adjustments.firstIndex(where: { $0.view === view }) {
                adjustments[index].reapply()
                return
            }

            if let effect = view as? NSVisualEffectView {
                guard Self.strippedMaterials.contains(effect.material) else { return }
                // 目标若是自己的祖先，隐藏会连内容一起抹掉 ⇒ 跳过（同主窗兜底逻辑）
                guard !isDescendant(of: effect) else { return }
                adjustments.append(
                    Adjustment(view: effect, kind: .visualEffect, originalHidden: effect.isHidden)
                )
                effect.isHidden = true
                return
            }

            if #available(macOS 26.0, *), let glass = view as? NSGlassEffectView {
                guard !isDescendant(of: glass) else { return }
                adjustments.append(
                    Adjustment(view: glass, kind: .visualEffect, originalHidden: glass.isHidden)
                )
                glass.isHidden = true
                return
            }

            if let scrollView = view as? NSScrollView {
                adjustments.append(
                    Adjustment(
                        view: scrollView,
                        kind: .scrollView,
                        originalDrawsBackground: scrollView.drawsBackground
                    )
                )
                scrollView.drawsBackground = false
                // List 的真底色在 documentView（NSTableView / NSOutlineView）上：
                // 实测为 `_sourceListBackgroundColor`，不清掉就是那块不透明浅灰。
                if let table = scrollView.documentView as? NSTableView {
                    adjustments.append(
                        Adjustment(
                            view: table,
                            kind: .tableView,
                            originalTableBackground: table.backgroundColor
                        )
                    )
                    table.backgroundColor = .clear
                }
                return
            }

            if let clipView = view as? NSClipView {
                adjustments.append(
                    Adjustment(
                        view: clipView,
                        kind: .clipView,
                        originalDrawsBackground: clipView.drawsBackground
                    )
                )
                clipView.drawsBackground = false
            }
        }

        // MARK: - 原值记录

        private struct Adjustment {
            enum Kind {
                case visualEffect
                case scrollView
                case clipView
                case tableView
            }

            weak var view: NSView?
            let kind: Kind
            var originalHidden = false
            var originalDrawsBackground = false
            var originalTableBackground: NSColor?

            func revert() {
                switch kind {
                case .visualEffect:
                    view?.isHidden = originalHidden
                case .scrollView:
                    (view as? NSScrollView)?.drawsBackground = originalDrawsBackground
                case .clipView:
                    (view as? NSClipView)?.drawsBackground = originalDrawsBackground
                case .tableView:
                    if let color = originalTableBackground {
                        (view as? NSTableView)?.backgroundColor = color
                    }
                }
            }

            func reapply() {
                switch kind {
                case .visualEffect:
                    view?.isHidden = true
                case .scrollView:
                    (view as? NSScrollView)?.drawsBackground = false
                case .clipView:
                    (view as? NSClipView)?.drawsBackground = false
                case .tableView:
                    (view as? NSTableView)?.backgroundColor = .clear
                }
            }
        }
    }
}
