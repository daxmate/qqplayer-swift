//  MacPlaybackGateTests.swift
//  QQPlayerTests
//
//  macOS 播放链路决策纯逻辑防回归测试（MacPlaybackGate）：
//  - canStartPlayback：play() 前置条件（audioFile 已加载 / 非 loading / 非 loading 态）
//  - segmentPlan：scheduleSegment 帧计划校验（engine running / startFrame 范围 / remaining）
//
//  背景（2026-08-31）：macOS 版首测暴露"能编译但行为错"类 bug（扫描不执行/库为空），
//  决策逻辑必须上收为纯函数并锁定语义，防止播放链路被后续改动悄悄破坏。
//

import Foundation
import Testing

@testable import QQPlayer

struct MacPlaybackGateCanStartTests {
    @Test("audioFile 已加载 + 非 loading：可播放")
    func readyCanPlay() {
        #expect(MacPlaybackGate.canStartPlayback(
            audioFileLoaded: true, isLoadingTrack: false, playbackStateIsLoading: false))
    }

    @Test("audioFile 未加载：不可播放")
    func noAudioFileCannotPlay() {
        #expect(!MacPlaybackGate.canStartPlayback(
            audioFileLoaded: false, isLoadingTrack: false, playbackStateIsLoading: false))
    }

    @Test("加载任务进行中：不可播放（避免与加载竞争）")
    func loadingTrackCannotPlay() {
        #expect(!MacPlaybackGate.canStartPlayback(
            audioFileLoaded: true, isLoadingTrack: true, playbackStateIsLoading: false))
    }

    @Test("播放状态为 loading：不可播放")
    func loadingStateCannotPlay() {
        #expect(!MacPlaybackGate.canStartPlayback(
            audioFileLoaded: true, isLoadingTrack: false, playbackStateIsLoading: true))
    }

    @Test("全部前置不满足：不可播放")
    func nothingReadyCannotPlay() {
        #expect(!MacPlaybackGate.canStartPlayback(
            audioFileLoaded: false, isLoadingTrack: true, playbackStateIsLoading: true))
    }
}

struct MacPlaybackGateSegmentPlanTests {
    @Test("正常帧计划：返回剩余帧数")
    func normalSegment() {
        #expect(MacPlaybackGate.segmentPlan(
            engineIsRunning: true, startFrame: 0, fileLength: 1000, maxFrameCount: 1_000_000)
            == .success(frameCount: 1000))
        #expect(MacPlaybackGate.segmentPlan(
            engineIsRunning: true, startFrame: 400, fileLength: 1000, maxFrameCount: 1_000_000)
            == .success(frameCount: 600))
    }

    @Test("引擎未运行：拒绝")
    func engineNotRunning() {
        #expect(MacPlaybackGate.segmentPlan(
            engineIsRunning: false, startFrame: 0, fileLength: 1000, maxFrameCount: 1_000_000)
            == .failure(.engineNotRunning))
    }

    @Test("startFrame 为负：拒绝")
    func negativeStartFrame() {
        #expect(MacPlaybackGate.segmentPlan(
            engineIsRunning: true, startFrame: -1, fileLength: 1000, maxFrameCount: 1_000_000)
            == .failure(.invalidStartFrame))
    }

    @Test("startFrame 超出文件长度：拒绝")
    func startFrameBeyondFile() {
        #expect(MacPlaybackGate.segmentPlan(
            engineIsRunning: true, startFrame: 1000, fileLength: 1000, maxFrameCount: 1_000_000)
            == .failure(.invalidStartFrame))
        #expect(MacPlaybackGate.segmentPlan(
            engineIsRunning: true, startFrame: 5000, fileLength: 1000, maxFrameCount: 1_000_000)
            == .failure(.invalidStartFrame))
    }

    @Test("remaining 超 AVAudioFrameCount.max：拒绝")
    func remainingExceedsMax() {
        #expect(MacPlaybackGate.segmentPlan(
            engineIsRunning: true, startFrame: 0, fileLength: 2_000_000_000, maxFrameCount: 1_000_000_000)
            == .failure(.exceedsMaxFrameCount))
    }

    @Test("remaining 恰好等于 max：接受")
    func remainingEqualsMax() {
        #expect(MacPlaybackGate.segmentPlan(
            engineIsRunning: true, startFrame: 0, fileLength: 1_000_000_000, maxFrameCount: 1_000_000_000)
            == .success(frameCount: 1_000_000_000))
    }
}

struct MacPlaybackGateSegmentFinishedTests {
    // 防回归背景（2026-09-01）：macOS seek() 漏 cancelPendingCompletions() →
    // playerNode.stop() 触发旧 segment completion（generation 仍等于当前代）→
    // 误判播完 → handleTrackEnd 停播（用户实测：点歌词/上下句首次不播放，二次才播）。
    // 判定已上收为纯函数，这里锁定全部分支。

    @Test("当前代 + 播放中 + 同曲目：触发曲目结束（正常播完）")
    func currentGenerationPlayingSameTrackTriggers() {
        #expect(MacPlaybackGate.shouldHandleSegmentFinished(
            generation: 5, scheduleGeneration: 5, isPlaying: true,
            completionTrackId: "t1", currentTrackId: "t1"))
    }

    @Test("旧代 completion（seek/play 已 cancel）：不触发——本次 bug 核心")
    func staleGenerationIgnored() {
        #expect(!MacPlaybackGate.shouldHandleSegmentFinished(
            generation: 4, scheduleGeneration: 5, isPlaying: true,
            completionTrackId: "t1", currentTrackId: "t1"))
        // cancelPendingCompletions 可能多次 +1，任意旧代都应失效
        #expect(!MacPlaybackGate.shouldHandleSegmentFinished(
            generation: 0, scheduleGeneration: 5, isPlaying: true,
            completionTrackId: "t1", currentTrackId: "t1"))
    }

    @Test("非播放中：不触发（暂停/停止态 stop 的回调忽略）")
    func notPlayingIgnored() {
        #expect(!MacPlaybackGate.shouldHandleSegmentFinished(
            generation: 5, scheduleGeneration: 5, isPlaying: false,
            completionTrackId: "t1", currentTrackId: "t1"))
    }

    @Test("completion 属于旧曲目：不触发（切歌后旧段回调忽略）")
    func staleTrackIgnored() {
        #expect(!MacPlaybackGate.shouldHandleSegmentFinished(
            generation: 5, scheduleGeneration: 5, isPlaying: true,
            completionTrackId: "old", currentTrackId: "new"))
    }

    @Test("completion 无曲目 id（兼容旧回调）：触发")
    func nilCompletionTrackIdTriggers() {
        #expect(MacPlaybackGate.shouldHandleSegmentFinished(
            generation: 5, scheduleGeneration: 5, isPlaying: true,
            completionTrackId: nil, currentTrackId: "t1"))
    }

    @Test("当前曲目 id 为 nil 且 completion 也为 nil：触发")
    func nilCurrentTrackIdWithNilCompletionTriggers() {
        #expect(MacPlaybackGate.shouldHandleSegmentFinished(
            generation: 5, scheduleGeneration: 5, isPlaying: true,
            completionTrackId: nil, currentTrackId: nil))
    }

    @Test("多条件同时不满足：不触发")
    func allWrongIgnored() {
        #expect(!MacPlaybackGate.shouldHandleSegmentFinished(
            generation: 1, scheduleGeneration: 9, isPlaying: false,
            completionTrackId: "old", currentTrackId: "new"))
    }
}

struct MacPlaybackGatePlayStartTests {
    // play() 起始位置决策（2026-09-12 审计 P1）：macOS 曲终 / seek 到末尾后 playbackTime
    // 停在 ≈ duration，旧 play() 直接用它算 startFrame 并被 segmentPlan 拒绝，但仍置
    // isPlaying = true（界面在播、实际无声、无自愈路径）。决策上收后此处锁定语义：
    // 位置不在 [1, fileLength) 内一律回零重播。

    @Test("暂停在文件中间：从该帧继续（暂停恢复不受影响）")
    func resumeFromMiddle() {
        #expect(MacPlaybackGate.playStartPlan(requestedFrame: 400, fileLength: 1000) == .resume(frame: 400))
        #expect(MacPlaybackGate.playStartPlan(requestedFrame: 1, fileLength: 1000) == .resume(frame: 1))
    }

    @Test("位置为 0：回零重播（等价从头，不产生无效调度）")
    func zeroRestarts() {
        #expect(MacPlaybackGate.playStartPlan(requestedFrame: 0, fileLength: 1000) == .restartFromStart)
    }

    @Test("位置正好等于末尾（曲终 / seek 到末尾后残留）：回零重播")
    func atEndRestarts() {
        #expect(MacPlaybackGate.playStartPlan(requestedFrame: 1000, fileLength: 1000) == .restartFromStart)
    }

    @Test("位置越过末尾（异常索引 / 时长漂移）：回零重播")
    func beyondEndRestarts() {
        #expect(MacPlaybackGate.playStartPlan(requestedFrame: 1200, fileLength: 1000) == .restartFromStart)
    }

    @Test("位置为负（异常）：回零重播")
    func negativeRestarts() {
        #expect(MacPlaybackGate.playStartPlan(requestedFrame: -1, fileLength: 1000) == .restartFromStart)
    }

    @Test("不变量：playStartPlan 的输出帧永远能通过 segmentPlan（不再产生 invalidStartFrame）")
    func planAlwaysSchedulable() {
        // 修复前 play() 把 playbackTime 直接当 startFrame 且丢弃 scheduleSegment 返回值，
        // 末尾位置会命中 .invalidStartFrame → 假播放。此不变量锁死两个纯函数的组合语义。
        for requested in [Int64(-5), 0, 1, 999, 1000, 1001, 10_000] {
            let frame: Int64
            switch MacPlaybackGate.playStartPlan(requestedFrame: requested, fileLength: 1000) {
            case let .resume(resumeFrame): frame = resumeFrame
            case .restartFromStart: frame = 0
            }
            switch MacPlaybackGate.segmentPlan(
                engineIsRunning: true, startFrame: frame, fileLength: 1000, maxFrameCount: 1_000_000
            ) {
            case .success: break
            case let .failure(reason):
                Issue.record("requested=\(requested) 得到 startFrame=\(frame)，被 segmentPlan 拒绝：\(reason)")
            }
        }
    }
}

struct MacPlaybackGateKaraokeLayoutTests {
    // 歌词大画面布局决策：播放区隐藏/歌词撑满（2026-09-01 跟唱 / 2026-09-06
    // 双击纯放大拆分为独立 isLyricsExpanded 维度——两者任一成立都进大画面）。
    // 手势交互（双击 toggle）无法单测，但布局决策抽纯函数锁定，防止后续改动悄悄破坏。
    // 2026-09-02：歌词面板常驻（无关闭入口），shouldAutoShowLyrics/lyricsCloseAction 已随关闭入口一起删除。

    @Test("跟唱开启：播放区隐藏，空间让给歌词")
    func karaokeOnHidesPlayerSection() {
        #expect(MacPlaybackGate.shouldHidePlayerSection(isKaraokeOn: true, isLyricsExpanded: false))
        #expect(!MacPlaybackGate.shouldHidePlayerSection(isKaraokeOn: false, isLyricsExpanded: false))
    }

    @Test("双击放大歌词：播放区同样隐藏（不跟唱也进大画面）")
    func lyricsExpandedHidesPlayerSection() {
        #expect(MacPlaybackGate.shouldHidePlayerSection(isKaraokeOn: false, isLyricsExpanded: true))
        #expect(!MacPlaybackGate.shouldHidePlayerSection(isKaraokeOn: false, isLyricsExpanded: false))
    }

    @Test("跟唱开启：歌词区撑满整个区域")
    func karaokeOnExpandsLyrics() {
        #expect(MacPlaybackGate.shouldExpandLyrics(isKaraokeOn: true, isLyricsExpanded: false))
        #expect(!MacPlaybackGate.shouldExpandLyrics(isKaraokeOn: false, isLyricsExpanded: false))
    }

    @Test("双击放大歌词：歌词区同样撑满")
    func lyricsExpandedExpandsLyrics() {
        #expect(MacPlaybackGate.shouldExpandLyrics(isKaraokeOn: false, isLyricsExpanded: true))
        #expect(!MacPlaybackGate.shouldExpandLyrics(isKaraokeOn: false, isLyricsExpanded: false))
    }
}

struct MacPlaybackGateLyricsHeightTests {
    // 分隔条拖动高度（2026-11-03）：
    //  - 松手回弹回归：onEnded 曾用拖动起始高度重算 → 松手即回到原值；现在必须保留当前高度
    //  - 抖动回归：DragGesture 默认 .local 空间会随分隔条自身位移污染 translation
    // 这两处手势层无法单测，但 clamp 语义抽纯函数锁定。
    private let container: CGFloat = 900   // 上限 = max(180, 900 - 360) = 540

    @Test("向下拖（translation 为正）：歌词变矮")
    func dragDownShrinks() {
        #expect(MacPlaybackGate.clampedLyricsHeight(
            start: 330, translation: 100, containerHeight: container) == 230)
    }

    @Test("向下拖：不低于最小高度 140")
    func dragDownStopsAtMin() {
        #expect(MacPlaybackGate.clampedLyricsHeight(
            start: 330, translation: 500, containerHeight: container) == 140)
    }

    @Test("向上拖（translation 为负）：歌词变高")
    func dragUpGrows() {
        #expect(MacPlaybackGate.clampedLyricsHeight(
            start: 330, translation: -100, containerHeight: container) == 430)
    }

    @Test("向上拖：不超过容器上限（containerHeight - 播放区最小 360）")
    func dragUpStopsAtMax() {
        #expect(MacPlaybackGate.clampedLyricsHeight(
            start: 330, translation: -1_000, containerHeight: container) == 540)
    }

    @Test("容器很矮：上限走保底 max(180, h - 360)")
    func shortContainerUsesMaxFloor() {
        #expect(MacPlaybackGate.clampedLyricsHeight(
            start: 140, translation: -300, containerHeight: 400) == 180)
    }

    @Test("松手保留当前值：clamp 幂等（覆盖回弹回归）")
    func clampingIsIdempotent() {
        for height in [CGFloat(-10), 0, 140, 200, 330, 540, 900, 10_000] {
            let once = MacPlaybackGate.clampedLyricsHeight(height, containerHeight: container)
            let twice = MacPlaybackGate.clampedLyricsHeight(once, containerHeight: container)
            #expect(once >= 140 && once <= 540)
            #expect(twice == once)
        }
    }
}

/// 面板高度 clamp 语义（2026-11-22；2026-11-22 二次修订）：
/// 拖拽路径继续用 `clampedLyricsHeight`（容器 − 360 只为手感，不代表播放区真实高度）。
/// 窗口缩放的渲染上限改由 `availableLyricsHeight` 实测决定（见 MacPlaybackGateLyricsPanelAvailableTests），
/// 这里锁住的是仍在用的 clamp 语义：下限 140 / 上限 max(180, h − 360) / 幂等。
struct MacPlaybackGateLyricsHeightWindowResizeTests {
    @Test("窗口变小：面板高度被 clamp 收缩")
    func shrinkingWindowClampsPanel() {
        // 600 - 360 = 240 → 330 收到 240
        #expect(MacPlaybackGate.clampedLyricsHeight(330, containerHeight: 600) == 240)
        // 500 - 360 = 140，但保底 180 → 收到 180
        #expect(MacPlaybackGate.clampedLyricsHeight(420, containerHeight: 500) == 180)
    }

    @Test("窗口变大：只受用户设定值约束（不会自动放大）")
    func growingWindowKeepsPanel() {
        #expect(MacPlaybackGate.clampedLyricsHeight(330, containerHeight: 1400) == 330)
    }

    @Test("窗口极矮：仍保留最小高度 140，且不超过保底上限")
    func tinyWindowKeepsMinimum() {
        #expect(MacPlaybackGate.clampedLyricsHeight(330, containerHeight: 300) == 180)
        #expect(MacPlaybackGate.clampedLyricsHeight(100, containerHeight: 1400) == 140)
    }

    @Test("反复 resize 幂等：clamp 结果再 clamp 不变")
    func resizeIsIdempotent() {
        for container in [240.0, 400, 500, 600, 900, 1200] as [CGFloat] {
            let once = MacPlaybackGate.clampedLyricsHeight(330, containerHeight: container)
            let twice = MacPlaybackGate.clampedLyricsHeight(once, containerHeight: container)
            #expect(once >= MacPlaybackGate.lyricsPanelMinHeight)
            #expect(twice == once)
        }
    }
}

/// 面板「实测可用高度」与渲染高度（2026-11-22 高亮行偏下的真根因）：
/// 面板此前只用 `playerSectionMinHeight`（360）估算上限，而播放区真实高度远大于它 →
/// 面板 frame 溢出容器、底部被窗口裁掉；歌词视图的 `GeometryReader` 量到未裁的布局高度 →
/// `scrollTo` 按「假视口」居中，日志 delta=0 而肉眼偏低。上限改为「容器 − 面板上方实测内容高」。
struct MacPlaybackGateLyricsPanelAvailableTests {
    private let minHeight = MacPlaybackGate.lyricsPanelMinHeight // 140

    @Test("可用高度 = 容器 − 面板上方实测内容高（播放区 + 分隔条）")
    func availableSubtractsMeasuredTop() {
        // 实测口径：容器 933、播放区内容固有高 466、分隔条 18 → 933 − 484 = 449
        #expect(MacPlaybackGate.availableLyricsHeight(
            containerHeight: 933, playerTopHeight: 466 + 18) == 449)
    }

    @Test("容器比面板上方内容还矮：可用高度保底 140，不返回负数")
    func tinyContainerFloorsAtMin() {
        #expect(MacPlaybackGate.availableLyricsHeight(containerHeight: 400, playerTopHeight: 484) == 140)
        #expect(MacPlaybackGate.availableLyricsHeight(containerHeight: 0, playerTopHeight: 484) == 140)
    }

    @Test("实测可用大于用户值：渲染用户值（用户意图优先）")
    func availableLargerKeepsUserHeight() {
        #expect(MacPlaybackGate.effectiveLyricsHeight(
            userHeight: 330, available: 449, minHeight: minHeight) == 330)
    }

    @Test("实测可用小于用户值：渲染收窄到可用高度（不再溢出被裁）")
    func availableSmallerClampsToAvailable() {
        #expect(MacPlaybackGate.effectiveLyricsHeight(
            userHeight: 532.6, available: 449, minHeight: minHeight) == 449)
    }

    @Test("可用空间小于最小高度：取最小高度（保底可拖空间）")
    func availableBelowMinFloors() {
        #expect(MacPlaybackGate.effectiveLyricsHeight(
            userHeight: 532.6, available: 100, minHeight: minHeight) == 140)
    }

    @Test("相等边界：可用 == 用户值 → 原值")
    func equalBoundary() {
        #expect(MacPlaybackGate.effectiveLyricsHeight(
            userHeight: 449, available: 449, minHeight: minHeight) == 449)
    }

    @Test("用户值低于最小高度：抬到最小高度（不出现 0 高面板）")
    func userBelowMinFloors() {
        #expect(MacPlaybackGate.effectiveLyricsHeight(
            userHeight: 40, available: 600, minHeight: minHeight) == 140)
    }

    @Test("幂等：渲染结果再算一次不变（布局每轮重算不抖动）")
    func effectiveIsIdempotent() {
        for user in [CGFloat(140), 330, 449, 532.6, 900] {
            for available in [CGFloat(140), 300, 449, 700] {
                let once = MacPlaybackGate.effectiveLyricsHeight(
                    userHeight: user, available: available, minHeight: minHeight)
                let twice = MacPlaybackGate.effectiveLyricsHeight(
                    userHeight: once, available: available, minHeight: minHeight)
                #expect(once >= minHeight)
                #expect(once <= Swift.max(available, minHeight))
                #expect(twice == once)
            }
        }
    }
}
