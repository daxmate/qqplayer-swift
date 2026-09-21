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

    /// 自动重连退避策略（**仅前台**使用；上限用尽 → 交手动「重连」）。
    enum IOSPassiveReconnectPolicy {
        /// 前台自动重连次数上限（此后只保留手动重连，避免无主机时无限耗电）
        static let maxAutomaticAttempts = 5
        /// 首次等待秒数（指数退避基数）
        static let baseDelay: TimeInterval = 2
        /// 单次等待封顶（避免长尾）
        static let maxDelay: TimeInterval = 30

        /// 第 n 次自动重连（1 起）前的等待秒数；超出上限返回 nil。
        static func delayBeforeAttempt(_ attempt: Int) -> TimeInterval? {
            guard attempt >= 1, attempt <= maxAutomaticAttempts else { return nil }
            return min(baseDelay * pow(2, Double(attempt - 1)), maxDelay)
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
