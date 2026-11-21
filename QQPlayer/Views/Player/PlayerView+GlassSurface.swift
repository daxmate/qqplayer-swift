//
//  PlayerView+GlassSurface.swift
//  QQPlayer
// target: ios-only（Mac 侧不铺卡片：整窗玻璃下播放信息直接浮在窗底上，见 MacPlayerView）
//
//  播放页封面毛玻璃背景（iOS）：
//    1. `surfaceStyle` —— 是否生效的唯一判定（开关 / 封面 / 降低透明度）
//    2. `playerBackground` —— 毛玻璃封面铺底，否则回落原渐变背景
//    3. `glassPanelLayer` —— 信息区玻璃面板：只画、不参与布局（歌名行顶部起、左右各 12pt）
//
//  为什么玻璃面板用 GeometryReader 叠在 ZStack 里画，而不是包住内容：
//  包住内容必然要把歌名行从「封面 + 歌名」那个 VStack 里拆出来 ——
//  外层两个弹性视图的分配会变，控件位置跟着动。任务要求不改布局，所以只画不改。
//

import SwiftUI

extension PlayerView {
    /// 当前播放页表面样式（毛玻璃是否生效）
    var surfaceStyle: PlayerSurfaceStyle {
        PlayerGlassBackground.isActive(
            isEnabled: glassBackgroundEnabled,
            hasArtwork: currentArtwork != nil,
            reduceTransparency: reduceTransparency
        ) ? .active : .fallback
    }

    /// 背景：毛玻璃封面 / 原渐变背景（开关切换 0.3s 过渡，不重建页面）
    @ViewBuilder
    var playerBackground: some View {
        Group {
            if surfaceStyle.isActive, let track = playerEngine.currentTrack {
                ArtworkBlurBackground(artwork: currentArtwork, cacheKey: track.stableId)
                    .ignoresSafeArea()
                    .transition(.opacity)
            } else {
                ScreenSpecificBackgroundView(screen: .player)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: glassBackgroundEnabled)
    }

    /// 信息区玻璃面板（歌名行 → 页面底部；左右各 12pt）
    @ViewBuilder
    var glassPanelLayer: some View {
        if surfaceStyle.isActive, playerInfoTop > 0 {
            GeometryReader { proxy in
                let top = glassTopLimit
                let height = max(proxy.size.height - top - DesignTokens.space12, 0)
                GlassPanelBackground()
                    .padding(.horizontal, DesignTokens.space12)
                    .frame(width: proxy.size.width, height: height)
                    .position(x: proxy.size.width / 2, y: top + height / 2)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: glassBackgroundEnabled)
        }
    }

    /// 玻璃面板顶部：歌名行上方留 12pt（量到之前不画，避免盖住封面）
    private var glassTopLimit: CGFloat {
        max(playerInfoTop - DesignTokens.space12, 0)
    }
}
