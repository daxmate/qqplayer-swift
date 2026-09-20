//
//  MacLyricsView.swift
//  QQPlayer
//
//  macOS lyrics panel: same visual language as the iOS full-screen lyrics
//  page (distance-graded typography, accent active line + glow, vertical
//  centering, edge fades, glass empty-state card, spring scrolling).
//  Karaoke mode keeps speed / single-line loop / AB loop controls
//  (MacKaraokeControlBar, macOS 单行样式). QQPlayerMac target only — kept
//  out of the iOS target via pbxproj membership exceptions.
//

import AppKit
import SwiftUI

/// 空态类型（加载中 / 纯音乐 / 无歌词）：决定玻璃卡图标与文案。
/// 文案 key 与 iOS LyricsView 完全共用（五语齐备，无需新增本地化）。
private enum MacLyricsEmptyKind {
    case loading
    case instrumental
    case notFound

    var title: String {
        switch self {
        case .loading: return "lyrics_empty_loading_title".localized
        case .instrumental: return "lyrics_empty_instrumental_title".localized
        case .notFound: return "lyrics_empty_not_found_title".localized
        }
    }

    var subtitle: String {
        switch self {
        case .loading: return "lyrics_empty_loading_subtitle".localized
        case .instrumental: return "lyrics_empty_instrumental_subtitle".localized
        case .notFound: return "lyrics_empty_not_found_subtitle".localized
        }
    }
}

// MARK: - 切句过渡（emphasis 逐帧插值）

/// 分段线性插值：节点按 emphasis 降序给出，超出两端取端值。
/// 每个节点值 = 改前（3ff6474）该档位的静态渲染值，故静态效果不变，只有节点之间才插值。
private func lyricLerp(_ value: Double, _ nodes: [(Double, Double)]) -> Double {
    guard let first = nodes.first, let last = nodes.last else { return value }
    if value >= first.0 { return first.1 }
    if value <= last.0 { return last.1 }
    for index in 0 ..< (nodes.count - 1) {
        let (highEmphasis, highValue) = nodes[index]
        let (lowEmphasis, lowValue) = nodes[index + 1]
        guard value <= highEmphasis, value >= lowEmphasis else { continue }
        let ratio = (value - lowEmphasis) / (highEmphasis - lowEmphasis)
        return lowValue + (highValue - lowValue) * ratio
    }
    return last.1
}

/// 0.66 → 1.0 的归一化进度：只有这一段跨色相（语义色 → accent），低段只动 alpha。
private func lyricEmphasisProgress(_ emphasis: Double) -> CGFloat {
    CGFloat(min(max((emphasis - 0.66) / 0.34, 0), 1))
}

/// 语义色 → accent 的跨档位混色（fraction 0 = 语义色，1 = accent）。
/// 用 NSColor.blended(withFraction:of:)：`Color.mix` 是 macOS 15+ API（2026-09-18 部署目标由 13.0 提到 14.0，本条结论不变，仍用不了）。
private func blendSemantic(
    _ base: NSColor,
    alpha: CGFloat,
    with accent: Color,
    fraction: CGFloat
) -> Color {
    let clamped = min(max(fraction, 0), 1)
    guard let from = base.withAlphaComponent(alpha).usingColorSpace(.sRGB),
          let to = NSColor(accent).usingColorSpace(.sRGB),
          let mixed = from.blended(withFraction: clamped, of: to)
    else { return accent }
    return Color(nsColor: mixed)
}

/// 行强调度（0…1，1 = 当前行）：Animatable —— 字号/颜色/阴影随过渡值逐帧插值，
/// 替代「字号瞬间跳变（SwiftUI 不插值 Font）+ 两条曲线不同步」的急促观感（2026-09-13 用户反馈）。
/// 字重不可插值 → 按 emphasis 阈值切换（切换点前后字号/透明度正在连续变化，视觉上被掩盖）。
/// 透明度/缩放/行距作用于整行（含译文行）→ 由下面的 static 方法供行容器调用。
private struct LyricLineEmphasis: ViewModifier, Animatable {
    /// 0…1
    var emphasis: Double
    let accent: Color
    let fontScale: CGFloat
    let karaoke: Bool

    /// 关键：让 emphasis 可插值 → body 逐帧重算 → 字号连续变化
    var animatableData: Double {
        get { emphasis }
        set { emphasis = newValue }
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: mainSize, weight: mainWeight))
            .foregroundColor(mainColor)
            .shadow(color: shadowColor, radius: shadowRadius)
    }

    // MARK: 行级度量（透明度/缩放/行距作用于整行，含译文行）

    /// 整行透明度（节点值 = 改前的 mainOpacity；跟唱 1.0 / 0.8）
    static func lineOpacity(_ emphasis: Double, karaoke: Bool) -> Double {
        if karaoke {
            return lyricLerp(emphasis, [(1.0, 1.0), (0.66, 0.8)])
        }
        return lyricLerp(
            emphasis,
            [(1.0, 1.0), (0.66, 0.9), (0.40, 0.6), (0.20, 0.3), (0.08, 0.15)]
        )
    }

    /// 整行缩放（节点值 = 改前的 lineScale；跟唱不缩放）
    static func lineScale(_ emphasis: Double, karaoke: Bool) -> CGFloat {
        guard !karaoke else { return 1.0 }
        return CGFloat(lyricLerp(emphasis, [(1.0, 1.02), (0.66, 0.97), (0.40, 0.94)]))
    }

    /// 整行垂直内边距（改前 当前行 24 / 其余 16；跟唱固定 18）
    static func linePadding(_ emphasis: Double, karaoke: Bool) -> CGFloat {
        guard !karaoke else { return 18 }
        return CGFloat(lyricLerp(emphasis, [(1.0, 24), (0.66, 16)]))
    }

    // MARK: 主行样式

    /// 字号（×fontScale）：1.0 → 26、0.66 → 19、0.40 及更远 → 16（跟唱 22 / 19）
    private var mainSize: CGFloat {
        let size = karaoke
            ? lyricLerp(emphasis, [(1.0, 22), (0.66, 19)])
            : lyricLerp(emphasis, [(1.0, 26), (0.66, 19), (0.40, 16)])
        return CGFloat(size) * fontScale
    }

    private var mainWeight: Font.Weight {
        if karaoke { return emphasis > 0.85 ? .bold : .regular }
        if emphasis > 0.85 { return .bold }
        if emphasis > 0.45 { return .semibold }
        return .medium
    }

    /// 颜色：≤0.66 只插值 primary 的 alpha（0.75 / 0.40 / 0.18），>0.66 才由 primary 混向 accent
    private var mainColor: Color {
        let fraction = lyricEmphasisProgress(emphasis)
        if karaoke {
            guard fraction > 0 else { return .primary.opacity(0.8) }
            return blendSemantic(.labelColor, alpha: 0.8, with: accent, fraction: fraction)
        }
        guard fraction > 0 else {
            let alpha = lyricLerp(emphasis, [(0.66, 0.75), (0.40, 0.4), (0.20, 0.18), (0.08, 0.18)])
            return .primary.opacity(alpha)
        }
        return blendSemantic(.labelColor, alpha: 0.75, with: accent, fraction: fraction)
    }

    /// 阴影：只有 0.66 → 1.0 段出现（1.0 → 半径 20 / accent 0.5，节点之下 → 0 / clear）
    private var shadowRadius: CGFloat {
        guard !karaoke else { return 0 }
        return CGFloat(lyricLerp(emphasis, [(1.0, 20), (0.66, 0)]))
    }

    private var shadowColor: Color {
        guard !karaoke else { return .clear }
        return accent.opacity(0.5 * Double(lyricEmphasisProgress(emphasis)))
    }
}

/// 译文行强调：与主行同一套路（节点值照旧：当前 16 / 距离 1 14 / 更远 13；
/// 跟唱 当前 16 / 其余 14），字号与颜色都按 emphasis 插值、字号 ×fontScale。
/// 整行透明度/缩放仍由行容器统一施加。
private struct LyricTranslationEmphasis: ViewModifier, Animatable {
    /// 次要行层级：译文（原档）/ 罗马音（同一套插值，比译文小一档）
    enum Tier {
        case translation
        case roman
    }

    var emphasis: Double
    let accent: Color
    let fontScale: CGFloat
    let karaoke: Bool
    var tier: Tier = .translation

    var animatableData: Double {
        get { emphasis }
        set { emphasis = newValue }
    }

    func body(content: Content) -> some View {
        content
            .font(.system(size: size * fontScale))
            .foregroundColor(color)
    }

    /// 字号阶梯：译文与罗马音共用这一张表（罗马音整体小一档）
    private var size: CGFloat {
        let table: [(Double, Double)]
        switch (karaoke, tier) {
        case (true, .translation): table = [(1.0, 16), (0.66, 14)]
        case (true, .roman): table = [(1.0, 14), (0.66, 12)]
        case (false, .translation): table = [(1.0, 16), (0.66, 14), (0.20, 13)]
        case (false, .roman): table = [(1.0, 14), (0.66, 12), (0.20, 11)]
        }
        return CGFloat(lyricLerp(emphasis, table))
    }

    private var color: Color {
        let fraction = lyricEmphasisProgress(emphasis)
        if karaoke {
            guard fraction > 0 else { return .secondary.opacity(0.7) }
            return blendSemantic(
                .secondaryLabelColor,
                alpha: 0.7,
                with: accent.opacity(0.95),
                fraction: fraction
            )
        }
        guard fraction > 0 else {
            let alpha = lyricLerp(emphasis, [(0.66, 0.85), (0.40, 0.5), (0.20, 0.25)])
            return .secondary.opacity(alpha)
        }
        return blendSemantic(
            .secondaryLabelColor,
            alpha: 0.85,
            with: accent.opacity(0.95),
            fraction: fraction
        )
    }
}

struct MacLyricsView: View {
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    @Environment(\.appAccentColor) private var appAccentColor
    let lyrics: Lyrics?
    let currentTime: TimeInterval
    let isLoading: Bool
    /// 是否大画面（跟唱或双击放大）：控制跟唱 mic 入口显示（普通态 mic 在播放区控制行）
    let isFullscreen: Bool
    /// 双击歌词：由宿主决定（普通态放大 / 放大态缩回 / 跟唱态退跟唱+缩回）
    let onToggleExpand: () -> Void
    /// 歌词搜索入口（播放页 sheet 弹出 MacLyricsSearchView）
    let onLyricsSearch: () -> Void

    @Environment(KaraokeController.self) private var karaoke

    /// 歌词设置（D3，web 版 lyric 设置对齐）：字号/译文行/整体延迟校准。
    /// 启动与 qqplayerSettingsDidChange 时从 DeleteSettings 刷新；offset 同时
    /// 注入 KaraokeController（跟唱 tick/跳句共用同一歌词时间轴）。
    /// 字号（12–22pt，默认 15）语义 = 整体缩放系数：所有字号等比 ×(fontSize / 15)。
    @State private var fontSize: Double = 15
    @State private var showTranslation = true
    @State private var showRoman = true
    @State private var lyricOffset: Double = 0

    /// 面板底色（对齐 iOS 的 systemBackground）
    private var baseColor: Color { Color(nsColor: .windowBackgroundColor) }
    /// 字号整体缩放系数（对齐 iOS LyricsView 的固定字号体系）
    private var fontScale: CGFloat { CGFloat(fontSize / 15.0) }

    /// 切句过渡动画：行强调与滚屏共用同一条曲线。
    /// 改前是两条响应不同的 spring（行 ≈0.31s / 滚屏 ≈0.48s）→ 文字先变完、屏才开始滚，
    /// 观感是二次突变；统一成一条 0.55s / 阻尼 0.92 的柔和曲线（2026-09-13 用户反馈）。
    private static let lyricAnimation = Animation.spring(response: 0.55, dampingFraction: 0.92)

    var body: some View {
        VStack(spacing: DesignTokens.space0) {
            header
            Divider()
            content
            // 对齐 iOS LyricsView：跟唱控制条常驻底部，无论歌词状态（加载中/纯文本/无歌词）都显示
            if karaoke.isKaraokeOn {
                Divider()
                MacKaraokeControlBar(accentColor: appAccentColor)
                    .padding(.vertical, DesignTokens.space8)
            }
        }
        .background(panelBackground)
        .onAppear {
            applyLyricSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            applyLyricSettings()
        }
        // 页面级双击：纯放大/缩回切换（2026-09-06 用户拍板：双击 ≠ 跟唱，跟唱经 mic 按钮）。
        // highPriority 双击优先，行单击等双击判定失败后才触发；快速双击不触发行跳转。
        .highPriorityGesture(
            TapGesture(count: 2)
                .onEnded {
                    onToggleExpand()
                }
        )
    }

    /// 面板底色：系统窗口底色铺满 + 主题色低透明径向辉光（对齐 iOS 的媒体库背景光晕）
    private var panelBackground: some View {
        ZStack {
            baseColor

            RadialGradient(
                colors: [appAccentColor.opacity(0.18), .clear],
                center: .center,
                startRadius: 0,
                endRadius: 320
            )
            .blur(radius: 40)
            .allowsHitTesting(false)
        }
    }

    /// 读取歌词设置并应用：字号/译文行显示 + offset 注入 KaraokeController。
    private func applyLyricSettings() {
        let settings = DeleteSettings.load()
        fontSize = settings.lyricFontSize
        showTranslation = settings.lyricShowTranslation
        showRoman = settings.lyricShowRoman
        lyricOffset = settings.lyricOffset
        karaoke.lyricOffset = settings.lyricOffset
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("lyrics".localized, systemImage: "quote.bubble")
                .font(.headline)
            Spacer()
            // 跟唱开关（2026-09-06 用户拍板：双击=放大不绑跟唱，跟唱入口放歌词区）。
            // 大画面（跟唱/放大）时显示：普通态 mic 在播放区控制行，避免重复。
            if isFullscreen {
                Button {
                    karaoke.toggleKaraokeMode()
                } label: {
                    Image(systemName: karaoke.isKaraokeOn ? "mic.fill" : "mic")
                        .font(.system(size: DesignTokens.font14, weight: .semibold))
                        .foregroundColor(karaoke.isKaraokeOn ? appAccentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("karaoke_mode_help".localized)
            }
            Button(action: onLyricsSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: DesignTokens.font14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("lyrics_search_title".localized)
            // 无关闭按钮：歌词常驻显示（2026-09-02 用户拍板：歌词是本 APP 第一重要功能）
        }
        .padding(.horizontal, DesignTokens.space16)
        .padding(.vertical, DesignTokens.space8)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            emptyState(.loading)
        } else if let lyrics {
            if lyrics.isInstrumental {
                emptyState(.instrumental)
            } else if !lyrics.syncedLyrics.isEmpty {
                syncedView(lyrics.syncedLyrics)
            } else if !lyrics.plainLyrics.isEmpty {
                // 无时间轴歌词同样是「渲染出来的歌词文本」→ 按 UI 语言归一字形
                plainView(DisplayScriptNormalizer.display(lyrics.plainLyrics))
            } else {
                emptyState(.notFound)
            }
        } else {
            emptyState(.notFound)
        }
    }

    // MARK: - Empty / loading / instrumental states（玻璃卡，按面板高度自适应）

    private func emptyState(_ kind: MacLyricsEmptyKind) -> some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            Group {
                if height < 200 {
                    // 极矮面板（最小 140pt）：只留图标 + 标题，不套卡片，保证不裁切
                    VStack(spacing: DesignTokens.space8) {
                        emptyIcon(kind, size: 28)
                        Text(kind.title)
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)
                    }
                } else {
                    emptyCard(kind, compact: height < 340)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyCard(_ kind: MacLyricsEmptyKind, compact: Bool) -> some View {
        VStack(spacing: compact ? DesignTokens.space12 : DesignTokens.space32) {
            ZStack {
                glassGlow(size: compact ? 120 : 200)

                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().stroke(glassStroke, lineWidth: 2))
                    .frame(width: compact ? 64 : 120, height: compact ? 64 : 120)
                    .shadow(color: appAccentColor.opacity(0.3), radius: 25, x: 0, y: 10)

                emptyIcon(kind, size: compact ? 28 : 50)
            }

            VStack(spacing: DesignTokens.space12) {
                Text(kind.title)
                    .font(compact ? Font.headline : Font.title)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.center)

                // 紧凑版隐藏副标题（面板矮时保证不裁切）
                if !compact {
                    Text(kind.subtitle)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .padding(compact ? DesignTokens.space20 : DesignTokens.space40)
        .background(cardBackground)
        .padding(.horizontal, DesignTokens.space40)
    }

    /// 外圈径向辉光（跟随主题色）
    private func glassGlow(size: CGFloat) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        appAccentColor.opacity(0.4),
                        appAccentColor.opacity(0.2),
                        appAccentColor.opacity(0.05),
                        .clear,
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .blur(radius: 30)
    }

    /// 玻璃圆描边渐变（主题色由亮到暗）
    private var glassStroke: LinearGradient {
        LinearGradient(
            colors: [
                appAccentColor.opacity(0.6),
                appAccentColor.opacity(0.3),
                appAccentColor.opacity(0.1),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 毛玻璃卡：ultraThinMaterial + 主题色渐变描边 + 内层高光 + 主题色投影
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: DesignTokens.radius28)
        return shape
            .fill(.ultraThinMaterial)
            .overlay(
                shape.stroke(
                    LinearGradient(
                        colors: [
                            appAccentColor.opacity(0.3),
                            Color.primary.opacity(0.15),
                            appAccentColor.opacity(0.2),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            )
            .overlay(
                shape.fill(
                    LinearGradient(
                        colors: [
                            appAccentColor.opacity(0.05),
                            .clear,
                            appAccentColor.opacity(0.08),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .shadow(color: appAccentColor.opacity(0.2), radius: 35, x: 0, y: 15)
    }

    @ViewBuilder
    private func emptyIcon(_ kind: MacLyricsEmptyKind, size: CGFloat) -> some View {
        switch kind {
        case .loading:
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .primary))
                .scaleEffect(1.5)
        case .instrumental, .notFound:
            Image(systemName: kind == .instrumental ? "music.note" : "text.badge.xmark")
                .font(.system(size: size, weight: .medium))
                .foregroundColor(.primary)
                .shadow(color: appAccentColor.opacity(0.6), radius: 15)
        }
    }

    // MARK: - Synced lyrics（距离分级排版，对齐 iOS LyricsView）

    private func syncedView(_ lines: [LyricsLine]) -> some View {
        // 歌词轴时间（音频时间 - offset，web lyricTime 语义）：高亮行与跟唱 tick 同轴
        let activeIndex = LyricTiming.activeLineIndex(time: currentTime - lyricOffset, in: lines)
        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: DesignTokens.space0) {
                            // 上下等距撑开 → 当前行恒在面板垂直中央
                            Spacer()
                                .frame(height: max(geometry.size.height / 2 - 40, 0))

                            // 保持普通 VStack（非 LazyVStack）：iOS 注释写明 LazyVStack 下
                            // scrollTo 未实例化行有已知失败风险，自动滚动可靠性优先。
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                let isActive = activeIndex == index
                                let distance = activeIndex.map { abs(index - $0) } ?? 99
                                lyricLineView(
                                    line: line,
                                    isActive: isActive,
                                    distance: distance,
                                    index: index
                                )
                            }

                            Spacer()
                                .frame(height: max(geometry.size.height / 2 - 40, 0))
                        }
                    }
                    // 面板内不禁用滚动：Mac 无 iOS 的手势冲突，用户可手动翻，行变化时回中心

                    // 上下边缘渐隐（面板可矮到 140pt → 渐隐高度随面板收缩）
                    VStack(spacing: DesignTokens.space0) {
                        LinearGradient(colors: fadeColors(top: true), startPoint: .top, endPoint: .bottom)
                            .frame(height: min(150, geometry.size.height * 0.22))

                        Spacer()

                        LinearGradient(colors: fadeColors(top: false), startPoint: .top, endPoint: .bottom)
                            .frame(height: min(150, geometry.size.height * 0.22))
                    }
                    .allowsHitTesting(false)
                }
                .onChange(of: activeIndex) { _, newIndex in
                    guard let newIndex else { return }
                    // 等选 AB 终点（b == nil）时暂停自动滚动：让用户手动滚动找 B 句
                    // （对齐 iOS updateActiveLineAndScroll，用户拍板 2026-08-29）
                    if karaoke.isKaraokeOn, let ab = karaoke.abLoop, ab.b == nil { return }
                    withAnimation(Self.lyricAnimation) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
                .onAppear {
                    guard let activeIndex else { return }
                    proxy.scrollTo(activeIndex, anchor: .center)
                }
            }
        }
    }

    /// 边缘渐隐用的底色色阶（top = 自上而下；bottom = 反向）
    private func fadeColors(top: Bool) -> [Color] {
        let stops = [
            baseColor.opacity(0.95),
            baseColor.opacity(0.7),
            baseColor.opacity(0.3),
            Color.clear,
        ]
        return top ? stops : stops.reversed()
    }

    /// 行强调度（0…1）：非跟唱按与当前行的距离取档（档位值 = 改前的静态值），跟唱统一 1.0 / 0.66。
    private func emphasisValue(isActive: Bool, distance: Int) -> Double {
        if karaoke.isKaraokeOn { return isActive ? 1.0 : 0.66 }
        if isActive { return 1.0 }
        switch distance {
        case 1: return 0.66
        case 2: return 0.40
        case 3: return 0.20
        default: return 0.08
        }
    }

    private func lyricLineView(line: LyricsLine, isActive: Bool, distance: Int, index: Int) -> some View {
        let emphasis = emphasisValue(isActive: isActive, distance: distance)
        let isKaraoke = karaoke.isKaraokeOn
        return VStack(spacing: DesignTokens.space4) {
            Text(line.displayText)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
                .modifier(
                    LyricLineEmphasis(
                        emphasis: emphasis,
                        accent: appAccentColor,
                        fontScale: fontScale,
                        karaoke: isKaraoke
                    )
                )

            if showRoman, let roman = line.displayRoman, !roman.isEmpty {
                Text(roman)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .modifier(
                        LyricTranslationEmphasis(
                            emphasis: emphasis,
                            accent: appAccentColor,
                            fontScale: fontScale,
                            karaoke: isKaraoke,
                            tier: .roman
                        )
                    )
            }

            if showTranslation, let translation = line.displayTranslation, !translation.isEmpty {
                Text(translation)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.center)
                    .modifier(
                        LyricTranslationEmphasis(
                            emphasis: emphasis,
                            accent: appAccentColor,
                            fontScale: fontScale,
                            karaoke: isKaraoke
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.space32)
        .padding(.vertical, LyricLineEmphasis.linePadding(emphasis, karaoke: isKaraoke))
        .id(index)
        .scaleEffect(LyricLineEmphasis.lineScale(emphasis, karaoke: isKaraoke), anchor: .center)
        .opacity(LyricLineEmphasis.lineOpacity(emphasis, karaoke: isKaraoke))
        // 行强调由播放 tick 驱动的 body 重算得出（不是用户事件）→ 靠 .animation(value:) 触发，
        // 与滚屏共用同一条曲线（不要再套 withAnimation）
        .animation(Self.lyricAnimation, value: emphasis)
        .contentShape(Rectangle())
        // 对齐 iOS LyricsView：仅跟唱模式响应，决策统一走 clickLine
        // （无 AB → 播放该句；等选终点 → 设 B；区间内 → 跳到该句播放）
        // 普通 onTapGesture：页面级 highPriorityGesture 双击优先，
        // 单击等双击窗口判定失败后触发（与 iOS 结构一致）
        .onTapGesture {
            guard karaoke.isKaraokeOn else { return }
            karaoke.clickLine(index: index)
        }
        // 对齐 iOS LyricsView：AB 激活时端点行加 accentColor 小圆点
        .overlay(alignment: .trailing) {
            if let ab = karaoke.abLoop, karaoke.isKaraokeOn,
               index == ab.a || index == ab.b {
                Circle()
                    .fill(appAccentColor)
                    .frame(width: 7, height: 7)
                    .padding(.trailing, DesignTokens.space24)
            }
        }
    }

    // MARK: - Plain lyrics（无时间轴）

    private func plainView(_ text: String) -> some View {
        ScrollView(showsIndicators: false) {
            Text(text)
                .font(.system(size: DesignTokens.font17 * fontScale, weight: .medium))
                .foregroundColor(.primary.opacity(0.9))
                .lineSpacing(10)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignTokens.space32)
                .padding(.vertical, DesignTokens.space16)
        }
    }
}
