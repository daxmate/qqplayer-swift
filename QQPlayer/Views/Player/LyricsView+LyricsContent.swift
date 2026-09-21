//
//  LyricsView+LyricsContent.swift
//  QQPlayer
//
//  全屏歌词页**正文渲染**：同步歌词滚动视图（逐行排版、距离分级字号 / 颜色 / 透明度）、
//  纯文本歌词视图、活动行自动滚动。
//
//  2026-09-21 从 LyricsView.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Player/LyricsView.swift             — 视图壳：stored property + `body` 装配 + `#Preview`
//    · Views/Player/LyricsView+EmptyStates.swift — 加载中 / 纯音乐 / 无歌词 占位视图
//
// target: ios-only（LyricsView 分片：消费端全在 iOS；Mac 侧为 MacLyricsView）
//

import SwiftUI

extension LyricsView {
    // MARK: - Synced Lyrics

    /// 分片：跨文件可见（原 private）
    func syncedLyricsView(_ lines: [LyricsLine]) -> some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ZStack {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: DesignTokens.space0) {
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
                    VStack(spacing: DesignTokens.space0) {
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
        VStack(spacing: DesignTokens.space4) {
            Text(line.displayText)
                .font(fontForLine(isActive: isActive, distance: distance))
                .fontWeight(isActive ? .bold : .semibold)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(lineColor(distance: distance, isActive: isActive))
                .multilineTextAlignment(.center)
                .shadow(
                    color: isActive ? accentColor.opacity(0.5) : .clear,
                    radius: isActive ? 20 : 0,
                    x: 0,
                    y: 0
                )

            // 罗马音（网易云 romalrc；仅日语等有数据的曲目非空）—— 原文下、译文上，比译文小一档
            if settings.lyricShowRoman, let roman = line.displayRoman, !roman.isEmpty {
                Text(roman)
                    .font(.system(size: romanFontSize(isActive: isActive, distance: distance), weight: .regular))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(romanColor(distance: distance, isActive: isActive))
                    .multilineTextAlignment(.center)
            }

            if let translation = line.displayTranslation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: translationFontSize(isActive: isActive, distance: distance), weight: .regular))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(translationColor(distance: distance, isActive: isActive))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.space32)
        .padding(.vertical, karaoke.isKaraokeOn ? DesignTokens.space16 : (isActive ? DesignTokens.space24 : DesignTokens.space16))
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
            karaoke.clickLine(index: index)
        }
        // 加分项：AB 激活时端点行加 accentColor 小圆点（桌面 AB 区间高亮的 iOS 简化）
        .overlay(alignment: .trailing) {
            if let ab = karaoke.abLoop, karaoke.isKaraokeOn,
               index == ab.a || index == ab.b {
                Circle()
                    .fill(accentColor)
                    .frame(width: 7, height: 7)
                    .padding(.trailing, DesignTokens.space24)
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
            return isActive ? accentColor.opacity(0.95) : .secondary.opacity(0.7)
        }
        if isActive {
            return accentColor.opacity(0.95)
        } else if distance <= 1 {
            return .secondary.opacity(0.85)
        } else if distance <= 2 {
            return .secondary.opacity(0.5)
        } else {
            return .secondary.opacity(0.25)
        }
    }

    /// 罗马音字号：复用译文那套阶梯（同一实现），整体小一档
    private func romanFontSize(isActive: Bool, distance: Int) -> CGFloat {
        max(11, translationFontSize(isActive: isActive, distance: distance) - 2)
    }

    /// 罗马音颜色：复用译文那套颜色，再淡一档
    private func romanColor(distance: Int, isActive: Bool) -> Color {
        translationColor(distance: distance, isActive: isActive).opacity(0.85)
    }

    private func fontForLine(isActive: Bool, distance: Int) -> Font {
        if karaoke.isKaraokeOn {
            // 跟唱：整屏歌词等大可见（当前句略大加粗），不聚焦淡出
            return .system(size: isActive ? DesignTokens.font22 : DesignTokens.font19, weight: isActive ? .bold : .regular)
        }
        if isActive {
            return .system(size: DesignTokens.font26, weight: .bold)
        } else if distance <= 1 {
            return .system(size: DesignTokens.font19, weight: .semibold)
        } else {
            return .system(size: DesignTokens.font16, weight: .medium)
        }
    }

    private func lineColor(distance: Int, isActive: Bool) -> Color {
        if karaoke.isKaraokeOn {
            // 跟唱：当前句主题色，其余正常可见
            return isActive ? accentColor : .primary.opacity(0.8)
        }
        if isActive {
            // 当前句用设置中的主题色
            return accentColor
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

    /// 分片：跨文件可见（原 private）
    func plainLyricsView(_ text: String) -> some View {
        // 容器已铺满全屏（ignoresSafeArea）：顶部手动补偿状态栏高度，文字不被遮挡
        GeometryReader { geometry in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: DesignTokens.space0) {
                    // 顶部 padding（状态栏高度 + 内容间距）
                    Spacer()
                        .frame(height: geometry.safeAreaInsets.top + 24)

                    Text(text)
                        .font(.system(size: DesignTokens.font17, weight: .medium))
                        .foregroundColor(.primary.opacity(0.9))
                        .lineSpacing(10)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DesignTokens.space32)
                        .padding(.vertical, DesignTokens.space16)

                    // Bottom padding
                    Spacer()
                        .frame(height: 40)
                }
            }
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
