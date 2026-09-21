//  PlayerEngine+AudioEngineRecovery.swift
//  QQPlayer
//
//  iOS 18 audio-engine reset path for PlayerEngine: rebuild the engine and nodes
//  after a media-services reset, restoring playback at the previous position.
//
//  2026-09-21 从 PlayerEngine+AudioSession.swift 原样搬出（纯搬家，无逻辑变更）。
#if os(iOS)
    import AVFoundation
    import Foundation
    import UIKit
    extension PlayerEngine {
        /// 分片：跨文件可见（原 private）
        func processMediaServicesReset() async {
            AppLog.warn(.general, "🔄 Media services were reset - need to recreate audio engine and nodes")

            // Stop current playback
            let wasPlaying = isPlaying
            let currentTime = playbackTime
            let currentTrackCopy = currentTrack

            // Clean up current audio engine and nodes
            await cleanupAudioEngineForReset()

            // Recreate audio engine and nodes
            recreateAudioEngine()

            // Reactivate audio session after reset
            try? activateAudioSession()

            // Restore playback if needed
            if let track = currentTrackCopy {
                await loadTrack(track, preservePlaybackTime: true)
                if wasPlaying {
                    playbackTime = currentTime
                    play()
                }
            }
        }

        // MARK: - iOS 18 Audio Engine Reset Management

        private func cleanupAudioEngineForReset() async {
            AppLog.info(.general, "🧹 Cleaning up audio engine for reset")

            // Stop all audio activity
            playerNode.stop()
            audioEngine.stop()

            // Remove all connections
            audioEngine.detach(playerNode)
            audioEngine.detach(timePitchNode)

            // Clear any scheduled buffers
            playerNode.reset()

            AppLog.info(.general, "✅ Audio engine cleanup complete")
        }

        private func recreateAudioEngine() {
            AppLog.info(.general, "🔄 Recreating audio engine and nodes")
            // Create detached instances. setupAudioEngine is the single owner of
            // node attachment and graph wiring; attaching here and then clearing
            // hasSetupAudioEngine made the next load attach the same node twice.
            audioEngine = AVAudioEngine()
            playerNode = AVAudioPlayerNode()
            timePitchNode = AVAudioUnitTimePitch()
            // 新 timePitch 实例 rate 默认 1.0：恢复当前倍速（异常恢复路径不丢变速）
            timePitchNode.rate = Float(currentPlaybackRate)
            eqManager.setAudioEngine(nil)
            // Reset flags
            hasSetupAudioEngine = false
            lastSampleRate = 0
            hasSetupAudioSession = false
            // 不复位 hasSetupRemoteCommands / hasSetupAudioSessionNotifications（P1-B）：
            // media services reset 只重建 mediaserverd 的音频对象；MPRemoteCommandCenter 的
            // command target 与 NotificationCenter 的 block observer 均为进程内注册，reset 后
            // 依然有效。若复位这两个标志，下次 play()/loadTrack() 会再次 setup：
            // ① MPRemoteCommandCenter.addTarget 是追加不覆盖 → 控制中心命令双触发（按暂停没反应）；
            // ② setupAudioSessionNotifications 追加第二套 observer → 中断 .ended 被处理两次
            //    （第二次强制 paused 把恢复的播放停住）；③ notificationObservers 数组无界增长。
            // 保持标志为 true = 各注册恰好一次，永不重复。
            AppLog.info(.general, "✅ Audio engine recreated successfully with EQ")
        }

    }
#endif
