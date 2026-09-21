//  SFBAudioEngineManager+Mac.swift
//  QQPlayer
//
//  macOS SFB playback chain for SFBAudioEngineManager: AudioPlayer (SFBAudioEngine)
//  is cross-platform. No CarPlay / AVAudioSession / DSD DoP preference on macOS —
//  DSD decodes to PCM and the system audio output handles the rest.
//
//  2026-09-21 从 SFBAudioEngineManager+Playback.swift 的 `#else` 分支原样搬出
//  （纯搬家；`#if os(iOS)… #else … #endif` 改为独立文件的 `#if os(macOS)`）。
#if os(macOS)
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
                AppLog.warn(.general, "⚠️ Failed to open decoder: \(error)")
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
            AppLog.info(.general, "✅ macOS SFBAudioEngine playback started: \(url.lastPathComponent)")
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
