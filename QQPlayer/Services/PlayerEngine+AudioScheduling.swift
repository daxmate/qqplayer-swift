//  PlayerEngine+AudioScheduling.swift
//  QQPlayer
//
//  Gapless audio scheduling, preloading, background monitoring, and track-end
//  detection for PlayerEngine.
//

#if os(iOS)
    import AVFoundation
    import Foundation
    import UIKit
    extension PlayerEngine {
        // MARK: - Audio Scheduling Helper

        @discardableResult
        func scheduleSegment(from startFrame: AVAudioFramePosition, file: AVAudioFile, track: Track? = nil, trackIndex: Int? = nil) -> Bool {
            // Safety check: Ensure audio engine is running
            guard audioEngine.isRunning else {
                print("❌ Cannot schedule segment: audio engine is not running")
                return false
            }

            // Validate startFrame is within bounds
            guard startFrame >= 0 && startFrame < file.length else {
                print("❌ Invalid startFrame: \(startFrame), file length: \(file.length)")
                return false
            }

            let remaining = file.length - startFrame
            guard remaining > 0 else {
                print("❌ No remaining frames to schedule: startFrame=\(startFrame), length=\(file.length)")
                return false
            }

            // Validate that frameCount doesn't overflow AVAudioFrameCount
            guard remaining <= AVAudioFrameCount.max else {
                print("❌ Remaining frames exceed AVAudioFrameCount.max: \(remaining)")
                return false
            }

            let scheduledGeneration = scheduleGeneration
            let scheduledTrackId = track?.stableId
            let scheduledIndex = trackIndex

            playerNode.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: AVAudioFrameCount(remaining),
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    await self?.handleScheduledSegmentFinished(
                        generation: scheduledGeneration,
                        trackStableId: scheduledTrackId,
                        trackIndex: scheduledIndex
                    )
                }
            }

            print("✅ Successfully scheduled segment: startFrame=\(startFrame), frameCount=\(remaining)")

            // Start background monitoring when we schedule a segment
            startBackgroundMonitoring()
            return true
        }

        private func nextPlayableIndexForPreload() -> Int? {
            guard !playbackQueue.isEmpty, !isLoopingSong else { return nil }
            if currentIndex < playbackQueue.count - 1 {
                return currentIndex + 1
            }
            if isRepeating {
                return 0
            }
            return nil
        }

        private func canGaplesslySchedule(_ currentFile: AVAudioFile, with nextFile: AVAudioFile) -> Bool {
            let currentFormat = currentFile.processingFormat
            let nextFormat = nextFile.processingFormat
            return abs(currentFormat.sampleRate - nextFormat.sampleRate) < 0.1
                && currentFormat.channelCount == nextFormat.channelCount
                && currentFormat.commonFormat == nextFormat.commonFormat
                && currentFormat.isInterleaved == nextFormat.isInterleaved
        }

        func preloadAndScheduleNextIfNeeded() {
            guard !usingSFBEngine,
                  isPlaying,
                  audioFile != nil,
                  let nextIndex = nextPlayableIndexForPreload(),
                  playbackQueue.indices.contains(nextIndex) else {
                return
            }

            let candidate = playbackQueue[nextIndex]

            if nextTrack?.stableId == candidate.stableId {
                scheduleGaplessNextIfPossible()
                return
            }

            clearPreloadedNext()

            let preloadGeneration = loadGeneration
            isPreloadingNext = true
            preloadNextTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let url = URL(fileURLWithPath: candidate.path)

                guard !SFBAudioEngineManager.canHandle(url: url) else {
                    self.isPreloadingNext = false
                    return
                }

                // Avoid holding security-scoped resources for a future track.
                guard await LibraryIndexer.shared.resolveBookmarkForTrack(candidate) == nil else {
                    self.isPreloadingNext = false
                    return
                }

                do {
                    // M3-2：本地沙盒文件无需 iCloud 实体化；缺失由 openNativeAudioFile 失败路径处理
                    try Task.checkCancellation()

                    let file = try await self.openNativeAudioFile(at: url, qos: .utility)
                    try Task.checkCancellation()

                    guard self.loadGeneration == preloadGeneration,
                          self.playbackQueue.indices.contains(nextIndex),
                          self.playbackQueue[nextIndex].stableId == candidate.stableId else {
                        return
                    }

                    self.nextAudioFile = file
                    self.nextTrack = candidate
                    self.nextTrackIndex = nextIndex
                    self.isPreloadingNext = false
                    self.scheduleGaplessNextIfPossible()
                } catch is CancellationError {
                    self.isPreloadingNext = false
                } catch {
                    self.isPreloadingNext = false
                    print("⚠️ Failed to preload next track for gapless playback: \(error)")
                }
            }
        }

        private func scheduleGaplessNextIfPossible() {
            guard !gaplessScheduled,
                  !usingSFBEngine,
                  isPlaying,
                  audioEngine.isRunning,
                  let currentFile = audioFile,
                  let nextFile = nextAudioFile,
                  let nextTrack,
                  let nextTrackIndex else {
                return
            }

            guard canGaplesslySchedule(currentFile, with: nextFile) else {
                print("ℹ️ Next track format differs; using normal transition instead of gapless")
                return
            }

            let currentStartFrame = AVAudioFramePosition(seekTimeOffset * currentFile.processingFormat.sampleRate)
            let remainingFrames = max(0, currentFile.length - currentStartFrame)
            guard remainingFrames > 0 else { return }

            let scheduled = scheduleSegment(from: 0, file: nextFile, track: nextTrack, trackIndex: nextTrackIndex)
            guard scheduled else { return }

            nextTimelineStartSampleTime = nodeTimelineStartSampleTime + remainingFrames
            gaplessScheduled = true
            print("✅ Gapless next track scheduled: \(nextTrack.title)")
        }

        private func promoteGaplessNextIfAvailable() -> Bool {
            guard gaplessScheduled,
                  let nextFile = nextAudioFile,
                  let next = nextTrack,
                  let nextIndex = nextTrackIndex,
                  playbackQueue.indices.contains(nextIndex) else {
                return false
            }

            currentIndex = nextIndex
            // Play history: settle the finished track before switching.
            PlayHistoryRecorder.shared.playbackEnded(track: currentTrack, at: playbackTime)
            currentTrack = next
            audioFile = nextFile
            duration = Double(nextFile.length) / nextFile.processingFormat.sampleRate
            seekTimeOffset = 0
            nodeTimelineStartSampleTime = nextTimelineStartSampleTime ?? currentNodeSampleTime() ?? 0
            playbackTime = currentTimeForCurrentNativeFile()
            playbackState = .playing
            isPlaying = true
            // Play history: the gapless next track starts a new session.
            PlayHistoryRecorder.shared.playbackBegan(track: next, at: 0)

            nextAudioFile = nil
            nextTrack = nil
            nextTrackIndex = nil
            nextTimelineStartSampleTime = nil
            gaplessScheduled = false
            isPreloadingNext = false

            resetNowPlayingCachesForTrackChange()
            lastControlCenterUpdate = 0
            updateNowPlayingInfoEnhanced()
            updateWidgetData()
            preloadAndScheduleNextIfNeeded()
            return true
        }

        func currentNodeSampleTime() -> AVAudioFramePosition? {
            // playerTime(forNodeTime:) raises an ObjC exception - not nil - when
            // the node is detached or the engine is torn down mid-query (App Store
            // crash group spanning 1.0.6-1.2.2), so check attachment and engine
            // state before asking.
            guard audioEngine.attachedNodes.contains(playerNode),
                  audioEngine.isRunning,
                  let nodeTime = playerNode.lastRenderTime,
                  let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
                return nil
            }
            return playerTime.sampleTime
        }

        func currentTimeForCurrentNativeFile() -> TimeInterval {
            guard let audioFile = audioFile,
                  let currentSampleTime = currentNodeSampleTime() else {
                // 中断诊断（2026-08-29）：此处是可疑 fallback——引擎已停/节点无效时退回
                // 冻结的 playbackTime（后台 UI timer 不跑，锁屏早于播放开始则其值为 0）
                let fallbackDiag = "🔍 [intr] currentTime fallback to playbackTime=\(playbackTime)s "
                    + "(audioFile=\(audioFile != nil) sampleTime=nil engineRunning=\(audioEngine.isRunning))"
                print(fallbackDiag)
                InterruptionDiagnostics.log(fallbackDiag)
                return playbackTime
            }

            let relativeSampleTime = max(0, currentSampleTime - nodeTimelineStartSampleTime)
            let time = seekTimeOffset + Double(relativeSampleTime) / audioFile.processingFormat.sampleRate
            let clamped = min(max(time, 0), duration)
            // 中断诊断（2026-08-30）：引擎存活、sampleTime 有效时刷新实时位置缓存，
            // 供中断 .began 保存位置 / .ended 恢复起点兜底。⚠️ 仅成功路径更新——
            // fallback（sampleTime 为 nil）分支绝不更新，避免把冻结值污染进缓存。
            // 此函数被前台 timer / 后台 0.5s checkIfTrackEnded / pause / seek 等多处调用，
            // 都会自然刷新。
            lastKnownPlaybackPosition = clamped
            lastKnownPlaybackPositionUpdatedAt = Date()
            return clamped
        }

        private func handleScheduledSegmentFinished(generation: UInt64, trackStableId: String?, trackIndex: Int?) async {
            guard generation == scheduleGeneration,
                  isPlaying,
                  !usingSFBEngine else {
                return
            }

            if let trackStableId, trackStableId != currentTrack?.stableId {
                return
            }

            if promoteGaplessNextIfAvailable() {
                return
            }

            await handleTrackEnd()
        }

        func startBackgroundMonitoring() {
            // Only create a background task if we don't already have one
            if backgroundTask == .invalid {
                backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                    print("🚨 Background task expiring during playback")
                    Task { @MainActor in
                        self?.endBackgroundMonitoring()
                    }
                }
            }

            // Start a timer that works in background
            backgroundCheckTimer?.invalidate()
            backgroundCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.checkIfTrackEnded()
                }
            }
        }

        func endBackgroundMonitoring() {
            backgroundCheckTimer?.invalidate()
            backgroundCheckTimer = nil

            if backgroundTask != .invalid {
                UIApplication.shared.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
        }

        func stopSilentPlaybackForPause() {
            pausedSilentPlayer?.stop()
            pausedSilentPlayer = nil
            print("🔇 Stopped silent playback for pause")
        }

        // NOTE: maintainAudioSessionForBackground() used to live here. It force-
        // reactivated the audio session while paused "to prevent termination" -
        // the same keep-alive anti-pattern as the silent player, and its only
        // caller was that player's error path. Being suspended while paused is the
        // correct outcome, so it has been removed rather than left to be re-wired.

        private func checkIfTrackEnded() async {
            // Check if audio has finished playing
            guard isPlaying else { return }

            // Skip native player checks when using SFBAudioEngine
            guard !usingSFBEngine else { return }

            // Check if player node has stopped naturally (reached end).
            // A stopped *engine* (config change, interruption) also makes the node
            // report not-playing - only treat it as track end while the engine runs.
            if audioEngine.isRunning && !playerNode.isPlaying && audioFile != nil {
                // Track has ended
                if promoteGaplessNextIfAvailable() {
                    return
                }
                await handleTrackEnd()
                return
            }

            // Alternative check: position-based
            if audioFile != nil {
                let currentTime = currentTimeForCurrentNativeFile()

                if currentTime >= duration - 0.2 && duration > 0 {
                    guard !gaplessScheduled else { return }
                    // Track is ending
                    isPlaying = false // Prevent multiple triggers
                    await handleTrackEnd()
                }
            }
        }

        func handleTrackEnd() async {
            guard !isLoadingTrack else { return }

            if promoteGaplessNextIfAvailable() {
                return
            }

            if isLoopingSong, let t = currentTrack {
                let loaded = await loadTrack(t)
                if loaded { play() }
                return
            }

            if currentIndex < playbackQueue.count - 1 {
                currentIndex = (currentIndex + 1) % playbackQueue.count
                let next = playbackQueue[currentIndex]
                let loaded = await loadTrack(next, preservePlaybackTime: false)
                if loaded {
                    if usingSFBEngine && isPlaying {
                        playbackState = .playing
                        startPlaybackTimer()
                    } else {
                        play()
                    }
                }
                return
            }

            if isRepeating, !playbackQueue.isEmpty {
                currentIndex = 0
                currentTrack = playbackQueue[0]
                let loaded = await loadTrack(playbackQueue[0])
                if loaded {
                    if usingSFBEngine && isPlaying {
                        playbackState = .playing
                        startPlaybackTimer()
                    } else {
                        play()
                    }
                }
                return
            }

            stop()
        }
    }

#else
    import AVFoundation
    import Foundation

    extension PlayerEngine {
        // macOS native scheduling: no background execution limits, so no
        // background monitoring and no UIKit background task. Gapless scheduling
        // will be ported with the SFB macOS batch.

        @discardableResult
        func scheduleSegment(from startFrame: AVAudioFramePosition, file: AVAudioFile, track: Track? = nil, trackIndex: Int? = nil) -> Bool {
            // 决策上收：guard 链语义与 MacPlaybackGate.segmentPlan 一一对应（有单测锁定）。
            guard case let .success(remaining) = MacPlaybackGate.segmentPlan(
                engineIsRunning: audioEngine.isRunning,
                startFrame: startFrame,
                fileLength: file.length,
                maxFrameCount: Int64(AVAudioFrameCount.max)
            ) else {
                print("❌ macOS scheduleSegment rejected (engine running=\(audioEngine.isRunning) start=\(startFrame) len=\(file.length))")
                return false
            }

            let scheduledGeneration = scheduleGeneration
            let scheduledTrackId = track?.stableId

            playerNode.scheduleSegment(
                file,
                startingFrame: startFrame,
                frameCount: AVAudioFrameCount(remaining),
                at: nil,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    await self?.handleMacSegmentFinished(
                        generation: scheduledGeneration,
                        trackStableId: scheduledTrackId
                    )
                }
            }
            return true
        }

        private func handleMacSegmentFinished(generation: UInt64, trackStableId: String?) async {
            // 判定上收纯函数（MacPlaybackGate.shouldHandleSegmentFinished，有防回归测试）：
            // 旧代 completion（seek/play 前 cancelPendingCompletions 已 +1）/ 非播放中 /
            // 非当前曲目 → 不触发。2026-09-01 修复：macOS seek 漏 cancel 导致误触发停播。
            guard MacPlaybackGate.shouldHandleSegmentFinished(
                generation: generation,
                scheduleGeneration: scheduleGeneration,
                isPlaying: isPlaying,
                completionTrackId: trackStableId,
                currentTrackId: currentTrack?.stableId
            ) else { return }
            await handleTrackEnd()
        }

        func currentNodeSampleTime() -> AVAudioFramePosition? {
            guard audioEngine.attachedNodes.contains(playerNode),
                  audioEngine.isRunning,
                  let nodeTime = playerNode.lastRenderTime,
                  let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
                return nil
            }
            return playerTime.sampleTime
        }

        func currentTimeForCurrentNativeFile() -> TimeInterval {
            guard let audioFile = audioFile,
                  let currentSampleTime = currentNodeSampleTime() else {
                return playbackTime
            }

            let relativeSampleTime = max(0, currentSampleTime - nodeTimelineStartSampleTime)
            let time = seekTimeOffset + Double(relativeSampleTime) / audioFile.processingFormat.sampleRate
            let clamped = min(max(time, 0), duration)
            lastKnownPlaybackPosition = clamped
            lastKnownPlaybackPositionUpdatedAt = Date()
            return clamped
        }

        func handleTrackEnd() async {
            guard !isLoadingTrack else { return }

            if isLoopingSong, let t = currentTrack {
                let loaded = await loadTrack(t)
                if loaded { play() }
                return
            }

            if currentIndex < playbackQueue.count - 1 {
                currentIndex += 1
                let next = playbackQueue[currentIndex]
                let loaded = await loadTrack(next)
                if loaded { play() }
                return
            }

            if isRepeating, !playbackQueue.isEmpty {
                currentIndex = 0
                let loaded = await loadTrack(playbackQueue[0])
                if loaded { play() }
                return
            }

            // End of queue: stop cleanly.
            isPlaying = false
            playbackState = .stopped
            stopPlaybackTimer()
            if usingSFBEngine {
                sfbAudioManager.stop()
            } else {
                playerNode.stop()
            }
            updateNowPlayingInfoEnhanced()
        }
    }
#endif
