//  PlayerEngine+AudioSession.swift
//  QQPlayer
//
//  Audio session wiring for PlayerEngine (iOS): session category/activation and
//  the native-reset entry points; notification wiring and session-event handlers
//  live in the sibling files below.
//
//  2026-09-21 结构拆分（纯搬家，无逻辑变更）。同族文件：
//    · PlayerEngine+AudioEngineSetup.swift    — AVAudioEngine 装配与播放链连接
//    · PlayerEngine+AudioSessionEvents.swift  — 通知装配 + 打断/路由/引擎重配/内存告警处理
//    · PlayerEngine+AudioEngineRecovery.swift — 媒体服务重置处理 + 引擎清理与重建
#if os(iOS)
    import AVFoundation
    import Foundation
    import UIKit
    extension PlayerEngine {
        func ensureAudioSessionSetup() {
            guard !hasSetupAudioSession else { return }
            hasSetupAudioSession = true

            do {
                try setupAudioSessionCategory()
            } catch {
                AppLog.error(.general, "Failed to setup audio session category: \(error)")
                // Continue anyway - we'll try to handle this when actually playing
            }
        }

        // MARK: - Audio Session Management

        private func setupAudioSessionCategory() throws {
            let s = AVAudioSession.sharedInstance()
            let isCarPlayEnvironment = sfbAudioManager.isCarPlayEnvironment
                || s.currentRoute.outputs.contains { $0.portType == .carAudio }

            // For background audio, avoid mixWithOthers - be the primary audio app
            let options: AVAudioSession.CategoryOptions = [.allowAirPlay, .allowBluetoothA2DP]

            // A connected CarPlay scene can own the session before `.carAudio`
            // appears in currentRoute. If the category is already playback, keep
            // CarPlay's mode/options instead of forcing another live reconfigure.
            if s.category != .playback || (!isCarPlayEnvironment && s.mode != .default) {
                try s.setCategory(.playback, mode: .default, options: options)
            }

            // CarPlay owns the hardware I/O settings for its active route. Asking to
            // change the buffer while that route is active fails with paramErr (-50)
            // and can trigger an unnecessary mediaserverd reconfiguration.
            if !isCarPlayEnvironment {
                try s.setPreferredIOBufferDuration(0.023) // 23ms buffer - good balance for iOS 18
            }

            AppLog.info(.general, "🎧 Audio session category configured for primary playback (no mixWithOthers)")
        }

        func activateAudioSession() throws {
            let s = AVAudioSession.sharedInstance()
            let isCarPlayEnvironment = sfbAudioManager.isCarPlayEnvironment
                || s.currentRoute.outputs.contains { $0.portType == .carAudio }

            AppLog.info(.general, "🎧 Audio session state - Category: \(s.category), Other audio: \(s.isOtherAudioPlaying)")

            // Changing category/options on an already configured CarPlay session
            // forces another hardware route rebuild. Configure only when the
            // session is not already in the mode we need.
            if s.category != .playback || (!isCarPlayEnvironment && s.mode != .default) {
                try setupAudioSessionCategory()
            }

            // Always try to activate (iOS manages the actual state)
            try s.setActive(true, options: [])
            AppLog.info(.general, "🎧 Audio session activation attempted successfully")

            UIApplication.shared.beginReceivingRemoteControlEvents()
            AppLog.info(.general, "🎧 Remote control events enabled")
        }

        // MARK: - Audio Session Configuration

        /// Reset AVAudioEngine to clean state when switching from SFBAudioEngine
        func resetAudioEngineForNative() {
            AppLog.info(.general, "🔄 Resetting AVAudioEngine for native playback")

            // Stop and reset the audio engine completely
            if audioEngine.isRunning {
                audioEngine.stop()
                AppLog.info(.general, "✅ AVAudioEngine stopped")
            }

            // Reset player node
            if playerNode.isPlaying {
                playerNode.stop()
            }

            // Replace the complete graph with detached instances. This transition
            // is hit when CarPlay takes over while SFBAudioEngine was playing.
            // setupAudioEngine will attach each node exactly once after the
            // CarPlay route and its hardware format have settled.
            eqManager.setAudioEngine(nil)
            audioEngine = AVAudioEngine()
            playerNode = AVAudioPlayerNode()

            // Reset setup flag to force proper reconnection
            hasSetupAudioEngine = false
            lastSampleRate = 0

            AppLog.info(.general, "✅ AVAudioEngine reset complete for native playback")
        }

        /// Reset audio session to standard configuration when switching from SFBAudioEngine
        func resetAudioSessionForNative() async {
            // AVAudioSession calls are blocking XPC round-trips to mediaserverd -
            // run them off the main thread so the UI never freezes
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let session = AVAudioSession.sharedInstance()

                        AppLog.info(.general, "🔄 Resetting audio session for native playback after SFBAudioEngine")

                        // Deactivate first to clear any SFBAudioEngine DoP/DSD configuration
                        try session.setActive(false)

                        // Set standard category for native playback
                        try session.setCategory(.playback, mode: .default, options: [.allowBluetoothA2DP])

                        // Reset to standard sample rate and buffer for native AVAudioEngine
                        try session.setPreferredSampleRate(44100) // Start with standard rate
                        try session.setPreferredIOBufferDuration(0.020) // 20ms buffer for native

                        // Reactivate with new settings
                        try session.setActive(true)
                        AppLog.info(.general, "✅ Audio session reset and reactivated for native playback")

                    } catch {
                        AppLog.warn(.general, "⚠️ Audio session reset failed (continuing): \(error)")
                        // Continue anyway - the next configureAudioSession call will fix it
                    }
                    continuation.resume()
                }
            }
        }

        func configureAudioSession(for format: AVAudioFormat) async {
            let targetSampleRate = currentTrack?.sampleRate
            let carPlaySceneIsActive = sfbAudioManager.isCarPlayEnvironment
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let session = AVAudioSession.sharedInstance()
                        let isCarPlayEnvironment = carPlaySceneIsActive
                            || session.currentRoute.outputs.contains { $0.portType == .carAudio }

                        // Only touch the session when the rate actually changes -
                        // setPreferredSampleRate + setActive are blocking XPC calls
                        // and can force an audio hardware reconfiguration
                        if !isCarPlayEnvironment,
                           let sampleRate = targetSampleRate,
                           abs(session.sampleRate - Double(sampleRate)) > 1.0 {
                            try session.setPreferredSampleRate(Double(sampleRate))
                            // CRITICAL: Must activate session for sample rate change to take effect
                            try session.setActive(true)
                        } else if isCarPlayEnvironment {
                            // CarPlay owns the hardware sample rate (commonly 48 kHz).
                            // AVAudioEngine performs the conversion from the file
                            // rate; requesting 44.1/96/192 kHz here can tear down
                            // the live route and crash while starting playback.
                            AppLog.info(.general, "🚗 Keeping CarPlay hardware sample rate: \(session.sampleRate)")
                        }

                        AppLog.info(.general, "Configured audio session - session rate: \(session.sampleRate), file rate: \(format.sampleRate)")

                    } catch {
                        AppLog.error(.general, "Failed to configure audio session: \(error)")
                    }
                    continuation.resume()
                }
            }
        }
    }

#else
    import Foundation

    extension PlayerEngine {
        // macOS: no AVAudioSession concept — playback runs on the default output
        // device and there are no interruption/route-change/media-reset or memory
        // warning lifecycle events. Stubs keep the shared PlayerEngine surface
        // compiling; real session handling is iOS-only.
    }
#endif
