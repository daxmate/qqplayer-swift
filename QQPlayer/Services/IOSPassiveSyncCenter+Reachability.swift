//
//  IOSPassiveSyncCenter+Reachability.swift
//  QQPlayer
//
//  iOS 被动同步中心分片：网络可达性门控 + 回前台去抖（A/C/F）。
//
//  背景（两个坏体验，2026-09 只读侦察）：
//    - 「看起来一直在试」：真·后台→前台时 `stop()` 清零退避计数 + `start()` 全新分支
//      → 完整 5 次重来（本批不再清零，见主文件 `start()`/`stop()`）。
//    - 「僵尸绿点」：断 Wi-Fi 时 `NWConnection` 可能长时间不进 `.failed`（只到
//      `.waiting`）→ 首页绿点常亮。这里拿系统**路径事实**做主动门控：
//      `.unsatisfied` 立即拆会话回「未连接」，`.satisfied`（恢复）立即补试一次。
//
//  复用而非重写：路径监听唯一实现 = `IOSPassivePathMonitor`；本分片不另写监听。
// target: ios-only（消费端全在 iOS；macOS 不编译）
//

#if os(iOS)

    import Foundation
    import Network

    // MARK: - 路径监听（`NWPathMonitor` 薄封装）

    /// 网络可达性监听抽象：只暴露「有可用路径 / 无可用路径」一个信号。
    ///
    /// 抽成协议只为测试注入假监视器（不真监听网络）；**唯一生产实现** =
    /// `IOSPassivePathMonitor`，别处不得再封装一份 `NWPathMonitor`。
    protocol IOSPassivePathMonitoring: AnyObject {
        /// 路径可用性变化（`true` = satisfied；任意线程回调，中心侧自行跳主线程）
        var onPathChange: (@Sendable (Bool) -> Void)? { get set }
        /// 开始监听（幂等）
        func start()
        /// 停止监听（幂等；`NWPathMonitor` cancel 后不可复用 → 由 `startPathMonitor` 重建）
        func stop()
    }

    /// `NWPathMonitor` 的薄封装：把系统路径状态收敛成「satisfied / unsatisfied」。
    final class IOSPassivePathMonitor: IOSPassivePathMonitoring, @unchecked Sendable {
        var onPathChange: (@Sendable (Bool) -> Void)?

        private let monitor = NWPathMonitor()
        private let queue = DispatchQueue(label: "com.daxmate.qqplayer.sync.pathmonitor")
        private let lock = NSLock()
        private var started = false

        func start() {
            lock.lock()
            let alreadyStarted = started
            started = true
            lock.unlock()
            guard !alreadyStarted else { return }
            monitor.pathUpdateHandler = { [weak self] path in
                self?.onPathChange?(path.status == .satisfied)
            }
            monitor.start(queue: queue)
        }

        func stop() {
            lock.lock()
            let wasStarted = started
            started = false
            lock.unlock()
            guard wasStarted else { return }
            monitor.pathUpdateHandler = nil
            monitor.cancel()
        }
    }

    // MARK: - 中心：路径门控

    extension IOSPassiveSyncCenter {
        /// 挂路径监听（幂等；生产在 `start()` 调，测试可注入假监视器）。
        func startPathMonitor() {
            guard pathMonitor == nil else { return }
            let monitor = makePathMonitor()
            monitor.onPathChange = { [weak self] satisfied in
                Task { @MainActor in self?.handlePathChange(satisfied: satisfied) }
            }
            pathMonitor = monitor
            monitor.start()
        }

        /// 摘路径监听（幂等）。
        func stopPathMonitor() {
            pathMonitor?.stop()
            pathMonitor = nil
            pathIsSatisfied = nil
        }

        /// 路径事实变化。**只在真正的状态迁移上动作**——`NWPathMonitor` 首帧通常会
        /// 直接给当前状态（satisfied），那不是「恢复」，不该把 `start()` 的正常尝试
        /// 又触发一遍。
        func handlePathChange(satisfied: Bool) {
            let previous = pathIsSatisfied
            pathIsSatisfied = satisfied
            guard isRunning else { return }
            if satisfied {
                // 仅「unsatisfied → satisfied」才算路径恢复；首帧 nil→satisfied 不动作。
                guard previous == false else { return }
                handlePathRecovered()
            } else {
                guard previous != false else { return }
                handlePathLost()
            }
        }

        /// 无可用路径：立即停浏览 + 取消重连 + 拆会话 + 回退「未连接」（绿点随之灰）。
        func handlePathLost() {
            guard isRunning else { return }
            cancelDiscovery()
            cancelReconnect()
            browser?.stopBrowsing()
            browser = nil
            tearDownSession()
            currentTarget = nil
            attemptedTargets.removeAll()
            state = .idle
        }

        /// 路径恢复：重置退避计数 + 立即补试一次（仅前台；本方法只在 `isRunning` 时被调）。
        func handlePathRecovered() {
            guard isRunning else { return }
            automaticAttempts = 0
            cancelReconnect()
            beginAttempt()
        }

        /// 复用现有会话前的**活性判定**（E）：路径可用 + 会话确实 ready。
        ///
        /// 僵尸场景：`state == .connected` 但底层通道已失活（`.waiting`/失败，会话已被
        /// `handleTransportInactive()` 收尾）→ 判定不通过 → 不复用，走真实重连。
        var isCurrentConnectionLive: Bool {
            pathIsSatisfied != false && session?.isReady == true
        }

        // MARK: 前台生命周期（C）

        /// 唯一前台生命周期入口（App `scenePhase` → 此处）：
        ///   - `.background`：拆会话（`stop()`；**保留**退避计数，不再清零）
        ///   - `.active` 真回前台：立即补试一次
        ///   - `.active` 由 inactive 抖动而来：去抖后再补试（`inactiveDebounce`）
        func handleScenePhase(_ phase: IOSPassiveForegroundGate.Phase) {
            if phase == .background {
                _ = foregroundGate.handle(.background)
                cancelForegroundDebounce()
                stop()
                return
            }
            switch foregroundGate.handle(phase) {
            case .retryNow:
                cancelForegroundDebounce()
                start()
            case .debounced:
                scheduleForegroundDebounce()
            case .none:
                break
            }
        }

        /// 去抖窗口结束后：仍停在 `.active` 才补试一次（期间又 inactive 则作废）。
        func scheduleForegroundDebounce() {
            cancelForegroundDebounce()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.foregroundGate.shouldRetryAfterDebounce() else { return }
                    self.foregroundDebounceWork = nil
                    self.start()
                }
            }
            foregroundDebounceWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + IOSPassiveForegroundGate.inactiveDebounce,
                execute: work
            )
        }

        /// 取消失去抖调度（新阶段到来 / 进后台即取消）。
        func cancelForegroundDebounce() {
            foregroundDebounceWork?.cancel()
            foregroundDebounceWork = nil
        }
    }

#endif
