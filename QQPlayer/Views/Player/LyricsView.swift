//
//  LyricsView.swift
//  QQPlayer
//
//  Lyrics display with synchronized scrolling
//

import SwiftUI

struct LyricsView: View {
    let lyrics: Lyrics?
    let currentTime: TimeInterval
    let isLoading: Bool
    let onClose: () -> Void
    @State private var scrollTarget: Int?
    @State private var settings = DeleteSettings.load()
    @State private var dragX: CGFloat = 0
    /// 首次进入全屏歌词页的手势提示气泡
    @State private var showHint = false
    /// 上次自动滚动的行号：仅 activeIndex 变化才 scrollTo（替代每 tick 全量遍历 + 对未变行也发起滚动）
    @State private var lastScrolledIndex: Int?
    @ObservedObject private var karaoke = KaraokeController.shared

    var body: some View {
        ZStack {
            // 不透明底色：不透出下层播放页封面（否则歌词字被图片干扰）
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()

            // 媒体库同款背景光晕（跟随设置主题色变化）
            ScreenSpecificBackgroundView(screen: .library)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if isLoading {
                    loadingView
                } else if let lyrics = lyrics {
                    if lyrics.isInstrumental {
                        instrumentalView
                    } else if !lyrics.syncedLyrics.isEmpty {
                        syncedLyricsView(lyrics.syncedLyrics)
                    } else if !lyrics.plainLyrics.isEmpty {
                        plainLyricsView(lyrics.plainLyrics)
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
                VStack(spacing: 0) {
                    Spacer()
                    KaraokeControlBar(accentColor: settings.backgroundColorChoice.color)
                        .padding(.bottom, 12)
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
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
                    accentColor: settings.backgroundColorChoice.color,
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.3)) {
                            showHint = false
                        }
                    }
                )
                .padding(.horizontal, 24)
            }
        }
        // 页面级双击：跟唱模式开关（挂在最外层 ZStack，全屏任意位置双击都触发）。
        // highPriorityGesture：优先于行单击识别——快速双击行 = 切换模式且不触发行跳转；
        // 单击（等双击窗口判定失败后）落到行的单击 = 跳转。控制条 Button 的触摸不经过本容器，不受影响。
        .highPriorityGesture(
            TapGesture(count: 2)
                .onEnded {
                    KaraokeController.shared.toggleKaraokeMode()
                }
        )
    }

    // MARK: - Synced Lyrics

    private func syncedLyricsView(_ lines: [LyricsLine]) -> some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 0) {
                            // Reduced spacer at top - use more space
                            Spacer()
                                .frame(height: geometry.size.height / 2 - 40)

                            // 每次 body 求值只算一次 activeIndex，isActive/distance 变 O(1) 查表
                            // （替代逐行全量遍历 + distanceFromActive 每行 O(n) 遍历）。
                            // 行列表保持 VStack：歌词行数通常 < 300，全量渲染开销可控；
                            // LazyVStack 下 scrollTo 未实例化行有已知失败风险，自动滚动可靠性优先。
                            let activeIndex = LyricTiming.activeLineIndex(time: currentTime, in: lines)
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

                            // Reduced spacer at bottom - use more space
                            Spacer()
                                .frame(height: geometry.size.height / 2 - 40)
                        }
                    }
                    // 非跟唱：禁用交互（纯自动滚动）；跟唱：可交互（单击行跳转 / 手动滚动）
                    .disabled(!karaoke.isKaraokeOn)

                    // Fade gradients at top and bottom（贴近系统底色，歌词边缘柔和融入背景）
                    VStack(spacing: 0) {
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color(uiColor: .systemBackground).opacity(0.95),
                                Color(uiColor: .systemBackground).opacity(0.7),
                                Color(uiColor: .systemBackground).opacity(0.3),
                                Color.clear,
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 150)

                        Spacer()

                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.clear,
                                Color(uiColor: .systemBackground).opacity(0.3),
                                Color(uiColor: .systemBackground).opacity(0.7),
                                Color(uiColor: .systemBackground).opacity(0.95),
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 150)
                    }
                    .allowsHitTesting(false)
                }
                .onChange(of: currentTime) { _, _ in
                    updateActiveLineAndScroll(for: lines, in: proxy)
                }
                .onAppear {
                    updateActiveLineAndScroll(for: lines, in: proxy)
                }
            }
        }
    }

    private func lyricLineView(line: LyricsLine, isActive: Bool, distance: Int, index: Int) -> some View {
        VStack(spacing: 4) {
            Text(line.text)
                .font(fontForLine(isActive: isActive, distance: distance))
                .fontWeight(isActive ? .bold : .semibold)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(lineColor(distance: distance, isActive: isActive))
                .multilineTextAlignment(.center)
                .shadow(
                    color: isActive ? settings.backgroundColorChoice.color.opacity(0.5) : .clear,
                    radius: isActive ? 20 : 0,
                    x: 0,
                    y: 0
                )

            if let translation = line.translation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: translationFontSize(isActive: isActive, distance: distance), weight: .regular))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(translationColor(distance: distance, isActive: isActive))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, karaoke.isKaraokeOn ? 18 : (isActive ? 24 : 16))
        .id(index)
        .scaleEffect(karaoke.isKaraokeOn ? 1.0 : (isActive ? 1.02 : (distance <= 1 ? 0.97 : 0.94)), anchor: .center)
        .opacity(lineOpacity(distance: distance, isActive: isActive))
        .animation(
            .interpolatingSpring(
                mass: 0.5,
                stiffness: 200,
                damping: 20,
                initialVelocity: 0
            ),
            value: isActive
        )
        // 跟唱模式：单击行 = 跳转 / 等选终点 = 设 B（决策在 KaraokeController.clickLine）。
        // 仅在跟唱模式挂载：非跟唱时行不响应点击，页面双击手势无竞争（双击更可靠）
        .contentShape(Rectangle())
        .onTapGesture {
            guard karaoke.isKaraokeOn else { return }
            KaraokeController.shared.clickLine(index: index)
        }
        // 加分项：AB 激活时端点行加 accentColor 小圆点（桌面 AB 区间高亮的 iOS 简化）
        .overlay(alignment: .trailing) {
            if let ab = karaoke.abLoop, karaoke.isKaraokeOn,
               index == ab.a || index == ab.b {
                Circle()
                    .fill(settings.backgroundColorChoice.color)
                    .frame(width: 7, height: 7)
                    .padding(.trailing, 26)
            }
        }
    }

    private func translationFontSize(isActive: Bool, distance: Int) -> CGFloat {
        if karaoke.isKaraokeOn {
            return isActive ? 16 : 14 // 跟唱：全部可见，当前句翻译略大
        }
        if isActive {
            return 16
        } else if distance <= 1 {
            return 14
        } else {
            return 13
        }
    }

    private func translationColor(distance: Int, isActive: Bool) -> Color {
        if karaoke.isKaraokeOn {
            return isActive ? settings.backgroundColorChoice.color.opacity(0.95) : .secondary.opacity(0.7)
        }
        if isActive {
            return settings.backgroundColorChoice.color.opacity(0.95)
        } else if distance <= 1 {
            return .secondary.opacity(0.85)
        } else if distance <= 2 {
            return .secondary.opacity(0.5)
        } else {
            return .secondary.opacity(0.25)
        }
    }

    private func fontForLine(isActive: Bool, distance: Int) -> Font {
        if karaoke.isKaraokeOn {
            // 跟唱：整屏歌词等大可见（当前句略大加粗），不聚焦淡出
            return .system(size: isActive ? 22 : 19, weight: isActive ? .bold : .regular)
        }
        if isActive {
            return .system(size: 26, weight: .bold)
        } else if distance <= 1 {
            return .system(size: 19, weight: .semibold)
        } else {
            return .system(size: 16, weight: .medium)
        }
    }

    private func lineColor(distance: Int, isActive: Bool) -> Color {
        if karaoke.isKaraokeOn {
            // 跟唱：当前句主题色，其余正常可见
            return isActive ? settings.backgroundColorChoice.color : .primary.opacity(0.8)
        }
        if isActive {
            // 当前句用设置中的主题色
            return settings.backgroundColorChoice.color
        } else if distance <= 1 {
            return .primary.opacity(0.75)
        } else if distance <= 2 {
            return .primary.opacity(0.4)
        } else {
            return .primary.opacity(0.18)
        }
    }

    private func lineOpacity(distance: Int, isActive: Bool) -> Double {
        if karaoke.isKaraokeOn {
            return isActive ? 1.0 : 0.8 // 跟唱：整屏可见，不强淡出
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
            return 0.15  // Show distant lines dimly instead of hiding
        }
    }

    // MARK: - Plain Lyrics

    private func plainLyricsView(_ text: String) -> some View {
        // 容器已铺满全屏（ignoresSafeArea）：顶部手动补偿状态栏高度，文字不被遮挡
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    // 顶部 padding（状态栏高度 + 内容间距）
                    Spacer()
                        .frame(height: geometry.safeAreaInsets.top + 24)

                    Text(text)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(.primary.opacity(0.9))
                        .lineSpacing(10)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32)
                        .padding(.vertical, 16)

                    // Bottom padding
                    Spacer()
                        .frame(height: 40)
                }
            }
        }
    }

    // MARK: - States

    private var instrumentalView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                // Animated icon with glass background
                ZStack {
                    // Large outer glow
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    settings.backgroundColorChoice.color.opacity(0.4),
                                    settings.backgroundColorChoice.color.opacity(0.2),
                                    settings.backgroundColorChoice.color.opacity(0.05),
                                    Color.clear,
                                ]),
                                center: .center,
                                startRadius: 0,
                                endRadius: 100
                            )
                        )
                        .frame(width: 200, height: 200)
                        .blur(radius: 30)

                    // Glass circle
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            settings.backgroundColorChoice.color.opacity(0.6),
                                            settings.backgroundColorChoice.color.opacity(0.3),
                                            settings.backgroundColorChoice.color.opacity(0.1),
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2
                                )
                        )
                        .frame(width: 120, height: 120)
                        .shadow(
                            color: settings.backgroundColorChoice.color.opacity(0.3),
                            radius: 25,
                            x: 0,
                            y: 10
                        )

                    Image(systemName: "music.note")
                        .font(.system(size: 50, weight: .medium))
                        .foregroundColor(.primary)
                        .shadow(color: settings.backgroundColorChoice.color.opacity(0.6), radius: 15)
                }

                VStack(spacing: 12) {
                    Text("lyrics_empty_instrumental_title".localized)
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    Text("lyrics_empty_instrumental_subtitle".localized)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .padding(44)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: 28)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    settings.backgroundColorChoice.color.opacity(0.3),
                                    Color.primary.opacity(0.15),
                                    settings.backgroundColorChoice.color.opacity(0.2),
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )

                    RoundedRectangle(cornerRadius: 28)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    settings.backgroundColorChoice.color.opacity(0.05),
                                    Color.clear,
                                    settings.backgroundColorChoice.color.opacity(0.08),
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shadow(color: settings.backgroundColorChoice.color.opacity(0.2), radius: 35, x: 0, y: 15)
            )
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    private var noLyricsView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                // Animated icon with glass background
                ZStack {
                    // Large outer glow
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    settings.backgroundColorChoice.color.opacity(0.4),
                                    settings.backgroundColorChoice.color.opacity(0.2),
                                    settings.backgroundColorChoice.color.opacity(0.05),
                                    Color.clear,
                                ]),
                                center: .center,
                                startRadius: 0,
                                endRadius: 100
                            )
                        )
                        .frame(width: 200, height: 200)
                        .blur(radius: 30)

                    // Glass circle
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            settings.backgroundColorChoice.color.opacity(0.6),
                                            settings.backgroundColorChoice.color.opacity(0.3),
                                            settings.backgroundColorChoice.color.opacity(0.1),
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2
                                )
                        )
                        .frame(width: 120, height: 120)
                        .shadow(
                            color: settings.backgroundColorChoice.color.opacity(0.3),
                            radius: 25,
                            x: 0,
                            y: 10
                        )

                    Image(systemName: "text.badge.xmark")
                        .font(.system(size: 50, weight: .medium))
                        .foregroundColor(.primary)
                        .shadow(color: settings.backgroundColorChoice.color.opacity(0.6), radius: 15)
                }

                VStack(spacing: 12) {
                    Text("lyrics_empty_not_found_title".localized)
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    Text("lyrics_empty_not_found_subtitle".localized)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .padding(44)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: 28)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    settings.backgroundColorChoice.color.opacity(0.3),
                                    Color.primary.opacity(0.15),
                                    settings.backgroundColorChoice.color.opacity(0.2),
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )

                    RoundedRectangle(cornerRadius: 28)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    settings.backgroundColorChoice.color.opacity(0.05),
                                    Color.clear,
                                    settings.backgroundColorChoice.color.opacity(0.08),
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shadow(color: settings.backgroundColorChoice.color.opacity(0.2), radius: 35, x: 0, y: 15)
            )
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 32) {
                // Animated loading with glass background
                ZStack {
                    // Large outer glow - animated
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [
                                    settings.backgroundColorChoice.color.opacity(0.4),
                                    settings.backgroundColorChoice.color.opacity(0.2),
                                    settings.backgroundColorChoice.color.opacity(0.05),
                                    Color.clear,
                                ]),
                                center: .center,
                                startRadius: 0,
                                endRadius: 100
                            )
                        )
                        .frame(width: 200, height: 200)
                        .blur(radius: 30)

                    // Glass circle
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            settings.backgroundColorChoice.color.opacity(0.6),
                                            settings.backgroundColorChoice.color.opacity(0.3),
                                            settings.backgroundColorChoice.color.opacity(0.1),
                                        ]),
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 2
                                )
                        )
                        .frame(width: 120, height: 120)
                        .shadow(
                            color: settings.backgroundColorChoice.color.opacity(0.3),
                            radius: 25,
                            x: 0,
                            y: 10
                        )

                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .primary))
                        .scaleEffect(1.5)
                }

                VStack(spacing: 12) {
                    Text("lyrics_empty_loading_title".localized)
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)

                    Text("lyrics_empty_loading_subtitle".localized)
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(44)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 28)
                        .fill(.ultraThinMaterial)

                    RoundedRectangle(cornerRadius: 28)
                        .stroke(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    settings.backgroundColorChoice.color.opacity(0.3),
                                    Color.primary.opacity(0.15),
                                    settings.backgroundColorChoice.color.opacity(0.2),
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )

                    RoundedRectangle(cornerRadius: 28)
                        .fill(
                            LinearGradient(
                                gradient: Gradient(colors: [
                                    settings.backgroundColorChoice.color.opacity(0.05),
                                    Color.clear,
                                    settings.backgroundColorChoice.color.opacity(0.08),
                                ]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
                .shadow(color: settings.backgroundColorChoice.color.opacity(0.2), radius: 35, x: 0, y: 15)
            )
            .padding(.horizontal, 40)

            Spacer()
        }
    }

    // MARK: - Helper Methods

    private func updateActiveLineAndScroll(for lines: [LyricsLine], in proxy: ScrollViewProxy) {
        // AB 等选终点（b == nil）：关闭自动滚动，让用户手动滚动找 B 句（用户拍板 2026-08-29）
        if karaoke.isKaraokeOn, let ab = karaoke.abLoop, ab.b == nil { return }
        guard let activeIndex = LyricTiming.activeLineIndex(time: currentTime, in: lines),
              activeIndex != lastScrolledIndex else { return }
        lastScrolledIndex = activeIndex
        withAnimation(
            .interpolatingSpring(
                mass: 1.0,
                stiffness: 170,
                damping: 25,
                initialVelocity: 0
            )
        ) {
            proxy.scrollTo(activeIndex, anchor: .center)
        }
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
}
