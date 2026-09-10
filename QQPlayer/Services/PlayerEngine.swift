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
#if os(iOS)
    import UIKit
#endif

@MainActor
class PlayerEngine: NSObject, ObservableObject {
    static let shared = PlayerEngine()

    @Published var currentTrack: Track?
    @Published var isPlaying = false
    let progress = PlaybackProgress()
    var playbackTime: TimeInterval {
        get { progress.playbackTime }
        set { progress.playbackTime = newValue }
    }
    /// 中断诊断（2026-08-30）：playbackTime 最后一次由前台 UI timer 刷新的时刻。
    /// 后台/锁屏时 timer 不跑，此时间戳与 Date() 的间隔 = playbackTime 的"冻结时长"，
    /// 用于判断中断 .began 保存的位置是否是过期的冻结值（从头播根因排查）。
    var playbackTimeUpdatedAt = Date()
    /// 中断诊断（2026-08-30 中断后从头播）：引擎存活时最后读取到的实时播放位置缓存。
    /// 背景：后台/锁屏时 0.25s UI timer 不跑 → playbackTime 冻结；系统音频抢占时
    /// interruption .began 通知延迟到达 → 引擎已停，currentNodeSampleTime() 失效，
    /// 保存/恢复只能读到冻结值 → 可能从头播。此缓存由 currentTimeForCurrentNativeFile()
    /// 成功路径（前台 timer / 后台 0.5s checkIfTrackEnded / pause / seek 等）持续刷新，
    /// 中断保存/恢复时用它兜底。⚠️ fallback 路径（sampleTime 为 nil）绝不更新此缓存，
    /// 否则会把冻结值污染进缓存。
    /// 注：setter 为 internal（同 playbackTimeUpdatedAt 模式）——private(set) 的 setter
    /// 仅限声明文件内可写，而刷新发生在跨文件的 extension 中，会编译失败。
    var lastKnownPlaybackPosition: TimeInterval = 0
    var lastKnownPlaybackPositionUpdatedAt = Date()
    @Published var duration: TimeInterval = 0
    @Published var playbackState: PlaybackState = .stopped
    @Published var playbackQueue: [Track] = []
    @Published var currentIndex = 0
    @Published var isRepeating = false
    @Published var isShuffled = false
    @Published var isLoopingSong = false

    var originalQueue: [String] = []
    private let maxPersistedQueueSize = 2000

    // Generation token to prevent stale completion handlers from firing
    var scheduleGeneration: UInt64 = 0

    var seekTimeOffset: TimeInterval = 0
    var lastSampleRate: Double = 0

    lazy var audioEngine = AVAudioEngine()
    lazy var playerNode = AVAudioPlayerNode()
    /// 倍速音频节点（跟唱模式变速不变调：rate 档位，pitch 保持 0）
    lazy var timePitchNode = AVAudioUnitTimePitch()
    var audioFile: AVAudioFile?
    private var playbackStrategy: PlaybackRouter.PlaybackStrategy?
    var playbackTimer: Timer?

    // Gapless playback support
    var nextAudioFile: AVAudioFile?
    var nextTrack: Track?
    var nextTrackIndex: Int?
    var isPreloadingNext = false
    var gaplessScheduled = false
    var preloadNextTask: Task<Void, Never>?
    var nodeTimelineStartSampleTime: AVAudioFramePosition = 0
    var nextTimelineStartSampleTime: AVAudioFramePosition?
    var engineConfigurationRecoveryTask: Task<Void, Never>?
    // NotificationCenter may invoke audio callbacks on Core Audio's private
    // queues. Keep block-observer tokens so every callback can explicitly hop
    // to MainActor before it touches player state.
    nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []

    // SFBAudioEngine integration
    lazy var sfbAudioManager = SFBAudioEngineManager.shared
    var usingSFBEngine = false
    var isUsingSFBEngine: Bool { usingSFBEngine }
    // EQ integration
    let eqManager = EQManager.shared

    var isLoadingTrack = false
    var currentLoadTask: Task<Bool, Never>?
    var loadGeneration: UInt64 = 0
    var hasRestoredState = false
    var hasSetupAudioEngine = false
    var hasSetupAudioSession = false
    var hasSetupSiriBackgroundSession = false
    var isAudioSessionInterrupted = false
    var wasPlayingBeforeInterruption = false
    /// Set when the current interruption is accompanied by the output device
    /// disappearing (headphones unplugged, Bluetooth disconnected). Scoped to a
    /// single interruption: cleared on .began, consulted on .ended. iOS 17+
    /// reports an unplug as an *interruption* whose .ended carries
    /// .shouldResume, so without this the app would resume into the speaker.
    var outputDeviceBecameUnavailable = false
    #if os(iOS)
        var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    #endif
    var isInBackground = false
    var hasSetupRemoteCommands = false
    nonisolated(unsafe) var hasSetupAudioSessionNotifications = false
    var backgroundCheckTimer: Timer?

    // Artwork caching
    var cachedArtwork: MPMediaItemArtwork?
    var cachedArtworkTrackId: String?
    var artworkLoadTask: Task<Void, Never>?
    var artworkLoadTaskTrackId: String?
    var cachedNowPlayingArtistTrackId: String?
    var cachedNowPlayingArtistName: String?

    // Security-scoped resource tracking for external files
    var currentSecurityScopedURL: URL?

    let databaseManager = DatabaseManager.shared

    // Enhanced Control Center synchronization (replaces MPNowPlayingSession approach)

    // Silent keepalive used only while explicitly paused in the background.
    // System output volume is already applied by iOS; polling outputVolume and
    // mirroring it onto the mixer caused synchronous audio-session XPC calls on
    // the main thread and effectively applied volume twice.
    var pausedSilentPlayer: AVAudioPlayer?

    enum PlaybackState {
        case stopped
        case playing
        case paused
        case loading
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
    var currentPlaybackRate: Double = 1.0

    /// 设置播放倍速（0.5-1.0 慢速档；跟唱模式专用）。
    /// 主引擎路径：AVAudioUnitTimePitch.rate（变速不变调）；SFBAudioEngine 路径暂不支持。

    var lastControlCenterUpdate: TimeInterval = 0

    // MARK: - State Persistence

    func setupBackgroundSessionForSiri() {
        #if os(iOS)
            // When Siri launches the app, it bypasses normal lifecycle events
            // This method manually sets up the background session that would normally
            // happen via handleWillResignActive() and handleDidEnterBackground()

            print("🎤 Setting up background session for Siri-initiated playback")

            // Check app state to confirm we're in background
            let appState = UIApplication.shared.applicationState
            print("🎤 App state: \(appState == .background ? "background" : appState == .inactive ? "inactive" : "active")")

            // Mark that we've set up Siri background session
            hasSetupSiriBackgroundSession = true

            // Set up audio session for background (same as handleWillResignActive)
            // But don't re-grab if interrupted by alarm/call
            guard !isAudioSessionInterrupted else {
                print("🎧 Audio session interrupted (alarm/call) - skipping Siri background session keepalive")
                return
            }
            do {
                // Don't call setCategory here - changing category/options on a live
                // session forces a hardware reconfiguration that stops playback
                try AVAudioSession.sharedInstance().setActive(true, options: [])
                print("🎧 Session keepalive on resign active - success")
            } catch {
                print("❌ Session keepalive on resign active failed: \(error)")
            }

            // Background diagnostic and state saving (same as handleDidEnterBackground)
            let backgroundTime = UIApplication.shared.backgroundTimeRemaining
            print("🔍 DIAGNOSTIC - backgroundTimeRemaining: \(backgroundTime)")

            // Stop all UI timers since we're in background
            suspendUITimersForBackground()

            // Save player state
            savePlayerState()
        #else
            // macOS: no Siri-initiated background launch or background session
            // concept; audio keeps playing on the default output device.
            print("ℹ️ setupBackgroundSessionForSiri: no-op on macOS")
        #endif
    }

    func savePlayerState() {
        guard let currentTrack = currentTrack else {
            print("🚫 No current track to save state for")
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
        print("✅ Player state saved to UserDefaults (offline, per-device)")
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
            print("🔄 Loading audio for restored track: \(currentTrack.title)")
            let savedPosition = playbackTime // Save the position before loadTrack
            await loadTrack(currentTrack, preservePlaybackTime: true)

            // Restore the playback position after loading (if position was saved)
            if savedPosition > 0 {
                print("🔄 Seeking to restored position: \(savedPosition)s")
                await seek(to: savedPosition)
                print("✅ Restored position: \(savedPosition)s")
            }
        }
    }

    func restoreUIStateOnly() async {
        guard let playerStateDict = UserDefaults.standard.dictionary(forKey: "QQPlayerState") else {
            print("📭 No saved player state found in UserDefaults")
            return
        }

        guard let lastSavedAt = playerStateDict["lastSavedAt"] as? Date else {
            print("🚫 Invalid saved state format")
            return
        }

        print("🔄 Restoring UI state only from \(lastSavedAt)")

        // Don't restore if the saved state is too old (more than 7 days)
        let daysSinceLastSave = Date().timeIntervalSince(lastSavedAt) / (24 * 60 * 60)
        if daysSinceLastSave > 7 {
            print("⏰ Saved state is too old (\(Int(daysSinceLastSave)) days), skipping restore")
            return
        }

        // Find the current track by stable ID
        guard let currentTrackStableId = playerStateDict["currentTrackStableId"] as? String else {
            print("🚫 No current track in saved state")
            return
        }

        do {
            let track = try DatabaseManager.shared.read { db in
                try Track.filter(Column("stable_id") == currentTrackStableId).fetchOne(db)
            }

            guard let restoredTrack = track else {
                print("🚫 Could not find saved track with ID: \(currentTrackStableId)")
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
                    print("✅ Loop song mode validated with single track queue")
                } else if self.isLoopingSong {
                    print("⚠️ Loop song mode with multi-track queue - this is fine")
                }

                // Additional validation for shuffle state
                if !self.isShuffled {
                    // When not shuffled, ensure currentIndex points to the actual currentTrack
                    if let currentTrack = self.currentTrack,
                       self.currentIndex < self.playbackQueue.count,
                       self.playbackQueue[self.currentIndex].stableId != currentTrack.stableId {
                        // Find the correct index for the current track
                        if let correctIndex = self.playbackQueue.firstIndex(where: { $0.stableId == currentTrack.stableId }) {
                            print("⚠️ Fixed currentIndex from \(self.currentIndex) to \(correctIndex) for non-shuffled queue")
                            self.currentIndex = correctIndex
                        } else {
                            print("⚠️ Current track not found in queue, resetting to index 0")
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

                print("✅ UI state restored - track: \(restoredTrack.title), position: \(savedTime)s, duration: \(self.duration)s (no audio loaded)")

                // Normalize index and track after restoration
                self.normalizeIndexAndTrack()
            }

        } catch {
            print("❌ Failed to restore UI state: \(error)")
        }
    }

    func restorePlayerState() async {
        guard let playerStateDict = UserDefaults.standard.dictionary(forKey: "QQPlayerState") else {
            print("📭 No saved player state found in UserDefaults")
            return
        }

        guard let lastSavedAt = playerStateDict["lastSavedAt"] as? Date else {
            print("🚫 Invalid saved state format")
            return
        }

        print("🔄 Restoring player state from \(lastSavedAt)")

        // Don't restore if the saved state is too old (more than 7 days)
        let daysSinceLastSave = Date().timeIntervalSince(lastSavedAt) / (24 * 60 * 60)
        if daysSinceLastSave > 7 {
            print("⏰ Saved state is too old (\(Int(daysSinceLastSave)) days), skipping restore")
            return
        }

        // Find the current track by stable ID
        guard let currentTrackStableId = playerStateDict["currentTrackStableId"] as? String else {
            print("🚫 No current track in saved state")
            return
        }

        do {
            let track = try DatabaseManager.shared.read { db in
                try Track.filter(Column("stable_id") == currentTrackStableId).fetchOne(db)
            }

            guard let restoredTrack = track else {
                print("🚫 Could not find saved track with ID: \(currentTrackStableId)")
                return
            }

            // Restore queue by finding tracks with stable IDs
            let queueTrackIds = playerStateDict["queueTrackIds"] as? [String] ?? []
            let originalQueueTrackIds = playerStateDict["originalQueueTrackIds"] as? [String] ?? []

            let queueTracks = try DatabaseManager.shared.getTracksByStableIdsPreservingOrder(queueTrackIds)
            let originalQueueTracks = try DatabaseManager.shared.getTracksByStableIdsPreservingOrder(originalQueueTrackIds)

            // Restore player state
            await MainActor.run {
                self.playbackQueue = queueTracks.isEmpty ? [restoredTrack] : queueTracks
                self.originalQueue = originalQueueTracks.isEmpty ? [restoredTrack.stableId] : originalQueueTracks.map { $0.stableId }

                let savedIndex = playerStateDict["currentIndex"] as? Int ?? 0
                self.currentIndex = max(0, min(savedIndex, self.playbackQueue.count - 1))

                self.isRepeating = playerStateDict["isRepeating"] as? Bool ?? false
                self.isShuffled = playerStateDict["isShuffled"] as? Bool ?? false
                self.isLoopingSong = playerStateDict["isLoopingSong"] as? Bool ?? false
                self.currentTrack = restoredTrack

                print("✅ Restored state: queue=\(self.playbackQueue.count) tracks, index=\(self.currentIndex), loop=\(self.isLoopingSong)")

                // Additional validation for shuffle state
                if !self.isShuffled {
                    // When not shuffled, ensure currentIndex points to the actual currentTrack
                    if let currentTrack = self.currentTrack,
                       self.currentIndex < self.playbackQueue.count,
                       self.playbackQueue[self.currentIndex].stableId != currentTrack.stableId {
                        // Find the correct index for the current track
                        if let correctIndex = self.playbackQueue.firstIndex(where: { $0.stableId == currentTrack.stableId }) {
                            print("⚠️ Fixed currentIndex from \(self.currentIndex) to \(correctIndex) for non-shuffled queue")
                            self.currentIndex = correctIndex
                        } else {
                            print("⚠️ Current track not found in queue, resetting to index 0")
                            self.currentIndex = 0
                        }
                    }
                }
            }

            await MainActor.run { self.normalizeIndexAndTrack() }

            await MainActor.run {
                // Set saved position before loading track
                let savedTime = playerStateDict["playbackTime"] as? TimeInterval ?? 0
                self.playbackTime = savedTime
            }

            // Load the track and preserve the saved position
            await loadTrack(restoredTrack, preservePlaybackTime: true)

            // Seek to the saved position after loading
            let savedTime = playerStateDict["playbackTime"] as? TimeInterval ?? 0
            if savedTime > 0 {
                await seek(to: savedTime)
                print("🔄 Seeked to restored position: \(savedTime)s")
            }

            print("✅ Player state restored from UserDefaults - track: \(restoredTrack.title), position: \(savedTime)s")

        } catch {
            print("❌ Failed to restore player state: \(error)")
        }
    }

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
