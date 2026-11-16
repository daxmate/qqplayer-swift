//
//  LyricAlignmentController.swift
//  QQPlayer
//
//  歌词时间轴对齐的 UI 状态机 + 编排（iOS / macOS 共用）。
//  视图只读 `state`，动作只有 start / cancel / revert / dismiss；
//  真实对齐仍走 LyricAlignmentService（这里只负责进度、取消与结果语义）。
//

import Foundation

/// 对齐服务的可测接口：controller 单测注入假实现，生产 = `LyricAlignmentService`。
/// 签名与 `LyricAlignmentService.align` 一致，不改服务行为。
protocol LyricAlignmentReporting: Sendable {
    func align(
        track: Track,
        currentLyrics: Lyrics,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> LyricAlignmentReport
}

extension LyricAlignmentService: LyricAlignmentReporting {}

/// 对齐流程的 UI 状态机（@MainActor 单例，Swift 6 严格并发）。
@MainActor
@Observable
final class LyricAlignmentController {
    /// 阶段（按进度区间映射，文案在视图层）。
    enum Phase: Equatable {
        case installingAssets
        case transcribing
        case aligning
    }

    enum State: Equatable {
        case idle
        case running(progress: Double, phase: Phase)
        /// 对齐完成（已自动写入 aligned 歌词库）。
        case finished(LyricAlignmentReport)
        case failed(message: String)
    }

    static let shared = LyricAlignmentController()

    /// 低质判据（覆盖率下限）：与 `LyricAlignmentAligner` 共用同一常量，避免两个真相。
    static let lowCoverage = LyricAlignmentAligner.lowCoverage
    /// 低质判据（锚点数下限）：命中行少于它视为可用歌词太少。
    static let minAnchors = LyricAlignmentAligner.minAnchors

    /// 视图观察的唯一状态。
    private(set) var state: State = .idle

    /// 当前（或刚完成的）对齐目标曲目：结果页「恢复原时间轴」需要它。
    private(set) var activeStableId: String?

    private let service: any LyricAlignmentReporting
    private let store: AlignedLyricsStore
    /// 对齐产物变化后的刷新动作（默认：清该歌歌词缓存 + 广播 `.lyricsDidChange`）。
    private let onLyricsChanged: @MainActor (String) -> Void
    private var runTask: Task<Void, Never>?
    /// 代次：取消 / 重开都会 +1，旧任务的任何状态写入都按代次丢弃。
    private var runGeneration = 0

    /// - Parameters:
    ///   - service: 对齐服务（测试注入假实现）。
    ///   - store: aligned 歌词库（revert 用；测试注入临时目录）。
    ///   - onLyricsChanged: 产物变化后的刷新回调（测试可注入闭包观察）。
    init(
        service: any LyricAlignmentReporting = LyricAlignmentService.shared,
        store: AlignedLyricsStore = .shared,
        onLyricsChanged: @escaping @MainActor (String) -> Void = LyricAlignmentController.defaultLyricsChanged
    ) {
        self.service = service
        self.store = store
        self.onLyricsChanged = onLyricsChanged
    }

    // MARK: - 派生状态（视图用）

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// 进度 sheet 是否该出现：运行中 / 有结果 / 失败都要展示（完成后等用户关闭）。
    var presentsSheet: Bool {
        switch state {
        case .idle: return false
        case .running, .finished, .failed: return true
        }
    }

    // MARK: - 动作

    /// 开始对齐：成功后写入 aligned 歌词库并触发刷新；取消静默回 idle，其余给可读文案。
    func start(track: Track, lyrics: Lyrics) async {
        runTask?.cancel()
        runGeneration += 1
        let generation = runGeneration
        activeStableId = track.stableId
        state = .running(progress: 0, phase: Self.phase(for: 0))

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await self.service.align(
                    track: track,
                    currentLyrics: lyrics
                ) { [weak self] value in
                    Task { @MainActor in
                        self?.apply(progress: value, generation: generation)
                    }
                }
                guard self.runGeneration == generation else { return }
                self.state = .finished(report)
                self.onLyricsChanged(track.stableId)
            } catch {
                guard self.runGeneration == generation else { return }
                self.state = Self.state(for: error)
            }
        }
        runTask = task
        await task.value
    }

    /// 取消进行中的对齐（引擎侧已有 cancelAndFinishNow 路径）；静默回 idle。
    func cancel() {
        runGeneration += 1
        runTask?.cancel()
        runTask = nil
        if case .running = state { state = .idle }
    }

    /// sheet 被关闭：运行中 = 取消，其余 = 复位。
    func dismiss() {
        if isRunning {
            cancel()
        } else {
            state = .idle
        }
    }

    /// 恢复原歌词时间轴：删除 aligned 产物 + 清该歌歌词缓存 = 回到对齐前的歌词。
    func revert(stableId: String) throws {
        try store.delete(forStableId: stableId)
        onLyricsChanged(stableId)
        state = .idle
    }

    /// 失败态收口（视图侧展示可读文案）。
    func fail(message: String) {
        state = .failed(message: message)
    }

    // MARK: - 纯函数（可单测）

    /// 进度 → 阶段。区间与引擎一致：0…0.15 资源、0.05…0.8 转写、0.85…1 对齐。
    static func phase(for progress: Double) -> Phase {
        if progress < 0.15 { return .installingAssets }
        if progress < 0.85 { return .transcribing }
        return .aligning
    }

    /// 错误 → 视图状态（`cancelled` 静默回 idle）。
    static func state(for error: Error) -> State {
        if let alignmentError = error as? LyricAlignmentError {
            switch alignmentError {
            case .cancelled:
                return .idle
            case .unsupportedSystem:
                return .failed(message: "lyrics.align.error.unsupported".localized)
            case .audioUnreadable:
                return .failed(message: "lyrics.align.error.audio".localized)
            case .lyricsEmpty:
                return .failed(message: "lyrics.align.error.emptyLyrics".localized)
            case .localeUnavailable:
                return .failed(message: "lyrics.align.error.locale".localized)
            case .assetInstallFailed:
                return .failed(message: "lyrics.align.error.assets".localized)
            case .alignmentFailed:
                return .failed(message: "lyrics.align.error.failed".localized)
            }
        }
        if error is CancellationError { return .idle }
        return .failed(message: "lyrics.align.error.generic".localized)
    }

    /// 识别覆盖率（0…1）；无歌词字符时按 0。
    static func matchRate(for report: LyricAlignmentReport) -> Double {
        report.coverage
    }

    /// 低质：锚点不足 **或** 覆盖率不足（任一成立即提示可恢复原时间轴）。
    static func isLowMatch(_ report: LyricAlignmentReport) -> Bool {
        report.matchedCount < minAnchors || report.coverage < lowCoverage
    }

    /// 默认刷新：清该歌歌词内存缓存（对齐/恢复后必须重取）+ 广播通知让播放页重载。
    ///
    /// 顺序是硬要求：**先清缓存再广播**。恢复原时间轴时内存缓存里还躺着 aligned 歌词，
    /// 先广播会让播放页 getLyrics 命中旧缓存（界面不换）。
    static func defaultLyricsChanged(stableId: String) {
        Task {
            await LyricsManager.shared.invalidateLyrics(forStableId: stableId)
            await MainActor.run {
                NotificationCenter.default.post(name: .lyricsDidChange, object: stableId)
            }
        }
    }

    // MARK: - 私有

    private func apply(progress: Double, generation: Int) {
        guard runGeneration == generation else { return }
        guard case .running = state else { return }
        let clamped = min(max(progress, 0), 1)
        state = .running(progress: clamped, phase: Self.phase(for: clamped))
    }
}
