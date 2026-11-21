//
//  MacWindowGlass.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  整窗「封面毛玻璃」底（Apple Music macOS 式）：
//    - 窗口背景 = 当前封面模糊图（复用 ArtworkBlurBackground + ArtworkBlurCache 预渲染）
//      + 按外观自适应雾面（浅色 white 0.62 / 深色 black 0.36），保证系统前景色可读；
//    - **整窗只有这一层底**：侧栏 / 中栏 / 播放区 / 歌词区都不再铺材质或底色，
//      内容直接浮在窗底上（Apple Music macOS 观感；见各分区 windowGlassActive 分支）；
//    - `macWindowGlassActive` 环境值：三栏 / 列表 / 播放页读它决定是否透明化，
//      避免每个视图各读一遍设置开关（开关语义唯一入口仍是 PlayerGlassBackground）。
//

import AppKit
import SwiftUI

// MARK: - 生效状态（环境值）

private struct MacWindowGlassActiveKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    /// 整窗毛玻璃是否生效（由 MacLibraryView 顶层注入一次；浮窗另注入）
    var macWindowGlassActive: Bool {
        get { self[MacWindowGlassActiveKey.self] }
        set { self[MacWindowGlassActiveKey.self] = newValue }
    }
}

// MARK: - 整窗底

/// 整窗背景：模糊封面 + 外观自适应雾面。调用方负责「开关 / 有封面 / 降低透明度」的判定。
struct MacWindowGlass: View {
    enum Scrim {
        /// 跟随外观：浅色加白色雾面（现有深色文字可读），深色加黑色雾面
        case adaptive
        /// 固定深色雾面（桌面歌词窗：正文是白色，必须压深底）
        case dark
    }

    let artwork: ArtworkImage?
    let cacheKey: String?
    var scrim: Scrim = .adaptive

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ArtworkBlurBackground(artwork: artwork, cacheKey: cacheKey)
            scrimColor
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var scrimColor: Color {
        switch scrim {
        case .dark:
            return Color.black.opacity(0.38)
        case .adaptive:
            return colorScheme == .dark ? Color.black.opacity(0.36) : Color.white.opacity(0.62)
        }
    }
}

// MARK: - 列表 / 表格透明化

/// 毛玻璃生效时：隐藏滚动背景 + 关闭交替行底色；关闭时恢复系统默认（不改纯色外观）。
private struct MacWindowGlassTransparency: ViewModifier {
    @Environment(\.macWindowGlassActive) private var active

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(active ? .hidden : .automatic)
            .alternatingRowBackgrounds(active ? .disabled : .automatic)
    }
}

extension View {
    /// 列表 / 表格接入整窗毛玻璃（幂等；不改布局，只改背景可见性）
    func macWindowGlassTransparency() -> some View {
        modifier(MacWindowGlassTransparency())
    }
}

/// 侧栏底：整窗玻璃生效时**不铺任何填充**（整窗只保留 MacLibraryView 那一层底），
/// 侧栏完全透明，列表内容直接浮在窗底上；关闭开关时不渲染，侧栏回到系统默认外观。
///
/// 顺带关掉 AppKit 侧栏自带的 `.sidebar` 材质视图：它按「窗口背后」（桌面壁纸）取景，
/// 会盖出一块比中栏更亮的矩形——正是「一块一块」的来源（见 MacSidebarMaterialStripper）。
struct MacSidebarGlassBackdrop: View {
    @Environment(\.macWindowGlassActive) private var active

    var body: some View {
        if active {
            Color.clear
                .macSidebarMaterialHidden()
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }
}

// MARK: - 侧栏系统材质剥离（仅玻璃模式）

extension View {
    /// 玻璃模式下剥离宿主 NSVisualEffectView（侧栏 `.sidebar` 材质）：整窗只有一层底。
    fileprivate func macSidebarMaterialHidden() -> some View {
        background(MacSidebarMaterialStripper())
    }
}

/// 找到宿主侧栏的 `.sidebar` 材质视图并临时隐藏（内容祖先除外），
/// 视图离开窗口或开关关闭时恢复原值。
private struct MacSidebarMaterialStripper: NSViewRepresentable {
    func makeNSView(context: Context) -> StripperNSView {
        StripperNSView()
    }

    func updateNSView(_ view: StripperNSView, context: Context) {
        view.strip()
    }

    final class StripperNSView: NSView {
        private weak var stripped: NSVisualEffectView?
        private var originalHidden = false

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

        private func restore() {
            if let stripped {
                stripped.isHidden = originalHidden
            }
            stripped = nil
        }

        /// 只认 `.sidebar` 材质的 NSVisualEffectView，且必须「不是本视图的祖先」——
        /// 祖先上做隐藏会把侧栏内容一起抹掉。找不到就什么都不做（保守：宁可不改也不错改）。
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

// MARK: - 桌面歌词浮窗玻璃底

/// 桌面歌词浮窗：整窗玻璃底（与主窗同一套模糊封面 + 材质；固定深色雾面，
/// 因为歌词正文是白色，浮窗又叠在任意桌面内容上，浅色雾面会让白字不可读）。
struct MacDesktopLyricGlassContainer<Content: View>: View {
    @Environment(PlayerEngine.self) private var player
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(PlayerGlassBackground.storageKey) private var glassBackgroundEnabled = PlayerGlassBackground.enabledByDefault

    @State private var artwork: ArtworkImage?
    @State private var artworkTrackId: String?

    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            if isActive {
                MacWindowGlass(artwork: artwork, cacheKey: artworkTrackId, scrim: .dark)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius20, style: .continuous))
            }
            content()
        }
        .task(id: player.currentTrack?.stableId) {
            await load()
        }
    }

    private var isActive: Bool {
        PlayerGlassBackground.isActive(
            isEnabled: glassBackgroundEnabled,
            hasArtwork: artwork != nil,
            reduceTransparency: reduceTransparency
        )
    }

    private func load() async {
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
