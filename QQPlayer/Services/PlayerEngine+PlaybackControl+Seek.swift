//  PlayerEngine+PlaybackControl+Seek.swift
//  QQPlayer
//
//  Seek for PlayerEngine (iOS).
//
//  2026-09-19 从 PlayerEngine+PlaybackControl.swift 原样搬出（纯搬家）。
#if os(iOS)
    import AVFoundation
    import Foundation
    extension PlayerEngine {
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
#endif
