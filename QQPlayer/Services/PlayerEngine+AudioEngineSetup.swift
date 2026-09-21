//  PlayerEngine+AudioEngineSetup.swift
//  QQPlayer
//
//  AVAudioEngine assembly for PlayerEngine (iOS): create or rebuild the engine for a
//  new format and connect playerNode → timePitch → EQ → mainMixerNode.
//
//  2026-09-21 从 PlayerEngine+AudioSession.swift 原样搬出（纯搬家，无逻辑变更）。
#if os(iOS)
    import AVFoundation
    import Foundation
    import UIKit
    extension PlayerEngine {
        func ensureAudioEngineSetup(with format: AVAudioFormat? = nil) {
            if !hasSetupAudioEngine {
                hasSetupAudioEngine = true
                setupAudioEngine(with: format)
                if let format = format {
                    lastSampleRate = format.sampleRate
                }
            } else if let format = format {
                // Check if sample rate has changed - if so, force reconfiguration
                if abs(format.sampleRate - lastSampleRate) > 0.1 {
                    AppLog.info(.general, "📊 Sample rate changed from \(lastSampleRate)Hz to \(format.sampleRate)Hz - forcing reconfiguration")
                    reconfigureAudioEngineForNewFormat(format)
                    lastSampleRate = format.sampleRate

                    // Reset timing state completely when sample rate changes
                    seekTimeOffset = 0
                    playbackTime = 0
                    lastControlCenterUpdate = 0

                    // Stop and restart playback timer to ensure proper timing with new sample rate
                    stopPlaybackTimer()
                    if isPlaying {
                        startPlaybackTimer()
                    }
                    AppLog.info(.general, "🔄 Reset timing state and timer for new sample rate")
                }
            }
        }

        private func reconfigureAudioEngineForNewFormat(_ format: AVAudioFormat) {
            // Force reconfiguration for new sample rate - stop engine if needed
            let wasRunning = audioEngine.isRunning
            if wasRunning {
                audioEngine.stop()
                AppLog.info(.general, "🛑 Stopped audio engine for reconfiguration")
            }
            AppLog.info(.general, "🔧 Reconfiguring audio engine for new format: \(format.sampleRate)Hz")
            // Rebuild the graph: playerNode -> timePitch（倍速）-> EQ -> mainMixerNode
            connectPlaybackChain(format: format)
            audioEngine.prepare()
            AppLog.info(.general, "✅ Audio engine reconfigured with EQ + timePitch for sample rate: \(format.sampleRate)Hz")
            // Restart engine if it was running
            if wasRunning {
                do {
                    try audioEngine.start()
                    AppLog.info(.general, "▶️ Restarted audio engine after reconfiguration")
                } catch {
                    AppLog.error(.general, "❌ Failed to restart audio engine: \(error)")
                }
            }
        }

        private func setupAudioEngine(with format: AVAudioFormat? = nil) {
            audioEngine.attach(playerNode)
            audioEngine.attach(timePitchNode)
            // Set up EQ manager with the audio engine
            eqManager.setAudioEngine(audioEngine)
            // Connect playerNode -> timePitch（倍速）-> EQ -> mainMixerNode.
            // AVAudioEngine owns the mainMixerNode -> outputNode connection and
            // negotiates that format with the current hardware route. Supplying
            // the mixer's format to the output node can raise an Objective-C
            // exception when CarPlay is fixed at a different sample rate from the
            // source file.
            connectPlaybackChain(format: format)
            // CRITICAL: Prepare the engine to guarantee render loop activity
            audioEngine.prepare()
            // Don't start the engine here - wait until we actually need to play
            AppLog.info(.general, "✅ Audio engine configured and prepared with EQ + timePitch integration, format: \(format?.description ?? "auto")")
        }

        /// 播放链接线：playerNode → timePitch（倍速）→ EQ → mainMixerNode
        /// AVAudioEngine.connect 会自动断开源节点旧连接，无需手动 disconnect playerNode
        private func connectPlaybackChain(format: AVAudioFormat?) {
            guard let eqNode = eqManager.currentEQNode else { return }
            audioEngine.disconnectNodeInput(audioEngine.mainMixerNode)
            audioEngine.disconnectNodeInput(eqNode)
            audioEngine.connect(playerNode, to: timePitchNode, format: format)
            audioEngine.connect(timePitchNode, to: eqNode, format: format)
            audioEngine.connect(eqNode, to: audioEngine.mainMixerNode, format: format)
        }

    }
#endif
