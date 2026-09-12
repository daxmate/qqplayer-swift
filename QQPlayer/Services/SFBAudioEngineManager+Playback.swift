//  SFBAudioEngineManager+Playback.swift
//  QQPlayer
//
//  Playback control for SFBAudioEngineManager: loadAndPlay, play/pause/stop,
//  seek, EQ support, and audio-session configuration for decoders.
//

#if os(iOS)
    import AVFoundation
    import Foundation
    import SFBAudioEngine
    extension SFBAudioEngineManager {
        // MARK: - Playback Control

        func loadAndPlay(url: URL) async throws {
            print("🚀 SFBAudioEngine.loadAndPlay called for: \(url.lastPathComponent)")
            try Task.checkCancellation()

            // Don't use SFBAudioEngine in CarPlay environment
            if isCarPlayEnvironment {
                print("🚗 CarPlay detected - refusing to load with SFBAudioEngine")
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

            print("🔍 SFBAudioEngine attempting to load: \(url.lastPathComponent)")

            // Create track and get properties/metadata first to get sample rate.
            // SFBTrack's init does a synchronous TagLib read of the whole file's
            // metadata - run it off the main actor so the UI doesn't hitch
            print("🔍 Creating SFBTrack for: \(url.lastPathComponent)")
            let track = await Task.detached(priority: .userInitiated) { SFBTrack(url: url) }.value
            try Task.checkCancellation()
            currentTrack = track

            // Set duration from track
            duration = track.duration
            print("📊 Track duration: \(duration) seconds")

            // Check user's DSD playback preference
            let settings = DeleteSettings.load()
            let isDSDFile = url.pathExtension.lowercased() == "dsf" || url.pathExtension.lowercased() == "dff"

            let enableDoP: Bool
            if isDSDFile {
                switch settings.dsdPlaybackMode {
                case .auto:
                    // Auto mode - detect DAC
                    enableDoP = await checkForExternalDAC()
                    print("🎵 DSD file detected, Auto mode: DAC present = \(enableDoP)")
                case .pcm:
                    // Always use PCM conversion
                    enableDoP = false
                    print("🎵 DSD file detected, PCM mode: Will convert to PCM")
                case .dop:
                    // Always use DoP
                    enableDoP = true
                    print("🎵 DSD file detected, DoP mode: Will use DoP encoding")
                }
            } else {
                enableDoP = false
            }

            print("🔍 Getting decoder for: \(url.lastPathComponent), enableDoP: \(enableDoP)")
            try Task.checkCancellation()

            guard let decoder = try track.decoder(enableDoP: enableDoP) else {
                print("❌ No decoder available for: \(url.lastPathComponent)")
                throw NSError(domain: "SFBAudioEngineManager", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Unsupported audio format",
                ])
            }

            print("🔧 Decoder created successfully")

            // Try to open the decoder to ensure format properties are available
            do {
                try decoder.open()
                try Task.checkCancellation()
                print("🔧 Decoder opened successfully")
            } catch {
                print("⚠️ Failed to open decoder: \(error)")
                // Continue anyway - some decoders might work without explicit opening
            }

            print("🔧 Decoder format: \(decoder.processingFormat)")
            print("🔧 Decoder sample rate: \(decoder.processingFormat.sampleRate)")
            print("🔧 Decoder channel count: \(decoder.processingFormat.channelCount)")

            // Also try to get source format for comparison
            let sourceFormat = decoder.sourceFormat
            print("🔧 Source format: \(sourceFormat)")
            print("🔧 Source sample rate: \(sourceFormat.sampleRate)")
            print("🔧 Source channel count: \(sourceFormat.channelCount)")

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
                print("⚠️ Decoder format properties unavailable: processing(sampleRate=\(decoderSampleRate), channels=\(decoderChannelCount)), source(sampleRate=\(sourceSampleRate), channels=\(sourceChannelCount))")
                print("🔄 Proceeding with playback - SFBAudioEngine may handle format internally")

                // Use default values for configuration
                self.decoderSampleRate = 48000 // Default sample rate
            } else {
                print("✅ Valid decoder properties: sampleRate=\(finalSampleRate), channels=\(finalChannelCount)")
                self.decoderSampleRate = finalSampleRate
            }

            // Store decoder properties for seeking when AudioFile properties are unavailable
            decoderFrameLength = decoder.length
            print("🔄 Stored decoder properties: frameLength=\(decoderFrameLength), sampleRate=\(self.decoderSampleRate)")

            // Update duration from decoder if it wasn't available from AudioFile and we have valid properties
            if duration == 0 && decoderFrameLength > 0 && self.decoderSampleRate > 0 {
                duration = Double(decoderFrameLength) / self.decoderSampleRate
                print("🔄 Updated duration from decoder: \(duration)s")
            }

            // CRITICAL: Configure audio session AFTER decoder creation and BEFORE playback
            // Use the determined sample rate for accurate configuration
            let actualSampleRate = self.decoderSampleRate
            print("🔍 Using determined sample rate: \(actualSampleRate)Hz")
            try Task.checkCancellation()

            do {
                try configureAudioSessionForDecoder(decoder: decoder, isDSD: isDSDFile, enableDoP: enableDoP)
            } catch {
                print("⚠️ Audio session configuration had warnings (ignoring): \(error)")
            }

            if isDSDFile {
                print("🔄 Resetting AudioPlayer for DSD file to prevent state issues")
                resetAudioPlayer()
            } else if audioPlayer?.isPlaying == true {
                print("🔄 Stopping existing playback before starting new track")
                audioPlayer?.stop()
                try await Task.sleep(nanoseconds: 100_000_000)
            }

            // Start playback with proper error handling
            print("🎵 Starting SFBAudioEngine playback...")
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

                print("✅ SFBAudioEngine playback started successfully")
            } catch {
                print("❌ Failed to start SFBAudioEngine playback: \(error)")
                // Let PlayerEngine handle error processing and user feedback
                throw error
            }

            print("✅ SFBAudioEngine started playback: \(url.lastPathComponent)")
            print("🎵 SFBAudioEngine loadAndPlay completed successfully")
        }

        func play() throws {
            if let player = audioPlayer {
                // Reactivate audio session when resuming
                do {
                    let audioSession = AVAudioSession.sharedInstance()
                    try audioSession.setActive(true)
                    print("✅ Audio session reactivated on resume")
                } catch {
                    print("⚠️ Failed to reactivate audio session on resume: \(error)")
                }

                try player.play()
                isPlaying = true
                startUpdateTimer()
                print("▶️ SFBAudioEngine resumed playback")
            } else {
                throw NSError(domain: "SFBAudioEngineManager", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "AudioPlayer not initialized",
                ])
            }
        }

        func pause() {
            print("⏸️ SFBAudioEngineManager.pause() called")

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
            print("✅ SFBAudioEngineManager paused")
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
            print("⏸️ SFBAudioEngine paused for interruption")
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
                print("❌ No audio player or track available for seeking")
                throw NSError(domain: "SFBAudioEngineManager", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "No audio player available",
                ])
            }

            print("🔍 SFBAudioEngine seeking to: \(time)s (duration: \(duration)s)")

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
                print("🔍 DSD file detected - trying time-based seeking only")
                let timeSeekResult = audioPlayer?.seek(time: time) ?? false
                guard timeSeekResult else {
                    throw seekFailed("DSD time-based seeking failed")
                }
                currentTime = time
                print("✅ DSD file seeked to time: \(time)s")
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

                print("🔍 Seeking to frame: \(safeFramePosition) of \(useTotalFrames) (time: \(time)s, sampleRate: \(useSampleRate))")

                // Try to seek to the calculated frame position
                // 2026-08-30 警告清理：player 已是非可选 AudioPlayer，去掉恒真 cast
                // Try frame-based seeking first (most precise)
                let seekResult = player.seek(frame: AVAudioFramePosition(safeFramePosition))
                if seekResult {
                    currentTime = time
                    print("✅ SFBAudioEngine seeked to frame: \(safeFramePosition)")
                    return
                }
                // Frame seeking failed, try time-based seeking
                let timeSeekResult = player.seek(time: time)
                if timeSeekResult {
                    currentTime = time
                    print("✅ SFBAudioEngine seeked to time: \(time)s (frame seek failed)")
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
            print("⚠️ No sample rate or duration, using time-only seeking (succeeded)")
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

        // MARK: - Audio Session Management

        /// Configure audio session to match decoder's exact requirements (critical for DoP)
        func configureAudioSessionForDecoder(decoder: PCMDecoding, isDSD: Bool, enableDoP: Bool) throws {
            let audioSession = AVAudioSession.sharedInstance()
            let decoderSampleRate = decoder.processingFormat.sampleRate

            print("🎵 Configuring audio session for decoder: sampleRate=\(decoderSampleRate)Hz, isDSD=\(isDSD), enableDoP=\(enableDoP)")

            // Check if we can avoid changing sample rate to prevent buffer underruns
            // Based on SFBAudioEngine issues #347 and #503, frequent rate changes cause problems
            if abs(lastConfiguredSampleRate - decoderSampleRate) < 1.0 && !isDSD {
                print("🔄 Skipping audio session reconfiguration - sample rate unchanged (\(decoderSampleRate)Hz)")
                return
            }

            if isDSD && enableDoP {
                // For DSD over DoP, session sample rate MUST exactly match decoder output
                print("🎵 Configuring audio session for DSD over DoP - EXACT rate matching required")

                // Log current session state before changes
                print("🔍 Current session state - Rate: \(audioSession.sampleRate)Hz, Buffer: \(audioSession.ioBufferDuration)s")

                // For DSD DoP on iOS, ensure proper audio routing
                do {
                    try audioSession.setCategory(.playback, mode: .default,
                                                 options: [.allowBluetoothA2DP, .allowAirPlay])
                    print("✅ Audio session category set for DoP")
                } catch {
                    print("⚠️ Category setting failed (continuing): \(error)")
                    // Continue anyway - category might already be correct
                }

                // CRITICAL: Deactivate session first as recommended by SFBAudioEngine wiki
                do {
                    try audioSession.setActive(false)
                    print("✅ Audio session deactivated")
                } catch {
                    print("⚠️ Session deactivation failed (continuing): \(error)")
                    // Continue anyway - session might already be inactive
                }

                // For DoP on iOS, we need to be more careful about sample rates
                // Some iOS devices/DACs don't support the exact DoP rates, so try fallbacks
                var targetSampleRate = decoderSampleRate

                // If the decoder reports 0.0 (invalid), use CORRECT DoP rate calculation from GitHub issue #185
                // DoP sample rate = DSD sample rate / 16
                if decoderSampleRate <= 0 {
                    print("⚠️ Decoder reports invalid sample rate (\(decoderSampleRate)Hz), using DSD rate calculation")
                    if let track = currentTrack {
                        let originalRate = track.sampleRate
                        if originalRate > 0 {
                            targetSampleRate = originalRate / 16.0  // Correct DoP formula from GitHub issue #185
                            print("🔄 DSD rate calculation: \(originalRate)Hz ÷ 16 = \(targetSampleRate)Hz (DoP)")
                            print("🔄 Track properties: sampleRate=\(track.sampleRate), frameLength=\(track.frameLength), duration=\(track.duration)")
                        } else {
                            targetSampleRate = 176400 // Default to DSD64 DoP rate
                            print("🔄 Track also has invalid rate, using default DoP rate: \(targetSampleRate)Hz")
                        }
                    } else {
                        targetSampleRate = 176400 // Default to DSD64 DoP rate
                        print("🔄 No track available, using default DoP rate: \(targetSampleRate)Hz")
                    }
                } else {
                    targetSampleRate = decoderSampleRate
                    print("✅ Using decoder sample rate: \(decoderSampleRate)Hz")
                }

                print("🎵 Setting preferred sample rate: \(targetSampleRate)Hz")

                // Try to set the target sample rate with better iOS compatibility
                var finalSampleRate = targetSampleRate
                do {
                    try audioSession.setPreferredSampleRate(targetSampleRate)
                    print("✅ Sample rate set successfully: \(targetSampleRate)Hz")
                } catch {
                    print("⚠️ Failed to set preferred rate \(targetSampleRate)Hz: \(error)")
                    // Try fallback rates that are more commonly supported on iOS
                    // For DoP, prefer rates that can handle the DoP encoding properly
                    let fallbackRates: [Double] = [176400, 88200, 96000, 48000, 44100]
                    var success = false
                    for rate in fallbackRates {
                        do {
                            try audioSession.setPreferredSampleRate(rate)
                            print("✅ Fallback rate set: \(rate)Hz")
                            finalSampleRate = rate
                            success = true
                            break
                        } catch {
                            print("⚠️ Fallback rate \(rate)Hz also failed: \(error)")
                        }
                    }
                    if !success {
                        print("⚠️ All sample rate attempts failed, using current session rate")
                        finalSampleRate = audioSession.sampleRate
                    }
                }

                // Use larger, more stable buffer to prevent ring buffer underruns
                // Based on SFBAudioEngine issues #347 and #503, smaller buffers can cause underruns
                do {
                    try audioSession.setPreferredIOBufferDuration(0.040) // 40ms buffer for stability
                    print("✅ Buffer duration set: 40ms for ring buffer stability")
                } catch {
                    print("⚠️ Failed to set buffer duration: \(error)")
                    // Try progressively larger buffers for stability
                    let fallbackBuffers: [Double] = [0.030, 0.023, 0.020]
                    for buffer in fallbackBuffers {
                        do {
                            try audioSession.setPreferredIOBufferDuration(buffer)
                            print("✅ Fallback buffer duration set: \(Int(buffer * 1000))ms")
                            break
                        } catch {
                            print("⚠️ Fallback buffer \(Int(buffer * 1000))ms failed: \(error)")
                        }
                    }
                }

                // Reactivate with new settings
                do {
                    try audioSession.setActive(true)
                    print("✅ Audio session reactivated with new DoP settings")
                } catch {
                    print("⚠️ Session reactivation failed: \(error)")
                    // This is more critical - try to activate anyway
                    do {
                        try audioSession.setActive(true, options: [])
                        print("✅ Audio session activated with fallback options")
                    } catch {
                        print("❌ Could not activate audio session: \(error)")
                        throw error
                    }
                }

                // Log final session state after all changes
                print("🎵 DSD DoP audio session configured:")
                print("  📊 Requested sample rate: \(targetSampleRate)Hz")
                print("  📊 Actual session rate: \(audioSession.sampleRate)Hz")
                print("  📊 Buffer duration: \(audioSession.ioBufferDuration)s")
                print("  📊 Category: \(audioSession.category)")
                print("  📊 Mode: \(audioSession.mode)")

                // Verify the sample rate was actually set correctly
                // Compare against final rate that was successfully set
                if abs(audioSession.sampleRate - finalSampleRate) > 1.0 {
                    print("⚠️ WARNING: Audio session sample rate (\(audioSession.sampleRate)Hz) does not match set rate (\(finalSampleRate)Hz)")
                    print("⚠️ This may cause DoP playback issues")
                } else {
                    print("✅ Sample rates match final rate - DoP should work correctly")
                }

                lastConfiguredSampleRate = audioSession.sampleRate

            } else if isDSD && !enableDoP {
                // For DSD to PCM conversion, use appropriate sample rate
                print("🎵 Configuring audio session for DSD PCM conversion")

                try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP, .allowAirPlay])

                // Deactivate first
                try audioSession.setActive(false)

                // For DSD PCM, use the decoder's output rate
                try audioSession.setPreferredSampleRate(decoderSampleRate)
                try audioSession.setPreferredIOBufferDuration(0.040) // 40ms buffer for ring buffer stability

                try audioSession.setActive(true)

                print("🎵 DSD PCM audio session configured: requested=\(decoderSampleRate)Hz, actual=\(audioSession.sampleRate)Hz")
                lastConfiguredSampleRate = audioSession.sampleRate

            } else {
                // For non-DSD files, use standard configuration but still match decoder rate
                try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP])

                try audioSession.setActive(false)
                try audioSession.setPreferredSampleRate(decoderSampleRate)
                try audioSession.setPreferredIOBufferDuration(0.040) // 40ms buffer for ring buffer stability
                try audioSession.setActive(true)

                print("🔊 Standard audio session configured: requested=\(decoderSampleRate)Hz, actual=\(audioSession.sampleRate)Hz")
                lastConfiguredSampleRate = audioSession.sampleRate
            }
        }

        // MARK: - DAC Detection

        private func checkForExternalDAC() async -> Bool {
            let audioSession = AVAudioSession.sharedInstance()
            let currentRoute = audioSession.currentRoute

            print("🔍 Checking iOS audio route for external DAC...")

            // Check all audio outputs for iOS-specific DAC detection
            for output in currentRoute.outputs {
                print("🔍 Audio output: \(output.portName) (type: \(output.portType.rawValue))")

                // Consider various external audio devices as potential DACs on iOS
                switch output.portType {
                case .usbAudio:
                    print("🎵 Found USB DAC: \(output.portName)")
                    return true
                case .headphones:
                    // On iOS, many DACs appear as headphones when connected via Lightning/USB-C adapters
                    // IMPORTANT: Be very conservative here - only true DACs should return true
                    let portNameLower = output.portName.lowercased()

                    // EXCLUDE computers, CarPlay, and basic audio devices - these are NOT DACs
                    let excludedDevices = ["macbook", "imac", "mac mini", "mac pro", "mac studio",
                                           "carplay", "car play", "android auto", "computer", "pc", "laptop",
                                           "earpods", "airpods", "headset", "earphones", "apple headphones",
                                           "lightning to 3.5", "usb-c to 3.5"]
                    for excludedDevice in excludedDevices where portNameLower.contains(excludedDevice) {
                        print("🚫 Excluding non-DAC device: \(output.portName)")
                        return false
                    }

                    // Check for known DAC brands FIRST (dedicated audio equipment only)
                    let dacBrands = ["fosi", "topping", "ifi", "audioquest", "chord", "schiit", "jds", "fiio",
                                     "denafrips", "ps audio", "mcintosh", "cambridge", "marantz", "denon",
                                     "smsl", "aune", "gustard", "matrix", "burson", "lehmann", "benchmark",
                                     "mojo", "hugo", "questyle", "cayin", "astell", "kann", "dx"]
                    for brand in dacBrands where portNameLower.contains(brand) {
                        print("🎵 Found recognized DAC brand: \(output.portName)")
                        return true
                    }

                    // Check for EXPLICIT DAC keywords (very specific - requires "dac" or "dsd")
                    // Do NOT use generic terms like "amp" or "hi-res" as those appear in marketing names
                    if portNameLower.contains(" dac") || portNameLower.contains("dac ") ||
                        portNameLower.contains("-dac") || portNameLower.contains("dac-") ||
                        portNameLower.contains("dsd") || portNameLower.contains("headphone amplifier") {
                        print("🎵 Found DAC device by explicit keyword: \(output.portName)")
                        return true
                    }

                    // For headphones port type, DEFAULT to false (no DAC)
                    // User should have a recognizable DAC brand or explicit DAC keyword
                    print("ℹ️ Headphones detected but no DAC indicators: \(output.portName)")
                case .lineOut:
                    print("🎵 Found line out (potential DAC): \(output.portName)")
                    return true
                case .bluetoothA2DP:
                    // High-end Bluetooth devices that may support better audio quality
                    let bluetoothKeywords = ["ldac", "aptx", "dsd", "hi-res", "hires"]
                    let portNameLower = output.portName.lowercased()
                    for keyword in bluetoothKeywords where portNameLower.contains(keyword) {
                        print("🎵 Found high-quality Bluetooth DAC: \(output.portName)")
                        return true
                    }
                default:
                    // Check for any port that's not the built-in speaker/receiver
                    if output.portType != .builtInSpeaker && output.portType != .builtInReceiver {
                        print("🔍 Found non-built-in audio device: \(output.portName)")
                        // For iOS, be more conservative - only treat as DAC if name suggests it
                        let portNameLower = output.portName.lowercased()
                        if portNameLower.contains("dac") || portNameLower.contains("external") {
                            print("🎵 Found external DAC device: \(output.portName)")
                            return true
                        }
                    }
                }
            }

            // Also check inputs for USB audio interfaces (less common on iOS but possible)
            for input in currentRoute.inputs where input.portType == .usbAudio {
                print("🎵 Found USB audio interface: \(input.portName)")
                return true
            }

            print("🔍 No external DAC detected on iOS - using internal audio with PCM conversion")
            return false
        }
    }

#else
    import AVFoundation
    import Foundation
    import SFBAudioEngine

    extension SFBAudioEngineManager {
        // macOS SFB playback: AudioPlayer (SFBAudioEngine) is cross-platform.
        // No CarPlay / AVAudioSession / DSD DoP preference on macOS — DSD decodes
        // to PCM and the system audio output handles the rest.

        // EQ 状态变化（开关/预设/全局增益）时把运行时数据应用到已 attach 的
        // SFB EQ 节点；共享实现在主文件（configureSFBEQBands/applySFBEQSettings）。
        func updateEQSettings() {
            applySFBEQSettings()
        }

        func loadAndPlay(url: URL) async throws {
            try Task.checkCancellation()

            setupAudioPlayer()
            guard let player = audioPlayer else {
                throw NSError(domain: "SFBAudioEngineManager", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "SFBAudioEngine unavailable - AudioPlayer initialization failed",
                ])
            }

            player.stop()
            cleanupEqualizer()
            try Task.checkCancellation()

            let track = await Task.detached(priority: .userInitiated) { SFBTrack(url: url) }.value
            try Task.checkCancellation()
            currentTrack = track
            duration = track.duration

            guard let decoder = try track.decoder(enableDoP: false) else {
                throw NSError(domain: "SFBAudioEngineManager", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Unsupported audio format",
                ])
            }

            do {
                try decoder.open()
            } catch {
                print("⚠️ Failed to open decoder: \(error)")
            }

            decoderSampleRate = decoder.processingFormat.sampleRate
            decoderFrameLength = decoder.length
            if duration == 0, decoderFrameLength > 0, decoderSampleRate > 0 {
                duration = Double(decoderFrameLength) / decoderSampleRate
            }

            try player.play(decoder)
            // EQ 已启用时把 EQ 节点插入播放图（对齐 iOS 分支 attachEqualizerToEngine
            // 调用点；未启用/先前失败时内部自动跳过）
            attachEqualizerToEngine(with: decoder.processingFormat)
            currentTime = 0
            isPlaying = true
            startUpdateTimer()
            print("✅ macOS SFBAudioEngine playback started: \(url.lastPathComponent)")
        }

        func play() throws {
            guard let player = audioPlayer else {
                throw NSError(domain: "SFBAudioEngineManager", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "AudioPlayer not initialized",
                ])
            }
            try player.play()
            isPlaying = true
            startUpdateTimer()
        }

        func pause() {
            audioPlayer?.pause()
            isPlaying = false
            updateTimer?.invalidate()
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
                throw NSError(domain: "SFBAudioEngineManager", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "No audio player available",
                ])
            }

            func seekFailed(_ detail: String) -> NSError {
                NSError(domain: "SFBAudioEngineManager", code: 5, userInfo: [
                    NSLocalizedDescriptionKey: "Seek failed",
                    NSLocalizedFailureReasonErrorKey: detail,
                ])
            }

            let useSampleRate = track.sampleRate > 0 ? track.sampleRate : decoderSampleRate
            let useTotalFrames = track.frameLength > 0 ? track.frameLength : decoderFrameLength

            if useSampleRate > 0, duration > 0, time <= duration, useTotalFrames > 0 {
                let framePosition = Int64(time * useSampleRate)
                let safeFramePosition = min(framePosition, max(0, useTotalFrames - 1))
                if player.seek(frame: AVAudioFramePosition(safeFramePosition)) {
                    currentTime = time
                    return
                }
            }

            guard player.seek(time: time) else {
                throw seekFailed("No format info and time-based seeking failed")
            }
            currentTime = time
        }

        // MARK: - Timer Management (macOS)

        private func startUpdateTimer() {
            updateTimer?.invalidate()
            updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.updatePlaybackPosition()
                }
            }
        }
    }
#endif
