//
//  ArtworkGlassBackdrop.swift
//  QQPlayer
//
//  封面毛玻璃底的**唯一视觉实现**（iOS 播放页 + 库列表页共用；文件编进双端 target，
//  macOS 目前不消费 —— 窗口玻璃仍是 `MacWindowGlass`，数值不动）。
//
//  分层（自下而上）：`ArtworkBlurBackground`（预渲染模糊封面，唯一模糊/缓存实现）
//  → 均匀雾面（浅 white 0.30 / 深 black 0.36，按外观自适应）→ 暗角（压住四角）。
//  雾面 / 暗角数值**只在本文件出现一次**；播放页与库列表页都从这里取。
//
//  用法：
//    · 播放页：`ArtworkGlassBackdrop(artwork:cacheKey:)` —— 封面由调用方解码好，直接铺；
//    · 库列表页：`ArtworkGlassScreenBackground { ScreenSpecificBackgroundView(screen: …) }`
//      —— 容器自己按当前播放曲目异步取图，并在玻璃生效时隐藏装饰底（节点保留）。
//
//  生效判定唯一入口仍是 `PlayerGlassBackground.isActive`（开关 / 有封面 / 降低透明度）。
//

import SwiftUI

// MARK: - 视觉层（模糊 + 雾面 + 暗角）

/// 封面毛玻璃底内容。只作为背景层内容使用（不进页面布局层级）。
struct ArtworkGlassBackdrop: View {
    /// 当前曲目封面（已解码位图；nil 时 `ArtworkBlurBackground` 只铺黑底）
    let artwork: ArtworkImage?
    /// 稳定标识（曲目 stableId）：模糊缓存键 + 切歌判定
    let cacheKey: String?

    /// 雾面按外观自适应（与 `MacWindowGlass` 同口径取色，数值不同源）
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            ArtworkBlurBackground(artwork: artwork, cacheKey: cacheKey)
            scrim
            vignette
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 均匀雾面：浅色 white 0.30（2026-11-23 真机反馈：0.62 把封面色洗掉，减淡让封面色透出来）/ 深色 black 0.36
    private var scrim: Color {
        colorScheme == .dark ? Color.black.opacity(0.36) : Color.white.opacity(0.30)
    }

    /// 暗角：压住四角，避免封面边缘过亮
    private var vignette: RadialGradient {
        RadialGradient(
            colors: [Color.black.opacity(0), Color.black.opacity(colorScheme == .dark ? 0.28 : 0.10)],
            center: .center,
            startRadius: 180,
            endRadius: 760
        )
    }
}

// MARK: - 生效判定（纯逻辑，单测可覆盖）

/// 库列表页的生效判定：**当前有曲目**才有可跟随的封面，其余条件交给唯一入口
/// `PlayerGlassBackground.isActive`（开关 / 有封面 / 降低透明度），不另写一套。
enum ArtworkGlassScreenActivation {
    static func isActive(
        hasCurrentTrack: Bool,
        hasArtwork: Bool,
        isEnabled: Bool,
        reduceTransparency: Bool
    ) -> Bool {
        guard hasCurrentTrack else { return false }
        return PlayerGlassBackground.isActive(
            isEnabled: isEnabled,
            hasArtwork: hasArtwork,
            reduceTransparency: reduceTransparency
        )
    }
}

// MARK: - 库列表页容器（装饰底 + 毛玻璃底二选一）

/// 库列表页的「装饰底 / 毛玻璃底」容器。
///
/// - 装饰底（调用方传入的 `ScreenSpecificBackgroundView`）**原地保留**：玻璃生效时只 `.opacity(0)`，
///   不删节点、不改其它属性；
/// - 玻璃只在这一层（背景层）出现，不新增页面布局节点、不动间距 / padding / frame；
/// - 回落（开关关 / 无当前曲目 / 无封面 / 系统「降低透明度」）⇒ 装饰底照常显示、无玻璃层；
/// - 封面按当前播放曲目异步取图（唯一入口 `ArtworkManager.getArtwork(for:)`），
///   `.task(id:)` 以 stableId 为身份 ⇒ 切歌正确换图（与播放页同款身份校验，不建第二份缓存）。
struct ArtworkGlassScreenBackground<Decoration: View>: View {
    /// 装饰底（各页面原有的背景节点）
    private let decoration: () -> Decoration

    @Environment(AppServices.self) private var services
    @Environment(PlayerEngine.self) private var playerEngine
    /// 回落条件之一：系统「降低透明度」
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// 沿用唯一开关（键 / 默认值唯一来源：`PlayerGlassBackground`）
    @AppStorage(PlayerGlassBackground.storageKey) private var glassBackgroundEnabled = PlayerGlassBackground.enabledByDefault
    /// 当前播放曲目封面（异步取图；切歌按 stableId 重取）
    @State private var artwork: ArtworkImage?

    init(@ViewBuilder decoration: @escaping () -> Decoration) {
        self.decoration = decoration
    }

    private var currentTrack: Track? { playerEngine.currentTrack }

    private var isActive: Bool {
        ArtworkGlassScreenActivation.isActive(
            hasCurrentTrack: currentTrack != nil,
            hasArtwork: artwork != nil,
            isEnabled: glassBackgroundEnabled,
            reduceTransparency: reduceTransparency
        )
    }

    var body: some View {
        ZStack {
            // 装饰底原地保留（与播放页同款：玻璃生效时只隐藏，不删节点）
            decoration()
                .opacity(isActive ? 0 : 1)

            if isActive {
                ArtworkGlassBackdrop(artwork: artwork, cacheKey: currentTrack?.stableId)
            }
        }
        .task(id: currentTrack?.stableId) {
            await loadArtwork()
        }
    }

    @MainActor
    private func loadArtwork() async {
        guard let track = currentTrack else {
            artwork = nil
            return
        }
        let image = await services.artworkManager.getArtwork(for: track)
        // 取图期间又切歌了：这次结果作废（`.task(id:)` 已随 stableId 取消，这里再按身份校验一次）
        guard !Task.isCancelled, currentTrack?.stableId == track.stableId else { return }
        artwork = image
    }
}
