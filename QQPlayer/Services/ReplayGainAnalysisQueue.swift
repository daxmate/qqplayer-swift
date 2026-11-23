//
//  ReplayGainAnalysisQueue.swift
//  QQPlayer
//
//  ReplayGain 后台补算队列（Phase 2）：对缺 ReplayGain 数据的曲目本地分析，
//  专辑模式在整张可分析时算 album gain。
//
//  约束（任务包）：
//   - 低优先级、可暂停 / 取消、可续跑；不阻塞 UI 与播放；
//   - 结果只写本地 DB，绝不改写用户音频文件标签；
//   - 失败曲目记状态并跳过，不无限重试；
//   - 重新扫描曲库时按 stableId 保留已分析结果（见 LibraryIndexer.saveParsedFile）。
//
//  并发：所有 I/O（DB 读写 + 阻塞分析）都在 detached 后台任务里做，
//  主线程只负责状态位 / 进度计数，保证不卡 UI、不干扰播放。
//

import Foundation
import Observation

@MainActor
@Observable
final class ReplayGainAnalysisQueue {
    static let shared = ReplayGainAnalysisQueue()

    /// 是否正在跑。
    private(set) var isRunning = false
    /// 用户是否暂停（跨启动记住）。
    private(set) var isPaused: Bool
    /// 已分析曲目数 / 总数（进度显示）。
    private(set) var analyzedCount = 0
    private(set) var totalCount = 0

    /// 是否已由 App 启动路径激活（测试 / 未启动时不跑）。
    @ObservationIgnored private var isActivated = false
    @ObservationIgnored private var runner: Task<Void, Never>?
    /// 当前曲目优先队列（首次播放时立即补算当前曲）。
    @ObservationIgnored private var priorityStableIds: [String] = []

    private static let batchSize = 10

    private init() {
        isPaused = UserDefaults.standard.bool(forKey: ReplayGainSettings.StorageKey.analysisPaused)
    }

    /// 进度百分比（total == 0 → 0）。
    var progress: Double {
        guard totalCount > 0 else { return 0 }
        return min(1.0, Double(analyzedCount) / Double(totalCount))
    }

    // MARK: - 控制

    /// App 启动路径调用：允许后台补算开始跑（幂等）。
    func activate() {
        isActivated = true
        resumeIfNeeded()
    }

    /// 当前曲目缺数据时入队（优先处理）。
    func enqueue(track: Track) {
        guard isActivated else { return }
        guard ReplayGainManager.shared.settings.analyzeMissingTracks else { return }
        if !priorityStableIds.contains(track.stableId) {
            priorityStableIds.append(track.stableId)
        }
        startIfNeeded()
    }

    /// 设置里打开「自动补算」后调用：未暂停则恢复。
    func resumeIfNeeded() {
        guard !isPaused else { return }
        startIfNeeded()
    }

    /// 开始补算（幂等）。
    func startIfNeeded() {
        guard isActivated else { return }
        guard ReplayGainManager.shared.settings.analyzeMissingTracks, !isPaused else { return }
        guard runner == nil else { return }
        isRunning = true
        runner = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func pause() {
        setPaused(true)
        runner?.cancel()
        runner = nil
        isRunning = false
    }

    func resume() {
        setPaused(false)
        startIfNeeded()
    }

    private func setPaused(_ paused: Bool) {
        isPaused = paused
        UserDefaults.standard.set(paused, forKey: ReplayGainSettings.StorageKey.analysisPaused)
    }

    // MARK: - 主循环

    private func runLoop() async {
        defer {
            runner = nil
            isRunning = false
            await refreshProgress()
        }

        // 先把「已分析 / 总数」刷出来，设置页进度条立即有底数
        await refreshProgress()

        while !Task.isCancelled {
            let albumHandled = await analyzeNextAlbumIfNeeded()
            let priority = priorityStableIds
            priorityStableIds.removeAll()
            let batch = await Self.nextBatch(priority: priority, limit: Self.batchSize)
            if batch.isEmpty {
                if !albumHandled { break }
                continue
            }
            for track in batch {
                if Task.isCancelled { break }
                let gain = await Self.analyze(track: track)
                await Self.persist(track: track, gain: gain)
                analyzedCount += 1
                ReplayGainManager.shared.refreshCurrentTrackIfNeeded(stableId: track.stableId)
            }
        }
    }

    private func refreshProgress() async {
        if let progress = await Self.fetchProgress() {
            analyzedCount = progress.analyzed
            totalCount = progress.total
        }
    }

    // MARK: - 后台任务（detached：DB + 分析均不占主线程）

    /// 取一批待分析曲目：优先队列在前，其余按库里顺序。
    private nonisolated static func nextBatch(priority: [String], limit: Int) async -> [Track] {
        await Task.detached(priority: .utility) {
            let db = DatabaseManager.shared
            var candidates: [Track] = []
            for stableId in priority where candidates.count < limit {
                if let track = try? db.getTrack(byStableId: stableId),
                   track.replaygainTrackGain == nil,
                   track.replaygainAnalysisState != ReplayGainAnalysisState.failed.rawValue {
                    candidates.append(track)
                }
            }
            if candidates.count < limit,
               let fetched = try? db.tracksNeedingReplayGainAnalysis(limit: limit - candidates.count) {
                let existing = Set(candidates.map(\.stableId))
                candidates.append(contentsOf: fetched.filter { !existing.contains($0.stableId) })
            }
            return candidates
        }.value
    }

    private nonisolated static func analyze(track: Track) async -> ReplayGainMath.Gains? {
        // 存储形态路径 → 绝对 URL（曲库内是相对 Documents/Music 的路径）
        let url = LibraryRoot.absoluteURL(forStoredPath: track.path)
        return await Task.detached(priority: .utility) {
            try? ReplayGainTagReader.analyzeTrack(url: url)
        }.value
    }

    private nonisolated static func persist(track: Track, gain: ReplayGainMath.Gains?) async {
        await Task.detached(priority: .utility) {
            let db = DatabaseManager.shared
            if let gain {
                try? db.recordReplayGainAnalysis(stableId: track.stableId, gains: gain, source: .analyzed)
            } else {
                AppLog.warn(.general, "⚠️ ReplayGain 分析失败（记状态跳过）: \(track.path)")
                try? db.markReplayGainAnalysisFailed(stableId: track.stableId)
            }
        }.value
    }

    private nonisolated static func fetchProgress() async -> (analyzed: Int, total: Int)? {
        await Task.detached(priority: .utility) {
            try? DatabaseManager.shared.replayGainAnalysisProgress()
        }.value
    }

    /// 专辑补算：整张曲目齐了才算 album gain；返回是否处理了专辑（用于循环控制）。
    private func analyzeNextAlbumIfNeeded() async -> Bool {
        guard ReplayGainManager.shared.settings.mode == .album else { return false }
        guard let albumId = await Self.nextAlbumId() else { return false }
        let tracks = await Self.tracksForAlbum(albumId: albumId)
        guard !tracks.isEmpty else { return true }
        let urls = tracks.map { LibraryRoot.absoluteURL(forStoredPath: $0.path) }
        let gains: ReplayGainMath.Gains? = await Task.detached(priority: .utility) {
            try? ReplayGainTagReader.analyzeAlbum(urls: urls)
        }.value
        await Task.detached(priority: .utility) {
            try? DatabaseManager.shared.recordAlbumReplayGainAnalysis(albumId: albumId, gains: gains)
        }.value
        for track in tracks {
            ReplayGainManager.shared.refreshCurrentTrackIfNeeded(stableId: track.stableId)
        }
        return true
    }

    private nonisolated static func nextAlbumId() async -> Int64? {
        await Task.detached(priority: .utility) {
            (try? DatabaseManager.shared.albumIdsNeedingReplayGainAnalysis(limit: 1))?.first
        }.value
    }

    private nonisolated static func tracksForAlbum(albumId: Int64) async -> [Track] {
        await Task.detached(priority: .utility) {
            (try? DatabaseManager.shared.tracksForAlbumReplayGain(albumId: albumId)) ?? []
        }.value
    }
}
