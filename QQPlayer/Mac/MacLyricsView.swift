//
//  MacLyricsView.swift
//  QQPlayer
//
//  macOS lyrics panel: same visual language as the iOS full-screen lyrics
//  page (distance-graded typography, accent active line + glow, vertical
//  centering, edge fades, glass empty-state card, spring scrolling).
//  Karaoke mode keeps speed / single-line loop / AB loop controls
//  (KaraokeControlBar). QQPlayerMac target only — kept out of the iOS
//  target via pbxproj membership exceptions.
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

    @ObservedObject private var karaoke = KaraokeController.shared

    /// 歌词设置（D3，web 版 lyric 设置对齐）：字号/译文行/整体延迟校准。
    /// 启动与 qqplayerSettingsDidChange 时从 DeleteSettings 刷新；offset 同时
    /// 注入 KaraokeController（跟唱 tick/跳句共用同一歌词时间轴）。
    /// 字号（12–22pt，默认 15）语义 = 整体缩放系数：所有字号等比 ×(fontSize / 15)。
    @State private var fontSize: Double = 15
    @State private var showTranslation = true
    @State private var lyricOffset: Double = 0

    /// 面板底色（对齐 iOS 的 systemBackground）
    private var baseColor: Color { Color(nsColor: .windowBackgroundColor) }
    /// 字号整体缩放系数（对齐 iOS LyricsView 的固定字号体系）
    private var fontScale: CGFloat { CGFloat(fontSize / 15.0) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            // 对齐 iOS LyricsView：跟唱控制条常驻底部，无论歌词状态（加载中/纯文本/无歌词）都显示
            if karaoke.isKaraokeOn {
                Divider()
                KaraokeControlBar(accentColor: appAccentColor)
                    .padding(.vertical, 8)
                    .background(
                        LinearGradient(
                            colors: [.clear, Color.black.opacity(0.35)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
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
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(karaoke.isKaraokeOn ? appAccentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help("karaoke_mode_help".localized)
            }
            Button(action: onLyricsSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("lyrics_search_title".localized)
            // 无关闭按钮：歌词常驻显示（2026-09-02 用户拍板：歌词是本 APP 第一重要功能）
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
                    VStack(spacing: 8) {
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
        VStack(spacing: compact ? 14 : 32) {
            ZStack {
                glassGlow(size: compact ? 120 : 200)

                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().stroke(glassStroke, lineWidth: 2))
                    .frame(width: compact ? 64 : 120, height: compact ? 64 : 120)
                    .shadow(color: appAccentColor.opacity(0.3), radius: 25, x: 0, y: 10)

                emptyIcon(kind, size: compact ? 28 : 50)
            }

            VStack(spacing: 12) {
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
        .padding(compact ? 20 : 44)
        .background(cardBackground)
        .padding(.horizontal, 40)
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
        let shape = RoundedRectangle(cornerRadius: 28)
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
                        VStack(spacing: 0) {
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
                    VStack(spacing: 0) {
                        LinearGradient(colors: fadeColors(top: true), startPoint: .top, endPoint: .bottom)
                            .frame(height: min(150, geometry.size.height * 0.22))

                        Spacer()

                        LinearGradient(colors: fadeColors(top: false), startPoint: .top, endPoint: .bottom)
                            .frame(height: min(150, geometry.size.height * 0.22))
                    }
                    .allowsHitTesting(false)
                }
                .onChange(of: activeIndex) { newIndex in
                    guard let newIndex else { return }
                    // 等选 AB 终点（b == nil）时暂停自动滚动：让用户手动滚动找 B 句
                    // （对齐 iOS updateActiveLineAndScroll，用户拍板 2026-08-29）
                    if karaoke.isKaraokeOn, let ab = karaoke.abLoop, ab.b == nil { return }
                    withAnimation(
                        .interpolatingSpring(
                            mass: 1.0,
                            stiffness: 170,
                            damping: 25,
                            initialVelocity: 0
                        )
                    ) {
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

    private func lyricLineView(line: LyricsLine, isActive: Bool, distance: Int, index: Int) -> some View {
        VStack(spacing: 4) {
            Text(line.displayText)
                .font(mainFont(isActive: isActive, distance: distance))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(mainColor(isActive: isActive, distance: distance))
                .multilineTextAlignment(.center)
                .shadow(
                    color: isActive ? appAccentColor.opacity(0.5) : .clear,
                    radius: isActive ? 20 : 0
                )

            if showTranslation, let translation = line.displayTranslation, !translation.isEmpty {
                Text(translation)
                    .font(translationFont(isActive: isActive, distance: distance))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(translationColor(isActive: isActive, distance: distance))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, karaoke.isKaraokeOn ? 18 : (isActive ? 24 : 16))
        .id(index)
        .scaleEffect(lineScale(isActive: isActive, distance: distance), anchor: .center)
        .opacity(mainOpacity(isActive: isActive, distance: distance))
        .animation(
            .interpolatingSpring(
                mass: 0.5,
                stiffness: 200,
                damping: 20,
                initialVelocity: 0
            ),
            value: isActive
        )
        .contentShape(Rectangle())
        // 对齐 iOS LyricsView：仅跟唱模式响应，决策统一走 clickLine
        // （无 AB → 播放该句；等选终点 → 设 B；区间内 → 跳到该句播放）
        // 普通 onTapGesture：页面级 highPriorityGesture 双击优先，
        // 单击等双击窗口判定失败后触发（与 iOS 结构一致）
        .onTapGesture {
            guard karaoke.isKaraokeOn else { return }
            KaraokeController.shared.clickLine(index: index)
        }
        // 对齐 iOS LyricsView：AB 激活时端点行加 accentColor 小圆点
        .overlay(alignment: .trailing) {
            if let ab = karaoke.abLoop, karaoke.isKaraokeOn,
               index == ab.a || index == ab.b {
                Circle()
                    .fill(appAccentColor)
                    .frame(width: 7, height: 7)
                    .padding(.trailing, 26)
            }
        }
    }

    /// 主行字号（×k）：跟唱整屏等大可见；非跟唱按与当前行的距离分级
    private func mainFont(isActive: Bool, distance: Int) -> Font {
        if karaoke.isKaraokeOn {
            return .system(size: (isActive ? 22 : 19) * fontScale, weight: isActive ? .bold : .regular)
        }
        if isActive {
            return .system(size: 26 * fontScale, weight: .bold)
        } else if distance <= 1 {
            return .system(size: 19 * fontScale, weight: .semibold)
        } else {
            return .system(size: 16 * fontScale, weight: .medium)
        }
    }

    private func mainColor(isActive: Bool, distance: Int) -> Color {
        if karaoke.isKaraokeOn {
            return isActive ? appAccentColor : .primary.opacity(0.8)
        }
        if isActive {
            return appAccentColor
        } else if distance <= 1 {
            return .primary.opacity(0.75)
        } else if distance <= 2 {
            return .primary.opacity(0.4)
        } else {
            return .primary.opacity(0.18)
        }
    }

    private func mainOpacity(isActive: Bool, distance: Int) -> Double {
        if karaoke.isKaraokeOn {
            return isActive ? 1.0 : 0.8
        }
        if isActive {
            return 1.0
        } else if distance <= 1 {
            return 0.9
        } else if distance <= 2 {
            return 0.6
        } else if distance <= 3 {
            return 0.3
        } else {
            return 0.15
        }
    }

    private func lineScale(isActive: Bool, distance: Int) -> CGFloat {
        if karaoke.isKaraokeOn { return 1.0 }
        if isActive { return 1.02 }
        return distance <= 1 ? 0.97 : 0.94
    }

    /// 译文行字号（×k）
    private func translationFont(isActive: Bool, distance: Int) -> Font {
        let size: CGFloat
        if karaoke.isKaraokeOn {
            size = isActive ? 16 : 14
        } else if isActive {
            size = 16
        } else if distance <= 1 {
            size = 14
        } else {
            size = 13
        }
        return .system(size: size * fontScale)
    }

    private func translationColor(isActive: Bool, distance: Int) -> Color {
        if karaoke.isKaraokeOn {
            return isActive ? appAccentColor.opacity(0.95) : .secondary.opacity(0.7)
        }
        if isActive {
            return appAccentColor.opacity(0.95)
        } else if distance <= 1 {
            return .secondary.opacity(0.85)
        } else if distance <= 2 {
            return .secondary.opacity(0.5)
        } else {
            return .secondary.opacity(0.25)
        }
    }

    // MARK: - Plain lyrics（无时间轴）

    private func plainView(_ text: String) -> some View {
        ScrollView(showsIndicators: false) {
            Text(text)
                .font(.system(size: 17 * fontScale, weight: .medium))
                .foregroundColor(.primary.opacity(0.9))
                .lineSpacing(10)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, 16)
        }
    }
}
