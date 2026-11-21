//
//  MacPlayerView+GlassSurface.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  播放页封面毛玻璃背景（macOS）：
//    1. `surfaceStyle` —— 生效判定（开关 / 有封面 / 未开「降低透明度」，与 iOS 同一纯函数）
//    2. `playerBackground` —— 毛玻璃封面铺底；关闭时保持原窗口背景（透明，不改观感）
//    3. `glassPanelLayer` —— 播放信息面板玻璃卡片：按实测上下沿只画、不参与布局
//
//  侧栏 / 歌词面板样式不动（歌词面板自带背景，见 MacLyricsView.panelBackground）。
//

import SwiftUI

extension MacPlayerView {
    /// 当前播放页表面样式（毛玻璃是否生效）
    var surfaceStyle: PlayerSurfaceStyle {
        PlayerGlassBackground.isActive(
            isEnabled: glassBackgroundEnabled,
            hasArtwork: artwork != nil,
            reduceTransparency: reduceTransparency
        ) ? .active : .fallback
    }

    /// 背景：毛玻璃封面 / 原窗口背景（开关切换 0.3s 过渡）
    @ViewBuilder
    var playerBackground: some View {
        if surfaceStyle.isActive {
            ArtworkBlurBackground(artwork: artwork, cacheKey: artworkTrackId)
                .ignoresSafeArea()
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: glassBackgroundEnabled)
        } else {
            Color.clear
        }
    }

    /// 播放信息面板玻璃卡片（歌名行上沿 → 控制条下沿，四周各留 20pt）
    @ViewBuilder
    var glassPanelLayer: some View {
        if surfaceStyle.isActive, !isLyricsFullscreen, playerInfoTop > 0, playerInfoBottom > playerInfoTop {
            GeometryReader { proxy in
                let inset = DesignTokens.space20
                let height = playerInfoBottom - playerInfoTop + inset * 2
                GlassPanelBackground()
                    .frame(width: max(proxy.size.width - DesignTokens.space32 * 2, 0), height: height)
                    .position(
                        x: proxy.size.width / 2,
                        y: (playerInfoTop + playerInfoBottom) / 2
                    )
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.3), value: glassBackgroundEnabled)
        }
    }
}
