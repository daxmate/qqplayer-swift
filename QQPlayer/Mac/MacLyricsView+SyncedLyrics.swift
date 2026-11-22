//
//  MacLyricsView+SyncedLyrics.swift
//  QQPlayer
//
//  `MacLyricsView` 的跟唱 / 距离分级排版与逐行视图（2026-09-21 从 `MacLyricsView.swift` 纯搬家，零行为/UI 变化）。
//
//  ⚠️ 可见性：被主片或其它分区文件引用的成员为 internal（原 `private`）。
//

import AppKit
import SwiftUI

extension MacLyricsView {
    // MARK: - Synced lyrics（距离分级排版，对齐 iOS LyricsView）

    /// 分片：跨文件可见（原 private）
    func syncedView(_ lines: [LyricsLine]) -> some View {
        // 歌词轴时间（音频时间 - offset，web lyricTime 语义）：高亮行与跟唱 tick 同轴
        let activeIndex = LyricTiming.activeLineIndex(time: currentTime - lyricOffset, in: lines)
        // 高亮行半高：档位字号 + padding 的纯函数（占位与居中口径同源）
        let rowHalfHeight = LyricsCenterMetrics.rowHalfHeight(
            emphasis: 1.0,
            karaoke: karaoke.isKaraokeOn,
            fontScale: fontScale
        )
        return GeometryReader { geometry in
            let centerInset = LyricsCenterMetrics.topInset(
                viewportHeight: geometry.size.height,
                rowHalfHeight: rowHalfHeight
            )
            ScrollViewReader { proxy in
                ZStack {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: DesignTokens.space0) {
                            // 用户手动滚动检测桥（AppKit；见文件末 MacLyricsScrollObserver）：
                            // 零尺寸占位，只当「找宿主 NSScrollView」的起点
                            MacLyricsScrollObserver(
                                onUserScroll: {
                                    guard !karaoke.isKaraokeOn else { return }
                                    if isFollowing { isFollowing = false }
                                    if !isScrollActive { isScrollActive = true }
                                },
                                onUserScrollEnd: {
                                    guard !karaoke.isKaraokeOn else { return }
                                    // 停止滚动：把「已跟到行号基线」同步为当时当前行（严格口径，
                                    // 见 LyricsFollowPolicy）—— 此后仅当再换句（activeIndexChanged）才回中
                                    if isScrollActive {
                                        isScrollActive = false
                                        lastFollowedIndex = LyricTiming.activeLineIndex(time: currentTime - lyricOffset, in: lines)
                                    }
                                }
                            )
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)

                            // 上下等距撑开 → 当前行恒在面板垂直中央（占位按当前档位行高算）
                            Spacer()
                                .frame(height: centerInset)

                            // 保持普通 VStack（非 LazyVStack）：iOS 注释写明 LazyVStack 下
                            // scrollTo 未实例化行有已知失败风险，自动滚动可靠性优先。
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
                // 手动滚动暂停跟随后浮出的「回到当前行」按钮（仅普通模式）
                .overlay(alignment: .bottom) {
                    if !karaoke.isKaraokeOn, !isFollowing {
                        backToCurrentLineButton(activeIndex: activeIndex, proxy: proxy)
                            .padding(.bottom, DesignTokens.space12)
                            .transition(.opacity)
                    }
                }
                .onChange(of: activeIndex) { _, newIndex in
                    guard let newIndex else { return }
                    // 等选 AB 终点（b == nil）时暂停自动滚动：让用户手动滚动找 B 句
                    // （对齐 iOS updateActiveLineAndScroll，用户拍板 2026-08-29）
                    if karaoke.isKaraokeOn, let ab = karaoke.abLoop, ab.b == nil { return }
                    // 「阅读态 → 回中」判据（唯一事实源：LyricsFollowPolicy）：停止手动滚动后到
                    // 「下一句」才恢复自动跟随（用户拍板 2026-10-12）。不在此自写布尔表达式。
                    if LyricsFollowPolicy.shouldResumeFollow(
                        isKaraoke: karaoke.isKaraokeOn,
                        isFollowing: isFollowing,
                        isScrollActive: isScrollActive,
                        activeIndexChanged: newIndex != lastFollowedIndex
                    ) {
                        isFollowing = true
                    }
                    // 普通模式手动滚动后暂停跟随：不自动拉回（用户拍板 2026-10-12）
                    if !karaoke.isKaraokeOn, !isFollowing { return }
                    // ① 立刻带同一条 spring 滚过去：与字号 / padding 动画同步起势（平滑推进）。
                    withAnimation(Self.lyricAnimation) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                    // ② 落定后重锚（0.45s / 0.90s）：字号与 padding 逐帧插值使行高在动画中变化，
                    //    首次 scrollTo 按当时布局算偏移，落定后可能仍偏一点 → 只在实测偏移超容差时补滚。
                    scheduleSettleReanchor(
                        proxy: proxy,
                        index: newIndex,
                        viewportHeight: geometry.size.height
                    )
                    lastFollowedIndex = newIndex
                }
                // 切歌 / 歌词变化：恢复自动跟随（需求 3）
                .onChange(of: lines) { _, _ in
                    isFollowing = true
                }
                .onAppear {
                    guard let activeIndex else { return }
                    lastFollowedIndex = activeIndex
                    // 首帧滚动：面板高度可能来自窗口尺寸 / 记忆值，当帧布局尚未落定
                    // → 下一轮主队列再滚，再补一拍幂等校正（避免首屏高亮行偏出中心）
                    DispatchQueue.main.async {
                        proxy.scrollTo(activeIndex, anchor: .center)
                        DispatchQueue.main.asyncAfter(
                            deadline: .now() + LyricsCenterMetrics.settleCorrectionDelay
                        ) {
                            proxy.scrollTo(activeIndex, anchor: .center)
                        }
                    }
                }
                // 尺寸变化（拖动分隔条逐帧 / 窗口缩放 / 全屏切换）：任何变化都无动画重锚，
                // 拖动中每个 tick 都保持居中（用动画会跟不上手）。
                .onChange(of: geometry.size) { _, _ in
                    reanchorAfterPanelResize(proxy: proxy, activeIndex: activeIndex)
                }
                // 字号设置 / 译文 / 罗马音开关改变行高：同样触发重锚（用户要求「任何改变布局的行为」）
                .onChange(of: fontScale) { _, _ in
                    reanchorAfterPanelResize(
                        proxy: proxy,
                        activeIndex: activeIndex,
                        settleDelay: LyricsCenterMetrics.settleReanchorDelays.first
                    )
                }
                .onChange(of: showTranslation) { _, _ in
                    reanchorAfterPanelResize(
                        proxy: proxy,
                        activeIndex: activeIndex,
                        settleDelay: LyricsCenterMetrics.settleReanchorDelays.first
                    )
                }
                .onChange(of: showRoman) { _, _ in
                    reanchorAfterPanelResize(
                        proxy: proxy,
                        activeIndex: activeIndex,
                        settleDelay: LyricsCenterMetrics.settleReanchorDelays.first
                    )
                }
            }
        }
    }

    /// 视口尺寸 / 行高变化后把当前行重锚回中心（窗口缩放 / 拖分隔条 / 全屏 / 字号 / 译文开关）。
    ///
    /// 成因：占位与内容高度随视口变，而 `NSScrollView` 的 `contentOffset` 不会自动修正
    /// ⇒ 高亮行相对视口漂移。跟随语义与「行变化回中」一致：普通模式阅读态（手动滚动后）
    /// 不拉回用户位置；跟唱等 AB 终点（`ab.b == nil`）时同样暂停。
    /// 不带动画：拖动中几何每帧都在变，动画会跟不上手、叠加成抖动。
    private func reanchorAfterPanelResize(
        proxy: ScrollViewProxy,
        activeIndex: Int?,
        settleDelay: TimeInterval? = nil
    ) {
        guard let activeIndex else { return }
        if karaoke.isKaraokeOn, let ab = karaoke.abLoop, ab.b == nil { return }
        if !karaoke.isKaraokeOn, !isFollowing { return }
        // 几何变化当帧内容尚未按新尺寸重排：下一轮主队列再滚，才滚到新布局的中心
        DispatchQueue.main.async {
            proxy.scrollTo(activeIndex, anchor: .center)
        }
        // 再补一拍（+0.05s）：字号 / 译文开关会改变行高，布局常有第二跳（文字重新换行）
        DispatchQueue.main.asyncAfter(deadline: .now() + LyricsCenterMetrics.settleCorrectionDelay) {
            proxy.scrollTo(activeIndex, anchor: .center)
        }
        // 行高类改动（字号 / 译文 / 罗马音开关）会触发动画：再在 +0.45s 补一次（有偏差才动）
        if let settleDelay {
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                guard abs(centerProbe.delta ?? 0) > LyricsCenterMetrics.settleReanchorTolerance else { return }
                proxy.scrollTo(activeIndex, anchor: .center)
            }
        }
    }

    /// 动画落定后的幂等重锚：0.45s / 0.90s 各读一次实测偏移，只有 |delta| > 0.5pt 才补滚。
    /// 补滚不带 `withAnimation` → 同一 index 的重复 scrollTo 无可见位移；无偏差时完全不动。
    /// 末拍附一次居中诊断日志（两种呈现模式共用，避免只有 fullscreen 有日志）。
    private func scheduleSettleReanchor(proxy: ScrollViewProxy, index: Int, viewportHeight: CGFloat) {
        let probe = centerProbe
        for delay in LyricsCenterMetrics.settleReanchorDelays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard abs(probe.delta ?? 0) > LyricsCenterMetrics.settleReanchorTolerance else { return }
                proxy.scrollTo(index, anchor: .center)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            scheduleCenterLog(delta: probe.delta, viewportHeight: viewportHeight)
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

    /// 验收日志：滚动停稳后（0.3s 防抖）打印高亮行中心与视口中心之差，确认后删除。
    private func scheduleCenterLog(rowMidY: CGFloat, viewportHeight: CGFloat) {
        LyricsCenterLogger.log(
            platform: "mac",
            mode: lyricsSurfaceMode,
            rowMidY: rowMidY,
            viewportHeight: viewportHeight
        ) { message in
            AppLog.info(.ui, message)
        }
    }

    /// 行内几何探针：写入实测偏移（供落定后重锚判定）+ 打居中日志。
    private func recordCenter(
        _ rowProxy: GeometryProxy,
        viewportHeight: CGFloat,
        isActive: Bool
    ) {
        guard isActive else { return }
        let midY = rowProxy.frame(in: .named(LyricsCenterMetrics.coordinateSpaceName)).midY
        centerProbe.delta = midY - viewportHeight / 2
        scheduleCenterLog(rowMidY: midY, viewportHeight: viewportHeight)
    }

    /// 用实测偏移（delta）落日志：滚动 / 重锚路径也能打点，不依赖行内几何再次变化。
    private func scheduleCenterLog(delta: CGFloat?, viewportHeight: CGFloat) {
        guard let delta else { return }
        scheduleCenterLog(rowMidY: viewportHeight / 2 + delta, viewportHeight: viewportHeight)
    }

    /// 诊断用的「呈现模式」：docked = 底部歌词面板，fullscreen = 独立歌词页 / 跟唱大画面。
    /// 之前日志只在 fullscreen 出现，是因为打点只挂在行内几何变化上；本值让两种模式都可区分。
    private var lyricsSurfaceMode: String {
        isFullscreen ? "fullscreen" : "docked"
    }

    private func lyricLineView(
        line: LyricsLine,
        isActive: Bool,
        distance: Int,
        index: Int,
        viewportHeight: CGFloat
    ) -> some View {
        let emphasis = emphasisValue(isActive: isActive, distance: distance)
        let isKaraoke = karaoke.isKaraokeOn
        // 阅读态（用户拍板 2026-10-12）：普通模式用户手动滚动后，整页关距离分级「灰度」+ 正常字号，
        // 直到回中（isFollowing 恢复 true）。跟唱模式不受影响（reading 恒 false）。
        let reading = !isKaraoke && !isFollowing
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
                        karaoke: isKaraoke,
                        reading: reading
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
                            reading: reading,
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
                            karaoke: isKaraoke,
                            reading: reading
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DesignTokens.space32)
        // 垂直 padding 在动画修饰符**内层** → 随 emphasis 逐帧插值（视觉要求：行高平滑变化）。
        // 居中不靠冻结布局，而靠「滚动时机 + 落定后重锚」（见 onChange(activeIndex)）。
        .padding(.vertical, LyricLineEmphasis.linePadding(emphasis, karaoke: isKaraoke))
        .id(index)
        .scaleEffect(LyricLineEmphasis.lineScale(emphasis, karaoke: isKaraoke, reading: reading), anchor: .center)
        .opacity(LyricLineEmphasis.lineOpacity(emphasis, karaoke: isKaraoke, reading: reading))
        // 行强调由播放 tick 驱动的 body 重算得出（不是用户事件）→ 靠 .animation(value:) 触发，
        // 与滚屏共用同一条曲线（不要再套 withAnimation）
        .animation(Self.lyricAnimation, value: emphasis)
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
                    // 行「变高亮」本身就是几何可能变化的时刻（字号 / padding 档位变了），
                    // 只靠 midY onChange 会漏掉「本轮刚成为高亮行」这一拍 → docked 模式下一条日志都没有。
                    .onChange(of: isActive) { _, active in
                        guard active else { return }
                        recordCenter(rowProxy, viewportHeight: viewportHeight, isActive: true)
                    }
            }
        )
        .contentShape(Rectangle())
        // 单击行：跟唱模式 = 跳转 / 等选终点 = 设 B（决策统一走 KaraokeController.clickLine）；
        // 普通模式 = 跳到该行播放（KaraokeController.seekToLyricLine）并恢复自动跟随。
        // 普通 onTapGesture：页面级 highPriorityGesture 双击（放大）优先，
        // 单击等双击窗口判定失败后触发（与 iOS 结构一致）
        .onTapGesture {
            if karaoke.isKaraokeOn {
                karaoke.clickLine(index: index)
            } else {
                isFollowing = true
                karaoke.seekToLyricLine(index)
            }
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

    /// 「回到当前行」按钮：恢复自动跟随并立刻把当前行滚回中央（普通模式手动滚动后浮出）
    private func backToCurrentLineButton(activeIndex: Int?, proxy: ScrollViewProxy) -> some View {
        Button {
            isFollowing = true
            if let activeIndex {
                withAnimation(Self.lyricAnimation) {
                    proxy.scrollTo(activeIndex, anchor: .center)
                }
            }
        } label: {
            HStack(spacing: DesignTokens.space4) {
                Image(systemName: "arrow.down.to.line.compact")
                Text(Localized.backToCurrentLine)
            }
            .font(.system(size: DesignTokens.font13, weight: .semibold))
            .padding(.horizontal, DesignTokens.space16)
            .padding(.vertical, DesignTokens.space8)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().stroke(appAccentColor.opacity(0.35), lineWidth: 1))
            .foregroundColor(appAccentColor)
        }
        .buttonStyle(.plain)
    }
}

/// 歌词面板「用户手动滚动」检测桥（Mac 专属）。
///
/// 选型说明：SwiftUI 的 `onScrollPhaseChange` 需 macOS 15，而本仓 Mac 部署目标为 14.0，
/// 故走 AppKit：沿视图树找到承载歌词滚动内容的 `NSScrollView`，监听
/// `willStartLiveScrollNotification`（**用户发起**的实时滚动开始：触控板 / 滚轮 / 滚动条）
/// 与 `didEndLiveScrollNotification`（用户实时滚动结束）—— 二者都只在**用户发起**的
/// 实时滚动时发出，程序化 `ScrollViewProxy.scrollTo` / `clipView.scroll` 不触发 ⇒
/// 自动滚动不会被误判成手动（这正是 iOS 端 onScrollPhaseChange 的等价保证）。
/// 与「唯一 AppKit 滚动入口」文件里的代表桥同款「延后一拍」装配先例。
struct MacLyricsScrollObserver: NSViewRepresentable {
    /// 用户手动滚动开始回调（主线程调用）
    let onUserScroll: () -> Void
    /// 用户手动滚动结束回调（主线程调用；didEndLiveScrollNotification）
    let onUserScrollEnd: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onUserScroll: onUserScroll, onUserScrollEnd: onUserScrollEnd)
    }

    /// 零尺寸占位视图：只当「沿视图树找宿主 NSScrollView」的起点，不绘制、不响应事件
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onUserScroll = onUserScroll
        context.coordinator.onUserScrollEnd = onUserScrollEnd
        context.coordinator.attachIfNeeded(from: nsView)
    }

    /// @unchecked Sendable：本类只在主线程访问（makeCoordinator/updateNSView 均 @MainActor，
    /// live-scroll 通知也投递到 .main 队列），故可安全被 @Sendable 通知闭包捕获。
    final class Coordinator: @unchecked Sendable {
        var onUserScroll: () -> Void
        var onUserScrollEnd: () -> Void
        private weak var scrollView: NSScrollView?
        private var startToken: NSObjectProtocol?
        private var endToken: NSObjectProtocol?
        init(onUserScroll: @escaping () -> Void, onUserScrollEnd: @escaping () -> Void) {
            self.onUserScroll = onUserScroll
            self.onUserScrollEnd = onUserScrollEnd
        }
        deinit { detach() }

        /// 找到宿主 NSScrollView 并挂一次 live-scroll 监听（幂等；视图未入树时延后一拍重试）
        func attachIfNeeded(from view: NSView) {
            guard scrollView == nil else { return }
            Task { @MainActor [weak self, weak view] in
                guard let self, let view,
                      let sv = MacHostScrollView.enclosing(of: view),
                      self.scrollView !== sv else { return }
                self.detach()
                self.scrollView = sv
                let center = NotificationCenter.default
                self.startToken = center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: sv,
                    queue: .main
                ) { [weak self] _ in
                    self?.onUserScroll()
                }
                self.endToken = center.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: sv,
                    queue: .main
                ) { [weak self] _ in
                    self?.onUserScrollEnd()
                }
            }
        }

        /// 摘掉已挂的通知（重新定位宿主 / 析构时调用；幂等）
        private func detach() {
            let center = NotificationCenter.default
            if let startToken { center.removeObserver(startToken) }
            if let endToken { center.removeObserver(endToken) }
            startToken = nil
            endToken = nil
        }
    }
}
