//
//  MacPlayerView+GlassSurface.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  播放页（右栏）在「整窗毛玻璃」下的做法：
//    - **不再自铺封面模糊背景**（整窗底已由 MacLibraryView 铺一次；再铺一层会发灰、也浪费一次大模糊）；
//      本片保持透明，让窗底的模糊封面直接透上来。
//    - `glassPanelLayer`：播放信息面板的玻璃卡片（按实测上下沿只画、不参与布局），材质见
//      `GlassPanelBackground`（ultraThinMaterial）。
//
//  文字颜色：整窗底是「模糊封面 + 外观自适应雾面」（浅色白雾面 / 深色黑雾面），
//  系统 `.primary` / `.secondary` 仍然可读，故 macOS 不注入浅色文字环境值（与 iOS 不同）。
//

import SwiftUI

extension MacPlayerView {
    /// 播放信息面板是否生效（开关 / 有封面 / 未开「降低透明度」；判定唯一实现见 `PlayerGlassBackground`）
    var surfaceStyle: PlayerSurfaceStyle {
        PlayerGlassBackground.isActive(
            isEnabled: glassBackgroundEnabled,
            hasArtwork: artwork != nil,
            reduceTransparency: reduceTransparency
        ) ? .active : .fallback
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
