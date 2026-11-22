//
//  IOSWindowGlass.swift
//  QQPlayer
// target: ios-only
//
//  iOS 整屏毛玻璃底（玻璃显示风格，2026-11-22）：
//    - 一整层：当前封面模糊（复用 `ArtworkBlurBackground` + `ArtworkBlurCache` 预渲染）
//      + 按外观自适应的均匀雾面 + 暗角，`.ignoresSafeArea()` 铺到状态栏背后与 Home 指示条区域；
//    - 无封面 / 无曲目 → 系统背景 + 强调色轻微 tint（不出现纯黑/纯白突兀块）；
//    - **一份实现两个装配点**：① 根 `ContentView`（曲库 + 推入的详情页共用同一层）；
//      ② 全屏播放页 `PlayerView`（fullScreenCover 是独立 presentation 容器，根的层到不了那里）。
//      其它页面**不要**再各画一层。
//
//  可读性口径（不做 `preferredColorScheme` 强翻）：雾面按 colorScheme 取
//  浅色 white 0.62 / 深色 black 0.36（与 `MacWindowGlass` 同口径）⇒ 前景与状态栏文字
//  都跟当前外观走（浅色外观 = 深字 + 浅雾面；深色外观 = 浅字 + 深雾面），永远有对比度。
//

import SwiftUI

// MARK: - 玻璃底（唯一实现）

struct IOSWindowGlass: View {
    /// 当前曲目封面（nil → 回退底）
    let artwork: ArtworkImage?
    /// 稳定标识（缓存键）
    let cacheKey: String?

    @Environment(\.appAppearanceStyle) private var appearanceStyle
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        if appearanceStyle == .glass {
            ZStack {
                if let artwork, let cacheKey {
                    ArtworkBlurBackground(artwork: artwork, cacheKey: cacheKey)
                } else {
                    emptyStateBase
                }
                scrim
                vignette
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// 无封面 / 无曲目：系统背景 + 强调色轻微 tint（不许纯黑/纯白突兀块）
    private var emptyStateBase: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            RadialGradient(
                colors: [accentColor.opacity(0.12), accentColor.opacity(0)],
                center: .topLeading,
                startRadius: 0,
                endRadius: 560
            )
        }
    }

    /// 均匀雾面：保证前景（列表文字 / 导航栏 / 状态栏）在封面颜色上可读
    private var scrim: Color {
        colorScheme == .dark ? Color.black.opacity(0.36) : Color.white.opacity(0.62)
    }

    /// 暗角：压住四角，避免边界处封面颜色过亮与状态栏抢对比度
    private var vignette: some View {
        RadialGradient(
            colors: [Color.black.opacity(0), Color.black.opacity(colorScheme == .dark ? 0.28 : 0.10)],
            center: .center,
            startRadius: 180,
            endRadius: 760
        )
    }
}

// MARK: - 按当前曲目加载封面的装配层

/// 根视图专用：跟随当前曲目加载封面，再交给 `IOSWindowGlass`。
/// 装配点只负责「放这一层」，不各自实现模糊/雾面。
struct IOSWindowGlassLayer: View {
    /// 当前曲目（nil = 无曲目 → IOSWindowGlass 回退底）
    let track: Track?

    @Environment(AppServices.self) private var services
    @Environment(\.appAppearanceStyle) private var appearanceStyle
    @State private var artwork: ArtworkImage?

    /// 重载键：曲目或风格变化都要重取（风格切回经典就不必留图）
    private struct LoadKey: Equatable {
        let stableId: String?
        let style: AppAppearanceStyle
    }

    private var loadKey: LoadKey {
        LoadKey(stableId: track?.stableId, style: appearanceStyle)
    }

    var body: some View {
        IOSWindowGlass(artwork: artwork, cacheKey: track?.stableId)
            .task(id: loadKey) {
                await loadArtwork()
            }
    }

    @MainActor
    private func loadArtwork() async {
        guard appearanceStyle == .glass, let track else {
            artwork = nil
            return
        }
        let loaded = await services.artworkManager.getArtwork(for: track)
        guard !Task.isCancelled else { return }
        artwork = loaded
    }
}

// MARK: - 系统栏 / 滚动底让位（单点修饰器）

/// 玻璃风格下让系统自己的底让位，露出整屏玻璃；经典风格**完全无效果**。
///
/// - 导航栏：`.toolbarBackground(.hidden)`（原先无条件写死的 `.clear` 只在经典分支生效时保留，
///   见 `LibraryView` 的调用点注释）；
/// - 滚动容器：`.scrollContentBackground(.hidden)`（List / Form 的默认底不让位会盖住玻璃）。
struct IOSGlassChromeModifier: ViewModifier {
    @Environment(\.appAppearanceStyle) private var appearanceStyle

    @ViewBuilder
    func body(content: Content) -> some View {
        if appearanceStyle == .glass {
            content
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarBackground(.hidden, for: .automatic)
                .scrollContentBackground(.hidden)
        } else {
            content
        }
    }
}

extension View {
    /// 玻璃风格下让系统栏与滚动容器底透出整屏玻璃（classic 无任何效果）
    func iosGlassChrome() -> some View {
        modifier(IOSGlassChromeModifier())
    }
}
