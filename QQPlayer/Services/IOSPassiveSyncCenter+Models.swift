#if os(iOS)

    import Foundation
    import Network

    // target: ios-only（iOS 被动同步中心分片：状态/纯逻辑模型；消费端全在 iOS，macOS 不编译）

    // MARK: - 状态（契约 C3）

    /// iOS 被动端连接状态（`IOSPassiveSyncCenter.state`）。
    enum IOSPassiveSyncState: Equatable, Sendable {
        /// 未运行 / 没有可连的主机
        case idle
        /// 浏览或连接中（hostName = nil 表示还在浏览）
        case connecting(hostName: String?)
        /// 已连接并接成被动端
        case connected(hostName: String, peerID: String)
        /// 失败（展示映射见 `IOSPassiveSyncPresenter`）
        case failed(IOSPassiveSyncFailure)

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        var isConnecting: Bool {
            if case .connecting = self { return true }
            return false
        }
    }

    /// 被动端失败模型：本端前置条件缺失，或复用扫码回连的 `SyncConnectFailure`。
    enum IOSPassiveSyncFailure: Equatable, Sendable {
        /// 本机没有已配对主机（设置页引导扫码添加）
        case noPairedHost
        /// 本端同步身份不可用（Keychain 异常）
        case identityUnavailable
        /// 连接/会话失败（分类复用 `SyncConnectLogic.failure(fromCloseReason:)`）
        case connect(SyncConnectFailure)
    }

    // MARK: - 纯逻辑：候选目标 / 退避策略（可单测）

    /// 一个候选连接目标：已配对主机（peerID = 握手 pinning 期望值）+ 浏览到的 endpoint。
    struct IOSPassiveSyncTarget: Equatable, Sendable {
        var peerID: String
        var hostName: String
        var endpoint: NWEndpoint
    }

    /// 被动端回连决策纯逻辑（无 IO / 无状态，可单测）。
    enum IOSPassiveReconnectLogic {
        /// 浏览结果 × 已配对主机 → 候选目标序列。
        ///
        /// 排序：名称 case-insensitive 相同者优先（**复用** `SyncConnectLogic.matches`
        /// 口径，与扫码回连同源）；改名/重名场景下剩余 endpoint 仍按发现顺序兜底尝试
        /// ——身份由握手 pinning（expectedPeerDeviceID）判定，广播名不作凭据，
        /// 连错也只会以 `peerUntrusted` / `identityMismatch` 关闭。
        static func targets(
            discovered: [SyncDiscoveredHost],
            pairedHosts: [PeerDevice]
        ) -> [IOSPassiveSyncTarget] {
            var matched: [IOSPassiveSyncTarget] = []
            var claimed: Set<Int> = []
            var unmatchedPeers: [PeerDevice] = []
            for peer in pairedHosts {
                let index = discovered.indices.first {
                    !claimed.contains($0)
                        && SyncConnectLogic.matches(hostName: discovered[$0].name, expected: peer.displayName)
                }
                if let index {
                    claimed.insert(index)
                    matched.append(IOSPassiveSyncTarget(
                        peerID: peer.peerID,
                        hostName: discovered[index].name,
                        endpoint: discovered[index].endpoint
                    ))
                } else {
                    unmatchedPeers.append(peer)
                }
            }
            let leftovers = discovered.indices
                .filter { !claimed.contains($0) }
                .map { discovered[$0] }
            let fallback = unmatchedPeers.flatMap { peer in
                leftovers.map { host in
                    IOSPassiveSyncTarget(peerID: peer.peerID, hostName: host.name, endpoint: host.endpoint)
                }
            }
            return matched + fallback
        }
    }

    /// 自动重连退避策略（**仅前台**使用；突发用尽 → 转低频稳态重试，**不放弃**）。
    enum IOSPassiveReconnectPolicy {
        /// 前台**突发**重连次数：此内指数退避（2/4/8/16/30），用尽后转低频稳态。
        static let maxBurstAttempts = 5
        /// 稳态（突发用尽后）重试间隔秒数——保持低频、不放弃：断网 / 对端离线时
        /// 网络一恢复 / 对端一上线即自动接上，不必等用户手动「重连」。
        static let steadyInterval: TimeInterval = 60
        /// 首次等待秒数（指数退避基数）
        static let baseDelay: TimeInterval = 2
        /// 单次等待封顶（避免长尾）
        static let maxDelay: TimeInterval = 30

        /// 第 n 次自动重连（1 起）前的等待秒数。
        ///
        /// 1..`maxBurstAttempts` → 2/4/8/16/30；≥`maxBurstAttempts`+1 → 恒定
        /// `steadyInterval`(60)。历史（2026-09-11 起）此函数在上限用尽后返回 nil →
        /// 上层停死重连、只留设置页手动兜底；「看起来一直在试 / 僵尸绿点」两个坏体验后
        /// 改为**低频不放弃**（进后台 / 路径不可用仍由上层停，见 `scheduleReconnect`）。
        /// attempt < 1（非法输入）返回 nil：上层 `automaticAttempts` 恒 ≥1，此分支不可达。
        static func delayBeforeAttempt(_ attempt: Int) -> TimeInterval? {
            guard attempt >= 1 else { return nil }
            guard attempt <= maxBurstAttempts else { return steadyInterval }
            return min(baseDelay * pow(2, Double(attempt - 1)), maxDelay)
        }
    }

    // MARK: - 纯逻辑：回前台动作决策（可单测）

    /// App 回前台时的连接补试决策（纯逻辑，无 SwiftUI / 无 IO）。
    ///
    /// 背景（场景 A「看起来一直在试」）：此前 `scenePhase` 每次 `.active` 都直接
    /// `start()` —— 真·后台→前台、与 inactive→active（控制中心 / 来电横幅的瞬时
    /// 中断）都会各开一轮，行为上看不出区别，退避计数也被反复清零。
    ///
    /// 本类型把两种 `.active` 区分开：
    ///   - `.background` → `.active`：真回前台 → `retryNow`（立即补试一次；计数**不清零**）
    ///   - `.inactive` → `.active`：抖动嫌疑 → `debounced`（等 `inactiveDebounce`，
    ///     期间再次 `.inactive` 则作废）
    struct IOSPassiveForegroundGate {
        enum Phase: Equatable { case active, inactive, background }

        /// inactive→active 去抖窗口（秒）：期间若又回 inactive 即判为瞬时中断，不补试。
        static let inactiveDebounce: TimeInterval = 1.5

        enum Action: Equatable {
            /// 真·后台→前台：立即补试一次
            case retryNow
            /// 需去抖判定（调用方等 `inactiveDebounce` 后查 `shouldRetryAfterDebounce()`）
            case debounced
            /// 不动作
            case none
        }

        /// 上一次观察到的阶段（nil = 尚未收到任何阶段；首帧 `.active` 视作「回前台」）
        private(set) var lastPhase: Phase?

        /// 处理一次阶段变化，返回**立即动作**（去抖的落地交给调用方调度）。
        mutating func handle(_ phase: Phase) -> Action {
            defer { lastPhase = phase }
            guard phase == .active else { return .none }
            switch lastPhase {
            case .background?, nil:
                return .retryNow
            case .inactive?:
                return .debounced
            case .active?:
                return .none
            }
        }

        /// 去抖窗口结束时的判定：期间没有新的阶段变化（仍停在 `.active`）才补试。
        func shouldRetryAfterDebounce() -> Bool {
            lastPhase == .active
        }
    }

    // MARK: - 纯逻辑：设置页展示映射（可单测）

    /// 设置页「接收同步」区展示模型：只带本地化 key / 数字，文案值由 View 取。
    struct IOSPassiveSyncPresentation: Equatable {
        var symbol: String
        var titleKey: String
        var titleArg: String?
        var detailKey: String?
        var detailArg: String?
        /// 已接收（已落位并交给入库入口）文件数
        var receivedFiles: Int
        /// 最近一批声明的条目数（0 = 尚无推送）
        var lastBatchEntries: Int
        /// 失败清单（View 截断展示）
        var failures: [SyncPushFailure]
        /// 是否展示「重连」按钮（连接中/已连接时不需要）
        var canReconnect: Bool
    }

    /// 状态 + 账目 → 展示模型（纯函数）。
    enum IOSPassiveSyncPresenter {
        static func presentation(
            state: IOSPassiveSyncState,
            summary: SyncLibraryPassiveSummary,
            hasPairedHost: Bool
        ) -> IOSPassiveSyncPresentation {
            let canReconnect = hasPairedHost && !state.isConnected && !state.isConnecting
            func make(
                _ symbol: String,
                _ titleKey: String,
                _ titleArg: String? = nil,
                _ detailKey: String? = nil,
                _ detailArg: String? = nil
            ) -> IOSPassiveSyncPresentation {
                IOSPassiveSyncPresentation(
                    symbol: symbol,
                    titleKey: titleKey,
                    titleArg: titleArg,
                    detailKey: detailKey,
                    detailArg: detailArg,
                    receivedFiles: summary.landed.count,
                    lastBatchEntries: summary.announcedEntries,
                    failures: summary.failed,
                    canReconnect: canReconnect
                )
            }

            switch state {
            case .idle:
                return make(
                    hasPairedHost ? "wifi.slash" : "plus.circle",
                    hasPairedHost ? "sync_passive_state_idle" : "sync_passive_state_unpaired"
                )

            case let .connecting(hostName):
                guard let hostName else {
                    return make("wifi", "sync_passive_state_searching")
                }
                return make("wifi", "sync_passive_state_connecting", hostName)

            case let .connected(hostName, _):
                return make("checkmark.circle.fill", "sync_passive_state_connected", hostName)

            case let .failed(failure):
                let copy = failureCopy(failure)
                return make("exclamationmark.triangle", copy.titleKey, copy.titleArg, copy.detailKey, copy.detailArg)
            }
        }

        /// 接收失败原因码 → 本地化 key（被动端只会出现接收/落位侧原因；
        /// 发送侧原因码（`sendFailed` / `localFileUnavailable`）不会出现在本链路，
        /// 兜底归入「其他」）。
        static func reasonKey(_ reason: String) -> String {
            if reason == SyncPushFailureReason.receiveFailed { return "sync_passive_reason_transfer" }
            if reason == SyncPushFailureReason.invalidPath { return "sync_passive_reason_path" }
            if reason == SyncPushFailureReason.landFailed { return "sync_passive_reason_save" }
            return "sync_passive_reason_other"
        }

        private static func failureCopy(
            _ failure: IOSPassiveSyncFailure
        ) -> (titleKey: String, titleArg: String?, detailKey: String?, detailArg: String?) {
            switch failure {
            case .noPairedHost:
                return ("sync_passive_state_unpaired", nil, nil, nil)
            case .identityUnavailable:
                return ("sync_passive_fail_identity", nil, nil, nil)
            case let .connect(connectFailure):
                switch connectFailure {
                case let .hostNotFound(name):
                    return name == nil
                        ? ("sync_passive_fail_not_found_generic", nil, nil, nil)
                        : ("sync_passive_fail_not_found", name, nil, nil)
                case let .rejected(reason):
                    return ("sync_passive_fail_rejected", nil, reason == nil ? nil : "sync_passive_detail", reason)
                case .timedOut:
                    return ("sync_passive_fail_timeout", nil, nil, nil)
                case let .connectionFailed(detail):
                    return ("sync_passive_fail_connection", nil, detail == nil ? nil : "sync_passive_detail", detail)
                }
            }
        }
    }

    // MARK: - 纯逻辑：数据同步端装配决策（可单测）

    /// 会话 ready 时数据同步端（帧 8/9 = `SyncChangeLogPeer`）的装配决策。
    ///
    /// 抽成纯函数是为了让 iOS 测试 target 能直接锁死这条决策：装配路径本身依赖网络
    /// 发现（浏览 → 连接 → ready），无法直接单测。
    enum IOSPassiveDataSyncLogic {
        /// 对端 hello 里的 Device ID → 数据同步端游标键；nil / 空串 → 不装配。
        ///
        /// 口径与 `MacSyncCoordinatorFactory` 一致：peerID 是 `sync_cursor.peer_id`
        /// 的键，空串会写出一条谁也匹配不到的脏游标行 → **宁可不接，不写脏数据**。
        static func dataSyncPeerID(peerDeviceID: String?) -> String? {
            guard let peerDeviceID, !peerDeviceID.isEmpty else { return nil }
            return peerDeviceID
        }
    }

#endif
