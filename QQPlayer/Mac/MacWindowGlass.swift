//
//  MacWindowGlass.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  整窗玻璃底（最小实现，2026-11-22 重做）：
//    - 窗口底 = 当前封面模糊图（复用 `ArtworkBlurBackground` + `ArtworkBlurCache` 预渲染）
//      + 一层**均匀**雾面（浅色 white 0.62 / 深色 black 0.36，按 colorScheme），保证前景可读；
//    - `macWindowGlassActive` 环境值：只有「歌词面板要不要把底色改成透明」需要读它。
//
//  ⚠️ 本文件只负责「窗口底」与「生效状态」两件事：不碰布局、不碰安全区、
//     不碰标题栏 / styleMask / 视图层级（这些在 2026-11-22 被用户明确否决）。
//

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
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var scrimColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.36) : Color.white.opacity(0.62)
    }
}
