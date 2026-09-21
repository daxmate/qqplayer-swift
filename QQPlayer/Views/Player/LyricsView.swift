//
//  LyricsView.swift
//  QQPlayer
//
//  全屏歌词页**视图壳**：stored property（注入 / 状态）+ `body` 装配 + `#Preview`。
//  其余按职责分片（2026-09-21 拆分，纯搬家、无逻辑变更）：
//    · Views/Player/LyricsView+LyricsContent.swift — 同步 / 纯文本歌词渲染 + 活动行自动滚动
//    · Views/Player/LyricsView+EmptyStates.swift   — 加载中 / 纯音乐 / 无歌词 占位视图

import SwiftUI

struct LyricsView: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    /// 分片：跨文件可见（原 private）
    @Environment(\.appAccentColor) var accentColor
    let lyrics: Lyrics?
    let currentTime: TimeInterval
    let isLoading: Bool
    let onClose: () -> Void
    @State private var scrollTarget: Int?
    /// 分片：跨文件可见（原 private）
    @State var settings = DeleteSettings.load()
    @State private var dragX: CGFloat = 0
    /// 首次进入全屏歌词页的手势提示气泡
    @State private var showHint = false
    /// 上次自动滚动的行号：仅 activeIndex 变化才 scrollTo（替代每 tick 全量遍历 + 对未变行也发起滚动）
    /// 分片：跨文件可见（原 private）
    @State var lastScrolledIndex: Int?
    /// 分片：跨文件可见（原 private）
    @Environment(KaraokeController.self) var karaoke

    var body: some View {
        ZStack {
            // 不透明底色：不透出下层播放页封面（否则歌词字被图片干扰）
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            // 媒体库同款背景光晕（跟随设置主题色变化）
            ScreenSpecificBackgroundView(screen: .library)
                .ignoresSafeArea()

            VStack(spacing: DesignTokens.space0) {
                if isLoading {
                    loadingView
                } else if let lyrics = lyrics {
                    if lyrics.isInstrumental {
                        instrumentalView
                    } else if !lyrics.syncedLyrics.isEmpty {
                        syncedLyricsView(lyrics.syncedLyrics)
                    } else if !lyrics.plainLyrics.isEmpty {
                        plainLyricsView(DisplayScriptNormalizer.display(lyrics.plainLyrics))
                    } else {
                        noLyricsView
                    }
                } else {
                    noLyricsView
                }
            }
            .ignoresSafeArea() // 内容容器与背景同尺寸铺满全屏（顶部不再留 safe area 空白）

            // 跟唱模式：底部控制条（非跟唱隐藏）
            if karaoke.isKaraokeOn {
                VStack(spacing: DesignTokens.space0) {
                    Spacer()
                    KaraokeControlBar()
                        .padding(.bottom, DesignTokens.space12)
                }
                .transition(.opacity)
            }
        }
        .onAppear {
            // 首次进入全屏歌词页：触发手势提示气泡（之后永不再现）
            withAnimation(.easeOut(duration: 0.3)) {
                showHint = HintCoordinator.showIfNeeded(.fullLyricsPage)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
        }
        // 右滑关闭：跟手位移，达阈值/快速回甩滑出（Apple Music 风格）。
        // simultaneousGesture：跟唱模式 ScrollView 可交互（pan 手势）时，pan 与关闭拖动
        // 互不取消——纵向滚动正常、右滑关闭仍可用；非跟唱 ScrollView 禁用，行为与原来一致。
        .offset(x: dragX)
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    guard value.translation.width > 0 else { return }
                    dragX = value.translation.width
                }
                .onEnded { value in
                    if PlayerDismissGesture.shouldDismissLyrics(
                        translation: value.translation.width,
                        predictedTranslation: value.predictedEndTranslation.width
                    ) {
                        // 由外层 transition（move trailing）负责滑出动画，从当前位置滑出
                        onClose()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            dragX = 0
                        }
                    }
                }
        )
        .animation(.easeInOut(duration: 0.2), value: karaoke.isKaraokeOn)
        // 首次进入的手势提示气泡：居中浮层（卡片自身不拦截卡片外区域）
        .overlay(alignment: .center) {
            if showHint {
                HintCardView(
                    title: Localized.hintFullLyricsTitle,
                    lines: [
                        Localized.hintFullLyricsLine1,
                        Localized.hintFullLyricsLine2,
                    ],
                    accentColor: accentColor,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.3)) {
                            showHint = false
                        }
                    }
                )
                .padding(.horizontal, DesignTokens.space24)
            }
        }
        // 页面级双击：跟唱模式开关（挂在最外层 ZStack，全屏任意位置双击都触发）。
        // highPriorityGesture：优先于行单击识别——快速双击行 = 切换模式且不触发行跳转；
        // 单击（等双击窗口判定失败后）落到行的单击 = 跳转。控制条 Button 的触摸不经过本容器，不受影响。
        .highPriorityGesture(
            TapGesture(count: 2)
                .onEnded {
                    karaoke.toggleKaraokeMode()
                }
        )
    }
}

// MARK: - Preview

#Preview {
    LyricsView(
        lyrics: Lyrics(
            plainLyrics: "Sample lyrics\nLine 2\nLine 3",
            syncedLyrics: [
                LyricsLine(timestamp: 0, text: "Sample lyrics"),
                LyricsLine(timestamp: 5, text: "Line 2"),
                LyricsLine(timestamp: 10, text: "Line 3"),
            ],
            isInstrumental: false,
            source: .embedded
        ),
        currentTime: 6.0,
        isLoading: false,
        onClose: {}
    )
    .environment(KaraokeController.shared)
}
