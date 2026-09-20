//  PlayerEngine+PlaybackControl+Mac.swift
//  QQPlayer
//
//  macOS native playback chain for PlayerEngine: AVAudioEngine +
//  AVAudioPlayerNode (loadTrack, play/pause, seek, engine setup).
//
//  2026-09-19 从 PlayerEngine+PlaybackControl.swift 的 `#else` 分支原样搬出
//  （纯搬家；`#if os(iOS)… #else … #endif` 改为独立文件的 `#if os(macOS)`）。
#if os(macOS)
    import AVFoundation
    import Foundation

    extension PlayerEngine {
        // macOS native playback chain: AVAudioEngine + AVAudioPlayerNode.
        // SFBAudioEngine formats (Opus/OGG/DSD) land with the SFB macOS batch.

        func setPlaybackRate(_ rate: Double) {
            currentPlaybackRate = rate
            // macOS 同 iOS：rate==1.0 bypass timePitch，避免从非 1.0 切回时
            // phase-vocoder 残留状态失真（2026-08-31 iOS 实测同根因）
            timePitchNode.auAudioUnit.shouldBypassEffect = (rate == 1.0)
            timePitchNode.rate = Float(rate)
            if usingSFBEngine {
                // SFB 引擎不支持变速：UI 立即复位显示（否则显示倍速档但实际没变速，对齐 iOS）
                AppLog.warn(.general, "⚠️ SFBAudioEngine 暂不支持倍速（Opus/OGG/DSD 不变速）——复位跟唱倍速显示")
                KaraokeController.shared.resetSpeedForUnsupportedEngine()
            }
        }

        @discardableResult
        func loadTrack(_ track: Track, preservePlaybackTime: Bool = false) async -> Bool {
            loadGeneration &+= 1
            let generation = loadGeneration

            currentLoadTask?.cancel()
            let task = Task { @MainActor [weak self] in
                guard let self else { return false }
                return await self.performMacLoadTrack(track, preservePlaybackTime: preservePlaybackTime, generation: generation)
            }
            currentLoadTask = task

            let loaded = await task.value
            if loadGeneration == generation {
                currentLoadTask = nil
            }
            return loaded
        }

        private func isCurrentLoad(_ generation: UInt64) -> Bool {
            loadGeneration == generation && !Task.isCancelled
        }

        private func performMacLoadTrack(_ track: Track, preservePlaybackTime: Bool, generation: UInt64) async -> Bool {
            let url = URL(fileURLWithPath: track.path)
            AppLog.info(.general, "📀 macOS loadTrack: \(track.title) (\(url.lastPathComponent))")

            // 切歌：清 AB 行号（保留跟唱模式/速度/单句循环；对齐 iOS performLoadTrack）
            KaraokeController.shared.resetForNewTrack()

            isLoadingTrack = true
            playbackState = .loading

            // Play history: settle the outgoing session before tearing down.
            PlayHistoryRecorder.shared.playbackEnded(track: currentTrack, at: nowPlayingElapsedTime())

            // Stop current playback and clean up.
            playerNode.stop()
            if audioEngine.isRunning {
                audioEngine.pause()
            }
            audioFile = nil
            if !preservePlaybackTime {
                seekTimeOffset = 0
                playbackTime = 0
                lastControlCenterUpdate = 0
            }
            nodeTimelineStartSampleTime = 0

            guard FileManager.default.fileExists(atPath: url.path) else {
                AppLog.error(.general, "❌ macOS loadTrack: file not found \(url.path)")
                playbackState = .stopped
                isLoadingTrack = false
                // 用户可见错误（2026-09-12 审计 P8）：macOS 失败同样不再静默
                reportPlaybackFailure(
                    PlaybackFailureMessage.messageKey(pathExtension: URL(fileURLWithPath: track.path).pathExtension).localized
                )
                return false
            }

            // SFB formats (Opus/OGG/DSD) play through SFBAudioEngine's AudioPlayer
            // (cross-platform, supports macOS 11+).
            if SFBAudioEngineManager.canHandle(url: url) {
                AppLog.info(.general, "🚀 macOS loadTrack delegating to SFBAudioEngine: \(url.lastPathComponent)")
                do {
                    try await sfbAudioManager.loadAndPlay(url: url)
                    guard isCurrentLoad(generation) else {
                        sfbAudioManager.stop()
                        return false
                    }
                    usingSFBEngine = true
                    duration = sfbAudioManager.duration
                    isPlaying = sfbAudioManager.isPlaying
                    currentTrack = track
                    playbackState = .stopped
                    isLoadingTrack = false
                    AppLog.info(.general, "✅ macOS delegated to SFBAudioEngine: \(url.lastPathComponent)")
                    return true
                } catch {
                    AppLog.error(.general, "❌ macOS SFBAudioEngine delegation failed: \(error)")
                    if isCurrentLoad(generation) {
                        usingSFBEngine = false
                        playbackState = .stopped
                        isLoadingTrack = false
                        // 用户可见错误（2026-09-12 审计 P8）：Opus/DSD 失败以前只 print，
                        // 用户侧表现是“点了完全无反应”（macOS 没有 iOS 那样的 native 回退）。
                        reportPlaybackFailure(
                            PlaybackFailureMessage.messageKey(pathExtension: URL(fileURLWithPath: track.path).pathExtension).localized
                        )
                    }
                    return false
                }
            }

            usingSFBEngine = false

            do {
                let file = try AVAudioFile(forReading: url)
                guard isCurrentLoad(generation) else { return false }
                audioFile = file
                duration = Double(file.length) / file.processingFormat.sampleRate
                currentTrack = track
                playbackState = .stopped
                isLoadingTrack = false
                return true
            } catch {
                AppLog.error(.general, "❌ macOS loadTrack failed: \(error)")
                if isCurrentLoad(generation) {
                    playbackState = .stopped
                    isLoadingTrack = false
                    audioFile = nil
                    reportPlaybackFailure(
                        PlaybackFailureMessage.messageKey(pathExtension: URL(fileURLWithPath: track.path).pathExtension).localized
                    )
                }
                return false
            }
        }

        func play() {
            if usingSFBEngine {
                do {
                    try sfbAudioManager.play()
                } catch {
                    AppLog.error(.general, "❌ macOS SFB play failed: \(error)")
                    return
                }
                isPlaying = true
                playbackState = .playing
                startPlaybackTimer()
                PlayHistoryRecorder.shared.playbackBegan(track: currentTrack, at: playbackTime)
                updateNowPlayingInfoEnhanced()
                AppLog.info(.general, "✅ macOS SFB playback resumed: \(currentTrack?.title ?? "")")
                return
            }

            // 启动恢复（restoreUIStateOnly）只恢复 UI 不载音频：首次点播放时
            // audioFile 为空 → 先补载当前曲并 seek 到断点再播（对齐 iOS play()）。
            // hasRestoredState 由 ensurePlayerStateRestored() 置位：冷启动首播走
            // ensure（loadTrack 保留时间 + seek）；中断/恢复后 audioFile 被清、
            // 再次播放走 preserve 分支（playbackTime 不重置，seek 到断点）。
            if audioFile == nil, currentTrack != nil, !isLoadingTrack {
                Task {
                    guard let track = currentTrack else { return }
                    var loaded = true
                    if hasRestoredState {
                        let savedPosition = playbackTime
                        loaded = await loadTrack(track, preservePlaybackTime: true)
                        if loaded, savedPosition > 0 {
                            await seek(to: savedPosition)
                            AppLog.info(.general, "✅ macOS restored position after reload: \(savedPosition)s")
                        }
                    } else {
                        await ensurePlayerStateRestored()
                    }
                    if loaded {
                        self.play()
                    }
                }
                return
            }

            // 决策上收：前置条件语义与 MacPlaybackGate.canStartPlayback 一一对应（有单测锁定）。
            guard let audioFile = audioFile,
                  MacPlaybackGate.canStartPlayback(
                      audioFileLoaded: true,
                      isLoadingTrack: isLoadingTrack,
                      playbackStateIsLoading: playbackState == .loading
                  ) else {
                AppLog.warn(.general, "⚠️ macOS play skipped: audioFile=\(audioFile != nil) state=\(playbackState)")
                return
            }

            ensureMacAudioEngineSetup(with: audioFile.processingFormat)

            if !audioEngine.isRunning {
                do {
                    try audioEngine.start()
                } catch {
                    AppLog.error(.general, "❌ macOS audioEngine start failed: \(error)")
                    return
                }
                // AVAudioEngine.start() 异步生效：紧跟的 scheduleSegment 有 engineIsRunning guard
                // （MacPlaybackGate.segmentPlan），isRunning 未变 true 时调度被拒 → 无声但 isPlaying=true
                // （2026-09-01 用户实测：首次点击歌词不播放、再次点击才播——首次 start 后才生效）。
                // 短轮询等 isRunning（引擎启动通常 <100ms，1s 兜底），用 RunLoop 转圈避免阻塞事件处理。
                let deadline = Date().addingTimeInterval(1.0)
                while !audioEngine.isRunning && Date() < deadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                if !audioEngine.isRunning {
                    AppLog.error(.general, "❌ macOS audioEngine did not become running after start")
                    return
                }
            }

            let requestedFrame = AVAudioFramePosition(playbackTime * audioFile.processingFormat.sampleRate)
            // 起始位置决策上收（MacPlaybackGate.playStartPlan，有单测锁定）：末尾/越界位置
            // 直接送进 scheduleSegment 会被 segmentPlan 拒绝 → 无调度、无 completion、永不自愈，
            // 但 isPlaying 仍被置 true（界面在播、实际无声；2026-09-12 审计 P1）。回零重播，
            // 并把位置状态一起归零（playbackTime / seekTimeOffset / lastKnown / 时间轴同源）。
            let startFrame: AVAudioFramePosition
            let requestedSeconds = playbackTime
            switch MacPlaybackGate.playStartPlan(requestedFrame: requestedFrame, fileLength: audioFile.length) {
            case let .resume(frame):
                startFrame = frame
            case .restartFromStart:
                startFrame = 0
                seekTimeOffset = 0
                playbackTime = 0
                nodeTimelineStartSampleTime = 0
                lastKnownPlaybackPosition = 0
                lastKnownPlaybackPositionUpdatedAt = Date()
                AppLog.warn(.general, "↩️ macOS play: 位置 \(requestedSeconds)s（帧 \(requestedFrame)/\(audioFile.length)）已在末尾或越界，从 0 重播")
            }

            // 对齐 iOS play（暂停恢复路径）：cancel + stop 再重新 schedule，避免队列残留旧 segment
            // 与旧 completion 误触发 handleTrackEnd（与 seek 同根因，2026-09-01）
            cancelPendingCompletions()
            playerNode.stop()
            guard scheduleSegment(from: startFrame, file: audioFile, track: currentTrack, trackIndex: currentIndex) else {
                // 调度失败（引擎未运行 / 帧范围非法）：绝不进入「显示在播但无声」——
                // 那条路径没有自愈机制（无调度 → 无 completion → 不会走到 handleTrackEnd），
                // 只能靠用户拖进度条解除（2026-09-12 审计 P1）。保持停止态，UI 与真实一致。
                isPlaying = false
                playbackState = .stopped
                stopPlaybackTimer()
                updateNowPlayingInfoEnhanced()
                AppLog.error(.general, "❌ macOS play: scheduleSegment 失败（startFrame=\(startFrame)），保持停止态不置 isPlaying")
                return
            }

            playerNode.play()
            isPlaying = true
            playbackState = .playing
            startPlaybackTimer()
            PlayHistoryRecorder.shared.playbackBegan(track: currentTrack, at: playbackTime)
            updateNowPlayingInfoEnhanced()
            AppLog.info(.general, "✅ macOS playback started: \(currentTrack?.title ?? "")")
        }

        func pause(fromControlCenter: Bool = false) {
            if usingSFBEngine {
                let currentPosition = sfbAudioManager.currentTime
                playbackTime = currentPosition
                seekTimeOffset = currentPosition
                sfbAudioManager.pause()
                isPlaying = false
                playbackState = .paused
                stopPlaybackTimer()
                PlayHistoryRecorder.shared.playbackPaused(track: currentTrack, at: playbackTime)
                updateNowPlayingInfoEnhanced()
                AppLog.info(.general, "⏸️ macOS SFB paused at \(playbackTime)s")
                return
            }

            guard audioFile != nil else { return }

            let currentPosition = currentTimeForCurrentNativeFile()
            playbackTime = currentPosition
            seekTimeOffset = currentPosition

            if audioEngine.isRunning {
                // 桌面端无 iOS 省电/后台挂起约束：只暂停播放节点，保留引擎运行。
                // 引擎级 pause() 停掉整个渲染线程，恢复 play() 必须重新 start + 轮询
                // 等 isRunning（音频硬件重启，外接声卡/蓝牙可达数百 ms）→ 用户感知
                // "暂停再播放卡顿"（2026-09-05）。playerNode.pause() 保留引擎与已调度
                // 缓冲，恢复走下方轻量重排路径，几乎无感。
                playerNode.pause()
            }
            isPlaying = false
            playbackState = .paused
            stopPlaybackTimer()
            PlayHistoryRecorder.shared.playbackPaused(track: currentTrack, at: playbackTime)
            updateNowPlayingInfoEnhanced()
            AppLog.info(.general, "⏸️ macOS paused at \(playbackTime)s")
        }

        func seek(to time: TimeInterval) async {
            if usingSFBEngine {
                let clamped = min(max(time, 0), duration)
                do {
                    try sfbAudioManager.seek(to: clamped)
                } catch {
                    AppLog.error(.general, "❌ macOS SFB seek failed: \(error)")
                    return
                }
                playbackTime = clamped
                lastKnownPlaybackPosition = clamped
                lastKnownPlaybackPositionUpdatedAt = Date()
                updateNowPlayingInfoEnhanced()
                AppLog.info(.general, "✅ macOS SFB seek to \(clamped)s")
                return
            }

            guard let audioFile = audioFile else { return }
            let clamped = min(max(time, 0), duration)
            let wasPlaying = isPlaying

            // 对齐 iOS seek：先取消 pending completion 再 stop——playerNode.stop() 会触发
            // 已调度 segment 的 completion 回调，不取消则 generation 仍匹配，handleMacSegmentFinished
            // 误判「播完」→ handleTrackEnd 停播/切歌（2026-09-01 日志实锤：播放中点歌词后
            // isPlaying 变 false，第二次点击才真正播放）
            cancelPendingCompletions()
            playerNode.stop()
            seekTimeOffset = clamped
            playbackTime = clamped
            nodeTimelineStartSampleTime = 0

            if wasPlaying {
                // 播放中 seek：重新调度并继续播放（引擎应在运行；未运行则启动并等 isRunning 生效）
                if !audioEngine.isRunning {
                    do {
                        try audioEngine.start()
                    } catch {
                        AppLog.error(.general, "❌ macOS seek: engine start failed \(error)")
                        return
                    }
                    // 等 isRunning（引擎启动通常 <100ms，1s 兜底）。async 上下文不能用
                    // RunLoop.current.run（Swift 6 并发检查标记不可用），改用 Task.sleep
                    // 轮询 + scheduleGeneration 防重入：await 期间新 seek 会递增 generation，
                    // 检测到变化即退出（让新 seek 赢，避免旧值覆盖播放位置）。
                    let seekGeneration = scheduleGeneration
                    let deadline = Date().addingTimeInterval(1.0)
                    while !audioEngine.isRunning && Date() < deadline {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        guard scheduleGeneration == seekGeneration else { return }
                    }
                }
                let startFrame = AVAudioFramePosition(clamped * audioFile.processingFormat.sampleRate)
                scheduleSegment(from: startFrame, file: audioFile, track: currentTrack, trackIndex: currentIndex)
                playerNode.play()
            }
            // 暂停态 seek：仅更新位置，不调度不启动引擎——由后续 play() 统一
            // schedule（避免 seekAndPlay 链路双重 schedule 同位置 segment，
            // 第一个 segment 播完误触发 handleTrackEnd 切歌；2026-09-01 发现）
            lastKnownPlaybackPosition = clamped
            lastKnownPlaybackPositionUpdatedAt = Date()
            updateNowPlayingInfoEnhanced()
            AppLog.info(.general, "✅ macOS seek to \(clamped)s")
        }

        func cancelPendingCompletions() {
            scheduleGeneration &+= 1
        }

        // MARK: - macOS Engine Graph

        /// 已配置的引擎图 format（缓存避免每次 play 重复 connect——AVAudioEngine.connect
        /// 是同步重操作，内部等待音频渲染线程，重复调用触发 Hang 检测的优先级反转
        /// （2026-09-01 跟唱跳转链路实测：PlayerEngineKaraokeActions → play → connect）
        /// static：extension 不允许实例存储属性；PlayerEngine 是单例，语义等价
        private static var macEngineGraphFormat: AVAudioFormat?
        /// 缓存所属的引擎实例（弱引用）：媒体服务重置 / recreateAudioEngine / resetAudioEngineForNative
        /// 都会换成新引擎——此时缓存 format 可能相同，但新引擎图上一条连线都没有，
        /// 必须重连（否则 playerNode 没接到 mixer = 无声）。
        private static weak var macEngineGraphOwner: AVAudioEngine?

        private func ensureMacAudioEngineSetup(with format: AVAudioFormat?) {
            if !audioEngine.attachedNodes.contains(playerNode) {
                audioEngine.attach(playerNode)
            }
            if !audioEngine.attachedNodes.contains(timePitchNode) {
                audioEngine.attach(timePitchNode)
            }
            // EQ 节点：首次创建并 attach（EQManager.setupEQNode 内部 attach 到 engine）。
            // 只在节点不存在时调用——重复调用会新建 AVAudioUnitEQ 重复 attach（引擎图脏）。
            // attach 必须在 engine 未运行时执行：首次 setup 发生在 play() 的 engine.start()
            // 之前 ✓；后续 format 变化只 connect 不 attach（节点已在图上）。
            if eqManager.currentEQNode == nil
                || !audioEngine.attachedNodes.contains(eqManager.currentEQNode!) {
                eqManager.setAudioEngine(audioEngine)
            }
            // 幂等跳过：只有「同 format **且同引擎实例**」才跳过（connect 是同步重操作，
            // 每次调用都等音频线程；但引擎换过就必须重连）
            if Self.macEngineGraphFormat == format, Self.macEngineGraphOwner === audioEngine {
                return
            }

            // ⚠️ 重连必须在**引擎停止**状态下做（2026-09-12 用户实测崩溃）：
            // 换歌时输入格式会变（mp3 库混采样率极常见：至少还有你-林忆莲.mp3 44.1kHz →
            // 死ぬのがいいわ-藤井風.mp3 48kHz），而 loadTrack 只 pause 了引擎。在未停止的引擎上
            // 改连接格式，AVAudioEngine 内部走 UpdateGraphAfterReconfig → 输出链初始化失败
            // （AVAEInternal.h:104 … error -10868 = kAudioUnitErr_FormatNotSupported）→
            // connect(_:to:format:) 抛 **ObjC 异常**，Swift 捕不到 → 直接崩进程。
            // 日志实锤：nextTrack(autoplay:) → play() → ensureMacAudioEngineSetup → connect。
            // 无条件 stop（不用 isRunning 判断：pause 后 isRunning 已为 false，但那种状态同样会崩）。
            // 对齐 iOS reconfigureAudioEngineForNewFormat（先 stop 再重连）；调用方 play()
            // 随后会自己 start（if !audioEngine.isRunning 分支）。
            //
            // 无爆音是构造上保证的：停引擎前先确认播放节点已停 → 停掉的是一个**没有任何
            // 音频在渲染**的引擎，不会在波形中途截断（那个才是爆音的来源）。调用方
            // loadTrack 已经 playerNode.stop()，这里再兜一次以防其它调用路径。
            if playerNode.isPlaying {
                playerNode.stop()
            }
            audioEngine.stop()

            // playerNode → timePitch（倍速）→ EQ → mainMixer（EQ 节点存在时；
            // 对齐 iOS connectPlaybackChain）。AVAudioEngine owns the mainMixer →
            // outputNode connection and negotiates the hardware format.
            audioEngine.connect(playerNode, to: timePitchNode, format: format)
            if let eqNode = eqManager.currentEQNode {
                audioEngine.connect(timePitchNode, to: eqNode, format: format)
                audioEngine.connect(eqNode, to: audioEngine.mainMixerNode, format: format)
            } else {
                audioEngine.connect(timePitchNode, to: audioEngine.mainMixerNode, format: format)
            }
            audioEngine.prepare()
            Self.macEngineGraphFormat = format
            Self.macEngineGraphOwner = audioEngine
        }
    }
#endif
