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

    @Test("startFrame == 文件末尾（remaining 为 0）：拒绝")
    func zeroRemaining() {
        #expect(MacPlaybackGate.segmentPlan(
            engineIsRunning: true, startFrame: 1000, fileLength: 1000, maxFrameCount: 1_000_000)
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

struct MacPlaybackGateKaraokeLayoutTests {
    // 跟唱大画面布局决策（2026-09-01 用户需求）：播放区隐藏/歌词撑满。
    // 手势交互（双击 toggle）无法单测，但布局决策抽纯函数锁定，防止后续改动悄悄破坏。
    // 2026-09-02：歌词面板常驻（无关闭入口），shouldAutoShowLyrics/lyricsCloseAction 已随关闭入口一起删除。

    @Test("跟唱开启：播放区隐藏，空间让给歌词")
    func karaokeOnHidesPlayerSection() {
        #expect(MacPlaybackGate.shouldHidePlayerSection(isKaraokeOn: true))
        #expect(!MacPlaybackGate.shouldHidePlayerSection(isKaraokeOn: false))
    }

    @Test("跟唱开启：歌词区撑满整个区域")
    func karaokeOnExpandsLyrics() {
        #expect(MacPlaybackGate.shouldExpandLyrics(isKaraokeOn: true))
        #expect(!MacPlaybackGate.shouldExpandLyrics(isKaraokeOn: false))
    }
}
