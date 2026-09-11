//
//  SyncAutoConnect.swift
//  QQPlayer
//
//  局域网同步（S2 接线）iOS 扫码确认后的自动回连：本地落库完成后启动
//  SyncBrowser 浏览 → 按 QR hostName 挑主机（case-insensitive 优先，无匹配
//  取第一个——expectedPeerDeviceID pinning 保证连错也安全）→ connect
//  （candidate 来自 QR 载荷）→ 会话推进驱动 UI 状态 → ready = 配对完成。
//
//  分层：SyncConnectLogic（纯逻辑，无 IO/UI，可单测）——主机挑选 /
//  关闭原因 → 失败模型 / 失败 → SyncPairOutcome 映射；
//  SyncAutoConnectController（@MainActor ObservableObject）——浏览器/会话
//  生命周期 + 超时调度，网络回调任意线程 → 主线程上抛。
//
//  会话回调挂接遵循链式惯例（存 prior → 自己的先跑 → 转发 prior）：
//  SyncBrowser.connect 已设 onStateChange（channel 清理），绝不能覆盖。
//

import Foundation
import Network

// MARK: - 纯逻辑（可单测）

/// 自动回连的失败原因（UI outcome 映射源；语义对齐 SyncSessionCloseReason）。
enum SyncConnectFailure: Equatable {
    /// 浏览期内未发现任何主机（含目标名不匹配空结果）
    case hostNotFound(hostName: String?)
    /// Mac 拒绝配对（PairResponse approved=false，附原因）
    case rejected(reason: String?)
    /// 等待批准超时（Mac 长时间未响应）
    case timedOut
    /// 连接/握手/身份不符等传输层失败（附细节）
    case connectionFailed(detail: String?)
}

/// 自动回连推进状态（UI 呈现用；终端态 paired/failed 由控制器产出）。
enum SyncConnectState: Equatable {
    /// 浏览中（找 QR 对应主机）
    case discovering(hostName: String)
    /// 已选主机，连接/握手中
    case connecting(hostName: String)
    /// 已发 PairRequest，等 Mac 批准
    case awaitingApproval(hostName: String)
    /// ready → 配对完成
    case paired(hostName: String)
    /// 失败（含原因；UI 提供重试/完成）
    case failed(SyncConnectFailure)

    var isTerminal: Bool {
        if case .paired = self { return true }
        if case .failed = self { return true }
        return false
    }
}

/// 自动回连决策纯逻辑（主机挑选 / 名称匹配 / 会话结果映射）。
enum SyncConnectLogic {
    /// Bonjour 服务名匹配（case-insensitive）——**唯一口径**：扫码回连的主机挑选
    /// 与 M6 被动端回连的候选排序共用本函数，避免两处各写一份比较规则。
    static func matches(hostName: String, expected: String) -> Bool {
        hostName.compare(expected, options: .caseInsensitive) == .orderedSame
    }

    /// 从浏览结果挑 QR 对应主机：服务名与 QR hostName case-insensitive 匹配
    /// 优先；无匹配返回第一个结果（expectedPeerDeviceID pinning 兜底安全）；
    /// 结果为空返回 nil。
    static func pickHost(
        from hosts: [SyncDiscoveredHost],
        qrHostName: String
    ) -> SyncDiscoveredHost? {
        guard !hosts.isEmpty else { return nil }
        if let matched = hosts.first(where: { matches(hostName: $0.name, expected: qrHostName) }) {
            return matched
        }
        return hosts.first
    }

    /// 会话关闭原因 → 失败模型。返回 nil = 本端主动取消（不呈现失败）。
    /// detail 只携带原始载荷（握手错误描述/deviceID/传输层信息），本地化
    /// 文案由 SyncPairOutcome(connectFailure:) 映射层负责——本层保持纯逻辑。
    static func failure(fromCloseReason reason: SyncSessionCloseReason) -> SyncConnectFailure? {
        switch reason {
        case .userCancelled:
            return nil
        case .pairingRejected(let rejectReason):
            return .rejected(reason: rejectReason)
        case .handshakeTimeout:
            return .timedOut
        case .remoteClosed, .receivedBye:
            return .connectionFailed(detail: nil)
        case .handshakeFailed(let error):
            return .connectionFailed(detail: String(describing: error))
        case .peerUntrusted(let deviceID):
            return .connectionFailed(detail: deviceID)
        case .protocolViolation(let detail), .storageError(let detail):
            return .connectionFailed(detail: detail)
        case .transportError:
            return .connectionFailed(detail: nil)
        }
    }
}

// MARK: - 失败 → UI outcome（SyncPairOutcome 是纯展示值，映射可单测）

extension SyncPairOutcome {
    /// 失败模型 → 结果页展示（sync_ 文案 key 见 Localizable.strings）。
    init(connectFailure: SyncConnectFailure, hostName: String?) {
        switch connectFailure {
        case let .hostNotFound(name):
            self = .hostNotFound(hostName: name ?? hostName)
        case let .rejected(reason):
            self = .connectRejected(reason: reason)
        case .timedOut:
            self = .connectTimedOut
        case let .connectionFailed(detail):
            self = .connectFailed(detail: detail)
        }
    }
}

// MARK: - 自动回连控制器

/// iOS 扫码确认后自动回连编排（@MainActor；网络回调跳主线程）。
@MainActor
final class SyncAutoConnectController: ObservableObject {
    /// 当前推进状态（UI 直接呈现；终端态由 retry/cancel 重置）
    @Published private(set) var state: SyncConnectState = .discovering(hostName: "")

    /// 浏览无结果超时（秒）
    static let discoveryTimeout: TimeInterval = 10
    /// 等待 Mac 批准超时（秒）
    static let approvalTimeout: TimeInterval = 90

    private let identityStore = SyncIdentityStore()
    private let trustStore = DeviceStore()

    private var browser: SyncBrowser?
    private var activeSession: SyncPeerSession?
    private var pendingCandidate: SyncPairingCandidate?
    private var pendingHostName = ""
    private var pendingClientName: String?
    private var expectedPeerDeviceID: String?
    private var discoveryWork: DispatchWorkItem?
    private var approvalWork: DispatchWorkItem?

    /// 会话关闭原因缓存（onStateChange(.closed) 先于 onClosed；用 onClosed 判定）
    private var terminalHandled = false

    // MARK: 生命周期

    /// 开始自动回连（本地 upsert 成功后由确认页调用）。
    /// - Parameters:
    ///   - candidate: 扫码候选（deviceID/publicKeyRaw/sessionNonce/hostName 来自 QR）
    ///   - expectedPeerDeviceID: 期望的 host Device ID（= QR payload.deviceID，pinning）
    ///   - hostName: QR hostName（浏览匹配 + 展示）
    ///   - clientName: 本机名（iOS 侧 UIDevice.current.name，调用方传入）
    func start(
        candidate: SyncPairingCandidate,
        expectedPeerDeviceID: String?,
        hostName: String,
        clientName: String?
    ) {
        cancelTimers()
        activeSession?.cancel(reason: .userCancelled)
        activeSession = nil
        terminalHandled = false

        pendingCandidate = candidate
        pendingHostName = hostName
        pendingClientName = clientName
        self.expectedPeerDeviceID = expectedPeerDeviceID

        state = .discovering(hostName: hostName)
        guard let identity = try? identityStore.loadOrCreateIdentity() else {
            state = .failed(.connectionFailed(detail: "sync_connect_identity_detail".localized))
            return
        }
        let browser = SyncBrowser(localIdentity: identity, trustStore: trustStore)
        browser.onResultsChanged = { [weak self] hosts in
            Task { @MainActor in
                self?.handleResults(hosts)
            }
        }
        browser.onBrowseFailure = { [weak self] error in
            Task { @MainActor in
                guard let self, !self.terminalHandled else { return }
                self.fail(.connectionFailed(detail: "\(error)"))
            }
        }
        self.browser = browser
        browser.startBrowsing()

        scheduleDiscoveryTimeout(hostName: hostName)
    }

    /// 失败/取消后重试：重新浏览连接（同一 QR 候选；nonce 已被 Mac 消费时
    /// 会再次被拒——届时请 Mac 刷新二维码后重新扫码）。
    func retry() {
        guard let candidate = pendingCandidate else { return }
        start(
            candidate: candidate,
            expectedPeerDeviceID: expectedPeerDeviceID,
            hostName: pendingHostName,
            clientName: pendingClientName
        )
    }

    /// 页面消失/用户放弃：清理浏览器与会话。
    func stop() {
        cancelTimers()
        browser?.stopBrowsing()
        browser = nil
        activeSession?.cancel(reason: .userCancelled)
        activeSession = nil
        terminalHandled = true
    }

    // MARK: 浏览

    private func handleResults(_ hosts: [SyncDiscoveredHost]) {
        guard case .discovering = state, !terminalHandled else { return }
        guard let host = SyncConnectLogic.pickHost(from: hosts, qrHostName: pendingHostName) else {
            // 无结果：继续浏览，等 discoveryTimeout 判超时
            return
        }
        discoveryWork?.cancel()
        discoveryWork = nil
        browser?.stopBrowsing()
        connect(to: host)
    }

    private func connect(to host: SyncDiscoveredHost) {
        guard let candidate = pendingCandidate else { return }
        state = .connecting(hostName: host.name)
        var config = SyncSessionConfiguration()
        config.clientDisplayName = pendingClientName
        let session = browser?.connect(
            to: host.endpoint,
            expectedPeerDeviceID: expectedPeerDeviceID,
            candidate: candidate,
            config: config
        )
        guard let session else {
            fail(.connectionFailed(detail: "sync_connect_transport_detail".localized))
            return
        }
        activeSession = session
        // 链式挂接：SyncBrowser.connect 已设 onStateChange（closed 时清理
        // channel），存 prior 先跑自己的再转发，绝不覆盖。
        let priorState = session.onStateChange
        session.onStateChange = { [weak self] phase in
            Task { @MainActor in self?.handlePhase(phase) }
            priorState?(phase)
        }
        let priorClosed = session.onClosed
        session.onClosed = { [weak self] reason in
            Task { @MainActor in self?.handleClosed(reason) }
            priorClosed?(reason)
        }
    }

    // MARK: 会话推进

    private func handlePhase(_ phase: SyncSessionPhase) {
        switch phase {
        case .waitingForPairResponse:
            approvalWork?.cancel()
            state = .awaitingApproval(hostName: pendingHostName)
            scheduleApprovalTimeout(hostName: pendingHostName)
        case .ready:
            guard case .paired = state else {
                // ready 已由 handlePhase 或 handleClosed 处理过则忽略
                break
            }
        case .closed:
            break // 关闭归 handleClosed
        default:
            break
        }
        if phase == .ready, !terminalHandled {
            approvalWork?.cancel()
            terminalHandled = true
            state = .paired(hostName: pendingHostName)
        }
    }

    private func handleClosed(_ reason: SyncSessionCloseReason) {
        guard !terminalHandled else { return }
        guard let failure = SyncConnectLogic.failure(fromCloseReason: reason) else {
            // userCancelled：本端主动清理（stop/切换），静默
            return
        }
        approvalWork?.cancel()
        terminalHandled = true
        state = .failed(failure)
    }

    private func fail(_ failure: SyncConnectFailure) {
        guard !terminalHandled else { return }
        cancelTimers()
        terminalHandled = true
        state = .failed(failure)
    }

    // MARK: 超时

    private func scheduleDiscoveryTimeout(hostName: String) {
        discoveryWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.terminalHandled else { return }
                if case .discovering = self.state {
                    self.fail(.hostNotFound(hostName: hostName))
                }
            }
        }
        discoveryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.discoveryTimeout, execute: work)
    }

    private func scheduleApprovalTimeout(hostName: String) {
        approvalWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self, !self.terminalHandled else { return }
                if case .awaitingApproval = self.state {
                    self.activeSession?.cancel(reason: .handshakeTimeout)
                    self.fail(.timedOut)
                }
            }
        }
        approvalWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.approvalTimeout, execute: work)
    }

    private func cancelTimers() {
        discoveryWork?.cancel()
        discoveryWork = nil
        approvalWork?.cancel()
        approvalWork = nil
    }
}
