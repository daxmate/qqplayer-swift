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
                                }
                            )
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)

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
                    withAnimation(Self.lyricAnimation) {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                    lastFollowedIndex = newIndex
                }
                // 切歌 / 歌词变化：恢复自动跟随（需求 3）
                .onChange(of: lines) { _, _ in
                    isFollowing = true
                }
                .onAppear {
                    guard let activeIndex else { return }
                    lastFollowedIndex = activeIndex
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
