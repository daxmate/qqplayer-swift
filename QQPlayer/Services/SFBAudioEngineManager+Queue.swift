//  SFBAudioEngineManager+Queue.swift
//  QQPlayer
//
//  Playback progress updates and format compatibility for SFBAudioEngineManager.
//  SFBAudioEngine has no queue API; gapless preload state lives on the core
//  class (nextTrackURL/onTrackNearingEnd/hasTriggeredNearEnd).
//
import AVFoundation
import Foundation
import SFBAudioEngine

extension SFBAudioEngineManager {
    func updatePlaybackPosition() {
        guard isPlaying, let player = audioPlayer else { return }

        // Read the player's real playback position: frames rendered by the
        // audio engine divided by the decoder sample rate (SFBAudioPlayer
        // exposes it as `currentTime`, nil only while the snapshot is
        // invalid). This is exact and immune to timer drift - the old
        // approach (currentTime += 0.1 per tick) accumulated error because
        // the timer fires at >= 0.1s intervals, drifting by seconds to tens
        // of seconds over a 5-minute track and delaying end-of-track
        // detection. SFB's currentTime stays valid while paused (the engine
        // keeps running with the decoder state intact), so the value freezes
        // at the last rendered frame instead of marching on.
        if let realTime = player.currentTime, realTime >= 0 {
            currentTime = realTime
        } else {
            // Playback snapshot unavailable (e.g. decoder still initializing
            // right after load). Nudge the stored value so progress advances
            // smoothly until the real position becomes readable.
            currentTime += 0.1
        }

        // Ensure we don't exceed the actual track duration (the real position
        // can overshoot the nominal end by a few frames)
        if duration > 0 && currentTime > duration {
            currentTime = duration
        }

        // Log position every 10 seconds for debugging
        if Int(currentTime * 10) % 100 == 0, AppLog.isEnabled(.debug, .general) {
            AppLog.debug(.general, "🎵 SFBAudioEngine position: \(currentTime)/\(duration)")
        }

        if duration > 0 && currentTime >= duration {
            AppLog.info(.general, "🏁 SFBAudioEngine track completed: \(currentTime)/\(duration)")
            // Track completion will be handled by PlayerEngine
            isPlaying = false
            updateTimer?.invalidate()
        }
    }

    // MARK: - Format Support Check

    static func canHandle(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()

        // Route all formats except WAV, FLAC, MP3, M4A, and AAC to SFBAudioEngine
        // M4A and AAC should be handled natively by AVAudioEngine for better compatibility
        let nativeFormats = ["wav", "flac", "mp3", "m4a", "aac"]
        let basicCanHandle = !nativeFormats.contains(ext)

        // For DSD files, let PlayerEngine handle the detailed sample rate validation
        // since it depends on whether we're using DoP or PCM conversion
        if basicCanHandle && (ext == "dsf" || ext == "dff") {
            AppLog.info(.general, "🔍 SFBAudioEngine.canHandle(\(url.lastPathComponent)): ext=\(ext), canHandle=true (DSD - validation deferred to PlayerEngine)")
            return true
        }

        AppLog.info(.general, "🔍 SFBAudioEngine.canHandle(\(url.lastPathComponent)): ext=\(ext), canHandle=\(basicCanHandle)")
        return basicCanHandle
    }
}
