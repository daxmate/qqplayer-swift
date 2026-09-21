//  PlayerEngine+NowPlaying.swift
//  QQPlayer
//
//  Now Playing / Control Center info, artwork loading, widget integration, and
//  remote commands for PlayerEngine.
//

#if os(iOS)
    import AVFoundation
    import Foundation
    import GRDB
    import MediaPlayer
    import SFBAudioEngine
    import UIKit
    import WidgetKit
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

        // MARK: - Widget Integration

        func updateWidgetData() {
            guard let track = currentTrack else {
                WidgetDataManager.shared.clearCurrentTrack()
                return
            }
            let trackId = track.stableId

            Task {
                // Get artwork
                let artwork = await ArtworkManager.shared.getArtwork(for: track)

                // pngData 编码 + 写盘下沉后台线程（主 actor 编码/同步 IO 卡 UI，
                // 2026-08-29 审计 #9）：值拷贝 UIImage 引用后离线处理。
                let artworkData: Data?
                if let artwork {
                    artworkData = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            continuation.resume(returning: artwork.pngData())
                        }
                    }
                } else {
                    artworkData = nil
                }

                // Get artist name
                let artistName: String
                if let artistId = track.artistId,
                   let artist = try? DatabaseManager.shared.read({ db in
                       try Artist.fetchOne(db, key: artistId)
                   }) {
                    artistName = ArtistNameNormalizer.displayName(artist.name)
                } else {
                    artistName = Localized.unknownArtist
                }

                // Get theme color（唯一取数 = IOSAppearance 名单；字段 = accentColorName，2026-09-17 收口）
                let settings = DeleteSettings.load()
                let colorHex = IOSAppearance.accentHex(forKey: settings.accentColorName)

                // 同曲校验（2026-09-12 审计 P5）：上面两次 await（封面 / 后台编码）期间可能已切歌，
                // 旧曲写进去会一直留在小组件（saveCurrentTrack 同步写盘 + reloadAllTimelines）。
                guard PlaybackTrackGate.isStillCurrent(trackId: trackId, currentTrackId: currentTrack?.stableId) else {
                    AppLog.warn(.general, "↩️ widget 更新丢弃：\(track.title) 已不是当前曲目")
                    return
                }

                let widgetData = WidgetTrackData(
                    trackId: track.stableId,
                    title: track.displayTitle,
                    artist: artistName,
                    isPlaying: isPlaying,
                    backgroundColorHex: colorHex
                )

                // 写盘 + 小组件刷新下沉后台（saveCurrentTrack 内部有 UserDefaults.synchronize
                // 与文件写入，均为同步 IO，2026-08-29 审计 #9）
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        WidgetDataManager.shared.saveCurrentTrack(widgetData, artworkData: artworkData)
                        WidgetCenter.shared.reloadAllTimelines()
                        continuation.resume()
                    }
                }
            }
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

            let currentTime = nowPlayingElapsedTime()

            // Create comprehensive Now Playing info
            // 展示字段一律走显示层字形（锁屏/控制中心/CarPlay 与 App 内一致）：
            // 数据库里 track.title 原文不动，只改写出的显示值。
            var info: [String: Any] = [
                // 车载歌词：CarPlay 连接期间标题位可能是当前歌词行（见 NowPlayingTitleOverlay）
                MPMediaItemPropertyTitle: NowPlayingTitleOverlay.displayTitle(fallback: track.displayTitle),
                MPMediaItemPropertyPlaybackDuration: duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
                MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
                MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
                MPNowPlayingInfoPropertyPlaybackQueueCount: playbackQueue.count,
            ]

            // Add queue position
            if playbackQueue.indices.contains(currentIndex) {
                info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = currentIndex
            }

            if let artistName = cachedArtistName(for: track) {
                info[MPMediaItemPropertyArtist] = artistName
            }

            // Add track number
            if let trackNo = track.trackNo {
                info[MPMediaItemPropertyAlbumTrackNumber] = trackNo
            }

            // Add cached artwork
            if let cachedArtwork = cachedArtwork, cachedArtworkTrackId == track.stableId {
                info[MPMediaItemPropertyArtwork] = cachedArtwork
                AppLog.info(.general, "🎨 Added cached artwork to Now Playing info for: \(track.title)")
            } else {
                AppLog.warn(.general, "⚠️ No cached artwork available for: \(track.title) (cached: \(cachedArtwork != nil), trackId match: \(cachedArtworkTrackId == track.stableId))")
            }

            // Update with explicit synchronization
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }

                // Re-attach artwork at write time: the artwork loader may have
                // finished between building `info` above and this block running,
                // and writing the stale artwork-less dictionary would wipe the
                // artwork it already set (lock screen loses the cover).
                var info = info
                if info[MPMediaItemPropertyArtwork] == nil,
                   let cachedArtwork = self.cachedArtwork,
                   self.cachedArtworkTrackId == track.stableId {
                    info[MPMediaItemPropertyArtwork] = cachedArtwork
                }

                // Update Now Playing Info
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info

                // Trigger CarPlay Now Playing button update
                MPNowPlayingInfoCenter.default().playbackState = self.isPlaying ? .playing : .paused

                AppLog.info(.general, "🎛️ Enhanced Control Center update - playing: \(self.isPlaying)")
                AppLog.info(.general, "🎛️ Title: \(track.title), Time: \(currentTime)")
            }

            if cachedArtworkTrackId != track.stableId,
               artworkLoadTaskTrackId != track.stableId {
                artworkLoadTask?.cancel()
                artworkLoadTaskTrackId = track.stableId
                artworkLoadTask = Task { [weak self] in
                    await self?.loadAndCacheArtwork(track: track)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if self.artworkLoadTaskTrackId == track.stableId {
                            self.artworkLoadTask = nil
                        }
                    }
                }
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
            AppLog.info(.general, "▶️ Resumed UI timers for foreground")
        }

        // MARK: - Now Playing Info

        func resetNowPlayingCachesForTrackChange() {
            cachedArtwork = nil
            cachedArtworkTrackId = nil
            artworkLoadTask?.cancel()
            artworkLoadTask = nil
            artworkLoadTaskTrackId = nil
            cachedNowPlayingArtistTrackId = nil
            cachedNowPlayingArtistName = nil
        }

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
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = nowPlayingElapsedTime()
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }

    }
#endif
