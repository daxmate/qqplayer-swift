//  PlayerEngine+PlaybackControl.swift
//  QQPlayer
//
//  Playback control for PlayerEngine (iOS): playback rate, the loadTrack
//  chain (native file open, preloaded next-track buffer) and the cleanup of
//  the current playback that a new load replaces.
//
//  2026-09-19 结构拆分（纯搬家，无逻辑变更）。同族文件：
//    · PlayerEngine+PlaybackControl+Transport.swift — play/pause/stop/cancel
//    · PlayerEngine+PlaybackControl+Seek.swift      — seek
//    · PlayerEngine+PlaybackControl+Mac.swift       — macOS 原生播放链
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
            // 新一轮载入开始：清掉上一个失败提示（2026-09-12 审计 P8）
            clearPlaybackFailure()
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
                        // DSD 的 "native fallback" 分支已删除（2026-09-12 审计 P8）：
                        // openNativeAudioFile 对 dsf/dff 无条件抛 3001，该分支**构造上必失败**
                        // （\(error) 只留下一条误导日志：“Attempting native playback fallback”），
                        // 删除是行为等价的：统一由这里 rethrow，交 performLoadTrack 的 catch
                        // 给出用户可见错误（不再静默）。
                        usingSFBEngine = false
                        throw error
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
                    // 用户可见错误（2026-09-12 审计 P8）：原来只 print，playTrack 拿到 false
                    // 直接 return → 用户侧只有“点了不播”。
                    reportPlaybackFailure(
                        PlaybackFailureMessage.messageKey(pathExtension: URL(fileURLWithPath: track.path).pathExtension).localized
                    )
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
    }
#endif
