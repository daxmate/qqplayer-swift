//  SFBAudioEngineManager+Playback.swift
//  QQPlayer
//
//  Playback control for SFBAudioEngineManager (iOS): loadAndPlay, play/pause/stop,
//  seek, timer and EQ support.
//
//  2026-09-21 结构拆分（纯搬家，无逻辑变更）。同族文件：
//    · SFBAudioEngineManager+Decoder.swift — 解码器音频会话配置 + 外置 DAC 检测
//    · SFBAudioEngineManager+Mac.swift     — macOS SFB 播放链
#if os(iOS)
    import AVFoundation
    import Foundation
    import SFBAudioEngine
    extension SFBAudioEngineManager {
        // MARK: - Playback Control

        func loadAndPlay(url: URL) async throws {
            AppLog.info(.general, "🚀 SFBAudioEngine.loadAndPlay called for: \(url.lastPathComponent)")
            try Task.checkCancellation()

            // Don't use SFBAudioEngine in CarPlay environment
            if isCarPlayEnvironment {
                AppLog.warn(.general, "🚗 CarPlay detected - refusing to load with SFBAudioEngine")
                throw NSError(domain: "SFBAudioEngine", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "SFBAudioEngine unavailable in CarPlay - using native playback",
                ])
            }

            // Ensure AudioPlayer is initialized (deferred from init for CarPlay compatibility)
            setupAudioPlayer()

            // If AudioPlayer failed to initialize, throw error to fall back to native playback
            guard audioPlayer != nil else {
                throw NSError(domain: "SFBAudioEngine", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "SFBAudioEngine unavailable - AudioPlayer initialization failed",
                ])
            }

            // Stop any current playback and cleanup
            audioPlayer?.stop()
            cleanupEqualizer()
            try Task.checkCancellation()

            AppLog.info(.general, "🔍 SFBAudioEngine attempting to load: \(url.lastPathComponent)")

            // Create track and get properties/metadata first to get sample rate.
            // SFBTrack's init does a synchronous TagLib read of the whole file's
            // metadata - run it off the main actor so the UI doesn't hitch
            AppLog.info(.general, "🔍 Creating SFBTrack for: \(url.lastPathComponent)")
            let track = await Task.detached(priority: .userInitiated) { SFBTrack(url: url) }.value
            try Task.checkCancellation()
            currentTrack = track

            // Set duration from track
            duration = track.duration
            AppLog.info(.general, "📊 Track duration: \(duration) seconds")

            // Check user's DSD playback preference
            let settings = DeleteSettings.load()
            let isDSDFile = url.pathExtension.lowercased() == "dsf" || url.pathExtension.lowercased() == "dff"

            let enableDoP: Bool
            if isDSDFile {
                switch settings.dsdPlaybackMode {
                case .auto:
                    // Auto mode - detect DAC
                    enableDoP = await checkForExternalDAC()
                    AppLog.info(.general, "🎵 DSD file detected, Auto mode: DAC present = \(enableDoP)")
                case .pcm:
                    // Always use PCM conversion
                    enableDoP = false
                    AppLog.info(.general, "🎵 DSD file detected, PCM mode: Will convert to PCM")
                case .dop:
                    // Always use DoP
                    enableDoP = true
                    AppLog.info(.general, "🎵 DSD file detected, DoP mode: Will use DoP encoding")
                }
            } else {
                enableDoP = false
            }

            AppLog.info(.general, "🔍 Getting decoder for: \(url.lastPathComponent), enableDoP: \(enableDoP)")
            try Task.checkCancellation()

            guard let decoder = try track.decoder(enableDoP: enableDoP) else {
                AppLog.error(.general, "❌ No decoder available for: \(url.lastPathComponent)")
                throw NSError(domain: "SFBAudioEngineManager", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Unsupported audio format",
                ])
            }

            AppLog.info(.general, "🔧 Decoder created successfully")

            // Try to open the decoder to ensure format properties are available
            do {
                try decoder.open()
                try Task.checkCancellation()
                AppLog.info(.general, "🔧 Decoder opened successfully")
            } catch {
                AppLog.warn(.general, "⚠️ Failed to open decoder: \(error)")
                // Continue anyway - some decoders might work without explicit opening
            }

            AppLog.info(.general, "🔧 Decoder format: \(decoder.processingFormat)")
            AppLog.info(.general, "🔧 Decoder sample rate: \(decoder.processingFormat.sampleRate)")
            AppLog.info(.general, "🔧 Decoder channel count: \(decoder.processingFormat.channelCount)")

            // Also try to get source format for comparison
            let sourceFormat = decoder.sourceFormat
            AppLog.info(.general, "🔧 Source format: \(sourceFormat)")
            AppLog.info(.general, "🔧 Source sample rate: \(sourceFormat.sampleRate)")
            AppLog.info(.general, "🔧 Source channel count: \(sourceFormat.channelCount)")

            // Validate decoder properties before proceeding
            let decoderSampleRate = decoder.processingFormat.sampleRate
            let decoderChannelCount = decoder.processingFormat.channelCount

            // Also check source format as fallback
            let sourceSampleRate = sourceFormat.sampleRate
            let sourceChannelCount = sourceFormat.channelCount

            // Use source format if processing format is invalid
            let finalSampleRate = decoderSampleRate > 0 ? decoderSampleRate : sourceSampleRate
            let finalChannelCount = decoderChannelCount > 0 ? decoderChannelCount : sourceChannelCount

            // Log the format properties but don't fail immediately - let SFBAudioEngine try to play
            if finalSampleRate <= 0 || finalChannelCount <= 0 {
                AppLog.warn(.general, "⚠️ Decoder format properties unavailable: processing(sampleRate=\(decoderSampleRate), channels=\(decoderChannelCount)), source(sampleRate=\(sourceSampleRate), channels=\(sourceChannelCount))")
                AppLog.info(.general, "🔄 Proceeding with playback - SFBAudioEngine may handle format internally")

                // Use default values for configuration
                self.decoderSampleRate = 48000 // Default sample rate
            } else {
                AppLog.info(.general, "✅ Valid decoder properties: sampleRate=\(finalSampleRate), channels=\(finalChannelCount)")
                self.decoderSampleRate = finalSampleRate
            }

            // Store decoder properties for seeking when AudioFile properties are unavailable
            decoderFrameLength = decoder.length
            AppLog.info(.general, "🔄 Stored decoder properties: frameLength=\(decoderFrameLength), sampleRate=\(self.decoderSampleRate)")

            // Update duration from decoder if it wasn't available from AudioFile and we have valid properties
            if duration == 0 && decoderFrameLength > 0 && self.decoderSampleRate > 0 {
                duration = Double(decoderFrameLength) / self.decoderSampleRate
                AppLog.info(.general, "🔄 Updated duration from decoder: \(duration)s")
            }

            // CRITICAL: Configure audio session AFTER decoder creation and BEFORE playback
            // Use the determined sample rate for accurate configuration
            let actualSampleRate = self.decoderSampleRate
            AppLog.info(.general, "🔍 Using determined sample rate: \(actualSampleRate)Hz")
            try Task.checkCancellation()

            do {
                try configureAudioSessionForDecoder(decoder: decoder, isDSD: isDSDFile, enableDoP: enableDoP)
            } catch {
                AppLog.warn(.general, "⚠️ Audio session configuration had warnings (ignoring): \(error)")
            }

            if isDSDFile {
                AppLog.info(.general, "🔄 Resetting AudioPlayer for DSD file to prevent state issues")
                resetAudioPlayer()
            } else if audioPlayer?.isPlaying == true {
                AppLog.info(.general, "🔄 Stopping existing playback before starting new track")
                audioPlayer?.stop()
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            // Start playback with proper error handling
            AppLog.info(.general, "🎵 Starting SFBAudioEngine playback...")
            try Task.checkCancellation()
            do {
                guard let player = audioPlayer else {
                    throw NSError(domain: "SFBAudioEngine", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "AudioPlayer not initialized",
                    ])
                }
                try player.play(decoder)
                // New decoder starts at frame 0 - reset the stored position so the
                // nil-snapshot fallback in updatePlaybackPosition never carries a
                // stale value from a previous track (which would fake an
                // end-of-track and cut the new track short)
                currentTime = 0
                isPlaying = true
                startUpdateTimer()

                // Attach EQ if user enabled it (will be skipped if previously failed)
                // Note: This is redundant as EQ is attached in delegate, but kept for safety
                attachEqualizerToEngine(with: decoder.processingFormat)

                AppLog.info(.general, "✅ SFBAudioEngine playback started successfully")
            } catch {
                AppLog.error(.general, "❌ Failed to start SFBAudioEngine playback: \(error)")
                // Let PlayerEngine handle error processing and user feedback
                throw error
            }

            AppLog.info(.general, "✅ SFBAudioEngine started playback: \(url.lastPathComponent)")
            AppLog.info(.general, "🎵 SFBAudioEngine loadAndPlay completed successfully")
        }

        func play() throws {
            if let player = audioPlayer {
                // Reactivate audio session when resuming
                do {
                    let audioSession = AVAudioSession.sharedInstance()
                    try audioSession.setActive(true)
                    AppLog.info(.general, "✅ Audio session reactivated on resume")
                } catch {
                    AppLog.warn(.general, "⚠️ Failed to reactivate audio session on resume: \(error)")
                }

                try player.play()
                isPlaying = true
                startUpdateTimer()
                AppLog.info(.general, "▶️ SFBAudioEngine resumed playback")
            } else {
                throw NSError(domain: "SFBAudioEngineManager", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "AudioPlayer not initialized",
                ])
            }
        }

        func pause() {
            AppLog.info(.general, "⏸️ SFBAudioEngineManager.pause() called")

            // Pause the audio player
            audioPlayer?.pause()
            isPlaying = false
            updateTimer?.invalidate()

            // ⚠️ 不在此 deactivate 音频会话（2026-09-12 审计 P3）：系统已按「我们仍关注音频」
            // 判定中断投递，主动 setActive(false) 会让 .ended（.shouldResume）不再送达
            // （被挂起后永远停在暂停态，如 CarPlay 导航播报/来电后）。主引擎对这条路径有
            // 明确相反的纪律与踩坑记录：PlayerEngine+AudioSession.swift 的中断处理
            // （"Do NOT deactivate the audio session here…"）与 PlaybackControl.swift 的
            // "NEVER deactivate session during cleanup"。native 暂停路径也从不 deactivate。
            AppLog.info(.general, "✅ SFBAudioEngineManager paused")
        }

        /// Pause playback for an audio session interruption (alarm, phone call).
        /// SFBAudioPlayer observes AVAudioSessionInterruptionNotification itself:
        /// it pauses on .began and restarts its engine on .ended. Never stop or
        /// start the engine behind its back - SFBAudioPlayer asserts that the
        /// engine's run state matches its cached flag, and the system has
        /// already stopped the engine by the time the notification arrives, so
        /// doing so aborts the app (App Store crash group on 1.2.2).
        func stopEngineForInterruption() {
            audioPlayer?.pause()
            isPlaying = false
            updateTimer?.invalidate()
            AppLog.info(.general, "⏸️ SFBAudioEngine paused for interruption")
        }

        func stop() {
            audioPlayer?.stop()
            isPlaying = false
            currentTime = 0
            currentTrack = nil
            decoderFrameLength = 0
            decoderSampleRate = 0
            updateTimer?.invalidate()
            cleanupEqualizer()
        }

        func seek(to time: TimeInterval) throws {
            guard let player = audioPlayer, let track = currentTrack else {
                AppLog.error(.general, "❌ No audio player or track available for seeking")
                throw NSError(domain: "SFBAudioEngineManager", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "No audio player available",
                ])
            }

            AppLog.info(.general, "🔍 SFBAudioEngine seeking to: \(time)s (duration: \(duration)s)")

            // 失败统一抛错（code 5）不再假装成功：PlayerEngine 据此回滚 UI 位置并提示
            // （2026-08-29 审计 #4）。code 4 保留给 "No audio player available"（P1-B 降级）。
            func seekFailed(_ detail: String) -> NSError {
                NSError(domain: "SFBAudioEngineManager", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "Seek failed",
                    NSLocalizedFailureReasonErrorKey: detail,
                ])
            }

            // For DSD files, try time-based seeking only (frame seeking can cause issues)
            let fileExtension = track.url.pathExtension.lowercased()
            let isDSDFile = fileExtension == "dsf" || fileExtension == "dff"

            if isDSDFile {
                AppLog.info(.general, "🔍 DSD file detected - trying time-based seeking only")
                let timeSeekResult = audioPlayer?.seek(time: time) ?? false
                guard timeSeekResult else {
                    throw seekFailed("DSD time-based seeking failed")
                }
                currentTime = time
                AppLog.info(.general, "✅ DSD file seeked to time: \(time)s")
                return
            }

            // Calculate frame position based on time and sample rate for non-DSD files
            // Use decoder properties if track properties are unavailable (common for M4A files)
            let useSampleRate = track.sampleRate > 0 ? track.sampleRate : decoderSampleRate
            let useTotalFrames = track.frameLength > 0 ? track.frameLength : decoderFrameLength

            if useSampleRate > 0 && duration > 0 && time <= duration && useTotalFrames > 0 {
                let framePosition = Int64(time * useSampleRate)

                // Ensure we don't seek past the end of the file
                let safeFramePosition = min(framePosition, max(0, useTotalFrames - 1))

                AppLog.info(.general, "🔍 Seeking to frame: \(safeFramePosition) of \(useTotalFrames) (time: \(time)s, sampleRate: \(useSampleRate))")

                // Try to seek to the calculated frame position
                // 2026-08-30 警告清理：player 已是非可选 AudioPlayer，去掉恒真 cast
                // Try frame-based seeking first (most precise)
                let seekResult = player.seek(frame: AVAudioFramePosition(safeFramePosition))
                if seekResult {
                    currentTime = time
                    AppLog.info(.general, "✅ SFBAudioEngine seeked to frame: \(safeFramePosition)")
                    return
                }
                // Frame seeking failed, try time-based seeking
                let timeSeekResult = player.seek(time: time)
                if timeSeekResult {
                    currentTime = time
                    AppLog.info(.general, "✅ SFBAudioEngine seeked to time: \(time)s (frame seek failed)")
                    return
                }
                throw seekFailed("Both frame and time seeking failed")
            }

            // Fallback when we don't have proper duration/sampleRate: still attempt a
            // real time-based seek instead of faking success.
            let timeSeekResult = player.seek(time: time)
            guard timeSeekResult else {
                throw seekFailed("No format info and time-based seeking failed")
            }
            currentTime = time
            AppLog.warn(.general, "⚠️ No sample rate or duration, using time-only seeking (succeeded)")
            throw seekFailed("AudioPlayer unavailable for seeking")
        }

        // MARK: - Timer Management

        private func startUpdateTimer() {
            updateTimer?.invalidate()
            updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.updatePlaybackPosition()
                }
            }
        }

        // MARK: - EQ Support

        // supportsEQ() 已删除（2026-09-12 审计死代码 ⚰️-5）：全仓 grep 仅命中定义处，零调用方。

        /// Update EQ settings from EQManager (applies to native SFBAudioEngine EQ)
        func updateEQSettings() {
            applySFBEQSettings()
        }

    }
#endif
