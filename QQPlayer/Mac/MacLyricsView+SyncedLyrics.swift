//
//  MacLyricsView+SyncedLyrics.swift
//  QQPlayer
//
//  `MacLyricsView` 的跟唱 / 距离分级排版与逐行视图（2026-09-21 从 `MacLyricsView.swift` 纯搬家，零行为/UI 变化）。
//
//  ⚠️ 可见性：被主片或其它分区文件引用的成员为 internal（原 `private`）。
//

import AppKit
import QuartzCore
import SwiftUI

extension MacLyricsView {
    // MARK: - Synced lyrics（距离分级排版，对齐 iOS LyricsView）

    /// 分片：跨文件可见（原 private）
    func syncedView(_ lines: [LyricsLine]) -> some View {
        // 歌词轴时间（音频时间 - offset，web lyricTime 语义）：高亮行与跟唱 tick 同轴
        let activeIndex = LyricTiming.activeLineIndex(time: currentTime - lyricOffset, in: lines)
        // 拖动分隔条时的顶部补偿（方案 A）：跟随态下补 delta/2，使文字在屏幕上不动
        let resizePinInset = MacPlaybackGate.lyricsResizePinInset(
            isResizing: isPanelResizing,
            isFollowing: isFollowing,
            heightDelta: panelResizeDelta
        )
        return GeometryReader { geometry in
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
                                },
                                // 宿主 NSScrollView：精确偏移滚屏用（拿不到时退回 ScrollViewProxy）
                                onScrollViewReady: { scrollView in
                                    lyricsScrollView = scrollView
                                }
                            )
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)

                            // 上下等距撑开 = 视口一半（不再减 40 的魔数：那是半个行高，
                            // 行高随字号/译文/强调内边距变化 → 首末行系统性偏出中心）
                            Spacer()
                                .frame(height: geometry.size.height / 2)

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
                                .frame(height: geometry.size.height / 2)
                            // 内容总高标记：居中偏移公式的 contentHeight（布局落定信号）
                            Color.clear
                                .frame(height: 0)
                                .onGeometryChange(for: CGFloat.self) { proxy in
                                    proxy.frame(in: .named(MacLyricsView.lyricsContentSpace)).maxY
                                } action: { height in
                                    lyricContentHeight = height
                                }
                        }
                        // 行 frame / 内容高度共用的坐标空间（居中偏移的唯一口径）
                        .coordinateSpace(name: MacLyricsView.lyricsContentSpace)
                        // 拖动分隔条时的顶部补偿（方案 A；非拖动/非跟随恒为 0）：
                        // 用 padding 而非撑高 Spacer——面板拖到最矮时 Spacer 会触零截断，
                        // 负补偿必须能继续把内容上提，否则底部大位移会残留漂移。
                        .padding(.top, resizePinInset)
                    }
                    // 玻璃模式：内容本身按透明度淡出（不铺任何颜色，见 LyricsGlassEdgeFade）
                    .modifier(
                        LyricsGlassEdgeFade(
                            active: windowGlassActive,
                            height: fadeHeight(geometry.size.height)
                        )
                    )
                    // 面板内不禁用滚动：Mac 无 iOS 的手势冲突，用户可手动翻，行变化时回中心

                    // 上下边缘渐隐（面板可矮到 140pt → 渐隐高度随面板收缩）
                    // 玻璃模式不能盖底色（baseColor 不透明 → 顶部成一条白带），改用透明遮罩，
                    // 即把滚动内容本身淡出（见 edgeFadeMask）。
                    if !windowGlassActive {
                        VStack(spacing: DesignTokens.space0) {
                            LinearGradient(colors: fadeColors(top: true), startPoint: .top, endPoint: .bottom)
                                .frame(height: fadeHeight(geometry.size.height))

                            Spacer()

                            LinearGradient(colors: fadeColors(top: false), startPoint: .top, endPoint: .bottom)
                                .frame(height: fadeHeight(geometry.size.height))
                        }
                        .allowsHitTesting(false)
                    }
                }
                // 手动滚动暂停跟随后浮出的「回到当前行」按钮（仅普通模式）
                .overlay(alignment: .bottom) {
                    if !karaoke.isKaraokeOn, !isFollowing {
                        backToCurrentLineButton(
                            activeIndex: activeIndex,
                            proxy: proxy,
                            viewportHeight: geometry.size.height
                        )
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
                    centerOnActiveLine(newIndex, proxy: proxy, viewportHeight: geometry.size.height, animated: true)
                    // 行高（强调内边距/译文行）在动画里变化 → 落定后按新几何再对一次中
                    scheduleRecenter(newIndex, proxy: proxy, viewportHeight: geometry.size.height)
                    lastFollowedIndex = newIndex
                }
                // 切歌 / 歌词变化：恢复自动跟随（需求 3）
                .onChange(of: lines) { _, _ in
                    isFollowing = true
                    // 新歌词的行高要等布局 → 落定后对准当前行（否则停在上一首的偏移）
                    scheduleRecenter(activeIndex, proxy: proxy, viewportHeight: geometry.size.height)
                }
                .onAppear {
                    guard let activeIndex else { return }
                    lastFollowedIndex = activeIndex
                    // 首帧滚动：面板高度可能来自窗口尺寸 / 记忆值，当帧布局尚未落定
                    // → 下一轮主队列再滚（避免首屏高亮行偏出中心，2026-11-17）
                    DispatchQueue.main.async {
                        centerOnActiveLine(activeIndex, proxy: proxy, viewportHeight: geometry.size.height, animated: false)
                    }
                }
                // 面板尺寸变化（窗口缩放 / 拖分隔条 / 记忆高度恢复）：把当前行重锚回中心
                // 拖动中跳过（补偿占位负责让文字不动），松手后统一重锚一次
                .onChange(of: geometry.size) { _, _ in
                    guard !isPanelResizing else { return }
                    reanchorAfterPanelResize(proxy: proxy, activeIndex: activeIndex, viewportHeight: geometry.size.height)
                }
                // 布局落定信号（字号 / 译文行 / 歌词重新加载 / 强调动画结束后内容高度变化）：
                // 跟随态下按最新几何再对一次中（无动画）
                .onChange(of: lyricContentHeight) { _, _ in
                    guard !isPanelResizing else { return }
                    scheduleRecenter(activeIndex, proxy: proxy, viewportHeight: geometry.size.height)
                }
                // 松手：补偿占位以 spring 归零，数学上恰好把当前行送到新面板中心
                // （顶部占位 = 视口高/2 - 40 ⇒ Δ/2 归零 = 屏幕中心上移 Δ/2）。
                // 兜底：动画结束后再对齐一次，修「拖动期间切句」造成的偏移；正常路径是空操作，
                // 因此不会和归零动画叠加成两倍位移（2026-11-18）。
                .onChange(of: isPanelResizing) { wasResizing, resizing in
                    guard wasResizing, !resizing else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        reanchorAfterPanelResize(proxy: proxy, activeIndex: activeIndex, viewportHeight: geometry.size.height)
                    }
                }
            }
        }
    }

    /// 面板尺寸变化后把当前行重锚回中心（2026-11-17 修复：窗口缩放 / 拖分隔条后高亮行漂出可见区）。
    ///
    /// 成因：歌词内容底部占位 = 视口高/2 - 40，面板高度一变内容高度就跟着变，而 `NSScrollView`
    /// 的 `contentOffset` 不会随内容高度修正 ⇒ 高亮行相对视口漂移，面板变矮时会被挤出可见区。
    /// 跟随语义与「行变化回中」一致：普通模式阅读态（手动滚动后）不拉回用户位置；跟唱等 AB
    /// 终点（`ab.b == nil`）时同样暂停。resize 路径不带动画——几何每帧都在变，动画会叠加成抖动。
    private func reanchorAfterPanelResize(proxy: ScrollViewProxy, activeIndex: Int?, viewportHeight: CGFloat) {
        guard let activeIndex else { return }
        // 拖动中不重锚：补偿占位负责让文字不动（2026-11-18）
        guard !isPanelResizing else { return }
        if karaoke.isKaraokeOn, let ab = karaoke.abLoop, ab.b == nil { return }
        if !karaoke.isKaraokeOn, !isFollowing { return }
        // 几何变化当帧内容尚未按新尺寸重排：下一轮主队列再滚，才滚到新布局的中心
        DispatchQueue.main.async {
            centerOnActiveLine(activeIndex, proxy: proxy, viewportHeight: viewportHeight, animated: false)
        }
    }

    // MARK: - 居中滚动（精确偏移；公式唯一实现见 LyricsCenterMath）

    /// 把指定歌词行居中。优先按**实测几何**算精确偏移滚 `NSScrollView`（误差可计算、可测），
    /// 取不到宿主滚动视图时退回 `ScrollViewProxy.scrollTo(anchor: .center)`。
    func centerOnActiveLine(
        _ index: Int?,
        proxy: ScrollViewProxy,
        viewportHeight: CGFloat,
        animated: Bool
    ) {
        guard let index else { return }
        guard let rect = lyricRowRects[index], lyricContentHeight > 0 else {
            proxy.scrollTo(index, anchor: .center)
            return
        }
        let offset = LyricsCenterMath.centeredOffset(
            rowCenterY: rect.midY,
            viewportHeight: viewportHeight,
            contentHeight: lyricContentHeight
        )
        guard let scrollView = lyricsScrollView, let documentView = scrollView.documentView else {
            proxy.scrollTo(index, anchor: .center)
            return
        }
        applyScrollOffset(
            offset,
            scrollView: scrollView,
            documentView: documentView,
            viewportHeight: viewportHeight,
            animated: animated
        )
    }

    /// 布局落定后再对一次中：切句时行高（强调内边距/译文行）变化会让本次滚屏动画
    /// 按旧几何落点；这里等动画结束 + 布局稳定后按**最新**实测几何补一次（无动画）。
    func scheduleRecenter(_ index: Int?, proxy: ScrollViewProxy, viewportHeight: CGFloat) {
        recenterTask?.cancel()
        recenterTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }
            guard karaoke.isKaraokeOn || isFollowing else { return }
            if karaoke.isKaraokeOn, let ab = karaoke.abLoop, ab.b == nil { return }
            centerOnActiveLine(index, proxy: proxy, viewportHeight: viewportHeight, animated: false)
        }
    }

    private func applyScrollOffset(
        _ offset: CGFloat,
        scrollView: NSScrollView,
        documentView: NSView,
        viewportHeight: CGFloat,
        animated: Bool
    ) {
        let clip = scrollView.contentView
        let documentHeight = max(documentView.bounds.height, lyricContentHeight)
        let maxOffset = max(documentHeight - viewportHeight, 0)
        let clamped = min(max(offset, 0), maxOffset)
        // flipped 文档视图：origin.y 从内容顶部量起；非 flipped 反过来
        let y = documentView.isFlipped ? clamped : maxOffset - clamped
        let point = NSPoint(x: clip.bounds.origin.x, y: y)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MacLyricsView.lyricScrollDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                clip.animator().setBoundsOrigin(point)
            } completionHandler: {
                scrollView.reflectScrolledClipView(clip)
            }
        } else {
            clip.setBoundsOrigin(point)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    /// 边缘渐隐高度（面板可矮到 140pt → 随面板收缩；与改前同一口径）
    private func fadeHeight(_ viewportHeight: CGFloat) -> CGFloat {
        min(150, viewportHeight * 0.22)
    }

    /// 边缘渐隐用的底色色阶（top = 自上而下；bottom = 反向）
    /// ⚠️ 只用于**关闭玻璃**的旧外观：baseColor 不透明，盖在玻璃上就是一条白带。
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
        .padding(.vertical, LyricLineEmphasis.linePadding(emphasis, karaoke: isKaraoke))
        .id(index)
        // 行 frame（内容坐标系）：高亮行居中的唯一测量口径（强调内边距/译文行变化都会反映到它）
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(MacLyricsView.lyricsContentSpace))
        } action: { rect in
            lyricRowRects[index] = rect
        }
        .scaleEffect(LyricLineEmphasis.lineScale(emphasis, karaoke: isKaraoke, reading: reading), anchor: .center)
        .opacity(LyricLineEmphasis.lineOpacity(emphasis, karaoke: isKaraoke, reading: reading))
        // 行强调由播放 tick 驱动的 body 重算得出（不是用户事件）→ 靠 .animation(value:) 触发，
        // 与滚屏共用同一条曲线（不要再套 withAnimation）
        .animation(Self.lyricAnimation, value: emphasis)
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
    private func backToCurrentLineButton(activeIndex: Int?, proxy: ScrollViewProxy, viewportHeight: CGFloat) -> some View {
        Button {
            isFollowing = true
            centerOnActiveLine(activeIndex, proxy: proxy, viewportHeight: viewportHeight, animated: true)
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
    /// 找到宿主 `NSScrollView` 时回传（精确偏移滚屏用）；找不到 / 析构回传 nil
    var onScrollViewReady: ((NSScrollView?) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onUserScroll: onUserScroll,
            onUserScrollEnd: onUserScrollEnd,
            onScrollViewReady: onScrollViewReady
        )
    }

    /// 零尺寸占位视图：只当「沿视图树找宿主 NSScrollView」的起点，不绘制、不响应事件
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onUserScroll = onUserScroll
        context.coordinator.onUserScrollEnd = onUserScrollEnd
        context.coordinator.onScrollViewReady = onScrollViewReady
        context.coordinator.attachIfNeeded(from: nsView)
    }

    /// @unchecked Sendable：本类只在主线程访问（makeCoordinator/updateNSView 均 @MainActor，
    /// live-scroll 通知也投递到 .main 队列），故可安全被 @Sendable 通知闭包捕获。
    final class Coordinator: @unchecked Sendable {
        var onUserScroll: () -> Void
        var onUserScrollEnd: () -> Void
        var onScrollViewReady: ((NSScrollView?) -> Void)?
        private weak var scrollView: NSScrollView?
        private var startToken: NSObjectProtocol?
        private var endToken: NSObjectProtocol?
        init(
            onUserScroll: @escaping () -> Void,
            onUserScrollEnd: @escaping () -> Void,
            onScrollViewReady: ((NSScrollView?) -> Void)?
        ) {
            self.onUserScroll = onUserScroll
            self.onUserScrollEnd = onUserScrollEnd
            self.onScrollViewReady = onScrollViewReady
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
                self.onScrollViewReady?(sv)
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

// MARK: - 玻璃模式边缘淡出

/// 整窗玻璃下的上下边缘淡出：把滚动内容**本身**按透明度遮罩淡出，
/// 不铺任何颜色（旧实现用 baseColor 渐变带，盖在玻璃上会显示成顶部/底部白带）。
/// 关闭玻璃时原样返回内容——旧外观逐像素不变，也不多一次离屏渲染。
private struct LyricsGlassEdgeFade: ViewModifier {
    let active: Bool
    let height: CGFloat

    func body(content: Content) -> some View {
        if active {
            content.mask {
                VStack(spacing: DesignTokens.space0) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.55), .black.opacity(0.92), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: height)

                    Color.black

                    LinearGradient(
                        colors: [.black, .black.opacity(0.92), .black.opacity(0.55), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: height)
                }
            }
        } else {
            content
        }
    }
}
