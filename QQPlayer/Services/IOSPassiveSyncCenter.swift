//
//  IOSPassiveSyncCenter.swift
//  QQPlayer
//
//  M6 · T4/T5（2026-09-11）iOS App 级被动同步中心。
//
//  背景：同步发起方**恒为 Mac**（R1b-2 起），iOS 只应答 Mac 的 manifest/fetch 请求
//  并接收 Mac 推送的文件落库；但 `SyncLibraryPassiveHost` 此前**全仓零实例化**，
//  且 iOS 配对后只有在扫码那一次回连 → Mac 的推送根本送不到手机。本文件把这条
//  链路接成 App 级能力：
//    ① 前台 `start()`：浏览 mDNS → 按「已配对主机」尝试连接（身份由握手 pinning
//       校验；Bonjour 广播名只用于排序/展示，**绝不作为身份凭据**）→ 会话 ready
//       后装配 `SyncLibraryPassiveHost`（曲库根 = 本地沙盒 Documents，与
//       LibraryIndexer 扫描同一事实源）并 `attach`。
//    ② 退后台 `stop()`：拆接线 + 关会话 + 停浏览（被动端只在前台工作）。
//    ③ 断线重连：**仅前台**，指数退避 + 上限（`IOSPassiveReconnectPolicy`）；上限
//       用尽后交设置页「重连」按钮手动兜底（`reconnectNow()`）。
//    ④ 进度：`SyncLibraryPassiveHost.onFileLanded` / `onBatchCompleted` → `summary`
//       （**不加新协议帧**；v1 文件级进度）。
//
//  复用而非重写（行为单一事实源）：
//    - 浏览/连接：`SyncBrowser`
//    - 名称匹配口径：`SyncConnectLogic.matches` / `SyncConnectLogic.pickHost`（扫码回连同源）
//    - 关闭原因 → 失败模型：`SyncConnectLogic.failure(fromCloseReason:)`
//    - 设备列表过滤：`SyncDeviceList.hosts(in:)`
//    - 接收落库：`SyncLibraryPassiveHost`（内部复用 `SyncLocalLibraryProvider` /
//      `SyncFileReceiver` / `SyncLyricsReceiver` / `LibraryIndexerSyncSink`）
//
//  平台：iOS 专用（macOS 侧由 `MacSyncHostCenter` 负责），整文件 `#if os(iOS)`。
//

#if os(iOS)

    import Combine
    import Foundation
    import Network
    import UIKit

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

    // MARK: - 中心（App 级单例）

    /// iOS App 级被动同步中心（契约 C3）：一个实例至多一个活动会话，只应答 + 接收。
    @MainActor
    final class IOSPassiveSyncCenter: ObservableObject {
        static let shared = IOSPassiveSyncCenter()

        /// 连接状态
        @Published private(set) var state: IOSPassiveSyncState = .idle
        /// 接收账目（`onFileLanded` / `onBatchCompleted` 驱动）
        @Published private(set) var summary = SyncLibraryPassiveSummary()
        /// 已配对主机数（设置页据此区分「未配对」与「未连接」）
        @Published private(set) var pairedHostCount = 0

        private let identityStore: SyncIdentityStore
        private let deviceStore: DeviceStore
        private let libraryRoot: () -> URL
        private let clientName: () -> String?

        /// 默认本机名来源（握手 hello / 配对请求携带的展示名）：
        /// 用户命名（`LocalDeviceNameStore`）优先，未命名回落系统设备名。
        /// 抽成静态函数是为了让 iOS 测试 target 能注入独立 store 锁定这条接线
        /// （不必建会话 / DB）；生产默认值即本函数。
        nonisolated static func defaultClientName(store: LocalDeviceNameStore = .shared) -> String? {
            store.name
        }

        private var browser: SyncBrowser?
        private var session: SyncPeerSession?
        private var passiveHost: SyncLibraryPassiveHost?
        private var pairedHosts: [PeerDevice] = []
        private var currentTarget: IOSPassiveSyncTarget?
        /// 本轮已尝试过的目标（`peerID|hostName`），避免浏览回调反复重连同一目标
        private var attemptedTargets: Set<String> = []
        private var isRunning = false
        private var isTearingDown = false
        private var isWaitingBackoff = false
        private var automaticAttempts = 0
        /// 每次尝试的令牌：旧会话/旧被动端回调据其失效
        private var attemptToken = UUID()
        private var discoveryWork: DispatchWorkItem?
        private var reconnectWork: DispatchWorkItem?

        init(
            identityStore: SyncIdentityStore = SyncIdentityStore(),
            deviceStore: DeviceStore = DeviceStore(),
            libraryRoot: @escaping () -> URL = { MusicFolderResolver.iosDocumentsDirectoryURL() },
            clientName: @escaping () -> String? = { IOSPassiveSyncCenter.defaultClientName() }
        ) {
            self.identityStore = identityStore
            self.deviceStore = deviceStore
            self.libraryRoot = libraryRoot
            self.clientName = clientName
            reloadPairedHosts()
        }

        // MARK: 生命周期

        /// App 进入前台 / 设置页出现：开始（幂等）。
        /// 已在跑但此前因「无已配对主机」闲置时，本调用会重新检查主机并立即开始。
        func start() {
            if isRunning {
                reloadPairedHosts()
                guard !state.isConnected, !state.isConnecting, !isWaitingBackoff, !pairedHosts.isEmpty else { return }
                beginAttempt()
                return
            }
            isRunning = true
            automaticAttempts = 0
            beginAttempt()
        }

        /// App 退到后台：拆接线 + 关会话 + 停浏览（幂等）。
        func stop() {
            isRunning = false
            automaticAttempts = 0
            isWaitingBackoff = false
            cancelDiscovery()
            cancelReconnect()
            browser?.stopBrowsing()
            browser = nil
            tearDownSession()
            attemptedTargets.removeAll()
            currentTarget = nil
            state = .idle
        }

        /// 手动重连（自动重连上限用尽 / 刚配对完 / 用户主动）：重置退避计数立即重来。
        func reconnectNow() {
            isRunning = true
            automaticAttempts = 0
            beginAttempt()
        }

        // MARK: 一次尝试

        private func beginAttempt() {
            cancelDiscovery()
            cancelReconnect()
            isWaitingBackoff = false
            attemptedTargets.removeAll()
            currentTarget = nil
            tearDownSession()
            reloadPairedHosts()

            guard !pairedHosts.isEmpty else {
                // 无已配对主机：不起浏览（省电），交设置页引导扫码
                state = .idle
                return
            }
            guard let identity = try? identityStore.loadOrCreateIdentity() else {
                state = .failed(.identityUnavailable)
                return
            }

            let token = UUID()
            attemptToken = token
            browser?.stopBrowsing()
            let browser = SyncBrowser(localIdentity: identity, trustStore: deviceStore)
            browser.onResultsChanged = { [weak self] hosts in
                Task { @MainActor in
                    guard let self, self.attemptToken == token else { return }
                    self.handleResults(hosts)
                }
            }
            browser.onBrowseFailure = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.attemptToken == token else { return }
                    self.handleDiscoveryTimeout()
                }
            }
            self.browser = browser
            state = .connecting(hostName: nil)
            browser.startBrowsing()
            scheduleDiscoveryTimeout(token: token)
        }

        private func handleResults(_ hosts: [SyncDiscoveredHost]) {
            guard isRunning, session == nil, !isWaitingBackoff, !state.isConnected else { return }
            let candidates = IOSPassiveReconnectLogic.targets(discovered: hosts, pairedHosts: pairedHosts)
            for candidate in candidates where !attemptedTargets.contains(Self.key(candidate)) {
                attemptedTargets.insert(Self.key(candidate))
                connect(to: candidate)
                return
            }
            // 候选都试过 / 无可试：继续等 discoveryTimeout 判失败
        }

        private func connect(to target: IOSPassiveSyncTarget) {
            guard let browser else { return }
            currentTarget = target
            state = .connecting(hostName: target.hostName)

            var config = SyncSessionConfiguration()
            config.clientDisplayName = clientName()
            let token = attemptToken
            let session = browser.connect(
                to: target.endpoint,
                expectedPeerDeviceID: target.peerID,
                candidate: nil, // 已配对重连：不带扫码候选 → 直通 ready（信任表 pinning 验证）
                config: config
            )
            // 链式挂接（SyncBrowser.connect 已设 onStateChange 做 channel 清理，
            // 绝不能覆盖）：存 prior → 先己后彼。
            let priorState = session.onStateChange
            session.onStateChange = { [weak self] phase in
                Task { @MainActor in
                    guard let self, self.attemptToken == token else { return }
                    self.handlePhase(phase)
                }
                priorState?(phase)
            }
            let priorClosed = session.onClosed
            session.onClosed = { [weak self] reason in
                Task { @MainActor in
                    guard let self, self.attemptToken == token else { return }
                    self.handleClosed(reason)
                }
                priorClosed?(reason)
            }
            self.session = session
        }

        // MARK: 会话推进

        private func handlePhase(_ phase: SyncSessionPhase) {
            guard isRunning, !isTearingDown, phase == .ready, let session, let target = currentTarget else { return }
            guard !state.isConnected else { return }
            cancelDiscovery()
            automaticAttempts = 0
            attachPassiveHost(to: session)
            state = .connected(hostName: target.hostName, peerID: target.peerID)
        }

        /// 会话 ready → 装配被动端（曲库根与既有扫描同源）。
        private func attachPassiveHost(to session: SyncPeerSession) {
            let token = attemptToken
            let host = SyncLibraryPassiveHost(libraryRoot: libraryRoot())
            host.onFileLanded = { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.attemptToken == token, let host = self.passiveHost else { return }
                    self.summary = host.summary
                }
            }
            host.onBatchCompleted = { [weak self] summary in
                Task { @MainActor in
                    guard let self, self.attemptToken == token else { return }
                    self.summary = summary
                }
            }
            passiveHost = host
            guard host.attach(to: session) else {
                // 曲库根不存在 / 接线失败：拆掉并让会话关闭走统一失败路径
                passiveHost = nil
                session.cancel(reason: .storageError("passive host attach failed"))
                return
            }
            summary = host.summary
        }

        private func handleClosed(_ reason: SyncSessionCloseReason) {
            guard !isTearingDown else { return }
            session = nil
            passiveHost = nil
            currentTarget = nil
            guard isRunning else { return }
            if let failure = SyncConnectLogic.failure(fromCloseReason: reason) {
                state = .failed(.connect(failure))
            }
            scheduleReconnect()
        }

        private func handleDiscoveryTimeout() {
            guard isRunning, !isWaitingBackoff, !state.isConnected else { return }
            guard !sessionHasPeer else { return }
            cancelDiscovery()
            state = .failed(.connect(.hostNotFound(hostName: currentTarget?.hostName ?? pairedHosts.first?.displayName)))
            scheduleReconnect()
        }

        /// 是否已建立会话（浏览超时判定用：有会话就不算「没找到主机」）
        private var sessionHasPeer: Bool {
            session != nil
        }

        // MARK: 重连退避

        private func scheduleReconnect() {
            guard isRunning else { return }
            automaticAttempts += 1
            guard let delay = IOSPassiveReconnectPolicy.delayBeforeAttempt(automaticAttempts) else {
                // 上限用尽：保持 failed，交设置页「重连」手动兜底
                browser?.stopBrowsing()
                browser = nil
                return
            }
            isWaitingBackoff = true
            cancelDiscovery()
            let token = attemptToken
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.isRunning, self.attemptToken == token else { return }
                    self.beginAttempt()
                }
            }
            reconnectWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }

        private func scheduleDiscoveryTimeout(token: UUID) {
            cancelDiscovery()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    guard let self, self.attemptToken == token else { return }
                    self.handleDiscoveryTimeout()
                }
            }
            discoveryWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + SyncAutoConnectController.discoveryTimeout,
                execute: work
            )
        }

        private func cancelDiscovery() {
            discoveryWork?.cancel()
            discoveryWork = nil
        }

        private func cancelReconnect() {
            reconnectWork?.cancel()
            reconnectWork = nil
            isWaitingBackoff = false
        }

        // MARK: 清理

        private func tearDownSession() {
            isTearingDown = true
            passiveHost?.detach()
            passiveHost = nil
            session?.cancel(reason: .userCancelled)
            session = nil
            isTearingDown = false
            attemptToken = UUID()
        }

        private func reloadPairedHosts() {
            let devices = (try? deviceStore.all()) ?? []
            pairedHosts = SyncDeviceList.hosts(in: devices)
            pairedHostCount = pairedHosts.count
        }

        private static func key(_ target: IOSPassiveSyncTarget) -> String {
            "\(target.peerID)|\(target.hostName)"
        }
    }

#endif
