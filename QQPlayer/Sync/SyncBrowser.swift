//
//  SyncBrowser.swift
//  QQPlayer
//
//  局域网同步（S2, M2a）Client 侧传输层：NWBrowser 浏览 Bonjour
//  （_qqplayer-sync._tcp）→ 解析结果（hostname/endpoint）→ connect(endpoint)
//  建 SyncPeerSession（client 角色）并发起握手；未配对时经扫码候选走配对流。
//
//  Bonjour 广播内容不可信（TXT/服务名只用于展示），真实身份在握手里以
//  Device ID + Ed25519 指纹验证（TOFU pinning / QR 信任根）。网络行为需
//  真机验证（本里程碑只编译级），会话纯逻辑由内存 transport 单测覆盖。
//

import Foundation
import Network

/// 发现到的主机（UI 列表项）。
struct SyncDiscoveredHost: Equatable, Sendable {
    /// Bonjour 服务名（Host 注册的设备名；仅展示，不作身份凭据）
    var name: String
    /// 连接用 endpoint
    var endpoint: NWEndpoint
}

/// Client 侧浏览器 + 连接工厂。
final class SyncBrowser: @unchecked Sendable {
    /// Bonjour 服务类型（与 SyncListener 一致）
    static let serviceType = "_qqplayer-sync._tcp"

    /// 浏览结果变化回调（任意线程；UI 层自行跳主线程）
    var onResultsChanged: (([SyncDiscoveredHost]) -> Void)?
    /// 浏览启动失败
    var onBrowseFailure: ((NWError) -> Void)?

    private let localIdentity: SyncIdentity
    private let trustStore: any SyncTrustStore
    private let queue = DispatchQueue(label: "com.daxmate.qqplayer.sync.browser")
    private var browser: NWBrowser?
    /// 活动连接（session 由调用方持有；此处仅防止连接对象被释放）
    private var channels: [UUID: NWPeerChannel] = [:]
    private let lock = NSLock()

    init(localIdentity: SyncIdentity, trustStore: any SyncTrustStore) {
        self.localIdentity = localIdentity
        self.trustStore = trustStore
    }

    var isBrowsing: Bool { browser != nil }

    // MARK: 浏览

    /// 开始浏览。
    func startBrowsing() {
        stopBrowsing()
        let parameters = NWParameters.tcp
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case let .failed(error) = state {
                self.onBrowseFailure?(error)
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let hosts = results.compactMap { result -> SyncDiscoveredHost? in
                guard case let .service(name, _, _, _) = result.endpoint else { return nil }
                return SyncDiscoveredHost(name: name, endpoint: result.endpoint)
            }
            .sorted { $0.name < $1.name }
            self.onResultsChanged?(hosts)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    /// 停止浏览（活动连接不受影响）。
    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    // MARK: 连接

    /// 连接某 endpoint 并建 client 会话（立即开始握手）。
    ///
    /// - Parameters:
    ///   - endpoint: 发现结果里的 endpoint
    ///   - expectedPeerDeviceID: 期望的 host Device ID（已配对/手输）；nil = 未知
    ///   - candidate: 扫码配对候选（未配对场景；含 host 公钥 + 一次性 nonce）
    ///   - config: 会话配置（超时等）
    /// - Returns: 会话（调用方挂 onStateChange/onClosed 后即收事件）
    @discardableResult
    func connect(
        to endpoint: NWEndpoint,
        expectedPeerDeviceID: String? = nil,
        candidate: SyncPairingCandidate? = nil,
        config: SyncSessionConfiguration = SyncSessionConfiguration()
    ) -> SyncPeerSession {
        let id = UUID()
        let connection = NWConnection(to: endpoint, using: .tcp)
        let channel = NWPeerChannel(connection: connection, queue: queue)
        let session = SyncPeerSession(
            role: .client,
            localIdentity: localIdentity,
            trustStore: trustStore,
            config: config,
            transport: channel
        )
        channel.session = session
        session.setPairingExpectations(
            expectedPeerDeviceID: expectedPeerDeviceID,
            candidate: candidate
        )
        session.onStateChange = { [weak self] phase in
            if phase == .closed {
                self?.detachChannel(id: id)
            }
        }
        lock.lock()
        channels[id] = channel
        lock.unlock()
        channel.start()
        return session
    }

    /// 关闭全部活动连接（断开会话由调用方各自 cancel）。
    func disconnectAll() {
        lock.lock()
        let channelsToClose = Array(channels.values)
        channels.removeAll()
        lock.unlock()
        channelsToClose.forEach { $0.session?.cancel(reason: .userCancelled) }
    }

    private func detachChannel(id: UUID) {
        lock.lock()
        channels.removeValue(forKey: id)
        lock.unlock()
    }
}
