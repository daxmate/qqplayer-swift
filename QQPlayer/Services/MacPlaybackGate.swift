//  MacPlaybackGate.swift
//  QQPlayer
//
//  macOS 播放链路的纯决策逻辑（平台无关，可单测）：
//  - canStartPlayback：play() 的前置条件（audioFile 已加载、非 loading 中、非 loading 态）
//  - segmentPlan：scheduleSegment 的帧范围校验与剩余帧计算
//  - canResumeFromSavedPosition：恢复播放时的位置有效性
//  - shouldHandleSegmentFinished：segment completion 是否应触发曲目结束
//    （seek/play 前 cancelPendingCompletions 使旧 completion 失效的判定核心）
//
//  设计遵循 InterruptionResumePolicy 模式：决策抽纯函数，引擎只执行不决策。
//  2026-08-31 立：macOS 首测暴露"能编译但行为错"类 bug，决策逻辑必须有防回归测试。
//  2026-09-01 增：macOS seek 漏 cancelPendingCompletions → playerNode.stop() 触发旧
//   completion → 误判播完 → handleTrackEnd 停播（用户实测：点歌词/上下句首次不播放，
//   二次点击才播）。判定逻辑上收为纯函数锁定，防再次被拆散。
//

import Foundation

enum MacPlaybackGate {
    /// play() 前置条件：native 路径能否真正开始播放。
    /// - audioFileLoaded：当前已加载音频文件
    /// - isLoadingTrack：加载任务进行中
    /// - playbackState：当前播放状态（.loading 时跳过，避免与加载竞争）
    static func canStartPlayback(audioFileLoaded: Bool, isLoadingTrack: Bool, playbackStateIsLoading: Bool) -> Bool {
        audioFileLoaded && !isLoadingTrack && !playbackStateIsLoading
    }

    /// scheduleSegment 的帧计划。与 PlayerEngine.scheduleSegment 的 guard 链一一对应：
    ///   engine running / startFrame 有效 / remaining > 0 / remaining 不超 AVAudioFrameCount.max
    static func segmentPlan(
        engineIsRunning: Bool,
        startFrame: Int64,
        fileLength: Int64,
        maxFrameCount: Int64
    ) -> SegmentPlanResult {
        guard engineIsRunning else { return .failure(.engineNotRunning) }
        guard startFrame >= 0 && startFrame < fileLength else { return .failure(.invalidStartFrame) }
        let remaining = fileLength - startFrame
        guard remaining > 0 else { return .failure(.noRemainingFrames) }
        guard remaining <= maxFrameCount else { return .failure(.exceedsMaxFrameCount) }
        return .success(frameCount: remaining)
    }

    enum SegmentPlanResult: Equatable {
        case success(frameCount: Int64)
        case failure(SegmentPlanFailure)

        enum SegmentPlanFailure: Equatable {
            case engineNotRunning
            case invalidStartFrame
            case noRemainingFrames
            case exceedsMaxFrameCount
        }
    }

    /// segment completion 是否应触发曲目结束（handleMacSegmentFinished 的判定核心）。
    /// 语义：completion 只属于「当前调度代 + 正在播放 + 当前曲目」时才有效。
    /// - generation：completion 回调携带的调度代（scheduleSegment 时捕获的 scheduleGeneration）
    /// - scheduleGeneration：当前调度代（seek/play 前 cancelPendingCompletions() 会 +1）
    /// - isPlaying：当前是否在播放
    /// - completionTrackId / currentTrackId：completion 所属曲目与当前曲目（nil 兼容）
    ///
    /// 防回归背景（2026-09-01）：macOS seek() 曾漏调 cancelPendingCompletions()，
    /// playerNode.stop() 触发旧 segment 的 completion 时 generation 仍与当前代相等，
    /// 误判"这段播完了"→ handleTrackEnd 停播/切歌，导致"点歌词/上下句首次不播放"。
    static func shouldHandleSegmentFinished(
        generation: UInt64,
        scheduleGeneration: UInt64,
        isPlaying: Bool,
        completionTrackId: String?,
        currentTrackId: String?
    ) -> Bool {
        guard generation == scheduleGeneration, isPlaying else { return false }
        if let completionTrackId, completionTrackId != currentTrackId {
            return false
        }
        return true
    }

    // MARK: - 跟唱大画面布局决策（2026-09-01 用户需求：跟唱时播放区隐藏、歌词撑满）

    /// 跟唱大画面：播放区是否隐藏（跟唱开启时把空间让给歌词区）
    static func shouldHidePlayerSection(isKaraokeOn: Bool) -> Bool {
        isKaraokeOn
    }

    /// 跟唱大画面：歌词区是否撑满整个 detail 区域（非跟唱固定 330 高）
    static func shouldExpandLyrics(isKaraokeOn: Bool) -> Bool {
        isKaraokeOn
    }
}
