//
//  PlayerSurfaceStyle.swift
//  QQPlayer
//
//  播放页「表面样式」环境值（iOS + macOS 共用）+ 玻璃面板修饰器。
//
//  唯一入口纪律：播放页**只在这里**决定「毛玻璃背景生效时文字该多亮」，
//  子视图一律读 `EnvironmentValues.playerSurfaceStyle`，不各自去读设置开关
//  （否则开关的第二实现会散落在每个子视图里）。
//

import SwiftUI

/// 播放页表面样式：`.active` = 封面毛玻璃背景生效（浅色文字），`.fallback` = 原渐变背景（系统语义色）。
enum PlayerSurfaceStyle: Equatable {
    case fallback
    case active

    var isActive: Bool {
        self == .active
    }

    /// 主文字（歌名 / 控制图标）
    var primaryText: Color {
        isActive ? .white : .primary
    }

    /// 次文字（歌手 / 时间戳 / 提示）
    var secondaryText: Color {
        isActive ? Color.white.opacity(0.72) : .secondary
    }

    /// 未高亮的歌词行（比次文字更淡，避免抢当前行）
    var lyricInactive: Color {
        isActive ? Color.white.opacity(0.55) : .secondary
    }

    /// 进度条底轨（深色背景上要看得见）
    var progressTrack: Color {
        isActive ? Color.white.opacity(0.28) : Color.gray.opacity(0.3)
    }
}

private struct PlayerSurfaceStyleKey: EnvironmentKey {
    static let defaultValue: PlayerSurfaceStyle = .fallback
}

extension EnvironmentValues {
    /// 播放页表面样式（由 PlayerView / MacPlayerView 顶层注入一次）
    var playerSurfaceStyle: PlayerSurfaceStyle {
        get { self[PlayerSurfaceStyleKey.self] }
        set { self[PlayerSurfaceStyleKey.self] = newValue }
    }
}

/// 玻璃面板：ultraThinMaterial + 6% 白叠层 + 顶部 1px 高光描边。
/// 「降低透明度」时退化为纯黑 28% 遮罩（不再有实时材质）。
struct GlassPanelBackground: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.radius28, style: .continuous)
        ZStack {
            if reduceTransparency {
                shape.fill(Color.black.opacity(0.28))
            } else {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.white.opacity(0.06))
                shape.strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.22), Color.white.opacity(0.04)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
