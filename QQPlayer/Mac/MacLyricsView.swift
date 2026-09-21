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
    /// 分片：跨文件可见（原 private）
    @State var showTranslation = true
    /// 分片：跨文件可见（原 private）
    @State var showRoman = true
    /// 分片：跨文件可见（原 private）
    @State var lyricOffset: Double = 0

    /// 面板底色（对齐 iOS 的 systemBackground）
    /// 分片：跨文件可见（原 private）
    var baseColor: Color { Color(nsColor: .windowBackgroundColor) }
    /// 字号整体缩放系数（对齐 iOS LyricsView 的固定字号体系）
    /// 分片：跨文件可见（原 private）
    var fontScale: CGFloat { CGFloat(fontSize / 15.0) }

    /// 切句过渡动画：行强调与滚屏共用同一条曲线。
    /// 改前是两条响应不同的 spring（行 ≈0.31s / 滚屏 ≈0.48s）→ 文字先变完、屏才开始滚，
    /// 观感是二次突变；统一成一条 0.55s / 阻尼 0.92 的柔和曲线（2026-09-13 用户反馈）。
    /// 分片：跨文件可见（原 private）
    static let lyricAnimation = Animation.spring(response: 0.55, dampingFraction: 0.92)

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
