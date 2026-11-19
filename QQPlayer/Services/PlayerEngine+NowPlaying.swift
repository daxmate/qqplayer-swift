//  PlayerEngine+NowPlaying.swift
//  QQPlayer
//
//  Now Playing / Control Center info plus the playback timers and remote commands
//  for PlayerEngine (iOS); artwork loading, widget integration and the macOS
//  branch live in the sibling files below.
//
//  2026-09-21 结构拆分（纯搬家，无逻辑变更）。同族文件：
//    · PlayerEngine+NowPlaying+Widget.swift     — 小组件快照推送
//    · PlayerEngine+NowPlaying+Artwork.swift    — 封面解析（AVAsset/FLAC/DSD + 图像整形）
//    · PlayerEngine+NowPlaying+ArtworkID3.swift — SFBAudioEngine 探测 + ID3v2 APIC / DSF 解析
//    · PlayerEngine+NowPlaying+Mac.swift        — macOS 分支（`#else` 原样搬出）
//

#if os(iOS)
    import AVFoundation
    import Foundation
    import GRDB
    import MediaPlayer
    import SFBAudioEngine
    import UIKit
    import WidgetKit

    /// 一次发布的完整字段快照。
    ///
    /// 为什么单独建模（2026-11-19 CarPlay 封面空白修复）：以前「补发封面」是
    /// 「读旧字典 + 只改 artwork 键」的局部写；任何一处拿半份字典覆盖，都会把
    /// title/duration/artwork 一起冲掉。改成「每次发布都从字段快照重建完整字典」，
    /// 让补发是原子的。
    struct NowPlayingInfoFields {
        var title: String
        var artist: String?
        var duration: TimeInterval
        var elapsed: TimeInterval
        var rate: Double
        var queueCount: Int
        var queueIndex: Int?
        var trackNumber: Int?
        var artwork: MPMediaItemArtwork?
    }

    enum NowPlayingInfoBuilder {
        /// 完整字典：键集合固定，有值的可选字段才追加。
        /// 测试按这个键集断言，防止再退回「半份字典」。
        static func dictionary(_ fields: NowPlayingInfoFields) -> [String: Any] {
            var info: [String: Any] = [
                MPMediaItemPropertyTitle: fields.title,
                MPMediaItemPropertyPlaybackDuration: fields.duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: fields.elapsed,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyPlaybackRate: fields.rate,
                MPNowPlayingInfoPropertyPlaybackQueueCount: fields.queueCount,
            ]
            if let artist = fields.artist {
                info[MPMediaItemPropertyArtist] = artist
            }
            if let queueIndex = fields.queueIndex {
                info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = queueIndex
            }
            if let trackNumber = fields.trackNumber {
                info[MPMediaItemPropertyAlbumTrackNumber] = trackNumber
            }
            if let artwork = fields.artwork {
                info[MPMediaItemPropertyArtwork] = artwork
            }
            return info
        }
    }

    extension PlayerEngine {
        func ensureRemoteCommandsSetup() {
            guard !hasSetupRemoteCommands else { return }
            hasSetupRemoteCommands = true
            setupRemoteCommands()
        }

        private func setupRemoteCommands() {
            let cc = MPRemoteCommandCenter.shared()

            // Play command handler - will be called from Control Center
            cc.playCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    AppLog.info(.general, "🎛️ Play command from Control Center")
                    self?.play()
                }
                return .success
            }

            // Pause command handler - will be called from Control Center
            cc.pauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    AppLog.info(.general, "🎛️ Pause command from Control Center")
                    self?.pause(fromControlCenter: true)
                }
                return .success
            }

            cc.nextTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    let shouldAutoplay = self?.isPlaying ?? false
                    await self?.nextTrack(autoplay: shouldAutoplay)
                }
                return .success
            }

            cc.previousTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    let shouldAutoplay = self?.isPlaying ?? false
                    await self?.previousTrack(autoplay: shouldAutoplay)
                }
                return .success
            }

            cc.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }

                // Perform seek synchronously for CarPlay
                let positionTime = e.positionTime
                AppLog.info(.general, "🎯 CarPlay seek request to: \(positionTime)s")

                Task { @MainActor in
                    await self.seek(to: positionTime)
                    AppLog.info(.general, "✅ Seek completed to: \(positionTime)s")
                }

                return .success
            }

            // Toggle play/pause command (for headphone button and other accessories)
            cc.togglePlayPauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    if self?.isPlaying == true {
                        self?.pause(fromControlCenter: true)
                    } else {
                        self?.play()
                    }
                }
                return .success
            }

            // Enable all commands initially
            cc.playCommand.isEnabled = true
            cc.pauseCommand.isEnabled = true
            cc.nextTrackCommand.isEnabled = true
            cc.previousTrackCommand.isEnabled = true
            cc.changePlaybackPositionCommand.isEnabled = true
            cc.togglePlayPauseCommand.isEnabled = true

            // Enable seeking in CarPlay
            cc.changePlaybackPositionCommand.isEnabled = true
            AppLog.info(.general, "✅ CarPlay seek command enabled")
        }

        // Enhanced manual approach with better Control Center synchronization
        func updateNowPlayingInfoEnhanced() {
            guard let track = currentTrack else {
                // Clear Now Playing info if no track
                DispatchQueue.main.async {
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                    AppLog.info(.general, "🎛️ Cleared Control Center - no track loaded")
                }
                return
            }

            // Create comprehensive Now Playing info
            // 展示字段一律走显示层字形（锁屏/控制中心/CarPlay 与 App 内一致）：
            // 数据库里 track.title 原文不动，只改写出的显示值。
            var fields = NowPlayingInfoFields(
                title: NowPlayingTitleOverlay.displayTitle(fallback: track.displayTitle),
                artist: cachedArtistName(for: track),
                duration: duration,
                elapsed: nowPlayingElapsedTime(),
                rate: isPlaying ? 1.0 : 0.0,
                queueCount: playbackQueue.count,
                queueIndex: playbackQueue.indices.contains(currentIndex) ? currentIndex : nil,
                trackNumber: track.trackNo
            )

            // Update with explicit synchronization
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                let publishStarted = CFAbsoluteTimeGetCurrent()

                // 封面在这一刻定稿：绝不发布「没有 artwork 键」的信息——
                // CarPlay 多数只在元数据变化时读一次，先发无图信息再补图 = 一路空白。
                let resolution = self.resolveArtworkForPublication(track: track)
                fields.artwork = resolution.artwork
                fields.rate = self.isPlaying ? 1.0 : 0.0
                MPNowPlayingInfoCenter.default().nowPlayingInfo = NowPlayingInfoBuilder.dictionary(fields)
                MPNowPlayingInfoCenter.default().playbackState = self.isPlaying ? .playing : .paused

                // 真机取证：这张图从哪来 / 多大 / 发布本身多久
                let publishMilliseconds = (CFAbsoluteTimeGetCurrent() - publishStarted) * 1000
                let artworkSide = Self.artworkSide(resolution.artwork)
                AppLog.info(
                    .general,
                    "🎛️ NowPlaying publish — artwork=\(resolution.source.rawValue) side=\(artworkSide) "
                        + "timeout=\(resolution.timedOut) publish=\(String(format: "%.1f", publishMilliseconds))ms "
                        + "playing=\(self.isPlaying) track=\(track.title)"
                )
            }

            // 本曲封面还没解析过 → 起后台任务，完成后走既有补发路径
            if cachedArtworkTrackId != track.stableId {
                loadArtworkInBackground(for: track)
            }
        }

        // MARK: - Timer and Updates

        func startPlaybackTimer() {
            // Don't start the high-frequency UI timer in background — it causes
            // SwiftUI view redraws that spike CPU and trigger the iOS watchdog.
            // Background track-end detection is handled by backgroundCheckTimer instead.
            if isInBackground {
                AppLog.warn(.general, "🔄 Skipping playback timer start - app is in background")
                return
            }

            let appState = UIApplication.shared.applicationState
            if hasSetupSiriBackgroundSession && appState == .background {
                AppLog.warn(.general, "🔄 Skipping playback timer start - Siri background mode active")
                return
            }

            stopPlaybackTimer()

            // Four UI updates per second are smooth enough for elapsed-time labels
            // and avoid flooding SwiftUI's list/layout pipeline. Audio timing comes
            // from the render timeline, not from this timer.
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.updatePlaybackTime()
                }
            }
        }
        private func updatePlaybackTime() async {
            // Handle SFBAudioEngine timing
            if usingSFBEngine {
                playbackTime = sfbAudioManager.currentTime
                playbackTimeUpdatedAt = Date()

                // Check for completion
                if playbackTime >= duration && duration > 0 {
                    await handleTrackEnd()
                }
                if abs(playbackTime - lastControlCenterUpdate) >= 0.5 {
                    lastControlCenterUpdate = playbackTime
                    updateNowPlayingElapsedTime()
                }
                // 跟唱 tick：SFB 无 timePitch 变速，但句末自动停/单句循环/AB 循环有效
                KaraokeController.shared.handlePlaybackTick(time: playbackTime, duration: duration)
                return
            }

            guard audioFile != nil,
                  audioEngine.attachedNodes.contains(playerNode),
                  audioEngine.isRunning,
                  playerNode.lastRenderTime != nil else {
                return
            }
            let calculatedTime = currentTimeForCurrentNativeFile()

            // Only update playback time if we're actually playing (prevents drift during pause/resume)
            if isPlaying {
                playbackTime = calculatedTime
                playbackTimeUpdatedAt = Date()
                // 播放中每 30s 打一条内存曲线（自带节流，不轮询、不额外起 timer）
                MemoryDiagnostics.logPeriodically("播放中")
            }

            // Remove this duplicate detection - it's handled by checkIfTrackEnded()
            /* DELETE THIS BLOCK:
             if isPlaying && playbackTime >= duration - 0.1 && duration > 0 {
             isPlaying = false
             await handleTrackEnd()
             }
             */

            // Update Control Center more frequently for better synchronization - every 0.5 seconds instead of 2 seconds
            // This ensures smooth time display in Control Center regardless of sample rate changes
            if abs(playbackTime - lastControlCenterUpdate) >= 0.5 {
                lastControlCenterUpdate = playbackTime
                updateNowPlayingElapsedTime()
            }
            // 跟唱 tick：句末自动停/单句循环/AB 循环决策
            KaraokeController.shared.handlePlaybackTick(time: playbackTime, duration: duration)
        }

        func stopPlaybackTimer() {
            playbackTimer?.invalidate()
            playbackTimer = nil
        }

        /// Stop all high-frequency UI timers when entering background to prevent
        /// SwiftUI redraws from spiking CPU and triggering the iOS watchdog kill.
        func suspendUITimersForBackground() {
            isInBackground = true
            stopPlaybackTimer()
            AppLog.info(.general, "⏸️ Suspended UI timers for background")
        }

        /// Restart UI timers when returning to foreground.
        func resumeUITimersForForeground() {
            isInBackground = false
            if isPlaying {
                startPlaybackTimer()
            }
            // 锁屏文件保护：后台读不到封面时不当成"永久没有"，回前台补一次
            retryArtworkIfNeeded()
            AppLog.info(.general, "▶️ Resumed UI timers for foreground")
        }

        // MARK: - Now Playing Info

        func resetNowPlayingCachesForTrackChange() {
            // 切歌代数 +1：旧曲迟到的封面结果 / 发布回调一律按旧代际丢弃。
            // 注意：lastResolvedArtwork 故意不清——它是「上一曲封面」，切歌瞬间真图
            // 未到时用来兜底，保证任何一次发布都带 artwork 键。
            artworkLoadGeneration += 1
            cachedArtwork = nil
            cachedArtworkTrackId = nil
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            artworkLoadTaskTrackId = nil
            artworkRetryTrackId = nil
            cachedNowPlayingArtistTrackId = nil
            cachedNowPlayingArtistName = nil
        }

        /// 首次发布门控：切歌时最多等 500ms 拿真封面，取到就随首次发布一起上屏。
        /// 超时返回，发布侧用「上一曲封面 / 占位图」兜底——保证任何时刻都带 artwork 键。
        ///
        /// 关键点：等待的是既有的 artworkLoadTask，**不新建发布入口、不取消它**；
        /// 超时后它继续在后台跑，完成后走 updateNowPlayingInfoWithCachedArtwork 补发。
        func awaitFirstArtworkForCurrentTrack() async {
            guard let track = currentTrack, cachedArtworkTrackId != track.stableId else { return }
            let generation = artworkLoadGeneration
            loadArtworkInBackground(for: track)
            guard let task = artworkLoadTask else { return }

            let started = CFAbsoluteTimeGetCurrent()
            let finished = await NowPlayingBoundedWait.run(
                for: task,
                timeout: .milliseconds(Self.firstArtworkWaitMilliseconds)
            )
            guard generation == artworkLoadGeneration else { return }
            let waited = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            if finished {
                AppLog.info(.general, "🎨 首次发布前取到封面 (\(waited)ms) track=\(track.title)")
            } else {
                AppLog.warn(.general, "⏱ 首次发布等封面超时 (\(waited)ms)，先用兜底图 track=\(track.title)")
            }
        }

        /// 首次发布的封面等待上限（任务要求 400–600ms 之间）。
        static let firstArtworkWaitMilliseconds = 500

        func nowPlayingElapsedTime() -> TimeInterval {
            if usingSFBEngine {
                return sfbAudioManager.currentTime
            }
            return currentTimeForCurrentNativeFile()
        }

        private func cachedArtistName(for track: Track) -> String? {
            if cachedNowPlayingArtistTrackId == track.stableId {
                return cachedNowPlayingArtistName
            }

            let artistName: String?
            do {
                artistName = try databaseManager.getArtistDisplayName(
                    forTrackStableId: track.stableId,
                    fallbackArtistId: track.artistId
                )
            } catch {
                AppLog.error(.general, "Failed to fetch metadata: \(error)")
                artistName = nil
            }

            cachedNowPlayingArtistTrackId = track.stableId
            cachedNowPlayingArtistName = artistName
            return artistName
        }

        private func updateNowPlayingElapsedTime() {
            guard currentTrack != nil else { return }

            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            // 没有曲目信息时不要只写播放进度（半份字典会把锁屏/车机刷成空白）
            guard info[MPMediaItemPropertyTitle] != nil else { return }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = nowPlayingElapsedTime()
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }

    }
#endif
