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

struct MacLyricsView: View {
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    /// 分片：跨文件可见（原 private）
    @Environment(\.appAccentColor) var appAccentColor
    let lyrics: Lyrics?
    let currentTime: TimeInterval
    let isLoading: Bool
    /// 是否大画面（跟唱或双击放大）：控制跟唱 mic 入口显示（普通态 mic 在播放区控制行）
    let isFullscreen: Bool
    /// 双击歌词：由宿主决定（普通态放大 / 放大态缩回 / 跟唱态退跟唱+缩回）
    let onToggleExpand: () -> Void
    /// 歌词搜索入口（播放页 sheet 弹出 MacLyricsSearchView）
    let onLyricsSearch: () -> Void

    /// 分片：跨文件可见（原 private）
    @Environment(KaraokeController.self) var karaoke

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
