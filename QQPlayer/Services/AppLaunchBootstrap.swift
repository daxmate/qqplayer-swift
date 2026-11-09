//
//  AppLaunchBootstrap.swift
//  QQPlayer
//
//  冷启动装配入口（iOS）：把「播放要用的东西」一次装齐，且可重复调用。
//
//  背景（2026-11-09）：无线 CarPlay 冷启动时车机上点播放没反应，必须先在 iPhone 上
//  播一次才活。原因是 App 启动只恢复了 UI 状态（AppCoordinator.initialize），音频会话
//  / 引擎 / 通知 / 远程命令都要等「手机端第一次播放成功」才装配（PlayerEngine.init
//  里这几步全是注释掉的）。CarPlay 直接接管屏幕时这一步永远等不到：MPRemoteCommandCenter
//  没有 play 命令、会话也没配好 → 车机上的播放键落空，并且 play() 在 currentTrack 为空
//  时只打一条 warn 就 return，界面上什么反馈都没有。
//
//  → CarPlay didConnect 与「play() 时 currentTrack 为空」两条冷启动路径都调这里补装配。
//
// target: ios-only（PlayerEngine 的 iOS 装配分片都在 #if os(iOS) 下）
//

#if os(iOS)
    import Foundation

    /// 冷启动装配：幂等（各 setup 自带 hasSetup* 门闸；状态恢复只补一次）。
    @MainActor
    enum AppLaunchBootstrap {
        /// 在途/已完成的「用持久化状态补出当前曲目」任务：并发调用共用一份，
        /// 避免 didConnect 与 play() 同时触发时重复读库、互相覆盖现场。
        private static var restoreTask: Task<Bool, Never>?

        /// play() 的冷启动补装配是否正在进行（防连点/系统重复回调叠 Task）。
        static var isColdStartPlayPending = false

        /// 装齐播放链路。已装好时是 no-op（会话激活仅在已有曲目时做，避免打断别的 App）。
        static func ensure(reason: String) {
            let engine = PlayerEngine.shared
            AppLog.info(.general, "🚀 AppLaunchBootstrap.ensure(reason: \(reason))")

            // 会话 category/mode/options：走既有门闸，CarPlay 环境判定依赖
            // SFBAudioEngineManager.updateCarPlayStatus() 先跑（见 didConnect 调用顺序）。
            engine.ensureAudioSessionSetup()
            engine.ensureAudioEngineSetup()
            engine.ensureAudioSessionNotificationsSetup()
            engine.ensureRemoteCommandsSetup()

            // 只有「确实有曲目要恢复」时才激活会话：冷启动无曲目时激活会把正在放歌的
            // 别的 App 打断，而 play() 自己会在真正开播前激活（Transport:activateAudioSession）。
            if engine.currentTrack != nil {
                activateSession(reason: reason)
            } else {
                AppLog.info(.general, "🎧 AppLaunchBootstrap: 暂不激活音频会话（当前无曲目，播放时再激活）")
            }

            // 冷启动没有曲目时补一次 UI 状态恢复（只恢复曲目/队列/进度，不自动播放），
            // 让车机上的播放键有东西可播。
            if engine.currentTrack == nil {
                Task { @MainActor in
                    await restoreStateIfNeeded(reason: reason)
                }
            }
        }

        /// 用持久化状态补出当前曲目/队列/进度（不自动播放）；并发调用共用同一个任务。
        @discardableResult
        static func restoreStateIfNeeded(reason: String) async -> Bool {
            let engine = PlayerEngine.shared
            if engine.currentTrack != nil { return true }
            if let restoreTask {
                return await restoreTask.value
            }
            AppLog.info(.general, "🔄 AppLaunchBootstrap: 恢复上次播放器状态（\(reason)）")
            let task = Task { @MainActor in
                await engine.restoreUIStateOnly()
                return engine.currentTrack != nil
            }
            restoreTask = task
            let restored = await task.value
            AppLog.info(.general, "🔄 AppLaunchBootstrap: 状态恢复完成（\(reason)），有曲目=\(restored)")
            return restored
        }

        /// 激活音频会话（幂等：同一会话重复 setActive(true) 无副作用）。
        static func activateSession(reason: String) {
            do {
                try PlayerEngine.shared.activateAudioSession()
                AppLog.info(.general, "🎧 AppLaunchBootstrap: 音频会话已激活（\(reason)）")
            } catch {
                AppLog.error(.general, "❌ AppLaunchBootstrap: 激活音频会话失败（\(reason)）: \(error)")
            }
        }
    }
#endif
