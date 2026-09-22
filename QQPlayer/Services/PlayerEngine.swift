//  PlayerEngine.swift
//  QQPlayer
//
//  Audio playback engine using AVAudioEngine for high-resolution FLAC playback
//
//  Split into domain extensions (behavior-identical refactor):
//    PlayerEngine+AudioSession.swift     session/interruption/route/reset
//    PlayerEngine+PlaybackControl.swift  loadTrack/play/pause/stop/seek
//    PlayerEngine+AudioScheduling.swift  gapless/preload/background monitor
//    PlayerEngine+Queue.swift            queue/order mode/shuffle
//    PlayerEngine+NowPlaying.swift       now playing info/widget/remote commands
//    PlayerEngine+SFB.swift              SFBAudioEngine integration
//    PlaybackModels.swift                PlaybackOrderMode/PlaybackProgress/PlayerError
//
import AVFoundation
import Combine
import Foundation
import GRDB
import MediaPlayer
import Observation
#if os(iOS)
    import UIKit
#endif

/// 音频播放引擎（iOS + macOS 共用，AVAudioEngine 高解析播放）。
/// 2026-09-20 批 6-6：`ObservableObject` → `@Observable`。10 个原 `@Published` 保持**被追踪**，
/// 其余存储属性一律 `@ObservationIgnored`（不进观察图）——判据见账本§批 6-6：视图 `body`
/// 只读这 10 个属性 + `progress.playbackTime`，逐条核对过 `nextTrack` / `originalQueue` /
/// `usingSFBEngine` / `audioEngine` 四个边界属性（均非 body 读取，不承担重绘依赖）。
@MainActor
@Observable
class PlayerEngine: NSObject {
    static let shared = PlayerEngine()

    var currentTrack: Track? {
        didSet { currentTrackSubject.send(currentTrack) }
    }

    var isPlaying = false {
        didSet { isPlayingSubject.send(isPlaying) }
    }

    // MARK: - 非视图消费者的观察入口（批 6-3）

    /// `currentTrack` 的变化信号。**非视图消费者的唯一观察入口**（CarPlay 场景根等）。
    /// 2026-09-20 批 6-6：`@Observable` 下 `$currentTrack` 合成投影**编译期消失** ⇒ 内芯换成
    /// `CurrentValueSubject`（由上面的 `didSet` 喂）——**消费者一行都没改**（6-3 立此入口就是为了这天）。
    /// 形状契约：`NonViewObservationRatchet`（生产码不得再跨文件写 `<Target>.shared.$…`）。
    @ObservationIgnored private let currentTrackSubject = CurrentValueSubject<Track?, Never>(nil)

    var currentTrackPublisher: AnyPublisher<Track?, Never> {
        currentTrackSubject.eraseToAnyPublisher()
    }

    /// `isPlaying` 的变化信号（同上）。
    @ObservationIgnored private let isPlayingSubject = CurrentValueSubject<Bool, Never>(false)

    var isPlayingPublisher: AnyPublisher<Bool, Never> {
        isPlayingSubject.eraseToAnyPublisher()
    }
    @ObservationIgnored let progress = PlaybackProgress()
    var playbackTime: TimeInterval {
        get { progress.playbackTime }
        set { progress.playbackTime = newValue }
    }
    /// 中断诊断（2026-08-30）：playbackTime 最后一次由前台 UI timer 刷新的时刻。
    /// 后台/锁屏时 timer 不跑，此时间戳与 Date() 的间隔 = playbackTime 的"冻结时长"，
    /// 用于判断中断 .began 保存的位置是否是过期的冻结值（从头播根因排查）。
    @ObservationIgnored var playbackTimeUpdatedAt = Date()
    /// 中断诊断（2026-08-30 中断后从头播）：引擎存活时最后读取到的实时播放位置缓存。
    /// 背景：后台/锁屏时 0.25s UI timer 不跑 → playbackTime 冻结；系统音频抢占时
    /// interruption .began 通知延迟到达 → 引擎已停，currentNodeSampleTime() 失效，
    /// 保存/恢复只能读到冻结值 → 可能从头播。此缓存由 currentTimeForCurrentNativeFile()
    /// 成功路径（前台 timer / 后台 0.5s checkIfTrackEnded / pause / seek 等）持续刷新，
    /// 中断保存/恢复时用它兜底。⚠️ fallback 路径（sampleTime 为 nil）绝不更新此缓存，
    /// 否则会把冻结值污染进缓存。
    /// 注：setter 为 internal（同 playbackTimeUpdatedAt 模式）——private(set) 的 setter
    /// 仅限声明文件内可写，而刷新发生在跨文件的 extension 中，会编译失败。
    @ObservationIgnored var lastKnownPlaybackPosition: TimeInterval = 0
    @ObservationIgnored var lastKnownPlaybackPositionUpdatedAt = Date()
    var duration: TimeInterval = 0
    var playbackState: PlaybackState = .stopped

    /// 播放失败的用户可见文案（2026-09-12 审计 P8）。
    /// 背景：载入失败（如 DSD 不被任何引擎支持）以前只 print，playTrack 拿到 false
    /// 直接 return → 用户侧表现是"点了不播"、无任何提示。载入开始/成功时清空，
    /// 失败时设置并在几秒后自动消失（不堵界面）。
    private(set) var playbackErrorMessage: String?
    var playbackQueue: [Track] = []
    var currentIndex = 0
    var isRepeating = false
    var isShuffled = false
    var isLoopingSong = false

    @ObservationIgnored var originalQueue: [String] = []
    @ObservationIgnored private let maxPersistedQueueSize = 2000

    // Generation token to prevent stale completion handlers from firing
    /// 调度代（seek/play 前 `cancelPendingCompletions()` 递增；语义见 `PlaybackGeneration`）。
    @ObservationIgnored var scheduleGeneration = PlaybackGeneration()

    @ObservationIgnored var seekTimeOffset: TimeInterval = 0
    @ObservationIgnored var lastSampleRate: Double = 0

    @ObservationIgnored lazy var audioEngine = AVAudioEngine()
    @ObservationIgnored lazy var playerNode = AVAudioPlayerNode()
    /// 倍速音频节点（跟唱模式变速不变调：rate 档位，pitch 保持 0）
    @ObservationIgnored lazy var timePitchNode = AVAudioUnitTimePitch()
    @ObservationIgnored var audioFile: AVAudioFile?
    @ObservationIgnored var playbackTimer: Timer?

    // Gapless playback support
    @ObservationIgnored var nextAudioFile: AVAudioFile?
    @ObservationIgnored var nextTrack: Track?
    @ObservationIgnored var nextTrackIndex: Int?
    @ObservationIgnored var isPreloadingNext = false
    @ObservationIgnored var gaplessScheduled = false
    @ObservationIgnored var preloadNextTask: Task<Void, Never>?
    @ObservationIgnored var nodeTimelineStartSampleTime: AVAudioFramePosition = 0
    @ObservationIgnored var nextTimelineStartSampleTime: AVAudioFramePosition?
    @ObservationIgnored var engineConfigurationRecoveryTask: Task<Void, Never>?
    // NotificationCenter may invoke audio callbacks on Core Audio's private
    // queues. Keep block-observer tokens so every callback can explicitly hop
    // to MainActor before it touches player state.
    @ObservationIgnored nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []

    // SFBAudioEngine integration
    @ObservationIgnored lazy var sfbAudioManager = SFBAudioEngineManager.shared
    @ObservationIgnored var usingSFBEngine = false
    var isUsingSFBEngine: Bool { usingSFBEngine }
    // EQ integration
    @ObservationIgnored let eqManager = EQManager.shared

    @ObservationIgnored var isLoadingTrack = false
    @ObservationIgnored var currentLoadTask: Task<Bool, Never>?
    /// 失败提示的自动清除任务（重复上报时取消上一个，见 reportPlaybackFailure）
    @ObservationIgnored private var playbackErrorClearTask: Task<Void, Never>?
    /// 载入代（切歌载入递增；语义见 `PlaybackGeneration`）。
    @ObservationIgnored var loadGeneration = PlaybackGeneration()
    @ObservationIgnored var hasRestoredState = false
    @ObservationIgnored var hasSetupAudioEngine = false
    @ObservationIgnored var hasSetupAudioSession = false
    @ObservationIgnored var hasSetupSiriBackgroundSession = false
    @ObservationIgnored var isAudioSessionInterrupted = false
    @ObservationIgnored var wasPlayingBeforeInterruption = false
    /// Set when the current interruption is accompanied by the output device
    /// disappearing (headphones unplugged, Bluetooth disconnected). Scoped to a
    /// single interruption: cleared on .began, consulted on .ended. iOS 17+
    /// reports an unplug as an *interruption* whose .ended carries
    /// .shouldResume, so without this the app would resume into the speaker.
    @ObservationIgnored var outputDeviceBecameUnavailable = false
    #if os(iOS)
        @ObservationIgnored var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    @ObservationIgnored var isInBackground = false
    @ObservationIgnored var hasSetupRemoteCommands = false
    @ObservationIgnored nonisolated(unsafe) var hasSetupAudioSessionNotifications = false
    @ObservationIgnored var backgroundCheckTimer: Timer?

    // Artwork caching
    @ObservationIgnored var cachedArtwork: MPMediaItemArtwork?
    @ObservationIgnored var cachedArtworkTrackId: String?
    @ObservationIgnored var artworkLoadTask: Task<Void, Never>?
    @ObservationIgnored var artworkLoadTaskTrackId: String?
    @ObservationIgnored var cachedNowPlayingArtistTrackId: String?
    @ObservationIgnored var cachedNowPlayingArtistName: String?

    // Security-scoped resource tracking for external files
    @ObservationIgnored var currentSecurityScopedURL: URL?

    @ObservationIgnored let databaseManager = DatabaseManager.shared

    // Enhanced Control Center synchronization (replaces MPNowPlayingSession approach)

    // Silent keepalive used only while explicitly paused in the background.
    // System output volume is already applied by iOS; polling outputVolume and
    // mirroring it onto the mixer caused synchronous audio-session XPC calls on
    // the main thread and effectively applied volume twice.
    @ObservationIgnored var pausedSilentPlayer: AVAudioPlayer?

    enum PlaybackState {
        case stopped
        case playing
        case paused
        case loading
    }

    /// 上报一次播放失败（自动清除任务同源：重复上报会取消上一个清除任务）。
    func reportPlaybackFailure(_ message: String) {
        playbackErrorMessage = message
        playbackErrorClearTask?.cancel()
        playbackErrorClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled else { return }
            self?.playbackErrorMessage = nil
        }
    }

    /// 清空播放失败提示（载入开始/成功时调用）。
    func clearPlaybackFailure() {
        playbackErrorClearTask?.cancel()
        playbackErrorClearTask = nil
        playbackErrorMessage = nil
    }

    private override init() {
        super.init()
        // Don't set up audio engine immediately - defer until first playback
        // setupAudioEngine()
        // Don't set up audio session immediately - defer until first playback
        // setupAudioSession()
        // Don't set up audio session notifications immediately - defer until first playback
        // setupAudioSessionNotifications()
        // Don't set up remote commands immediately - defer until first playback
        // setupRemoteCommands()
        setupPeriodicStateSaving()
    }

    // MARK: - Playback Control

    /// 当前倍速（KaraokeController 驱动；接入 AVAudioUnitTimePitch 由跟唱任务实现）
    @ObservationIgnored var currentPlaybackRate: Double = 1.0

    /// 设置播放倍速（0.5-1.0 慢速档；跟唱模式专用）。
    /// 主引擎路径：AVAudioUnitTimePitch.rate（变速不变调）；SFBAudioEngine 路径暂不支持。

    @ObservationIgnored var lastControlCenterUpdate: TimeInterval = 0

    // MARK: - State Persistence

    func setupBackgroundSessionForSiri() {
        #if os(iOS)
            // When Siri launches the app, it bypasses normal lifecycle events
            // This method manually sets up the background session that would normally
            // happen via handleWillResignActive() and handleDidEnterBackground()

            AppLog.info(.general, "🎤 Setting up background session for Siri-initiated playback")

            // Check app state to confirm we're in background
            let appState = UIApplication.shared.applicationState
            AppLog.info(.general, "🎤 App state: \(appState == .background ? "background" : appState == .inactive ? "inactive" : "active")")

            // Mark that we've set up Siri background session
            hasSetupSiriBackgroundSession = true

            // Set up audio session for background (same as handleWillResignActive)
            // But don't re-grab if interrupted by alarm/call
            guard !isAudioSessionInterrupted else {
                AppLog.warn(.general, "🎧 Audio session interrupted (alarm/call) - skipping Siri background session keepalive")
                return
            }
            do {
                // Don't call setCategory here - changing category/options on a live
                // session forces a hardware reconfiguration that stops playback
                try AVAudioSession.sharedInstance().setActive(true, options: [])
                AppLog.info(.general, "🎧 Session keepalive on resign active - success")
            } catch {
                AppLog.error(.general, "❌ Session keepalive on resign active failed: \(error)")
            }

            // Background diagnostic and state saving (same as handleDidEnterBackground)
            let backgroundTime = UIApplication.shared.backgroundTimeRemaining
            AppLog.info(.general, "🔍 DIAGNOSTIC - backgroundTimeRemaining: \(backgroundTime)")

            // Stop all UI timers since we're in background
            suspendUITimersForBackground()

            // Save player state
            savePlayerState()
        #else
            // macOS: no Siri-initiated background launch or background session
            // concept; audio keeps playing on the default output device.
            AppLog.info(.general, "ℹ️ setupBackgroundSessionForSiri: no-op on macOS")
        #endif
    }

    func savePlayerState() {
        guard let currentTrack = currentTrack else {
            AppLog.warn(.general, "🚫 No current track to save state for")
            return
        }

        let playbackQueueTrackIds = playbackQueue.map { $0.stableId }
        let (cappedQueueTrackIds, cappedCurrentIndex) = cappedTrackIdsForPersistence(
            playbackQueueTrackIds,
            currentIndex: currentIndex
        )
        let originalQueueCurrentIndex = originalQueue.firstIndex(of: currentTrack.stableId) ?? 0
        let (cappedOriginalQueueTrackIds, _) = cappedTrackIdsForPersistence(
            originalQueue,
            currentIndex: originalQueueCurrentIndex
        )

        // Same reason as the interruption handler: playbackTime is only
        // refreshed by the foreground UI timer, so while backgrounded it goes
        // stale. Persist the live render position instead, or a track playing
        // with the screen locked is restored minutes behind where it actually is.
        let positionToPersist = isPlaying ? nowPlayingElapsedTime() : playbackTime

        let playerState: [String: Any] = [
            "currentTrackStableId": currentTrack.stableId,
            "playbackTime": positionToPersist,
            "isPlaying": false, // Always save as paused to prevent auto-play on launch
            "queueTrackIds": cappedQueueTrackIds,
            "currentIndex": cappedCurrentIndex,
            "isRepeating": isRepeating,
            "isShuffled": isShuffled,
            "isLoopingSong": isLoopingSong,
            "originalQueueTrackIds": cappedOriginalQueueTrackIds,
            "lastSavedAt": Date(),
        ]

        UserDefaults.standard.set(playerState, forKey: "QQPlayerState")
        UserDefaults.standard.synchronize()
        AppLog.info(.general, "✅ Player state saved to UserDefaults (offline, per-device)")

        // S2-T12+（2026-09-15）：跨端续播（同步面板开关，默认关）。
        // 关 = `recordIfEnabled` 直接 return：不读设置外的任何东西、不碰 DB、不写 outbox。
        PlaybackPositionCapture.recordIfEnabled(
            trackStableId: currentTrack.stableId,
            positionMs: Int64(positionToPersist * 1000),
            enabled: DeleteSettings.load().syncPlaybackPositionEnabled
        )
    }

    private func cappedTrackIdsForPersistence(_ trackIds: [String], currentIndex: Int) -> ([String], Int) {
        guard !trackIds.isEmpty else { return ([], 0) }
        guard trackIds.count > maxPersistedQueueSize else {
            let safeIndex = max(0, min(currentIndex, trackIds.count - 1))
            return (trackIds, safeIndex)
        }

        let halfWindow = maxPersistedQueueSize / 2
        var start = max(0, currentIndex - halfWindow)
        let end = min(trackIds.count, start + maxPersistedQueueSize)
        start = max(0, end - maxPersistedQueueSize)

        let cappedTrackIds = Array(trackIds[start ..< end])
        let adjustedIndex = max(0, min(currentIndex - start, cappedTrackIds.count - 1))
        return (cappedTrackIds, adjustedIndex)
    }

    func ensurePlayerStateRestored() async {
        guard !hasRestoredState else { return }
        hasRestoredState = true

        // Only load the audio file if we have a current track from UI restoration
        if let currentTrack = currentTrack {
            AppLog.info(.general, "🔄 Loading audio for restored track: \(currentTrack.title)")
            let savedPosition = playbackTime // Save the position before loadTrack
            await loadTrack(currentTrack, preservePlaybackTime: true)

            // Restore the playback position after loading (if position was saved)
            if savedPosition > 0 {
                AppLog.info(.general, "🔄 Seeking to restored position: \(savedPosition)s")
                await seek(to: savedPosition)
                AppLog.info(.general, "✅ Restored position: \(savedPosition)s")
            }
        }
    }

    func restoreUIStateOnly() async {
        guard let playerStateDict = UserDefaults.standard.dictionary(forKey: "QQPlayerState") else {
            AppLog.info(.general, "📭 No saved player state found in UserDefaults")
            return
        }

        guard let lastSavedAt = playerStateDict["lastSavedAt"] as? Date else {
            AppLog.warn(.general, "🚫 Invalid saved state format")
            return
        }

        AppLog.info(.general, "🔄 Restoring UI state only from \(lastSavedAt)")

        // Don't restore if the saved state is too old (more than 7 days)
        let daysSinceLastSave = Date().timeIntervalSince(lastSavedAt) / (24 * 60 * 60)
        if daysSinceLastSave > 7 {
            AppLog.warn(.general, "⏰ Saved state is too old (\(Int(daysSinceLastSave)) days), skipping restore")
            return
        }

        // Find the current track by stable ID
        guard let currentTrackStableId = playerStateDict["currentTrackStableId"] as? String else {
            AppLog.warn(.general, "🚫 No current track in saved state")
            return
        }

        do {
            let track = try DatabaseManager.shared.read { db in
                try Track.filter(Column("stable_id") == currentTrackStableId).fetchOne(db)
            }

            guard let restoredTrack = track else {
                AppLog.warn(.general, "🚫 Could not find saved track with ID: \(currentTrackStableId)")
                return
            }

            // Restore queue by finding tracks with stable IDs
            let queueTrackIds = playerStateDict["queueTrackIds"] as? [String] ?? []
            let originalQueueTrackIds = playerStateDict["originalQueueTrackIds"] as? [String] ?? []

            let queueTracks = try DatabaseManager.shared.getTracksByStableIdsPreservingOrder(queueTrackIds)
            let originalQueueTracks = try DatabaseManager.shared.getTracksByStableIdsPreservingOrder(originalQueueTrackIds)

            // Restore UI state only - no audio loading
            await MainActor.run {
                self.playbackQueue = queueTracks.isEmpty ? [restoredTrack] : queueTracks
                self.originalQueue = originalQueueTracks.isEmpty ? [restoredTrack.stableId] : originalQueueTracks.map { $0.stableId }

                let savedIndex = playerStateDict["currentIndex"] as? Int ?? 0
                self.currentIndex = max(0, min(savedIndex, self.playbackQueue.count - 1))

                self.isRepeating = playerStateDict["isRepeating"] as? Bool ?? false
                self.isShuffled = playerStateDict["isShuffled"] as? Bool ?? false
                self.isLoopingSong = playerStateDict["isLoopingSong"] as? Bool ?? false
                self.currentTrack = restoredTrack

                // Validate restored state consistency
                if self.isLoopingSong && self.playbackQueue.count == 1 {
                    AppLog.info(.general, "✅ Loop song mode validated with single track queue")
                } else if self.isLoopingSong {
                    AppLog.warn(.general, "⚠️ Loop song mode with multi-track queue - this is fine")
                }

                // Additional validation for shuffle state
                if !self.isShuffled {
                    // When not shuffled, ensure currentIndex points to the actual currentTrack
                    if let currentTrack = self.currentTrack,
                       self.currentIndex < self.playbackQueue.count,
                       self.playbackQueue[self.currentIndex].stableId != currentTrack.stableId {
                        // Find the correct index for the current track
                        if let correctIndex = self.playbackQueue.firstIndex(where: { $0.stableId == currentTrack.stableId }) {
                            AppLog.warn(.general, "⚠️ Fixed currentIndex from \(self.currentIndex) to \(correctIndex) for non-shuffled queue")
                            self.currentIndex = correctIndex
                        } else {
                            AppLog.warn(.general, "⚠️ Current track not found in queue, resetting to index 0")
                            self.currentIndex = 0
                        }
                    }
                }

                // Set saved position for UI display
                let savedTime = playerStateDict["playbackTime"] as? TimeInterval ?? 0
                self.playbackTime = savedTime

                // Set duration from track metadata for UI display
                if let durationMs = restoredTrack.durationMs {
                    self.duration = Double(durationMs) / 1000.0 // Convert ms to seconds
                } else {
                    self.duration = 0
                }

                // Set playback state to stopped so it doesn't show as playing
                self.playbackState = .stopped
                self.isPlaying = false

                AppLog.info(.general, "✅ UI state restored - track: \(restoredTrack.title), position: \(savedTime)s, duration: \(self.duration)s (no audio loaded)")

                // Normalize index and track after restoration
                self.normalizeIndexAndTrack()
            }

        } catch {
            AppLog.error(.general, "❌ Failed to restore UI state: \(error)")
        }
    }

    // restorePlayerState() 已删除（2026-09-12 审计死代码 ⚰️-1）：全仓 grep 仅命中定义处、零调用方，
    // 且与 restoreUIStateOnly()（唯一在用的恢复入口，只恢复 UI 不载音频）功能重叠；
    // 需要时从 git 历史取回。

    private func setupPeriodicStateSaving() {
        // Save state every 30 seconds while playing, and on important events
        Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                if self?.isPlaying == true && self?.currentTrack != nil {
                    self?.savePlayerState()
                }
            }
        }
    }

    deinit {
        // Note: Cannot access main actor properties or methods in deinit
        // State saving is handled by app lifecycle notifications instead

        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}
