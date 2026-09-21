//  SFBAudioEngineManager+Decoder.swift
//  QQPlayer
//
//  Decoder-facing audio-session support for SFBAudioEngineManager (iOS): apply a
//  decoder's exact format requirements (critical for DSD DoP) and detect an
//  external DAC on the current route.
//
//  2026-09-21 从 SFBAudioEngineManager+Playback.swift 原样搬出（纯搬家，无逻辑变更）。
#if os(iOS)
    import AVFoundation
    import Foundation
    import SFBAudioEngine

    extension SFBAudioEngineManager {
        // MARK: - Audio Session Management

        /// Configure audio session to match decoder's exact requirements (critical for DoP)
        func configureAudioSessionForDecoder(decoder: PCMDecoding, isDSD: Bool, enableDoP: Bool) throws {
            let audioSession = AVAudioSession.sharedInstance()
            let decoderSampleRate = decoder.processingFormat.sampleRate

            AppLog.info(.general, "🎵 Configuring audio session for decoder: sampleRate=\(decoderSampleRate)Hz, isDSD=\(isDSD), enableDoP=\(enableDoP)")

            // Check if we can avoid changing sample rate to prevent buffer underruns
            // Based on SFBAudioEngine issues #347 and #503, frequent rate changes cause problems
            if abs(lastConfiguredSampleRate - decoderSampleRate) < 1.0 && !isDSD {
                AppLog.warn(.general, "🔄 Skipping audio session reconfiguration - sample rate unchanged (\(decoderSampleRate)Hz)")
                return
            }

            if isDSD && enableDoP {
                // For DSD over DoP, session sample rate MUST exactly match decoder output
                AppLog.info(.general, "🎵 Configuring audio session for DSD over DoP - EXACT rate matching required")

                // Log current session state before changes
                AppLog.info(.general, "🔍 Current session state - Rate: \(audioSession.sampleRate)Hz, Buffer: \(audioSession.ioBufferDuration)s")

                // For DSD DoP on iOS, ensure proper audio routing
                do {
                    try audioSession.setCategory(.playback, mode: .default,
                                                 options: [.allowBluetoothA2DP, .allowAirPlay])
                    AppLog.info(.general, "✅ Audio session category set for DoP")
                } catch {
                    AppLog.warn(.general, "⚠️ Category setting failed (continuing): \(error)")
                    // Continue anyway - category might already be correct
                }

                // CRITICAL: Deactivate session first as recommended by SFBAudioEngine wiki
                do {
                    try audioSession.setActive(false)
                    AppLog.info(.general, "✅ Audio session deactivated")
                } catch {
                    AppLog.warn(.general, "⚠️ Session deactivation failed (continuing): \(error)")
                    // Continue anyway - session might already be inactive
                }

                // For DoP on iOS, we need to be more careful about sample rates
                // Some iOS devices/DACs don't support the exact DoP rates, so try fallbacks
                var targetSampleRate = decoderSampleRate

                // If the decoder reports 0.0 (invalid), use CORRECT DoP rate calculation from GitHub issue #185
                // DoP sample rate = DSD sample rate / 16
                if decoderSampleRate <= 0 {
                    AppLog.warn(.general, "⚠️ Decoder reports invalid sample rate (\(decoderSampleRate)Hz), using DSD rate calculation")
                    if let track = currentTrack {
                        let originalRate = track.sampleRate
                        if originalRate > 0 {
                            targetSampleRate = originalRate / 16.0  // Correct DoP formula from GitHub issue #185
                            AppLog.info(.general, "🔄 DSD rate calculation: \(originalRate)Hz ÷ 16 = \(targetSampleRate)Hz (DoP)")
                            AppLog.info(.general, "🔄 Track properties: sampleRate=\(track.sampleRate), frameLength=\(track.frameLength), duration=\(track.duration)")
                        } else {
                            targetSampleRate = 176400 // Default to DSD64 DoP rate
                            AppLog.info(.general, "🔄 Track also has invalid rate, using default DoP rate: \(targetSampleRate)Hz")
                        }
                    } else {
                        targetSampleRate = 176400 // Default to DSD64 DoP rate
                        AppLog.info(.general, "🔄 No track available, using default DoP rate: \(targetSampleRate)Hz")
                    }
                } else {
                    targetSampleRate = decoderSampleRate
                    AppLog.info(.general, "✅ Using decoder sample rate: \(decoderSampleRate)Hz")
                }

                AppLog.info(.general, "🎵 Setting preferred sample rate: \(targetSampleRate)Hz")

                // Try to set the target sample rate with better iOS compatibility
                var finalSampleRate = targetSampleRate
                do {
                    try audioSession.setPreferredSampleRate(targetSampleRate)
                    AppLog.info(.general, "✅ Sample rate set successfully: \(targetSampleRate)Hz")
                } catch {
                    AppLog.warn(.general, "⚠️ Failed to set preferred rate \(targetSampleRate)Hz: \(error)")
                    // Try fallback rates that are more commonly supported on iOS
                    // For DoP, prefer rates that can handle the DoP encoding properly
                    let fallbackRates: [Double] = [176400, 88200, 96000, 48000, 44100]
                    var success = false
                    for rate in fallbackRates {
                        do {
                            try audioSession.setPreferredSampleRate(rate)
                            AppLog.info(.general, "✅ Fallback rate set: \(rate)Hz")
                            finalSampleRate = rate
                            success = true
                            break
                        } catch {
                            AppLog.warn(.general, "⚠️ Fallback rate \(rate)Hz also failed: \(error)")
                        }
                    }
                    if !success {
                        AppLog.warn(.general, "⚠️ All sample rate attempts failed, using current session rate")
                        finalSampleRate = audioSession.sampleRate
                    }
                }

                // Use larger, more stable buffer to prevent ring buffer underruns
                // Based on SFBAudioEngine issues #347 and #503, smaller buffers can cause underruns
                do {
                    try audioSession.setPreferredIOBufferDuration(0.040) // 40ms buffer for stability
                    AppLog.info(.general, "✅ Buffer duration set: 40ms for ring buffer stability")
                } catch {
                    AppLog.warn(.general, "⚠️ Failed to set buffer duration: \(error)")
                    // Try progressively larger buffers for stability
                    let fallbackBuffers: [Double] = [0.030, 0.023, 0.020]
                    for buffer in fallbackBuffers {
                        do {
                            try audioSession.setPreferredIOBufferDuration(buffer)
                            AppLog.info(.general, "✅ Fallback buffer duration set: \(Int(buffer * 1000))ms")
                            break
                        } catch {
                            AppLog.warn(.general, "⚠️ Fallback buffer \(Int(buffer * 1000))ms failed: \(error)")
                        }
                    }
                }

                // Reactivate with new settings
                do {
                    try audioSession.setActive(true)
                    AppLog.info(.general, "✅ Audio session reactivated with new DoP settings")
                } catch {
                    AppLog.warn(.general, "⚠️ Session reactivation failed: \(error)")
                    // This is more critical - try to activate anyway
                    do {
                        try audioSession.setActive(true, options: [])
                        AppLog.info(.general, "✅ Audio session activated with fallback options")
                    } catch {
                        AppLog.error(.general, "❌ Could not activate audio session: \(error)")
                        throw error
                    }
                }

                // Log final session state after all changes
                AppLog.info(.general, "🎵 DSD DoP audio session configured:"
                    + "\n  📊 Requested sample rate: \(targetSampleRate)Hz"
                    + "\n  📊 Actual session rate: \(audioSession.sampleRate)Hz"
                    + "\n  📊 Buffer duration: \(audioSession.ioBufferDuration)s"
                    + "\n  📊 Category: \(audioSession.category)"
                    + "\n  📊 Mode: \(audioSession.mode)")

                // Verify the sample rate was actually set correctly
                // Compare against final rate that was successfully set
                if abs(audioSession.sampleRate - finalSampleRate) > 1.0 {
                    AppLog.warn(.general, "⚠️ WARNING: Audio session sample rate (\(audioSession.sampleRate)Hz) does not match set rate (\(finalSampleRate)Hz)")
                    AppLog.warn(.general, "⚠️ This may cause DoP playback issues")
                } else {
                    AppLog.info(.general, "✅ Sample rates match final rate - DoP should work correctly")
                }

                lastConfiguredSampleRate = audioSession.sampleRate

            } else if isDSD && !enableDoP {
                // For DSD to PCM conversion, use appropriate sample rate
                AppLog.info(.general, "🎵 Configuring audio session for DSD PCM conversion")

                try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP, .allowAirPlay])

                // Deactivate first
                try audioSession.setActive(false)

                // For DSD PCM, use the decoder's output rate
                try audioSession.setPreferredSampleRate(decoderSampleRate)
                try audioSession.setPreferredIOBufferDuration(0.040) // 40ms buffer for ring buffer stability

                try audioSession.setActive(true)

                AppLog.info(.general, "🎵 DSD PCM audio session configured: requested=\(decoderSampleRate)Hz, actual=\(audioSession.sampleRate)Hz")
                lastConfiguredSampleRate = audioSession.sampleRate

            } else {
                // For non-DSD files, use standard configuration but still match decoder rate
                try audioSession.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP])

                try audioSession.setActive(false)
                try audioSession.setPreferredSampleRate(decoderSampleRate)
                try audioSession.setPreferredIOBufferDuration(0.040) // 40ms buffer for ring buffer stability
                try audioSession.setActive(true)

                AppLog.info(.general, "🔊 Standard audio session configured: requested=\(decoderSampleRate)Hz, actual=\(audioSession.sampleRate)Hz")
                lastConfiguredSampleRate = audioSession.sampleRate
            }
        }

        // MARK: - DAC Detection

        /// 分片：跨文件可见（原 private）
        func checkForExternalDAC() async -> Bool {
            let audioSession = AVAudioSession.sharedInstance()
            let currentRoute = audioSession.currentRoute

            AppLog.info(.general, "🔍 Checking iOS audio route for external DAC...")

            // Check all audio outputs for iOS-specific DAC detection
            for output in currentRoute.outputs {
                if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🔍 Audio output: \(output.portName) (type: \(output.portType.rawValue))") }

                // Consider various external audio devices as potential DACs on iOS
                switch output.portType {
                case .usbAudio:
                    AppLog.info(.general, "🎵 Found USB DAC: \(output.portName)")
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
                        AppLog.warn(.general, "🚫 Excluding non-DAC device: \(output.portName)")
                        return false
                    }

                    // Check for known DAC brands FIRST (dedicated audio equipment only)
                    let dacBrands = ["fosi", "topping", "ifi", "audioquest", "chord", "schiit", "jds", "fiio",
                                     "denafrips", "ps audio", "mcintosh", "cambridge", "marantz", "denon",
                                     "smsl", "aune", "gustard", "matrix", "burson", "lehmann", "benchmark",
                                     "mojo", "hugo", "questyle", "cayin", "astell", "kann", "dx"]
                    for brand in dacBrands where portNameLower.contains(brand) {
                        AppLog.info(.general, "🎵 Found recognized DAC brand: \(output.portName)")
                        return true
                    }

                    // Check for EXPLICIT DAC keywords (very specific - requires "dac" or "dsd")
                    // Do NOT use generic terms like "amp" or "hi-res" as those appear in marketing names
                    if portNameLower.contains(" dac") || portNameLower.contains("dac ") ||
                        portNameLower.contains("-dac") || portNameLower.contains("dac-") ||
                        portNameLower.contains("dsd") || portNameLower.contains("headphone amplifier") {
                        AppLog.info(.general, "🎵 Found DAC device by explicit keyword: \(output.portName)")
                        return true
                    }

                    // For headphones port type, DEFAULT to false (no DAC)
                    // User should have a recognizable DAC brand or explicit DAC keyword
                    AppLog.info(.general, "ℹ️ Headphones detected but no DAC indicators: \(output.portName)")
                case .lineOut:
                    AppLog.info(.general, "🎵 Found line out (potential DAC): \(output.portName)")
                    return true
                case .bluetoothA2DP:
                    // High-end Bluetooth devices that may support better audio quality
                    let bluetoothKeywords = ["ldac", "aptx", "dsd", "hi-res", "hires"]
                    let portNameLower = output.portName.lowercased()
                    for keyword in bluetoothKeywords where portNameLower.contains(keyword) {
                        AppLog.info(.general, "🎵 Found high-quality Bluetooth DAC: \(output.portName)")
                        return true
                    }
                default:
                    // Check for any port that's not the built-in speaker/receiver
                    if output.portType != .builtInSpeaker && output.portType != .builtInReceiver {
                        AppLog.info(.general, "🔍 Found non-built-in audio device: \(output.portName)")
                        // For iOS, be more conservative - only treat as DAC if name suggests it
                        let portNameLower = output.portName.lowercased()
                        if portNameLower.contains("dac") || portNameLower.contains("external") {
                            AppLog.info(.general, "🎵 Found external DAC device: \(output.portName)")
                            return true
                        }
                    }
                }
            }

            // Also check inputs for USB audio interfaces (less common on iOS but possible)
            for input in currentRoute.inputs where input.portType == .usbAudio {
                AppLog.info(.general, "🎵 Found USB audio interface: \(input.portName)")
                return true
            }

            AppLog.info(.general, "🔍 No external DAC detected on iOS - using internal audio with PCM conversion")
            return false
        }
    }
#endif
