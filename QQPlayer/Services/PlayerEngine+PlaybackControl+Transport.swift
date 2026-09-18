//  PlayerEngine+PlaybackControl+Transport.swift
//  QQPlayer
//
//  Playback transport for PlayerEngine (iOS): play, pause, stop and
//  cancelling pending completion handlers.
//
//  2026-09-19 从 PlayerEngine+PlaybackControl.swift 原样搬出（纯搬家）。
#if os(iOS)
    import AVFoundation
    import Foundation
    extension PlayerEngine {
        func play() {
            print("▶️ play() called - state: \(playbackState), loading: \(isLoadingTrack), usingSFBEngine: \(usingSFBEngine)")

            // Delegate to SFBAudioEngine if it's handling this track
            if usingSFBEngine {
                do {
                    try sfbAudioManager.play()
                    isPlaying = true
                    playbackState = .playing
                    startPlaybackTimer()
                    print("✅ SFBAudioEngine resumed playback")
                    PlayHistoryRecorder.shared.playbackBegan(track: currentTrack, at: nowPlayingElapsedTime())
                    updateNowPlayingInfoEnhanced()
                    updateWidgetData()
                    return
                } catch {
                    // P1-B 降级（2026-08-29）：CarPlay 切换时 SFBAudioEngineManager.updateCarPlayStatus()
                    // 会 stop() + audioPlayer = nil，但此处 usingSFBEngine 未复位 → 之后每次 play 都抛
                    // "AudioPlayer not initialized" 被静默吞掉：界面显示在播、实际无声，只能重选曲目恢复。
                    // 失败时复位标志并落入下方 native 路径（不 return）：audioFile 为 nil 时自动走
                    // loadTrack 重载；audioFile 是上一首 native 曲目残留时置 nil 强制重载，
                    // 避免用错误文件出声。
                    print("❌ Failed to play with SFBAudioEngine: \(error) — falling back to native engine")
                    usingSFBEngine = false
                    isPlaying = false
                    playbackState = .paused
                    audioFile = nil
                    stopPlaybackTimer()
                }
            }

            // If no audio file is loaded but we have a current track, load it first
            if audioFile == nil && currentTrack != nil && !isLoadingTrack {
                Task {
                    // Task 晚于当前 turn 执行，期间 normalizeIndexAndTrack()（清空队列时
                    // 置 currentTrack=nil）可能先跑 → 直接强解包会崩溃。先捕获局部值。
                    guard let track = currentTrack else { return }
                    var loaded = true
                    // If state was already restored but audioFile is nil (e.g., after interruption),
                    // we need to reload the current track with preserved position
                    if hasRestoredState {
                        print("🔄 Reloading track after interruption, preserving position: \(playbackTime)s")
                        let savedPosition = playbackTime
                        loaded = await loadTrack(track, preservePlaybackTime: true)

                        // Restore position after reload
                        if loaded && savedPosition > 0 {
                            await seek(to: savedPosition)
                            print("✅ Restored position after reload: \(savedPosition)s")
                        }
                    } else {
                        // First-time state restoration
                        await ensurePlayerStateRestored()
                    }

                    // After loading, try to play again
                    if loaded {
                        self.play()
                    }
                }
                return
            }

            guard let audioFile = audioFile,
                  playbackState != .loading,
                  !isLoadingTrack else {
                print("⚠️ Cannot play: audioFile=\(audioFile != nil), state=\(playbackState), loading=\(isLoadingTrack)")
                return
            }

            // Set up audio engine only when needed (FIRST) with file's format
            // For new tracks, always ensure proper format configuration
            ensureAudioEngineSetup(with: audioFile.processingFormat)

            // Ensure basic audio session setup first
            ensureAudioSessionSetup()

            // CRITICAL: Activate audio session BEFORE starting engine (iOS 18 fix)
            do {
                try activateAudioSession()
            } catch {
                print("❌ Session activate failed: \(error)")
                // Try to continue anyway - might still work
            }

            if playbackState == .paused {
                print("▶️ Resuming from pause at position: \(playbackTime)s")

                // When resuming from pause, we need to re-schedule audio from the correct position
                // instead of just continuing the engine, because the timing may have drifted
                cancelPendingCompletions()
                playerNode.stop()

                // Re-schedule from the stored pause position
                // Note: audioFile is already unwrapped from the guard statement above

                // CRITICAL: Update seekTimeOffset to match the resume position
                // This ensures time calculation (seekTimeOffset + nodePlaybackTime) is correct
                seekTimeOffset = playbackTime
                nodeTimelineStartSampleTime = 0

                let framePosition = AVAudioFramePosition(playbackTime * audioFile.processingFormat.sampleRate)

                // IMPORTANT: Ensure audio engine is running BEFORE scheduling
                do {
                    if !audioEngine.isRunning {
                        try audioEngine.start()
                        print("✅ Started audio engine before scheduling (resume)")
                    }
                } catch {
                    print("❌ Failed to start audio engine when resuming: \(error)")
                    return
                }

                scheduleSegment(from: framePosition, file: audioFile, track: currentTrack, trackIndex: currentIndex)

                playerNode.play()
                isPlaying = true
                playbackState = .playing
                startPlaybackTimer()
                PlayHistoryRecorder.shared.playbackBegan(track: currentTrack, at: playbackTime)

                // End paused state monitoring and start regular playing monitoring
                stopSilentPlaybackForPause()
                endBackgroundMonitoring()
                startBackgroundMonitoring()

                print("✅ Resumed playback from position: \(playbackTime)s")

                // Update Now Playing info with enhanced approach
                updateNowPlayingInfoEnhanced()
                updateWidgetData()
                preloadAndScheduleNextIfNeeded()
                return
            }

            cancelPendingCompletions()
            playerNode.stop()

            print("🔊 Audio format - Sample Rate: \(audioFile.processingFormat.sampleRate), Channels: \(audioFile.processingFormat.channelCount)")
            print("🔊 Audio file length: \(audioFile.length) frames")

            // Check if the file length is reasonable: 固定 1e9 帧上限误杀长高解析度曲目
            // （96kHz≈2.9h、192kHz≈1.45h），按 sampleRate 换算小时数做上限
            // （2026-08-29 审计 #3）。Int64 + scheduleSegment 已有 AVAudioFrameCount.max 防护。
            let durationHours = Double(audioFile.length) / audioFile.processingFormat.sampleRate / 3600.0
            guard audioFile.length > 0, durationHours <= 24.0 else {
                print("❌ Invalid audio file length: \(audioFile.length) frames (\(String(format: "%.1f", durationHours))h)")
                return
            }

            // IMPORTANT: Ensure audio engine is running BEFORE scheduling
            if !audioEngine.isRunning {
                do {
                    try audioEngine.start()
                    print("✅ Audio engine started before scheduling")
                } catch {
                    print("❌ Failed to start audio engine: \(error)")
                    return
                }
            }

            // Preserve current seek offset and playback time when resuming
            let currentPosition = playbackTime
            let startFrame = AVAudioFramePosition(currentPosition * audioFile.processingFormat.sampleRate)

            // Schedule appropriate segment based on current position
            if startFrame > 0 && startFrame < audioFile.length {
                // Continue from current position
                seekTimeOffset = currentPosition
                nodeTimelineStartSampleTime = 0
                scheduleSegment(from: startFrame, file: audioFile, track: currentTrack, trackIndex: currentIndex)
                print("✅ Resuming playback from \(currentPosition)s (frame: \(startFrame))")
            } else {
                // Start from beginning - but only reset if we're actually at the beginning
                if playbackTime > 1.0 {
                    // We're not actually at the beginning, so preserve current position
                    let startFrame2 = AVAudioFramePosition(playbackTime * audioFile.processingFormat.sampleRate)
                    seekTimeOffset = playbackTime
                    nodeTimelineStartSampleTime = 0
                    scheduleSegment(from: startFrame2, file: audioFile, track: currentTrack, trackIndex: currentIndex)
                    print("✅ Resuming playback from current position: \(playbackTime)s")
                } else {
                    // Actually starting from beginning
                    // 中断诊断（2026-08-29）：从头播路径——记录触发条件（playbackTime<=1 或 startFrame 越界）
                    let fromBeginningDiag = "🔍 [intr] PLAY FROM BEGINNING: playbackTime=\(playbackTime)s "
                        + "currentPosition=\(currentPosition)s startFrame=\(startFrame) "
                        + "fileLength=\(audioFile.length) sampleRate=\(audioFile.processingFormat.sampleRate)"
                    print(fromBeginningDiag)
                    InterruptionDiagnostics.log(fromBeginningDiag)
                    seekTimeOffset = 0
                    playbackTime = 0
                    nodeTimelineStartSampleTime = 0
                    scheduleSegment(from: 0, file: audioFile, track: currentTrack, trackIndex: currentIndex)
                    print("✅ Starting playback from beginning")
                }
            }

            print("✅ Audio segment scheduled successfully")

            // Set up audio session notifications only when needed
            ensureAudioSessionNotificationsSetup()

            // Set up remote commands only when needed
            ensureRemoteCommandsSetup()

            playerNode.play()
            isPlaying = true
            playbackState = .playing
            startPlaybackTimer()
            PlayHistoryRecorder.shared.playbackBegan(track: currentTrack, at: playbackTime)

            // Update Now Playing info with enhanced approach
            updateNowPlayingInfoEnhanced()
            updateWidgetData()
            preloadAndScheduleNextIfNeeded()

            print("✅ Playback started and control center claimed")
        }

        func pause(fromControlCenter: Bool = false) {
            print("⏸️ pause() called - usingSFBEngine: \(usingSFBEngine)")

            // Delegate to SFBAudioEngine if it's handling this track
            if usingSFBEngine {
                // P1-B 降级：CarPlay 切换后 SFBAudioEngineManager 的 audioPlayer 已被置 nil，
                // 下面 pause() 是空操作，且 usingSFBEngine 会一直残留导致 play()/seek() 哑播。
                // 检测到 CarPlay 环境即复位标志并落入 native 暂停路径（与 play()/seek() 一致）。
                if !sfbAudioManager.isCarPlayEnvironment {
                    sfbAudioManager.pause()
                    isPlaying = false
                    playbackState = .paused
                    stopPlaybackTimer()
                    // Let the app suspend while paused - see the note in the native
                    // pause path below.
                    stopSilentPlaybackForPause()
                    endBackgroundMonitoring()
                    print("✅ SFBAudioEngine paused")
                    PlayHistoryRecorder.shared.playbackPaused(track: currentTrack, at: nowPlayingElapsedTime())
                    updateNowPlayingInfoEnhanced()
                    updateWidgetData()
                    return
                }
                print("⚠️ SFBAudioEngine player unavailable in CarPlay — falling back to native pause")
                usingSFBEngine = false
            }

            // Capture current playback position before pausing
            if audioFile != nil {
                let currentPosition = currentTimeForCurrentNativeFile()

                print("🔄 Pausing at position: \(currentPosition)s (from Control Center: \(fromControlCenter))")

                // Store the exact pause position
                playbackTime = currentPosition
                seekTimeOffset = currentPosition
            }

            // Use AVAudioEngine.pause() instead of playerNode.pause()
            audioEngine.pause()

            // Update state
            isPlaying = false
            playbackState = .paused
            stopPlaybackTimer()
            PlayHistoryRecorder.shared.playbackPaused(track: currentTrack, at: playbackTime)

            print("🔄 Paused audio engine - stored position: \(playbackTime)s")

            // Update Now Playing info with enhanced approach
            updateNowPlayingInfoEnhanced()
            updateWidgetData()

            // Release everything that keeps the process awake. A paused player has
            // no reason to stay resident: the lock screen and Control Center are
            // driven by MPRemoteCommandCenter + MPNowPlayingInfoCenter, and iOS
            // resumes us to service a remote command. Previously we looped a
            // near-silent buffer here purely to dodge suspension, which pinned the
            // audio route awake indefinitely and kept every timer below alive -
            // the app effectively never slept after a pause.
            stopSilentPlaybackForPause()
            endBackgroundMonitoring()

            // Save state when pausing
            savePlayerState()
        }

        @inline(__always)
        func cancelPendingCompletions() {
            scheduleGeneration &+= 1
            gaplessScheduled = false
            nextTimelineStartSampleTime = nil
        }

        func stop() {
            // Play history: settle any open session (stop from background uses the
            // live render position, which the foreground timer does not refresh).
            PlayHistoryRecorder.shared.playbackEnded(track: currentTrack, at: isPlaying ? nowPlayingElapsedTime() : playbackTime)
            cancelEngineConfigurationRecovery()
            cancelPendingCompletions()
            clearPreloadedNext()
            playerNode.stop()
            isPlaying = false
            playbackState = .stopped
            playbackTime = 0

            // Stop accessing security-scoped resource if any
            if let securedURL = currentSecurityScopedURL {
                securedURL.stopAccessingSecurityScopedResource()
                currentSecurityScopedURL = nil
                print("🔓 Stopped accessing security-scoped resource on stop")
            }
            stopPlaybackTimer()

            // Stop all background monitoring and silent playback
            stopSilentPlaybackForPause()
            endBackgroundMonitoring()

            // Update Now Playing info to show stopped state (but keep track info)
            updateNowPlayingInfoEnhanced()

            // Don't clear remote commands during track transitions - keep Control Center connected
            // Remote commands should only be cleared when the app is truly shutting down
            print("🎛️ Keeping remote commands connected for Control Center")

            // Don't deactivate audio session during track transitions - keep Control Center connected
            // Audio session should stay active to maintain Control Center connection
            // Only deactivate when the app is truly backgrounded or user explicitly stops playback
            print("🎧 Keeping audio session active to maintain Control Center connection")

            // Save state when stopping
            savePlayerState()
        }
    }
#endif
