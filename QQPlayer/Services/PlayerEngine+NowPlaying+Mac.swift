//  PlayerEngine+NowPlaying+Mac.swift
//  QQPlayer
//
//  macOS Now Playing / media-key handling for PlayerEngine: MPRemoteCommandCenter
//  wiring plus MPNowPlayingInfoCenter updates and the macOS playback timer.
//
//  2026-09-21 从 PlayerEngine+NowPlaying.swift 的 `#else` 分支原样搬出
//  （纯搬家；`#if os(iOS)… #else … #endif` 改为独立文件的 `#if os(macOS)`）。
#if os(macOS)
    import Foundation
    import MediaPlayer

    extension PlayerEngine {
        // macOS Now Playing / media keys: MPRemoteCommandCenter + MPNowPlayingInfoCenter
        // work on macOS (verified by the desktop shell, main.swift 834-918). The
        // macOS playback timer drives elapsed time; WidgetKit stays iOS-only.

        func updateWidgetData() {
            // WidgetKit is iOS-only in this app; nothing to refresh on macOS.
        }

        func ensureRemoteCommandsSetup() {
            guard !hasSetupRemoteCommands else { return }
            hasSetupRemoteCommands = true
            setupMacRemoteCommands()
        }

        private func setupMacRemoteCommands() {
            let cc = MPRemoteCommandCenter.shared()

            cc.playCommand.isEnabled = true
            cc.playCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    self?.play()
                }
                return .success
            }

            cc.pauseCommand.isEnabled = true
            cc.pauseCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    self?.pause(fromControlCenter: true)
                }
                return .success
            }

            cc.togglePlayPauseCommand.isEnabled = true
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

            cc.nextTrackCommand.isEnabled = true
            cc.nextTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    let shouldAutoplay = self?.isPlaying ?? false
                    await self?.nextTrack(autoplay: shouldAutoplay)
                }
                return .success
            }

            cc.previousTrackCommand.isEnabled = true
            cc.previousTrackCommand.addTarget { [weak self] _ in
                Task { @MainActor in
                    let shouldAutoplay = self?.isPlaying ?? false
                    await self?.previousTrack(autoplay: shouldAutoplay)
                }
                return .success
            }

            cc.changePlaybackPositionCommand.isEnabled = true
            cc.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                let positionTime = e.positionTime
                Task { @MainActor in
                    await self?.seek(to: positionTime)
                }
                return .success
            }
        }

        func updateNowPlayingInfoEnhanced() {
            guard let currentTrack else {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                return
            }

            var info: [String: Any] = [
                MPMediaItemPropertyTitle: NowPlayingTitleOverlay.displayTitle(fallback: currentTrack.displayTitle),
                MPMediaItemPropertyPlaybackDuration: duration,
                MPNowPlayingInfoPropertyElapsedPlaybackTime: playbackTime,
                MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            ]

            if let artistName = try? DatabaseManager.shared.getArtistDisplayName(
                forTrackStableId: currentTrack.stableId,
                fallbackArtistId: currentTrack.artistId
            ) {
                info[MPMediaItemPropertyArtist] = artistName
            }

            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }

        func updateNowPlayingElapsedTime() {
            guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = playbackTime
            info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }

        func startPlaybackTimer() {
            stopPlaybackTimer()
            // Four UI updates per second are smooth enough for elapsed-time labels.
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.updateMacPlaybackTime()
                }
            }
        }

        private func updateMacPlaybackTime() async {
            // SFBAudioEngine timing: progress + end-of-track detection.
            if usingSFBEngine {
                playbackTime = sfbAudioManager.currentTime
                playbackTimeUpdatedAt = Date()

                if duration > 0, playbackTime >= duration {
                    await handleTrackEnd()
                    return
                }
                if abs(playbackTime - lastControlCenterUpdate) >= 0.5 {
                    lastControlCenterUpdate = playbackTime
                    updateNowPlayingElapsedTime()
                }
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
            if isPlaying {
                playbackTime = calculatedTime
                playbackTimeUpdatedAt = Date()
            }

            if abs(playbackTime - lastControlCenterUpdate) >= 0.5 {
                lastControlCenterUpdate = playbackTime
                updateNowPlayingElapsedTime()
            }
            // 跟唱 tick：句末自动停/单句循环/AB 循环决策（对齐 iOS updatePlaybackTime native 分支）
            KaraokeController.shared.handlePlaybackTick(time: playbackTime, duration: duration)
        }

        func stopPlaybackTimer() {
            playbackTimer?.invalidate()
            playbackTimer = nil
        }

        func nowPlayingElapsedTime() -> TimeInterval {
            if usingSFBEngine {
                return sfbAudioManager.currentTime
            }
            return playbackTime
        }
    }
#endif
