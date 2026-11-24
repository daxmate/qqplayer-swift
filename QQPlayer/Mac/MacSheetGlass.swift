//
//  MacSheetGlass.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  sheet 页统一玻璃底（唯一入口，2026-11-24）。
//
//  为什么需要单独一层：sheet 在 macOS 上是**独立 NSWindow**，主窗 / 设置窗那层
//  封面模糊底（`MacWindowGlass`）与环境值（`macWindowGlassActive`）都下不来。
//  每个 sheet 的内容根挂一次 `macSheetGlass()` 即可：
//    ① 玻璃层用 `.background`（**不许**用 ZStack 根兄弟层：根插层会改几何提案 → 整页重排）；
//    ② 窗口透明：SwiftUI 侧 `.presentationBackground` + AppKit 兜底（只动 isOpaque / backgroundColor，
//       逐项还原；不碰 styleMask / frame / toolbar / titlebar）；
//    ③ 注入 `macWindowGlassActive`，让页内 List / Table 的 `.macGlassListBackground()` 让路；
//       **不覆盖** `macSettingsGlassActive`（设置窗来源的 sheet 要保留继承值）；
//    ④ 跟随当前曲目拉封面（切歌丢弃旧结果，路径与设置窗 `MacSettingsWindowGlass` 同一份）。
//
//  开关关闭 / 开「降低透明度」→ 不加层、不动窗口属性，逐像素还原现状。
//  生效判据只有一处：`PlayerGlassBackground.isActive`（本文件不另写条件）。
//

import AppKit
import SwiftUI

// MARK: - sheet 内列表让路（双来源）

/// sheet 可能由**主窗**或**设置窗**弹出，任一来源的玻璃生效都要清掉 List / Form / Table
/// 自带的系统底色。语义与 `macGlassListBackground` / `macSettingsGlassListBackground`
/// 完全相同（都只是 `scrollContentBackground`），差别只在判据取两个键的并集——
/// 供「两个入口共用同一个视图」的 sheet 使用（例：同步面板 / 批量刮削进度）。
struct MacSheetGlassListBackground: ViewModifier {
    @Environment(\.macWindowGlassActive) private var windowActive
    @Environment(\.macSettingsGlassActive) private var settingsActive

    func body(content: Content) -> some View {
        content.scrollContentBackground(windowActive || settingsActive ? .hidden : .automatic)
    }
}

extension View {
    /// sheet 内 List / Form / Table 让路给玻璃（主窗 / 设置窗两个来源都认）。
    func macSheetGlassListBackground() -> some View {
        modifier(MacSheetGlassListBackground())
    }
}

// MARK: - 主修饰器

struct MacSheetGlass: ViewModifier {
    /// 「封面毛玻璃背景」开关（键与默认值的唯一来源见 `PlayerGlassBackground`）
    @AppStorage(PlayerGlassBackground.storageKey) private var glassEnabled = PlayerGlassBackground.enabledByDefault
    /// 系统「降低透明度」：开启时回落原样
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// 当前曲目（玻璃底的封面来源）
    @Environment(PlayerEngine.self) private var player
    @Environment(AppServices.self) private var services

    @State private var artwork: ArtworkImage?
    @State private var artworkTrackId: String?

    /// 生效判定仍走唯一实现；sheet 没有「当前曲目封面」这个前置条件 ⇒ hasArtwork 传 true
    /// （与设置窗 `MacSettingsGlassScene` 同口径）。
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
                    MacWindowGlass(artwork: artwork, cacheKey: artworkTrackId)
                }
            }
            // 非玻璃时用 SwiftUI 的默认 presentation 背景样式（`.background`），语义等价于「不覆盖」。
            .presentationBackground(
                isActive ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.background)
            )
            // AppKit 兜底：sheet 窗口自身透明（只动 isOpaque / backgroundColor，卸载 / 关开关逐项还原）
            .background { MacSheetWindowTransparency(active: isActive) }
            // 页内 List / Table 让路（设置窗来源的 `macSettingsGlassActive` 继承值原样保留）
            .environment(\.macWindowGlassActive, isActive)
            .task(id: player.currentTrack?.stableId) {
                await loadArtwork()
            }
    }

    /// 拉取当前曲目封面（切歌后旧结果丢弃）——与 `MacSettingsWindowGlass.loadArtwork()` 同一路径。
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
    /// sheet 内容根的玻璃底（唯一入口，含窗口透明与列表让路环境值）。
    func macSheetGlass() -> some View {
        modifier(MacSheetGlass())
    }
}

// MARK: - 窗口透明（AppKit 兜底）

/// 把 sheet 宿主窗口设成透明，让 `MacWindowGlass` 那层模糊底真正透出来。
/// 只动两项窗口属性（isOpaque / backgroundColor），逐项记录原值；
/// 关开关 / 离开窗口 / 卸载时还原。不碰 styleMask / frame / toolbar / titlebar。
private struct MacSheetWindowTransparency: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> HostView {
        HostView()
    }

    func updateNSView(_ view: HostView, context: Context) {
        view.apply(active: active)
    }

    static func dismantleNSView(_ view: HostView, coordinator: ()) {
        view.restore()
    }

    final class HostView: NSView {
        /// 最近一次收到的生效状态（窗口晚于视图到达时补一次）
        private var pendingActive = false
        private weak var appliedWindow: NSWindow?
        private var originalIsOpaque: Bool?
        private var originalBackgroundColor: NSColor?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 离开窗口（关 sheet / 换宿主）：先还原，别把透明留在别的窗口上
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
            // 换窗口前先把旧窗口还原，避免属性残留
            if appliedWindow !== window {
                restore()
                appliedWindow = window
                originalIsOpaque = window.isOpaque
                originalBackgroundColor = window.backgroundColor
            }
            window.isOpaque = false
            window.backgroundColor = .clear
        }

        func restore() {
            if let window = appliedWindow {
                if let originalIsOpaque {
                    window.isOpaque = originalIsOpaque
                }
                window.backgroundColor = originalBackgroundColor
            }
            appliedWindow = nil
            originalIsOpaque = nil
            originalBackgroundColor = nil
        }
    }
}
