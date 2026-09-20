//  PlayerEngine+AudioSession.swift
//  QQPlayer
//
//  Audio session configuration, interruption/route handling, media services
//  reset, memory warnings, and AVAudioEngine (re)setup for PlayerEngine.
//

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

        func ensureAudioSessionNotificationsSetup() {
            guard !hasSetupAudioSessionNotifications else { return }
            hasSetupAudioSessionNotifications = true
            setupAudioSessionNotifications()
        }

        private func setupAudioSessionNotifications() {
            // Audio-session notifications are not guaranteed to arrive on the
            // main queue. An Objective-C selector targeting this @MainActor class
            // traps in _dispatch_assert_queue_fail before Swift can hop actors.
            let interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: nil
            ) { @Sendable [weak self] notification in
                guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else {
                    return
                }
                let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                Task { @MainActor [weak self] in
                    self?.processAudioSessionInterruption(
                        typeValue: typeValue,
                        optionsValue: optionsValue
                    )
                }
            }
            notificationObservers.append(interruptionObserver)

            let routeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: nil
            ) { @Sendable [weak self] notification in
                guard let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
                    return
                }
                Task { @MainActor [weak self] in
                    self?.processAudioSessionRouteChange(reason: reason)
                }
            }
            notificationObservers.append(routeObserver)

            let mediaServicesObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: nil
            ) { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.processMediaServicesReset()
                }
            }
            notificationObservers.append(mediaServicesObserver)

            // AVAudioEngine stops itself when the system reconfigures the audio
            // hardware (CarPlay mixing in nav prompts, sample rate changes, Siri
            // chimes). Without handling this, playback goes silent.
            // Do not use a selector here. PlayerEngine is @MainActor, so Swift adds
            // a main-executor check to its Objective-C entry thunk. AVAudioEngine
            // posts this notification on its private `engine` queue, which traps in
            // _dispatch_assert_queue_fail before a selector method can hop actors.
            let engineConfigurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: nil,
                queue: nil
            ) { @Sendable [weak self] notification in
                guard let changedEngine = notification.object as? AVAudioEngine else { return }
                let changedEngineID = ObjectIdentifier(changedEngine)
                Task { @MainActor [weak self] in
                    self?.processEngineConfigurationChange(changedEngineID)
                }
            }
            notificationObservers.append(engineConfigurationObserver)

            // Listen for memory pressure warnings
            let memoryWarningObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: nil
            ) { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.processMemoryWarning()
                }
            }
            notificationObservers.append(memoryWarningObserver)
        }

        private func processAudioSessionInterruption(typeValue: UInt, optionsValue: UInt?) {
            guard let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
                return
            }

            switch type {
            case .began:
                AppLog.warn(.general, "🚫 Audio session interruption began - pausing playback")
                isAudioSessionInterrupted = true
                // Scope the route flag to this interruption. On an unplug the
                // .oldDeviceUnavailable route change arrives after this .began and
                // before .ended, so it is set again in time to be read below.
                outputDeviceBecameUnavailable = false

                // Save current playback position before interruption.
                // Read the LIVE render position, not the cached playbackTime: the
                // 0.25s UI timer that maintains playbackTime is deliberately not
                // running while the app is backgrounded, so the cached value is
                // frozen at whatever it held when the screen locked. Resuming from
                // it rewound the track - to 0 if the screen was locked soon after
                // playback started. This must be read before the engine is stopped,
                // while the player node still has a valid render time.
                let wasPlaying = isPlaying
                let livePosition = wasPlaying ? nowPlayingElapsedTime() : playbackTime
                // 中断诊断（2026-08-29 中断后从头播排查）：记录保存位置时的引擎状态，
                // 判断 savedPosition 是否走了 fallback（引擎已停导致 currentNodeSampleTime 为 nil）
                let sampleTimeValid = (currentNodeSampleTime() != nil)
                // 中断诊断（2026-08-30）：引擎已停读不到实时位置时，用引擎存活时缓存的
                // lastKnownPlaybackPosition 兜底，避免把冻结的 playbackTime（可能 0）存为恢复起点
                let lastKnownAge = Date().timeIntervalSince(lastKnownPlaybackPositionUpdatedAt)
                let savedPosition = InterruptionResumePolicy.savedPosition(
                    wasPlaying: wasPlaying,
                    livePosition: livePosition,
                    sampleTimeValid: sampleTimeValid,
                    lastKnown: lastKnownPlaybackPosition,
                    lastKnownAge: lastKnownAge
                ) ?? livePosition
                let appState = UIApplication.shared.applicationState
                let frozenAge = Date().timeIntervalSince(playbackTimeUpdatedAt)
                let diagLine = "🔍 [intr] .began wasPlaying=\(wasPlaying) savedPosition=\(savedPosition)s "
                    + "engineRunning=\(audioEngine.isRunning) usingSFB=\(usingSFBEngine) "
                    + "sampleTimeValid=\(sampleTimeValid) audioFile=\(audioFile != nil) "
                    + "appState=\(appState.rawValue) playbackTime=\(playbackTime)s "
                    + "playbackTimeAge=\(String(format: "%.1f", frozenAge))s "
                    + "lastKnown=\(lastKnownPlaybackPosition)s lastKnownAge=\(String(format: "%.1f", lastKnownAge))s"
                AppLog.info(.general, diagLine)
                InterruptionDiagnostics.log(diagLine)
                wasPlayingBeforeInterruption = wasPlaying

                if isPlaying {
                    if usingSFBEngine {
                        // Stop the SFBAudioEngine's internal AVAudioEngine completely
                        // so it releases the audio hardware for the alarm/call
                        sfbAudioManager.stopEngineForInterruption()
                        isPlaying = false
                        playbackState = .paused
                        stopPlaybackTimer()
                        updateNowPlayingInfoEnhanced()
                    } else {
                        // Stop native AVAudioEngine completely (not just pause)
                        audioEngine.stop()
                        isPlaying = false
                        playbackState = .paused
                        stopPlaybackTimer()
                        updateNowPlayingInfoEnhanced()
                    }
                }

                // Also stop any silent background players that hold audio hardware
                stopSilentPlaybackForPause()

                // NOTE: Do NOT deactivate the audio session here. The system has
                // already interrupted it, and explicitly deactivating makes iOS
                // treat us as no longer interested - the .ended notification
                // (with .shouldResume) is then never delivered if the app gets
                // suspended, leaving playback paused forever (e.g. on CarPlay
                // after a nav prompt or phone call).

                // Restore the saved position (pause() may have updated it)
                playbackTime = savedPosition
                AppLog.info(.general, "💾 Saved playback position: \(savedPosition)s (was playing: \(wasPlaying))")

            case .ended:
                AppLog.info(.general, "✅ Audio session interruption ended")
                isAudioSessionInterrupted = false
                AppLog.info(.general, "💾 Will restore to position: \(playbackTime)s when playback resumes")

                // Re-activate our audio session now that the interruption is over
                do {
                    try AVAudioSession.sharedInstance().setActive(true, options: [])
                    AppLog.info(.general, "🔊 Audio session re-activated after interruption")
                } catch {
                    AppLog.warn(.general, "⚠️ Failed to re-activate audio session: \(error)")
                }

                // NOTE: the native engine is deliberately NOT restarted here.
                // play() starts it itself, right before it re-schedules the audio
                // segment. Starting it here was actively harmful: after a plain
                // pause the player node is still "playing", so start() resumed it
                // behind our back - audio came out of the speaker while isPlaying
                // stayed false and the timeline sat frozen. It also risked starting
                // the engine on a route that had not finished settling, which
                // rendered silence.

                // Check if we should resume playback
                let shouldResume: Bool
                if let optionsValue {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    shouldResume = options.contains(.shouldResume)
                    AppLog.info(.general, "🔍 Interruption options: shouldResume = \(shouldResume)")
                } else {
                    shouldResume = false
                    AppLog.info(.general, "🔍 No interruption options - will not auto-resume")
                }

                // Only auto-resume if:
                // 1. The system tells us to (e.g., after a Siri interruption)
                // 2. The user was actually playing before the interruption (not manually paused)
                // 3. The output device did not disappear. Unplugging headphones is
                //    delivered as an interruption on iOS 17+, and its .ended still
                //    carries .shouldResume - honouring it would blast the track out
                //    of the built-in speaker, which is exactly what the user is
                //    trying to avoid by unplugging.
                let resumeAllowed = shouldResume
                    && wasPlayingBeforeInterruption
                    && playbackState == .paused
                    && !outputDeviceBecameUnavailable

                // 中断诊断（2026-08-30）：恢复决策全因素落盘——确认 play() 用的 playbackTime
                // 是否被重置/回退（从头播根因排查），以及为何自动恢复/为何不恢复
                let diagState = String(describing: playbackState)
                let diagDeviceUnavailable = outputDeviceBecameUnavailable
                let diagAudioFile = audioFile != nil
                let resumeDiag = "🔍 [intr] .ended decision: shouldResume=\(shouldResume) "
                    + "wasPlayingBefore=\(wasPlayingBeforeInterruption) "
                    + "state=\(diagState) deviceUnavailable=\(diagDeviceUnavailable) "
                    + "resumeAllowed=\(resumeAllowed) playbackTime=\(playbackTime)s "
                    + "seekOffset=\(seekTimeOffset)s audioFile=\(diagAudioFile) "
                    + "usingSFB=\(usingSFBEngine) isPlaying=\(isPlaying)"
                AppLog.info(.general, resumeDiag)
                InterruptionDiagnostics.log(resumeDiag)

                // Consume the flags so they can never leak into a later
                // interruption and trigger a phantom resume.
                wasPlayingBeforeInterruption = false
                outputDeviceBecameUnavailable = false

                if resumeAllowed {
                    AppLog.info(.general, "▶️ Auto-resuming playback after interruption (was playing before)")
                    // 中断诊断（2026-08-29）：恢复前快照，确认 play() 用的 playbackTime 是否被
                    // 重置/回退（从头播根因排查）
                    let resumeSnapshot = "🔍 [intr] .ended resume: playbackTime=\(playbackTime)s seekOffset=\(seekTimeOffset)s audioFile=\(audioFile != nil) usingSFB=\(usingSFBEngine) isPlaying=\(isPlaying) state=\(playbackState)"
                    AppLog.info(.general, resumeSnapshot)
                    InterruptionDiagnostics.log(resumeSnapshot)
                    // 中断诊断（2026-08-30）双保险：.began 修正未生效的边角场景下，
                    // playbackTime 仍是冻结值（playbackTimeUpdatedAt 久未刷新）时，
                    // 用新鲜且明显更大的 lastKnown 覆盖，避免命中 PLAY FROM BEGINNING 分支。
                    // 幂等：条件不满足（playbackTime 新鲜 / lastKnown 陈旧 / 差值不足）时不影响现状。
                    let playbackFrozenAge = Date().timeIntervalSince(playbackTimeUpdatedAt)
                    let resumeLastKnownAge = Date().timeIntervalSince(lastKnownPlaybackPositionUpdatedAt)
                    if let correctedPosition = InterruptionResumePolicy.correctedResumePosition(
                        playbackTime: playbackTime,
                        playbackTimeAge: playbackFrozenAge,
                        lastKnown: lastKnownPlaybackPosition,
                        lastKnownAge: resumeLastKnownAge
                    ) {
                        AppLog.info(.general, "🩹 Resume position corrected: \(playbackTime)s → \(correctedPosition)s (frozen playbackTime)")
                        playbackTime = correctedPosition
                    }
                    play()
                } else {
                    AppLog.info(.general, "⏸️ Not auto-resuming - user must manually resume")

                    // Ensure playback state is correct but keep position saved
                    isPlaying = false
                    playbackState = .paused
                    updateNowPlayingInfoEnhanced()
                }

            @unknown default:
                break
            }
        }

        private func processAudioSessionRouteChange(reason: AVAudioSession.RouteChangeReason) {
            // Update CarPlay status when route changes
            sfbAudioManager.updateCarPlayStatus()

            switch reason {
            case .oldDeviceUnavailable:
                // Only pause if audio would now blast from the built-in speaker.
                // Wireless CarPlay briefly flaps to the Bluetooth phone-call
                // channel (Siri, nav voice) and back - that also reports
                // .oldDeviceUnavailable, but the audio stays on the car, and
                // pausing there is wrong.
                let currentOutputs = AVAudioSession.sharedInstance().currentRoute.outputs
                let fellBackToSpeaker = currentOutputs.isEmpty || currentOutputs.contains { $0.portType == .builtInSpeaker }
                if fellBackToSpeaker {
                    AppLog.warn(.general, "🎧 Audio device disconnected (fell back to speaker) - pausing playback")
                    // Record this even when playback is already stopped. On iOS 17+
                    // the unplug arrives as an interruption whose .began has
                    // already paused us, so `isPlaying` is false by the time we get
                    // here - but .ended is still coming with .shouldResume and must
                    // not be honoured.
                    outputDeviceBecameUnavailable = true
                    if isPlaying {
                        pause()
                    }
                } else {
                    AppLog.info(.general, "🎧 Route changed but still on external output (\(currentOutputs.map { $0.portType.rawValue })) - continuing")
                }
            default:
                break
            }
        }

        private func processMediaServicesReset() async {
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

        private func processEngineConfigurationChange(_ changedEngineID: ObjectIdentifier) {
            // Only react to our own engine - SFBAudioEngine manages its own.
            guard changedEngineID == ObjectIdentifier(audioEngine) else { return }
            guard !usingSFBEngine else { return }

            // Interruptions have their own began/ended recovery path.
            guard isPlaying, !isAudioSessionInterrupted else { return }

            // CarPlay can emit several configuration notifications while its
            // route settles. Coalesce them so we never stop/start/schedule the
            // same player node concurrently.
            guard engineConfigurationRecoveryTask == nil else { return }
            let recoveryLoadGeneration = loadGeneration
            let recoveryTrackID = currentTrack?.stableId
            engineConfigurationRecoveryTask = Task { @MainActor [weak self] in
                defer { self?.engineConfigurationRecoveryTask = nil }
                do {
                    try await Task.sleep(for: .milliseconds(150))
                } catch {
                    return
                }

                guard let self,
                      self.isPlaying,
                      !self.isLoadingTrack,
                      !self.isAudioSessionInterrupted,
                      !self.usingSFBEngine,
                      self.loadGeneration == recoveryLoadGeneration,
                      self.currentTrack?.stableId == recoveryTrackID else { return }

                let resumeTime = self.nowPlayingElapsedTime()
                self.playbackTime = resumeTime
                AppLog.warn(.general, "🔧 Audio engine configuration changed - restarting playback at \(resumeTime)s")

                // The engine has already stopped; go through the resume path so
                // the segment is scheduled once at the preserved position.
                self.isPlaying = false
                self.playbackState = .paused
                self.stopPlaybackTimer()
                self.play()
            }
        }

        func cancelEngineConfigurationRecovery() {
            engineConfigurationRecoveryTask?.cancel()
            engineConfigurationRecoveryTask = nil
        }

        private func processMemoryWarning() {
            AppLog.warn(.general, "⚠️ Memory warning received - cleaning up audio resources")

            // Clear cached artwork to free memory
            cachedArtwork = nil
            cachedArtworkTrackId = nil

            // Don't touch the audio engine if we're currently loading or playing
            // Stopping during a load causes the load to fail on large files
            if !isPlaying && !isLoadingTrack {
                audioEngine.stop()
                playerNode.stop()
                AppLog.warn(.general, "🛑 Stopped audio engine due to memory pressure")
            }

            AppLog.info(.general, "🧹 Cleaned up audio resources due to memory warning")
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
