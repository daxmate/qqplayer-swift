//  PlayerEngine+PlaybackControl.swift
//  QQPlayer
//
//  Playback control for PlayerEngine: loadTrack chain, play/pause/stop/seek,
//  and current-playback cleanup.
//

#if os(iOS)
    import AVFoundation
    import Foundation
    extension PlayerEngine {
        func setPlaybackRate(_ rate: Double) {
            currentPlaybackRate = rate
            // rate == 1.0 时 bypass timePitch：AVAudioUnitTimePitch 从非 1.0 切回 1.0 时
            // phase-vocoder 窗口状态残留，rate=1.0 仍走 DSP → 持续失真
            // （2026-08-31 用户实测 0.7→1.0 声音失真）。1.0 本就不需要变速处理，
            // bypass 直通最干净；非 1.0 时恢复 DSP。
            timePitchNode.auAudioUnit.shouldBypassEffect = (rate == 1.0)
            // engine 未 setup 时设属性也安全：attach 后生效
            timePitchNode.rate = Float(rate)
            if usingSFBEngine {
                // SFB 引擎不支持变速：UI 立即复位显示（否则显示倍速档但实际没变速，
                // 2026-08-29 审计 #7）。currentPlaybackRate 保留用户值：切回 native 曲目时恢复。
                print("⚠️ SFBAudioEngine 暂不支持倍速（Opus/DSD 不变速）——复位跟唱倍速显示")
                KaraokeController.shared.resetSpeedForUnsupportedEngine()
            }
        }

        @discardableResult
        func loadTrack(_ track: Track, preservePlaybackTime: Bool = false) async -> Bool {
            // A song chosen on the phone or CarPlay supersedes any delayed route
            // recovery. Otherwise the 150 ms recovery for the old route can wake
            // after the new selection and reschedule the wrong playback state.
            cancelEngineConfigurationRecovery()
            loadGeneration &+= 1
            let generation = loadGeneration

            currentLoadTask?.cancel()
            let task = Task { @MainActor [weak self] in
                guard let self else { return false }
                return await self.performLoadTrack(track, preservePlaybackTime: preservePlaybackTime, generation: generation)
            }
            currentLoadTask = task

            let loaded = await task.value
            if loadGeneration == generation {
                currentLoadTask = nil
            }
            return loaded
        }

        private func isCurrentLoad(_ generation: UInt64) -> Bool {
            loadGeneration == generation && !Task.isCancelled
        }

        private func performLoadTrack(_ track: Track, preservePlaybackTime: Bool, generation: UInt64) async -> Bool {
            // Determine actual format from file extension
            let url = URL(fileURLWithPath: track.path)
            let formatInfo = PlaybackRouter.getFormatInfo(for: url)
            print("📀 loadTrack called for: \(track.title) (format: \(formatInfo.format))")

            isLoadingTrack = true
            print("🔄 Starting load process for: \(track.title)")

            // 切歌：清 AB 行号（保留跟唱模式/速度/单句循环）
            KaraokeController.shared.resetForNewTrack()

            // Play history: settle the outgoing session before the engine is torn
            // down, while the live position is still readable.
            PlayHistoryRecorder.shared.playbackEnded(track: currentTrack, at: nowPlayingElapsedTime())

            // Stop current playback and clean up
            await cleanupCurrentPlayback(resetTime: !preservePlaybackTime)
            guard isCurrentLoad(generation) else { return false }
            if nextTrack?.stableId != track.stableId {
                clearPreloadedNext()
            }

            // Reset timing state when loading a new track to ensure clean state for new sample rate
            if !preservePlaybackTime {
                seekTimeOffset = 0
                playbackTime = 0
                lastControlCenterUpdate = 0
            }

            nodeTimelineStartSampleTime = 0

            resetNowPlayingCachesForTrackChange()

            currentTrack = track
            playbackState = .loading

            // Volume control already set up in init

            do {
                // Stop accessing previous security-scoped resource if any
                if let previousURL = currentSecurityScopedURL {
                    previousURL.stopAccessingSecurityScopedResource()
                    currentSecurityScopedURL = nil
                    print("🔓 Stopped accessing previous security-scoped resource")
                }

                // Check if this is an external file with a bookmark (file may have moved)
                var url: URL

                if let resolvedURL = await LibraryIndexer.shared.resolveBookmarkForTrack(track) {
                    guard isCurrentLoad(generation) else { return false }

                    // Bookmark found and resolved - use the current location
                    print("📍 Using resolved bookmark location: \(resolvedURL.path)")
                    url = resolvedURL

                    // Start accessing security-scoped resource for external files
                    guard url.startAccessingSecurityScopedResource() else {
                        print("❌ Failed to start accessing security-scoped resource")
                        throw PlayerError.fileNotFound
                    }

                    // Store URL to stop access later
                    currentSecurityScopedURL = url
                    print("🔐 Started accessing security-scoped resource for external file")
                } else {
                    // No bookmark - use path from database
                    url = URL(fileURLWithPath: track.path)
                }

                try await cloudDownloadManager.ensureLocal(url)
                guard isCurrentLoad(generation) else { return false }

                // Remove file protection to prevent background stalls
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.none],
                                                       ofItemAtPath: url.path)

                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw PlayerError.fileNotFound
                }

                // Remember whether the PREVIOUS track played through SFBAudioEngine -
                // the session/engine reset below is only needed for that switch
                let wasUsingSFBEngine = usingSFBEngine

                // Check if SFBAudioEngine can handle this format
                if SFBAudioEngineManager.canHandle(url: url) {
                    print("🚀 PlayerEngine delegating to SFBAudioEngine: \(url.lastPathComponent)")

                    do {
                        try Task.checkCancellation()
                        // Delegate to SFBAudioEngine for Opus, Vorbis, DSD
                        try await sfbAudioManager.loadAndPlay(url: url)
                        guard isCurrentLoad(generation) else {
                            sfbAudioManager.stop()
                            return false
                        }
                        usingSFBEngine = true

                        // SFB 引擎不支持变速：切到 Opus/DSD 曲目时若之前设了倍速，
                        // 复位 UI 显示（否则倍速静默失效而 UI/跟唱仍显示倍速档，
                        // 2026-08-29 审计 #7）。
                        if currentPlaybackRate != 1.0 {
                            print("⚠️ SFBAudioEngine 不支持倍速（currentPlaybackRate=\(currentPlaybackRate)）——复位跟唱倍速显示")
                            KaraokeController.shared.resetSpeedForUnsupportedEngine()
                        }

                        // Note: SFBAudioEngine now handles its own native EQ setup

                        // Sync duration from SFB engine
                        duration = sfbAudioManager.duration
                        isPlaying = sfbAudioManager.isPlaying
                        print("🔄 PlayerEngine duration synced from SFBAudioEngine: \(duration)s")

                        print("✅ Delegated to SFBAudioEngine: \(url.lastPathComponent)")
                    } catch {
                        print("❌ SFBAudioEngine delegation failed: \(error)")

                        // Check if this is a DSD sample rate issue - if so, try native fallback
                        if let nsError = error as NSError?,
                           (nsError.domain == "SFBAudioEngineManager" && nsError.code == 1001) ||
                           (nsError.domain == "org.sbooth.AudioEngine.DSDDecoder" && nsError.code == 2),
                           url.pathExtension.lowercased() == "dff" || url.pathExtension.lowercased() == "dsf" {
                            print("💡 Attempting native playback fallback for DSD file with unsupported sample rate")

                            // Force native playback for this DSD file
                            usingSFBEngine = false

                            let loadedAudioFile = try await openNativeAudioFile(at: url, qos: .background)
                            guard isCurrentLoad(generation) else { return false }
                            audioFile = loadedAudioFile
                            print("✅ DSD file loaded successfully with native AVAudioFile fallback")
                        } else {
                            // For other SFBAudioEngine errors (like AudioPlayer init failure), rethrow
                            print("❌ SFBAudioEngine failed and no fallback available for this file type")
                            throw error
                        }
                    }
                } else {
                    // Use your existing native implementation for FLAC, MP3, WAV, AAC
                    usingSFBEngine = false

                    if let preloadedAudioFile = takePreloadedAudioFile(for: track) {
                        audioFile = preloadedAudioFile
                        print("⚡ Using preloaded native audio file: \(url.lastPathComponent)")
                    } else {
                        let loadedAudioFile = try await openNativeAudioFile(at: url, qos: .userInitiated)
                        guard isCurrentLoad(generation) else { return false }
                        audioFile = loadedAudioFile
                    }

                    guard let audioFile = audioFile else {
                        throw PlayerError.invalidAudioFile
                    }

                    duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
                }

                guard isCurrentLoad(generation) else { return false }

                // Handle SFBAudioEngine specific setup
                if usingSFBEngine {
                    if !preservePlaybackTime {
                        playbackTime = 0
                    }
                    // Audio session already configured in SFBAudioEngineManager.loadAndPlay()
                    // Don't call configureAudioSession() again to avoid overriding DoP settings
                } else {
                    // Native setup (already handled above)
                    // audioFile 是属性（optional）：上方 if/else 加载块内的 guard 绑定
                    // 作用域到不了这里，重新绑定避免强解包（2026-08-29 审计 #2）。
                    guard let audioFile = audioFile else {
                        print("⚠️ audioFile became nil before native graph setup")
                        return false
                    }
                    if !preservePlaybackTime {
                        playbackTime = 0
                    }

                    // Reset session/engine ONLY when switching from SFBAudioEngine
                    // (DoP/DSD config is incompatible with native AVAudioEngine).
                    // Running these on every native track change meant 5 blocking
                    // XPC calls plus a full engine rebuild per song - the main
                    // source of UI freezes when starting a song.
                    if wasUsingSFBEngine {
                        await resetAudioSessionForNative()
                        resetAudioEngineForNative()
                    }

                    // Activate the final route before building the graph. In a
                    // CarPlay launch, the inactive session can still report the
                    // phone speaker's format; constructing against that format and
                    // then activating CarPlay can crash AVAudioEngine.
                    ensureAudioSessionSetup()
                    do {
                        try activateAudioSession()
                    } catch {
                        print("⚠️ Could not activate native audio session before graph setup: \(error)")
                    }

                    // 用上方 guard 绑定的局部 audioFile，不用属性强解包：中间隔了
                    // await resetAudioSessionForNative()，并发 loadTrack 失败路径可能把
                    // 属性置 nil（2026-08-29 审计 #2）。
                    await configureAudioSession(for: audioFile.processingFormat)
                    ensureAudioEngineSetup(with: audioFile.processingFormat)
                }

                guard isCurrentLoad(generation) else { return false }

                // Ensure remote commands are set up for Control Center
                ensureRemoteCommandsSetup()

                // Force immediate Control Center update with new track info and reset timing
                lastControlCenterUpdate = 0
                updateNowPlayingInfoEnhanced()

                playbackState = usingSFBEngine && isPlaying ? .playing : .stopped
                if usingSFBEngine && isPlaying {
                    startPlaybackTimer()
                    updateWidgetData()
                }
                isLoadingTrack = false
                return true

            } catch is CancellationError {
                if isCurrentLoad(generation) {
                    playbackState = .stopped
                    isLoadingTrack = false
                    audioFile = nil
                }
                return false
            } catch {
                print("Failed to load track: \(error)")
                if isCurrentLoad(generation) {
                    playbackState = .stopped
                    isLoadingTrack = false
                    audioFile = nil
                }
                return false
            }
        }

        func openNativeAudioFile(at url: URL, qos: DispatchQoS.QoSClass = .userInitiated) async throws -> AVAudioFile {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: qos).async {
                    do {
                        print("🎵 Loading native audio file: \(url.lastPathComponent)")

                        let fileExtension = url.pathExtension.lowercased()
                        if fileExtension == "dsf" || fileExtension == "dff" {
                            print("⚠️ DSD file rejected by SFBAudioEngine - may be due to sample rate or format incompatibility")

                            let dsdError = NSError(domain: "PlayerEngine", code: 3001, userInfo: [
                                NSLocalizedDescriptionKey: "DSD file not supported",
                                NSLocalizedFailureReasonErrorKey: "This DSD file has a sample rate that is too high for playback.",
                                NSLocalizedRecoverySuggestionErrorKey: "Try converting this DSD file to a lower sample rate (DSD64) or to a PCM format like FLAC.",
                            ])
                            continuation.resume(throwing: dsdError)
                            return
                        }

                        guard FileManager.default.fileExists(atPath: url.path) else {
                            continuation.resume(throwing: PlayerError.fileNotFound)
                            return
                        }

                        let audioFile = try AVAudioFile(forReading: url)
                        print("✅ Native AVAudioFile loaded successfully: \(url.lastPathComponent)")
                        continuation.resume(returning: audioFile)
                    } catch {
                        print("❌ Failed to load native AVAudioFile: \(error)")
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        private func takePreloadedAudioFile(for track: Track) -> AVAudioFile? {
            guard nextTrack?.stableId == track.stableId, let preloaded = nextAudioFile else {
                return nil
            }

            nextAudioFile = nil
            nextTrack = nil
            nextTrackIndex = nil
            preloadNextTask = nil
            isPreloadingNext = false
            gaplessScheduled = false
            return preloaded
        }

        func clearPreloadedNext() {
            preloadNextTask?.cancel()
            preloadNextTask = nil
            nextAudioFile = nil
            nextTrack = nil
            nextTrackIndex = nil
            isPreloadingNext = false
            gaplessScheduled = false
            nextTimelineStartSampleTime = nil
        }

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

        private func cleanupCurrentPlayback(resetTime: Bool = false) async {
            print("🧹 Cleaning up current playback")

            cancelEngineConfigurationRecovery()
            // Stopping AVAudioPlayerNode invokes outstanding completion handlers.
            // Invalidate them first so an old phone/CarPlay selection cannot be
            // mistaken for a natural track end while the replacement loads.
            cancelPendingCompletions()

            // Stop accessing security-scoped resource if any
            if let securedURL = currentSecurityScopedURL {
                securedURL.stopAccessingSecurityScopedResource()
                currentSecurityScopedURL = nil
                print("🔓 Stopped accessing security-scoped resource during cleanup")
            }

            // Stop timer first
            stopPlaybackTimer()

            // Stop appropriate audio engine
            if usingSFBEngine {
                print("🛑 Stopping SFBAudioEngine")
                sfbAudioManager.stop()
            } else {
                // Stop player node
                playerNode.stop()
            }

            // NEVER deactivate session during cleanup - this causes 30-second suspension on iOS 18

            // Reset state
            isPlaying = false
            if resetTime { playbackTime = 0 }        // was unconditional

            // Keep audio engine running for next playback
            // Don't stop the engine here as it causes the error message
            // 2026-08-29 审计 #6：删除固定 10ms 盲睡（每次切歌都付；playerNode.stop()/
            // AVAudioEngine API 均同步，无明确事件可等。若后续出现竞态，应等待明确事件而非盲睡）
        }

        func seek(to time: TimeInterval) async {
            print("⏪ seek(to: \(time)) called - usingSFBEngine: \(usingSFBEngine)")
            clearPreloadedNext()

            // Delegate to SFBAudioEngine if it's handling this track
            if usingSFBEngine {
                do {
                    try sfbAudioManager.seek(to: time)
                    playbackTime = time
                    print("✅ SFBAudioEngine seeked to: \(time)s")
                    updateNowPlayingInfoEnhanced()
                    return
                } catch {
                    let nsError = error as NSError
                    if nsError.domain == "SFBAudioEngineManager" && nsError.code == 4 {
                        // P1-B 降级：与 play() 一致——SFB 不可用时（CarPlay 切换后 audioPlayer 被置
                        // nil）复位 usingSFBEngine 落入 native 路径。audioFile 置 nil（可能是上一首
                        // native 曲目残留，避免在错误文件上 seek）；目标位置写入 playbackTime，
                        // 后续 play() 重载时会以该位置恢复。
                        print("❌ Failed to seek with SFBAudioEngine: \(error) — falling back to native engine")
                        usingSFBEngine = false
                        audioFile = nil
                        playbackTime = time
                    } else {
                        // 真实 seek 失败（SFBAudioEngineManager code 5）：音频没动，
                        // 回滚 playbackTime（保持原位置不更新 UI），并提示（2026-08-29 审计 #4）。
                        print("❌ SFBAudioEngine seek failed: \(error) — keeping position at \(playbackTime)s")
                        NotificationCenter.default.post(
                            name: NSNotification.Name("PlayerSeekFailed"),
                            object: nil,
                            userInfo: ["targetTime": time]
                        )
                        return
                    }
                }
            }

            // If no audio file is loaded but we have a current track, load it first
            if audioFile == nil && currentTrack != nil && !isLoadingTrack {
                await ensurePlayerStateRestored()
            }

            guard let audioFile = audioFile,
                  !isLoadingTrack else {
                print("⚠️ Cannot seek: audioFile=\(audioFile != nil), loading=\(isLoadingTrack)")
                return
            }

            let framePosition = AVAudioFramePosition(time * audioFile.processingFormat.sampleRate)
            let wasPlaying = isPlaying

            // Ensure framePosition is valid
            guard framePosition >= 0 && framePosition < audioFile.length else {
                print("❌ Invalid seek position: \(framePosition), file length: \(audioFile.length)")
                return
            }

            print("🔍 Seeking to: \(time)s (frame: \(framePosition))")

            // Ensure audio engine is set up before seeking with file's format
            ensureAudioEngineSetup(with: audioFile.processingFormat)

            // Ensure audio engine is running before scheduling
            if !audioEngine.isRunning {
                do {
                    try audioEngine.start()
                    print("✅ Started audio engine before scheduling (seek)")
                } catch {
                    print("❌ Failed to start audio engine during seek: \(error)")
                    return
                }
            }

            cancelPendingCompletions()
            playerNode.stop()

            // Update seek offset and playback time
            seekTimeOffset = time
            playbackTime = time
            nodeTimelineStartSampleTime = 0
            scheduleSegment(from: framePosition, file: audioFile, track: currentTrack, trackIndex: currentIndex)

            if wasPlaying {
                playerNode.play()
                isPlaying = true
                playbackState = .playing
                startPlaybackTimer()

                // Update Now Playing info after seek
                updateNowPlayingInfoEnhanced()
                preloadAndScheduleNextIfNeeded()
            } else {
                // Update position even when paused
                updateNowPlayingInfoEnhanced()
            }

            print("✅ Seek completed")
        }
    }

#else
    import AVFoundation
    import Foundation

    extension PlayerEngine {
        // macOS native playback chain: AVAudioEngine + AVAudioPlayerNode.
        // SFBAudioEngine formats (Opus/OGG/DSD) land with the SFB macOS batch.

        func setPlaybackRate(_ rate: Double) {
            currentPlaybackRate = rate
            // macOS 同 iOS：rate==1.0 bypass timePitch，避免从非 1.0 切回时
            // phase-vocoder 残留状态失真（2026-08-31 iOS 实测同根因）
            timePitchNode.auAudioUnit.shouldBypassEffect = (rate == 1.0)
            timePitchNode.rate = Float(rate)
            if usingSFBEngine {
                // SFB 引擎不支持变速：UI 立即复位显示（否则显示倍速档但实际没变速，对齐 iOS）
                print("⚠️ SFBAudioEngine 暂不支持倍速（Opus/OGG/DSD 不变速）——复位跟唱倍速显示")
                KaraokeController.shared.resetSpeedForUnsupportedEngine()
            }
        }

        @discardableResult
        func loadTrack(_ track: Track, preservePlaybackTime: Bool = false) async -> Bool {
            loadGeneration &+= 1
            let generation = loadGeneration

            currentLoadTask?.cancel()
            let task = Task { @MainActor [weak self] in
                guard let self else { return false }
                return await self.performMacLoadTrack(track, preservePlaybackTime: preservePlaybackTime, generation: generation)
            }
            currentLoadTask = task

            let loaded = await task.value
            if loadGeneration == generation {
                currentLoadTask = nil
            }
            return loaded
        }

        private func isCurrentLoad(_ generation: UInt64) -> Bool {
            loadGeneration == generation && !Task.isCancelled
        }

        private func performMacLoadTrack(_ track: Track, preservePlaybackTime: Bool, generation: UInt64) async -> Bool {
            let url = URL(fileURLWithPath: track.path)
            print("📀 macOS loadTrack: \(track.title) (\(url.lastPathComponent))")

            // 切歌：清 AB 行号（保留跟唱模式/速度/单句循环；对齐 iOS performLoadTrack）
            KaraokeController.shared.resetForNewTrack()

            isLoadingTrack = true
            playbackState = .loading

            // Play history: settle the outgoing session before tearing down.
            PlayHistoryRecorder.shared.playbackEnded(track: currentTrack, at: nowPlayingElapsedTime())

            // Stop current playback and clean up.
            playerNode.stop()
            if audioEngine.isRunning {
                audioEngine.pause()
            }
            audioFile = nil
            if !preservePlaybackTime {
                seekTimeOffset = 0
                playbackTime = 0
                lastControlCenterUpdate = 0
            }
            nodeTimelineStartSampleTime = 0

            guard FileManager.default.fileExists(atPath: url.path) else {
                print("❌ macOS loadTrack: file not found \(url.path)")
                playbackState = .stopped
                isLoadingTrack = false
                return false
            }

            // SFB formats (Opus/OGG/DSD) play through SFBAudioEngine's AudioPlayer
            // (cross-platform, supports macOS 11+).
            if SFBAudioEngineManager.canHandle(url: url) {
                print("🚀 macOS loadTrack delegating to SFBAudioEngine: \(url.lastPathComponent)")
                do {
                    try await sfbAudioManager.loadAndPlay(url: url)
                    guard isCurrentLoad(generation) else {
                        sfbAudioManager.stop()
                        return false
                    }
                    usingSFBEngine = true
                    duration = sfbAudioManager.duration
                    isPlaying = sfbAudioManager.isPlaying
                    currentTrack = track
                    playbackState = .stopped
                    isLoadingTrack = false
                    print("✅ macOS delegated to SFBAudioEngine: \(url.lastPathComponent)")
                    return true
                } catch {
                    print("❌ macOS SFBAudioEngine delegation failed: \(error)")
                    if isCurrentLoad(generation) {
                        usingSFBEngine = false
                        playbackState = .stopped
                        isLoadingTrack = false
                    }
                    return false
                }
            }

            usingSFBEngine = false

            do {
                let file = try AVAudioFile(forReading: url)
                guard isCurrentLoad(generation) else { return false }
                audioFile = file
                duration = Double(file.length) / file.processingFormat.sampleRate
                currentTrack = track
                playbackState = .stopped
                isLoadingTrack = false
                return true
            } catch {
                print("❌ macOS loadTrack failed: \(error)")
                if isCurrentLoad(generation) {
                    playbackState = .stopped
                    isLoadingTrack = false
                    audioFile = nil
                }
                return false
            }
        }

        func play() {
            if usingSFBEngine {
                do {
                    try sfbAudioManager.play()
                } catch {
                    print("❌ macOS SFB play failed: \(error)")
                    return
                }
                isPlaying = true
                playbackState = .playing
                startPlaybackTimer()
                PlayHistoryRecorder.shared.playbackBegan(track: currentTrack, at: playbackTime)
                updateNowPlayingInfoEnhanced()
                print("✅ macOS SFB playback resumed: \(currentTrack?.title ?? "")")
                return
            }

            // 启动恢复（restoreUIStateOnly）只恢复 UI 不载音频：首次点播放时
            // audioFile 为空 → 先补载当前曲并 seek 到断点再播（对齐 iOS play()）。
            // hasRestoredState 由 ensurePlayerStateRestored() 置位：冷启动首播走
            // ensure（loadTrack 保留时间 + seek）；中断/恢复后 audioFile 被清、
            // 再次播放走 preserve 分支（playbackTime 不重置，seek 到断点）。
            if audioFile == nil, currentTrack != nil, !isLoadingTrack {
                Task {
                    guard let track = currentTrack else { return }
                    var loaded = true
                    if hasRestoredState {
                        let savedPosition = playbackTime
                        loaded = await loadTrack(track, preservePlaybackTime: true)
                        if loaded, savedPosition > 0 {
                            await seek(to: savedPosition)
                            print("✅ macOS restored position after reload: \(savedPosition)s")
                        }
                    } else {
                        await ensurePlayerStateRestored()
                    }
                    if loaded {
                        self.play()
                    }
                }
                return
            }

            // 决策上收：前置条件语义与 MacPlaybackGate.canStartPlayback 一一对应（有单测锁定）。
            guard let audioFile = audioFile,
                  MacPlaybackGate.canStartPlayback(
                      audioFileLoaded: true,
                      isLoadingTrack: isLoadingTrack,
                      playbackStateIsLoading: playbackState == .loading
                  ) else {
                print("⚠️ macOS play skipped: audioFile=\(audioFile != nil) state=\(playbackState)")
                return
            }

            ensureMacAudioEngineSetup(with: audioFile.processingFormat)

            if !audioEngine.isRunning {
                do {
                    try audioEngine.start()
                } catch {
                    print("❌ macOS audioEngine start failed: \(error)")
                    return
                }
                // AVAudioEngine.start() 异步生效：紧跟的 scheduleSegment 有 engineIsRunning guard
                // （MacPlaybackGate.segmentPlan），isRunning 未变 true 时调度被拒 → 无声但 isPlaying=true
                // （2026-09-01 用户实测：首次点击歌词不播放、再次点击才播——首次 start 后才生效）。
                // 短轮询等 isRunning（引擎启动通常 <100ms，1s 兜底），用 RunLoop 转圈避免阻塞事件处理。
                let deadline = Date().addingTimeInterval(1.0)
                while !audioEngine.isRunning && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                if !audioEngine.isRunning {
                    print("❌ macOS audioEngine did not become running after start")
                    return
                }
            }

            let startFrame = AVAudioFramePosition(playbackTime * audioFile.processingFormat.sampleRate)
            // 对齐 iOS play（暂停恢复路径）：cancel + stop 再重新 schedule，避免队列残留旧 segment
            // 与旧 completion 误触发 handleTrackEnd（与 seek 同根因，2026-09-01）
            cancelPendingCompletions()
            playerNode.stop()
            scheduleSegment(from: startFrame, file: audioFile, track: currentTrack, trackIndex: currentIndex)

            playerNode.play()
            isPlaying = true
            playbackState = .playing
            startPlaybackTimer()
            PlayHistoryRecorder.shared.playbackBegan(track: currentTrack, at: playbackTime)
            updateNowPlayingInfoEnhanced()
            print("✅ macOS playback started: \(currentTrack?.title ?? "")")
        }

        func pause(fromControlCenter: Bool = false) {
            if usingSFBEngine {
                let currentPosition = sfbAudioManager.currentTime
                playbackTime = currentPosition
                seekTimeOffset = currentPosition
                sfbAudioManager.pause()
                isPlaying = false
                playbackState = .paused
                stopPlaybackTimer()
                PlayHistoryRecorder.shared.playbackPaused(track: currentTrack, at: playbackTime)
                updateNowPlayingInfoEnhanced()
                print("⏸️ macOS SFB paused at \(playbackTime)s")
                return
            }

            guard audioFile != nil else { return }

            let currentPosition = currentTimeForCurrentNativeFile()
            playbackTime = currentPosition
            seekTimeOffset = currentPosition

            if audioEngine.isRunning {
                // 桌面端无 iOS 省电/后台挂起约束：只暂停播放节点，保留引擎运行。
                // 引擎级 pause() 停掉整个渲染线程，恢复 play() 必须重新 start + 轮询
                // 等 isRunning（音频硬件重启，外接声卡/蓝牙可达数百 ms）→ 用户感知
                // "暂停再播放卡顿"（2026-09-05）。playerNode.pause() 保留引擎与已调度
                // 缓冲，恢复走下方轻量重排路径，几乎无感。
                playerNode.pause()
            }
            isPlaying = false
            playbackState = .paused
            stopPlaybackTimer()
            PlayHistoryRecorder.shared.playbackPaused(track: currentTrack, at: playbackTime)
            updateNowPlayingInfoEnhanced()
            print("⏸️ macOS paused at \(playbackTime)s")
        }

        func seek(to time: TimeInterval) async {
            if usingSFBEngine {
                let clamped = min(max(time, 0), duration)
                do {
                    try sfbAudioManager.seek(to: clamped)
                } catch {
                    print("❌ macOS SFB seek failed: \(error)")
                    return
                }
                playbackTime = clamped
                lastKnownPlaybackPosition = clamped
                lastKnownPlaybackPositionUpdatedAt = Date()
                updateNowPlayingInfoEnhanced()
                print("✅ macOS SFB seek to \(clamped)s")
                return
            }

            guard let audioFile = audioFile else { return }
            let clamped = min(max(time, 0), duration)
            let wasPlaying = isPlaying

            // 对齐 iOS seek：先取消 pending completion 再 stop——playerNode.stop() 会触发
            // 已调度 segment 的 completion 回调，不取消则 generation 仍匹配，handleMacSegmentFinished
            // 误判「播完」→ handleTrackEnd 停播/切歌（2026-09-01 日志实锤：播放中点歌词后
            // isPlaying 变 false，第二次点击才真正播放）
            cancelPendingCompletions()
            playerNode.stop()
            seekTimeOffset = clamped
            playbackTime = clamped
            nodeTimelineStartSampleTime = 0

            if wasPlaying {
                // 播放中 seek：重新调度并继续播放（引擎应在运行；未运行则启动并等 isRunning 生效）
                if !audioEngine.isRunning {
                    do {
                        try audioEngine.start()
                    } catch {
                        print("❌ macOS seek: engine start failed \(error)")
                        return
                    }
                    // 等 isRunning（引擎启动通常 <100ms，1s 兜底）。async 上下文不能用
                    // RunLoop.current.run（Swift 6 并发检查标记不可用），改用 Task.sleep
                    // 轮询 + scheduleGeneration 防重入：await 期间新 seek 会递增 generation，
                    // 检测到变化即退出（让新 seek 赢，避免旧值覆盖播放位置）。
                    let seekGeneration = scheduleGeneration
                    let deadline = Date().addingTimeInterval(1.0)
                    while !audioEngine.isRunning && Date() < deadline {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        guard scheduleGeneration == seekGeneration else { return }
                    }
                }
                let startFrame = AVAudioFramePosition(clamped * audioFile.processingFormat.sampleRate)
                scheduleSegment(from: startFrame, file: audioFile, track: currentTrack, trackIndex: currentIndex)
                playerNode.play()
            }
            // 暂停态 seek：仅更新位置，不调度不启动引擎——由后续 play() 统一
            // schedule（避免 seekAndPlay 链路双重 schedule 同位置 segment，
            // 第一个 segment 播完误触发 handleTrackEnd 切歌；2026-09-01 发现）
            lastKnownPlaybackPosition = clamped
            lastKnownPlaybackPositionUpdatedAt = Date()
            updateNowPlayingInfoEnhanced()
            print("✅ macOS seek to \(clamped)s")
        }

        func cancelPendingCompletions() {
            scheduleGeneration &+= 1
        }

        // MARK: - macOS Engine Graph

        /// 已配置的引擎图 format（缓存避免每次 play 重复 connect——AVAudioEngine.connect
        /// 是同步重操作，内部等待音频渲染线程，重复调用触发 Hang 检测的优先级反转
        /// （2026-09-01 跟唱跳转链路实测：PlayerEngineKaraokeActions → play → connect）
        /// static：extension 不允许实例存储属性；PlayerEngine 是单例，语义等价
        private static var macEngineGraphFormat: AVAudioFormat?

        private func ensureMacAudioEngineSetup(with format: AVAudioFormat?) {
            if !audioEngine.attachedNodes.contains(playerNode) {
                audioEngine.attach(playerNode)
            }
            if !audioEngine.attachedNodes.contains(timePitchNode) {
                audioEngine.attach(timePitchNode)
            }
            // EQ 节点：首次创建并 attach（EQManager.setupEQNode 内部 attach 到 engine）。
            // 只在节点不存在时调用——重复调用会新建 AVAudioUnitEQ 重复 attach（引擎图脏）。
            // attach 必须在 engine 未运行时执行：首次 setup 发生在 play() 的 engine.start()
            // 之前 ✓；后续 format 变化只 connect 不 attach（节点已在图上）。
            if eqManager.currentEQNode == nil
                || !audioEngine.attachedNodes.contains(eqManager.currentEQNode!) {
                eqManager.setAudioEngine(audioEngine)
            }
            // 同 format 已 connect 过：跳过重复 connect（幂等，但每次调用都同步等音频线程）
            if Self.macEngineGraphFormat == format {
                return
            }
            // playerNode → timePitch（倍速）→ EQ → mainMixer（EQ 节点存在时；
            // 对齐 iOS connectPlaybackChain）。AVAudioEngine owns the mainMixer →
            // outputNode connection and negotiates the hardware format.
            audioEngine.connect(playerNode, to: timePitchNode, format: format)
            if let eqNode = eqManager.currentEQNode {
                audioEngine.connect(timePitchNode, to: eqNode, format: format)
                audioEngine.connect(eqNode, to: audioEngine.mainMixerNode, format: format)
            } else {
                audioEngine.connect(timePitchNode, to: audioEngine.mainMixerNode, format: format)
            }
            audioEngine.prepare()
            Self.macEngineGraphFormat = format
        }
    }
#endif
