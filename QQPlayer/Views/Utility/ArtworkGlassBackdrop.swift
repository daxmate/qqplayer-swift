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
        // 布局钳制（2026-11-23 真机回归）：内层 ArtworkBlurBackground 的 scaledToFill
        // 会报告超额布局尺寸（≈844pt 见方）；这里同样取父级提议尺寸，保证本组件即使被误放成
        // ZStack 子节点也不会把整页撑宽（背景修饰器接法下视觉零变化：只填父级提议区域）。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

// MARK: - 自定义布局页接法（内容侧也要知道玻璃是否在铺）

/// 非分组列表页（自定义 `VStack` / `ZStack` 页面）接入封面毛玻璃。
///
/// 视觉层与库列表页完全同源（`ArtworkGlassScreenBackground`：装饰底 / 封面玻璃二选一），
/// 唯一附加能力是把**生效状态**经 `\.isArtworkGlassActive` 下发给**内容层**——
/// 供页面在玻璃铺上时撤掉自己那层「贴合系统底色」的白色渐变（全屏歌词页 2026-11-23 真机反馈）。
/// 生效判定 / 取图 / 切歌身份校验与容器同款，不另写一套。
private struct ArtworkGlassScreenModifier<Decoration: View>: ViewModifier {
    /// 页面装饰底（各页原有节点，玻璃生效时由容器隐藏）
    private let decoration: () -> Decoration

    @Environment(AppServices.self) private var services
    @Environment(PlayerEngine.self) private var playerEngine
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// 沿用唯一开关（键 / 默认值唯一来源：`PlayerGlassBackground`）
    @AppStorage(PlayerGlassBackground.storageKey) private var glassBackgroundEnabled = PlayerGlassBackground.enabledByDefault
    /// 当前曲目封面：只用于「玻璃是否生效」的判定（取图命中 `ArtworkManager` 缓存）
    @State private var artwork: ArtworkImage?

    init(@ViewBuilder decoration: @escaping () -> Decoration) {
        self.decoration = decoration
    }

    private var currentTrack: Track? { playerEngine.currentTrack }

    /// 开关变化也要重跑取图（关 → 清空，开 → 重新取）
    private var glassTaskId: String {
        "\(currentTrack?.stableId ?? "-")#\(glassBackgroundEnabled)"
    }

    private var isActive: Bool {
        ArtworkGlassScreenActivation.isActive(
            hasCurrentTrack: currentTrack != nil,
            hasArtwork: artwork != nil,
            isEnabled: glassBackgroundEnabled,
            reduceTransparency: reduceTransparency
        )
    }

    func body(content: Content) -> some View {
        content
            // 只在玻璃确实铺上时才告诉内容层「让路」；未生效时内容层保持原样
            .environment(\.isArtworkGlassActive, isActive)
            .background {
                ArtworkGlassScreenBackground(decoration: decoration)
            }
            .task(id: glassTaskId) {
                await loadArtwork()
            }
    }

    @MainActor
    private func loadArtwork() async {
        guard glassBackgroundEnabled, let track = currentTrack else {
            artwork = nil
            return
        }
        let image = await services.artworkManager.getArtwork(for: track)
        // 取图期间又切歌：这次结果作废（与容器同款身份校验）
        guard !Task.isCancelled, currentTrack?.stableId == track.stableId else { return }
        artwork = image
    }
}

extension View {
    /// 自定义布局页接入封面毛玻璃（实现见 `ArtworkGlassScreenModifier`）。
    func artworkGlassScreen<Decoration: View>(@ViewBuilder decoration: @escaping () -> Decoration) -> some View {
        modifier(ArtworkGlassScreenModifier(decoration: decoration))
    }
}

// MARK: - 分区行背景（设置页卡片透明）

/// 「封面玻璃正在铺」的生效标记：由 `ArtworkGlassGroupedListModifier`（分组列表）/
/// `ArtworkGlassScreenModifier`（自定义布局页）用 `ArtworkGlassScreenActivation` 算好后
/// 经环境下发（判定唯一，写入点 = 这两个容器），行内 / 内容层不再另算一套。
private struct ArtworkGlassActiveKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 当前页面是否正铺着封面毛玻璃（写入点：`ArtworkGlassGroupedListModifier` / `ArtworkGlassScreenModifier`）。
    var isArtworkGlassActive: Bool {
        get { self[ArtworkGlassActiveKey.self] }
        set { self[ArtworkGlassActiveKey.self] = newValue }
    }
}

/// 设置页分区卡片透明：玻璃生效时清掉行背景，系统分组白底不再压在封面上；
/// 玻璃未生效时**不产生任何修饰**（走 `content` 原样），与接入前逐像素一致。
/// 只动行背景 —— 分隔线 / 行高 / padding / `listStyle` 一律不碰，层次靠分隔线保留。
struct GlassClearRowBackground: ViewModifier {
    @Environment(\.isArtworkGlassActive) private var isGlassActive

    @ViewBuilder
    func body(content: Content) -> some View {
        if isGlassActive {
            content.listRowBackground(Color.clear)
        } else {
            content
        }
    }
}

extension View {
    /// 见 `GlassClearRowBackground`。挂在 `Section` 上（行背景 trait 会下发到该分区每一行）。
    func glassClearRowBackground() -> some View {
        modifier(GlassClearRowBackground())
    }
}

// MARK: - 分组列表页接法（设置页 `Form` / 分组 `List`）

/// 设置类页面接入封面毛玻璃：视觉层与库列表页同源（`ArtworkGlassScreenBackground` + 各页原装饰底）。
///
/// 与库列表页唯一差别：`Form` / 分组 `List` 自带系统分组底，会整个压在玻璃上
/// （真机上就是「设置页没做进玻璃」的那一块），所以玻璃生效时把它隐藏；
/// 玻璃未生效（开关关 / 当前曲目无封面 / 系统「降低透明度」）时回落 `.automatic`，
/// 外观与接入前逐像素一致。
///
/// 装饰底由调用方以 `@ViewBuilder` 传入（本文件编进双端 target，不在此处引用 iOS 专属的
/// `ScreenSpecificBackgroundView` / `ScreenType`）。
private struct ArtworkGlassGroupedListModifier<Decoration: View>: ViewModifier {
    /// 页面装饰底（各页原有节点，玻璃生效时由容器隐藏）
    private let decoration: () -> Decoration

    @Environment(AppServices.self) private var services
    @Environment(PlayerEngine.self) private var playerEngine
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// 沿用唯一开关（键 / 默认值唯一来源：`PlayerGlassBackground`）
    @AppStorage(PlayerGlassBackground.storageKey) private var glassBackgroundEnabled = PlayerGlassBackground.enabledByDefault
    /// 当前曲目封面：只用于「要不要隐藏分组底」的判定（取图命中 `ArtworkManager` 缓存）
    @State private var artwork: ArtworkImage?

    init(@ViewBuilder decoration: @escaping () -> Decoration) {
        self.decoration = decoration
    }

    private var currentTrack: Track? { playerEngine.currentTrack }

    /// 开关变化也要重跑取图（关 → 清空，开 → 重新取）
    private var glassTaskId: String {
        "\(currentTrack?.stableId ?? "-")#\(glassBackgroundEnabled)"
    }

    private var isActive: Bool {
        ArtworkGlassScreenActivation.isActive(
            hasCurrentTrack: currentTrack != nil,
            hasArtwork: artwork != nil,
            isEnabled: glassBackgroundEnabled,
            reduceTransparency: reduceTransparency
        )
    }

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(isActive ? .hidden : .automatic)
            // 卡片行背景（`GlassClearRowBackground`）跟同一判定走：只在玻璃确实铺上时才清
            .environment(\.isArtworkGlassActive, isActive)
            .background {
                ArtworkGlassScreenBackground(decoration: decoration)
            }
            .task(id: glassTaskId) {
                await loadArtwork()
            }
    }

    @MainActor
    private func loadArtwork() async {
        guard glassBackgroundEnabled, let track = currentTrack else {
            artwork = nil
            return
        }
        let image = await services.artworkManager.getArtwork(for: track)
        // 取图期间又切歌：这次结果作废（与 `ArtworkGlassScreenBackground` 同款身份校验）
        guard !Task.isCancelled, currentTrack?.stableId == track.stableId else { return }
        artwork = image
    }
}

extension View {
    /// 设置页 / 分组列表接入封面毛玻璃（实现见 `ArtworkGlassGroupedListModifier`）。
    func artworkGlassGroupedList<Decoration: View>(@ViewBuilder decoration: @escaping () -> Decoration) -> some View {
        modifier(ArtworkGlassGroupedListModifier(decoration: decoration))
    }
}
