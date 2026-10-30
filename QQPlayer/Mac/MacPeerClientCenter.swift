//
//  MacPeerClientCenter.swift
//  QQPlayer
//
//  局域网同步 · 批 1（2026-10-30）**Mac 侧客户端角色（对等）**。
//
//  背景：此前 Mac 只有 host 半边（SyncHostCenter 装 SyncListener），客户端角色
//  （浏览器 + 主动连接 + 配对）只有 iOS 在用（SyncAutoConnect / IOSPassiveSyncCenter）。
//  本类型把同一套 SyncBrowser / SyncPeerSession 装配到 Mac，实现「同一台 Mac 可同时是
//  host 和 client」：listener 始终在跑（SyncHostCenter），浏览是**独立开关**。
//
//  职责边界（批 1）：发现列表 + 连接/断开 + 6 位码配对 + 会话状态。
//  **不含曲库数据流**（批 2）；ready 之后本批只维持会话与状态展示。
//
//  ⚠️ 发现层固定用 SyncBrowser（DNS-SD C API）——见 SyncBrowser 文件头的 2026-09-17
//  实测结论：NWBrowser 在该场景一条结果都不交付，不要「优化」回去。
//

import Foundation
import Network
import Observation

/// Mac 侧客户端角色中心（发现 / 连接 / 配对 / 会话状态）。
@MainActor
@Observable
final class MacPeerClientCenter {
    /// 组合根唯一实例（App 根 + 预览环境同源）。
    static let shared = MacPeerClientCenter()

    /// 「自动发现」开关的持久化键（独立于 host 监听开关）。
    static let browsingDefaultsKey = "sync.peerBrowsingEnabled.v1"

    /// 会话阶段（UI 只读值）。
    enum Phase: Equatable, Sendable {
        /// 未开启浏览
        case idle
        /// 正在发现
        case browsing
        /// 正在连接某台（展示名）
        case connecting(String)
        /// 已发出配对（等对方批准 / 码校验）；展示名
        case pairing(String)
        /// 会话就绪（展示名）
        case connected(String)
        /// 失败（localized key 或原始原因文本）
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .connecting, .pairing:
                return true
            case .idle, .browsing, .connected, .failed:
                return false
            }
        }
    }

    /// 发现列表一行（与纯逻辑 `SyncPeerDiscoveryEntry` 同形；这里加 Identifiable 供 ForEach）。
    struct DiscoveredPeer: Identifiable, Equatable, Sendable {
        /// Bonjour 服务名（同网同名极少，够用；连接用 name 查回 endpoint）
        var id: String { name }
        let name: String
        /// 信任库里已有同名已配对设备（启发式：client 侧落库的 displayName = host 展示名）
        let isPaired: Bool

        init(name: String, isPaired: Bool) {
            self.name = name
            self.isPaired = isPaired
        }

        init(_ entry: SyncPeerDiscoveryEntry) {
            name = entry.name
            isPaired = entry.isPaired
        }
    }

    // MARK: 对外状态

    private(set) var peers: [DiscoveredPeer] = []
    private(set) var phase: Phase = .idle
    private(set) var browsingEnabled: Bool
    /// 最近一次失败文案 key（nil = 无失败）；UI 用来弹一行红字
    private(set) var lastErrorKey: String?

    // MARK: 内部装配

    @ObservationIgnored private var browser: SyncBrowser?
    @ObservationIgnored private var session: SyncPeerSession?
    @ObservationIgnored private var discovered: [String: SyncDiscoveredHost] = [:]
    @ObservationIgnored private var pairedNames: Set<String> = []
    @ObservationIgnored private var activeTarget: String?
    @ObservationIgnored private var browserStarted = false

    private let defaults: UserDefaults
    private let trustStore: DeviceStore
    @ObservationIgnored var identityProvider: () throws -> SyncIdentity = {
        try SyncIdentityStore().loadOrCreateIdentity()
    }
    @ObservationIgnored var localDeviceNameProvider: () -> String = {
        LocalDeviceNameStore.shared.name
    }

    init(defaults: UserDefaults = .standard, trustStore: DeviceStore = DeviceStore()) {
        self.defaults = defaults
        self.trustStore = trustStore
        self.browsingEnabled = defaults.object(forKey: Self.browsingDefaultsKey) as? Bool ?? true
    }

    // MARK: 生命周期

    /// App 启动时调用：按持久化开关决定是否开始浏览（不主动连接）。
    func start() {
        refreshPairedNames()
        guard browsingEnabled else {
            phase = .idle
            return
        }
        beginBrowsing()
    }

    /// 用户切换「自动发现」。关闭 = 停止浏览 + 断开当前连接（与 iOS 行为一致）。
    func setBrowsing(_ enabled: Bool) {
        guard browsingEnabled != enabled else { return }
        browsingEnabled = enabled
        defaults.set(enabled, forKey: Self.browsingDefaultsKey)
        if enabled {
            beginBrowsing()
        } else {
            disconnect()
            stopBrowsing()
            phase = .idle
        }
    }

    /// 停止一切（App 退出 / 用户关闭面板）。
    func stop() {
        disconnect()
        stopBrowsing()
        phase = .idle
    }

    /// 清掉失败提示（用户看过之后）。
    func clearError() {
        lastErrorKey = nil
    }

    // MARK: 浏览（发现）

    private func beginBrowsing() {
        guard !browserStarted else { return }
        let identity: SyncIdentity
        do {
            identity = try identityProvider()
        } catch {
            AppLog.warn(.sync, "⚠️ MacPeerClientCenter: 身份加载失败 \(error)")
            lastErrorKey = "sync_peer_identity_error"
            phase = .failed("sync_peer_identity_error")
            return
        }
        let browser = SyncBrowser(localIdentity: identity, trustStore: trustStore)
        browser.onResultsChanged = { [weak self] hosts in
            Task { @MainActor in self?.apply(hosts: hosts) }
        }
        browser.onBrowseFailure = { error in
            Task { @MainActor in
                AppLog.warn(.sync, "⚠️ MacPeerClientCenter: 浏览失败 \(String(describing: error))")
            }
        }
        self.browser = browser
        browserStarted = true
        browser.startBrowsing()
        if case .connected = phase {
            // 已连接：保持连接态（发现结果只刷新列表）
        } else if !phase.isBusy {
            phase = .browsing
        }
        AppLog.info(.sync, "ℹ️ MacPeerClientCenter: 已开始发现（_qqplayer-sync）")
    }

    private func stopBrowsing() {
        browser?.stopBrowsing()
        browser?.disconnectAll()
        browser = nil
        browserStarted = false
        discovered.removeAll()
        peers = []
    }

    /// 发现结果上屏：排除本机自己的广播；标注已配对设备。
    private func apply(hosts: [SyncDiscoveredHost]) {
        discovered = Dictionary(hosts.map { ($0.name, $0) }, uniquingKeysWith: { _, latest in latest })
        peers = SyncPeerDiscoveryList.entries(
            names: hosts.map(\.name),
            excludingSelf: localDeviceNameProvider(),
            pairedNames: pairedNames
        ).map(DiscoveredPeer.init)
        if case .idle = phase, browsingEnabled {
            phase = .browsing
        }
    }

    /// 从信任库刷「已配对」标记（client 侧落库 displayName = 对端展示名 = Bonjour 名）。
    func refreshPairedNames() {
        let devices = (try? trustStore.all()) ?? []
        pairedNames = Set(devices.map(\.displayName))
        peers = peers.map { DiscoveredPeer(name: $0.name, isPaired: pairedNames.contains($0.name)) }
    }

    // MARK: 连接 / 配对

    /// 连接一台已发现的设备（已配对 ⇒ 直接进会话；未配对 ⇒ 会被对端以未信任拒绝）。
    func connect(to peerName: String) {
        guard let session = prepareSession(to: peerName) else { return }
        session.setPairingExpectations(expectedPeerDeviceID: nil, candidate: nil)
        startSession(session, name: peerName, pairing: false)
    }

    /// 用 6 位配对码连接一台已发现的设备（A 方案）。
    func pair(with peerName: String, code: String) {
        guard let normalized = SyncPairingCodeStore.normalizedInput(code) else {
            lastErrorKey = "sync_pair_code_failed_format"
            return
        }
        guard let session = prepareSession(to: peerName) else { return }
        session.setPairingExpectations(expectedPeerDeviceID: nil, candidate: nil)
        session.setPairingCode(normalized)
        startSession(session, name: peerName, pairing: true)
    }

    /// 断开当前会话（保留浏览）。
    func disconnect() {
        session?.cancel(reason: .userCancelled)
        session = nil
        activeTarget = nil
        if browsingEnabled, browserStarted {
            phase = .browsing
        } else if !browserStarted {
            phase = .idle
        }
    }

    /// 连接前置：确保浏览器已起、目标仍在发现列表里，返回待注入期望的会话。
    private func prepareSession(to peerName: String) -> SyncPeerSession? {
        guard let host = discovered[peerName] else {
            lastErrorKey = "sync_peer_missing_host"
            return nil
        }
        if browser == nil {
            beginBrowsing()
        }
        guard let browser else {
            lastErrorKey = "sync_peer_identity_error"
            return nil
        }
        var config = SyncSessionConfiguration()
        config.clientDisplayName = localDeviceNameProvider()
        return browser.connect(to: host.endpoint, expectedPeerDeviceID: nil, candidate: nil, config: config)
    }

    private func startSession(_ session: SyncPeerSession, name: String, pairing: Bool) {
        self.session = session
        activeTarget = name
        lastErrorKey = nil
        phase = pairing ? .pairing(name) : .connecting(name)
        session.onStateChange = { [weak self] newPhase in
            Task { @MainActor in self?.handle(newPhase, name: name) }
        }
        session.onClosed = { [weak self] reason in
            Task { @MainActor in self?.handleClosed(reason) }
        }
    }

    private func handle(_ newPhase: SyncSessionPhase, name: String) {
        switch newPhase {
        case .ready:
            phase = .connected(name)
            activeTarget = name
            refreshPairedNames()
        case .waitingForPairApproval, .waitingForPairResponse:
            if !phase.isBusy { phase = .pairing(name) }
        case .waitingForPairRequest, .waitingForPeerHello:
            if !phase.isBusy { phase = .connecting(name) }
        case .idle, .closed:
            break
        }
    }

    private func handleClosed(_ reason: SyncSessionCloseReason) {
        session = nil
        guard let key = Self.errorKey(for: reason) else {
            if browsingEnabled, browserStarted { phase = .browsing } else { phase = .idle }
            return
        }
        lastErrorKey = key
        phase = .failed(key)
    }

    /// 关闭原因 → UI 文案 key（nil = 正常关闭，不提示）。
    /// 码路径的 pairingRejected 带的是「文案 key」，原样透出；其它中文原因回落通用 key。
    static func errorKey(for reason: SyncSessionCloseReason) -> String? {
        switch reason {
        case .userCancelled, .remoteClosed, .receivedBye:
            return nil
        case let .pairingRejected(detail):
            if let detail, detail.hasPrefix("sync_") { return detail }
            return "sync_peer_pairing_rejected"
        case .peerUntrusted:
            return "sync_peer_untrusted"
        case .handshakeTimeout:
            return "sync_peer_handshake_timeout"
        case .handshakeFailed:
            return "sync_peer_handshake_failed"
        case .storageError:
            return "sync_peer_storage_failed"
        case .protocolViolation:
            return "sync_peer_protocol_violation"
        case .transportError:
            return "sync_peer_transport_error"
        }
    }
}
