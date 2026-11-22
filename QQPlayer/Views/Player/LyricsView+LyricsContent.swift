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
            // 占位：优先用高亮行**实测高度**（含 padding / 译文 / 罗马音）；测量前回落档位公式
            let centerInset = measuredInset ?? LyricsCenterMetrics.topInset(
                viewportHeight: geometry.size.height,
                rowHalfHeight: LyricsCenterMetrics.rowHalfHeight(
                    emphasis: 1.0,
                    karaoke: karaoke.isKaraokeOn,
                    fontScale: 1.0
                )
            )
            ScrollViewReader { proxy in
                ZStack {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: DesignTokens.space0) {
                            // 上下等距撑开 → 高亮行视觉中心 = 视口垂直中心（占位按当前档位行高算）
                            Spacer()
                                .frame(height: centerInset)

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
                                    index: index,
                                    viewportHeight: geometry.size.height
                                )
                            }

                            Spacer()
                                .frame(height: centerInset)
                        }
                    }
                    .coordinateSpace(name: LyricsCenterMetrics.coordinateSpaceName)
                    // 手动滚动检测：普通模式手动滚动 → 暂停自动跟随（画面不再被自动拉回）。
                    // 用 onScrollPhaseChange（iOS 18+）：tracking / interacting / decelerating 仅由
                    // 用户发起；程序化 proxy.scrollTo 是 .animating —— 故自动滚动不会误判成手动。
                    // 跟唱模式不介入本状态（行为不变，见需求 4）。
                    .onScrollPhaseChange { _, newPhase in
                        guard !karaoke.isKaraokeOn else { return }
                        switch newPhase {
                        case .tracking, .interacting, .decelerating:
                            if isFollowing { isFollowing = false }
                            if !isScrollActive { isScrollActive = true }
                        case .idle:
                            // 停止滚动：把「已跟到行号基线」同步为当时当前行 —— 此后仅当再换句
                            // （activeIndexChanged）才回中（严格口径，见 LyricsFollowPolicy）。
                            // 仅当此前确实在手滚中（true→false）才同步，程序化 scrollTo 的 .idle 不误触。
                            if isScrollActive {
                                isScrollActive = false
                                lastScrolledIndex = LyricTiming.activeLineIndex(time: currentTime, in: lines)
                            }
                        default:
                            break
                        }
                    }

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
                // 手动滚动暂停跟随后浮出的「回到当前行」按钮（仅普通模式）：
                // 点它恢复自动跟随并立刻把当前行滚回中央
                .overlay(alignment: .bottom) {
                    if !karaoke.isKaraokeOn, !isFollowing {
                        backToCurrentLineButton(
                            lines: lines,
                            proxy: proxy,
                            viewportHeight: geometry.size.height
                        )
                        .padding(.bottom, DesignTokens.space32)
                        .transition(.opacity)
                    }
                }
                .onChange(of: currentTime) { _, _ in
                    updateActiveLineAndScroll(
                        for: lines,
                        in: proxy,
                        viewportHeight: geometry.size.height
                    )
                }
                // 切歌 / 歌词变化：恢复自动跟随（需求 3）
                .onChange(of: lines) { _, _ in
                    isFollowing = true
                }
                // 进入 / 退出跟唱：恢复自动跟随（退出后普通模式继续跟随；进入后跟唱语义不变）
                .onChange(of: karaoke.isKaraokeOn) { _, _ in
                    isFollowing = true
                }
                .onAppear {
                    updateActiveLineAndScroll(
                        for: lines,
                        in: proxy,
                        viewportHeight: geometry.size.height
                    )
                }
                // 尺寸变化（旋转 / 分屏 / sheet 高度）：任何变化都重锚回中心
                .onChange(of: geometry.size) { _, _ in
                    reanchorActiveLine(
                        for: lines,
                        in: proxy,
                        viewportHeight: geometry.size.height
                    )
                }
            }
        }
    }

    /// 验收日志：滚动停稳后（0.3s 防抖）打印高亮行实测高度 / 中心偏差 / 当前占位，确认后删除。
    private func scheduleCenterLog(rowMidY: CGFloat, viewportHeight: CGFloat) {
        let rowHeight = centerProbe.rowHeight
            ?? 2 * LyricsCenterMetrics.rowHalfHeight(
                emphasis: 1.0,
                karaoke: karaoke.isKaraokeOn,
                fontScale: 1.0
            )
        let inset = measuredInset
            ?? LyricsCenterMetrics.topInset(viewportHeight: viewportHeight, rowHalfHeight: rowHeight / 2)
        LyricsCenterLogger.log(
            platform: "ios",
            mode: "fullscreen",
            sample: LyricsCenterMetrics.Sample(
                rowHeight: rowHeight,
                rowMidY: rowMidY,
                viewportHeight: viewportHeight,
                inset: inset
            )
        ) { message in
            AppLog.info(.ui, message)
        }
    }

    /// 行内几何探针：写入实测偏移（落定后重锚判定）+ 打居中日志。
    private func recordCenter(
        _ rowProxy: GeometryProxy,
        viewportHeight: CGFloat,
        isActive: Bool
    ) {
        guard isActive else { return }
        // 实测整行 frame（含 padding / 译文 / 罗马音）：占位与诊断都用它
        let frame = rowProxy.frame(in: .named(LyricsCenterMetrics.coordinateSpaceName))
        centerProbe.delta = frame.midY - viewportHeight / 2
        centerProbe.rowHeight = frame.height
        scheduleCenterLog(rowMidY: frame.midY, viewportHeight: viewportHeight)
    }

    /// 用实测偏移（delta）落日志：重锚路径也能打点，不依赖行内几何再次变化。
    private func scheduleCenterLog(delta: CGFloat?, viewportHeight: CGFloat) {
        guard let delta else { return }
        scheduleCenterLog(rowMidY: viewportHeight / 2 + delta, viewportHeight: viewportHeight)
    }

    private func lyricLineView(
        line: LyricsLine,
        isActive: Bool,
        distance: Int,
        index: Int,
        viewportHeight: CGFloat
    ) -> some View {
        // 阅读态（用户拍板 2026-10-12）：普通模式用户手动滚动后，整页关距离分级「灰度」+ 正常字号，
        // 直到回中（isFollowing 恢复 true）。跟唱模式不受影响（reading 恒 false）。
        let reading = !karaoke.isKaraokeOn && !isFollowing
        return VStack(spacing: DesignTokens.space4) {
            Text(line.displayText)
                .font(fontForLine(isActive: isActive, distance: distance, reading: reading))
                .fontWeight(isActive ? .bold : .semibold)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundColor(lineColor(distance: distance, isActive: isActive, reading: reading))
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
                    .font(.system(size: romanFontSize(isActive: isActive, distance: distance, reading: reading), weight: .regular))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(romanColor(distance: distance, isActive: isActive, reading: reading))
                    .multilineTextAlignment(.center)
            }

            if let translation = line.displayTranslation, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: translationFontSize(isActive: isActive, distance: distance, reading: reading), weight: .regular))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(translationColor(distance: distance, isActive: isActive, reading: reading))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.space32)
        // 垂直 padding 在动画修饰符**内层** → 随切句动画逐帧插值（视觉要求：行高平滑变化）。
        // 居中不靠冻结布局，而靠「滚动时机 + 落定后重锚」（见 updateActiveLineAndScroll）。
        .padding(.vertical, LyricsCenterMetrics.verticalPadding(
            emphasis: isActive ? 1.0 : 0.66,
            karaoke: karaoke.isKaraokeOn
        ))
        .id(index)
        // 阅读态 scaleEffect 1.0（用户定）：关距离分级的同时不再缩放。
        .scaleEffect(karaoke.isKaraokeOn || reading ? 1.0 : (isActive ? 1.02 : (distance <= 1 ? 0.97 : 0.94)), anchor: .center)
        .opacity(lineOpacity(distance: distance, isActive: isActive, reading: reading))
        .animation(
            .interpolatingSpring(
                mass: 0.5,
                stiffness: 200,
                damping: 20,
                initialVelocity: 0
            ),
            value: isActive
        )
        .background(
            GeometryReader { rowProxy in
                Color.clear
                    .onAppear {
                        recordCenter(rowProxy, viewportHeight: viewportHeight, isActive: isActive)
                    }
                    .onChange(
                        of: rowProxy.frame(in: .named(LyricsCenterMetrics.coordinateSpaceName)).midY
                    ) { _, _ in
                        recordCenter(rowProxy, viewportHeight: viewportHeight, isActive: isActive)
                    }
                    // 刚成为高亮行这一拍也测一次（只靠 midY 变化会漏掉「行身份切换」）
                    .onChange(of: isActive) { _, active in
                        guard active else { return }
                        recordCenter(rowProxy, viewportHeight: viewportHeight, isActive: true)
                    }
            }
        )
        // 单击行：跟唱模式 = 跳转 / 等选终点 = 设 B（决策在 KaraokeController.clickLine）；
        // 普通模式 = 跳到该行播放（KaraokeController.seekToLyricLine）并恢复自动跟随。
        // 页面级双击（进跟唱）是 highPriorityGesture，仍优先——单击等双击判定失败后才触发。
        .contentShape(Rectangle())
        .onTapGesture {
            if karaoke.isKaraokeOn {
                karaoke.clickLine(index: index)
            } else {
                isFollowing = true
                lastScrolledIndex = nil // 强制下一次 tick 重新滚到当前行（含点当前行的情况）
                karaoke.seekToLyricLine(index)
            }
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

    private func translationFontSize(isActive: Bool, distance: Int, reading: Bool) -> CGFloat {
        if karaoke.isKaraokeOn {
            return isActive ? 16 : 14 // 跟唱：全部可见，当前句翻译略大
        }
        if reading {
            return 14 // 阅读态：正常大小 = 高亮行下一行那档（14）
        }
        if isActive {
            return 16
        } else if distance <= 1 {
            return 14
        } else {
            return 13
        }
    }

    private func translationColor(distance: Int, isActive: Bool, reading: Bool) -> Color {
        if karaoke.isKaraokeOn {
            return isActive ? accentColor.opacity(0.95) : .secondary.opacity(0.7)
        }
        if reading {
            return .secondary // 阅读态：译文全亮，不再叠加 opacity（关灰度）
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
    private func romanFontSize(isActive: Bool, distance: Int, reading: Bool) -> CGFloat {
        max(11, translationFontSize(isActive: isActive, distance: distance, reading: reading) - 2)
    }

    /// 罗马音颜色：复用译文那套颜色，再淡一档（阅读态同样全亮，不再叠加 opacity）
    private func romanColor(distance: Int, isActive: Bool, reading: Bool) -> Color {
        if reading { return .secondary }
        return translationColor(distance: distance, isActive: isActive, reading: false).opacity(0.85)
    }

    private func fontForLine(isActive: Bool, distance: Int, reading: Bool) -> Font {
        if karaoke.isKaraokeOn {
            // 跟唱：整屏歌词等大可见（当前句略大加粗），不聚焦淡出
            return .system(size: isActive ? DesignTokens.font22 : DesignTokens.font19, weight: isActive ? .bold : .regular)
        }
        if reading {
            // 阅读态：正常大小 = 高亮行下一行那档（主行 19），当前行加粗保留
            return .system(size: DesignTokens.font19, weight: isActive ? .bold : .semibold)
        }
        if isActive {
            return .system(size: DesignTokens.font26, weight: .bold)
        } else if distance <= 1 {
            return .system(size: DesignTokens.font19, weight: .semibold)
        } else {
            return .system(size: DesignTokens.font16, weight: .medium)
        }
    }

    private func lineColor(distance: Int, isActive: Bool, reading: Bool) -> Color {
        if karaoke.isKaraokeOn {
            // 跟唱：当前句主题色，其余正常可见
            return isActive ? accentColor : .primary.opacity(0.8)
        }
        if reading {
            // 阅读态：全亮、不分级（当前行 accent + 加粗高亮，其余 primary）
            return isActive ? accentColor : .primary
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

    private func lineOpacity(distance: Int, isActive: Bool, reading: Bool) -> Double {
        if karaoke.isKaraokeOn {
            return isActive ? 1.0 : 0.8 // 跟唱：整屏可见，不强淡出
        }
        if reading {
            return 1.0 // 阅读态：整行全亮（关灰度）
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

    private func updateActiveLineAndScroll(
        for lines: [LyricsLine],
        in proxy: ScrollViewProxy,
        viewportHeight: CGFloat,
        force: Bool = false
    ) {
        // AB 等选终点（b == nil）：关闭自动滚动，让用户手动滚动找 B 句（用户拍板 2026-08-29）
        if karaoke.isKaraokeOn, let ab = karaoke.abLoop, ab.b == nil { return }
        guard let activeIndex = LyricTiming.activeLineIndex(time: currentTime, in: lines) else { return }
        // 「阅读态 → 回中」判据（唯一事实源：LyricsFollowPolicy）：停止手动滚动后到「下一句」才恢复
        // 自动跟随（用户拍板 2026-10-12）。不在此自写布尔表达式（形状契约测试防第二实现）。
        if LyricsFollowPolicy.shouldResumeFollow(
            isKaraoke: karaoke.isKaraokeOn,
            isFollowing: isFollowing,
            isScrollActive: isScrollActive,
            activeIndexChanged: activeIndex != lastScrolledIndex
        ) {
            isFollowing = true
        }
        // 普通模式手动滚动后暂停跟随：不自动拉回（用户拍板 2026-10-12）。
        // force=true（「回到当前行」按钮）绕过该暂停，重新跟随并滚回当前行。
        if !karaoke.isKaraokeOn, !isFollowing, !force { return }
        guard force || activeIndex != lastScrolledIndex else { return }
        lastScrolledIndex = activeIndex
        // ① 立刻带 spring 滚过去：与字号 / padding 动画同步起势（平滑推进）。
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
        // ② 落定后重锚（0.45s / 0.90s）：padding 逐帧插值使行高在动画中变化，
        //    首次 scrollTo 按当时布局算偏移 → 只在实测偏移超容差时补滚（无偏差完全不动）。
        scheduleSettleReanchor(proxy: proxy, index: activeIndex, viewportHeight: viewportHeight)
    }

    /// 动画落定后的幂等重锚：0.45s / 0.90s 各先用实测行高刷新占位，再按需补滚（index 幂等）。
    /// 补滚不带 `withAnimation` → 同一 index 的重复 scrollTo 无可见位移。
    private func scheduleSettleReanchor(proxy: ScrollViewProxy, index: Int, viewportHeight: CGFloat) {
        for delay in LyricsCenterMetrics.settleReanchorDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                refreshInsetThenReanchor(proxy: proxy, index: index, viewportHeight: viewportHeight)
            }
        }
    }

    /// 重锚前先用高亮行**实测高度**刷新占位；占位或偏差任一变过才滚动（同一拍：先占位、后滚动）。
    private func refreshInsetThenReanchor(proxy: ScrollViewProxy, index: Int, viewportHeight: CGFloat) {
        let insetChanged = refreshMeasuredInset(viewportHeight: viewportHeight)
        let offCenter = abs(centerProbe.delta ?? 0) > LyricsCenterMetrics.settleReanchorTolerance
        guard insetChanged || offCenter else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    /// 用实测行高算占位 `max(viewport/2 - rowH/2, 0)`；|Δ| ≤ 0.5pt 不写（防抖）。返回是否写入。
    @discardableResult
    private func refreshMeasuredInset(viewportHeight: CGFloat) -> Bool {
        guard let rowHeight = centerProbe.rowHeight else { return false }
        let inset = max(viewportHeight / 2 - rowHeight / 2, 0)
        let fallbackHalf = LyricsCenterMetrics.rowHalfHeight(
            emphasis: 1.0,
            karaoke: karaoke.isKaraokeOn,
            fontScale: 1.0
        )
        let current = measuredInset
            ?? LyricsCenterMetrics.topInset(viewportHeight: viewportHeight, rowHalfHeight: fallbackHalf)
        guard abs(inset - current) > LyricsCenterMetrics.settleReanchorTolerance else { return false }
        measuredInset = inset
        return true
    }

    /// 视口尺寸变化（旋转 / 分屏 / sheet 高度）：无动画重锚回中心（拖动中每 tick 都跟得上）。
    private func reanchorActiveLine(
        for lines: [LyricsLine],
        in proxy: ScrollViewProxy,
        viewportHeight: CGFloat
    ) {
        if karaoke.isKaraokeOn, let ab = karaoke.abLoop, ab.b == nil { return }
        guard let activeIndex = LyricTiming.activeLineIndex(time: currentTime, in: lines) else { return }
        if !karaoke.isKaraokeOn, !isFollowing { return }
        // 视口变了：用实测行高重算占位（有变化才写，写入后下一拍滚动才按新布局算）
        _ = refreshMeasuredInset(viewportHeight: viewportHeight)
        DispatchQueue.main.async {
            proxy.scrollTo(activeIndex, anchor: .center)
        }
        // 再补一拍（+0.05s）：padding / 换行会让布局有第二跳
        DispatchQueue.main.asyncAfter(deadline: .now() + LyricsCenterMetrics.settleCorrectionDelay) {
            proxy.scrollTo(activeIndex, anchor: .center)
        }
    }

    /// 「回到当前行」按钮：恢复自动跟随并立刻把当前行滚回中央（普通模式手动滚动后浮出）
    private func backToCurrentLineButton(
        lines: [LyricsLine],
        proxy: ScrollViewProxy,
        viewportHeight: CGFloat
    ) -> some View {
        Button {
            isFollowing = true
            updateActiveLineAndScroll(
                for: lines,
                in: proxy,
                viewportHeight: viewportHeight,
                force: true
            )
        } label: {
            HStack(spacing: DesignTokens.space4) {
                Image(systemName: "arrow.down.to.line.compact")
                Text(Localized.backToCurrentLine)
            }
            .font(.system(size: DesignTokens.font13, weight: .semibold))
            .padding(.horizontal, DesignTokens.space16)
            .padding(.vertical, DesignTokens.space8)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(accentColor.opacity(0.35), lineWidth: 1))
            .foregroundColor(accentColor)
        }
        .buttonStyle(.plain)
    }
}
