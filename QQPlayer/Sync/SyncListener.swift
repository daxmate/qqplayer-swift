//
//  SyncListener.swift
//  QQPlayer
//
//  局域网同步（S2, M2a）Host 侧传输层：NWListener + Bonjour 广播
//  （_qqplayer-sync._tcp，TXT protoVer=1 + name）+ 接受连接 →
//  SyncPeerSession（host 角色）。
//
//  网络行为（发现/握手/配对）需真机验证（本里程碑只编译级；CI/真机覆盖），
//  本地单测注入内存 SyncPeerTransport 覆盖会话纯逻辑。NW 回调一律走本文件
//  内部串行队列；暴露给 UI 的回调（onReady/onFailure/onSessionStateChange/
//  onSessionClosed/pairApprovalHandler）在队列线程触发，UI 层自行跳主线程。
//

import Foundation
import Network

// MARK: - NWConnection 帧通道（Listener/Browser 共用）

/// NWConnection ↔ SyncPeerSession 的字节通道适配器：收字节喂会话（会话内部
/// 拼帧/解密），会话外发字节经 connection.send。网络线程回调内部串行处理。
final class NWPeerChannel: SyncPeerTransport, @unchecked Sendable {
    /// 会话（strong：channel 是会话的唯一持有者；会话对 channel 弱引用，无环）
    var session: SyncPeerSession?
    /// 连接状态变化（UI 设备列表用；线程 = 本通道串行队列）
    var onStateUpdate: ((NWConnection.State) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    /// 收帧循环进行中（防重入）
    private var receiving = false
    private var closed = false
    /// 是否已 notify 关闭（幂等）
    private var notifiedClosed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// 启动连接 + 状态监听。connection .ready 后通知会话开始握手。
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                self.onStateUpdate?(state)
                switch state {
                case .ready:
                    self.session?.handleTransportReady()
                    self.startReceiveLoopIfNeeded()
                case .failed, .cancelled:
                    self.notifyChannelClosed()
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
    }

    /// 启动收帧循环（幂等）。
    private func startReceiveLoopIfNeeded() {
        guard !receiving, !closed else { return }
        receiving = true
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                if error != nil {
                    self.notifyChannelClosed()
                    return
                }
                if let data, !data.isEmpty {
                    self.session?.handleInboundData(data)
                }
                if isComplete {
                    self.notifyChannelClosed()
                    return
                }
                self.receiveNext()
            }
        }
    }

    /// 会话关闭/连接失败 → 幂等收尾（cancel 连接 + 通知外部）。
    private func notifyChannelClosed() {
        guard !closed else { return }
        closed = true
        session?.handleTransportClosed()
        connection.cancel()
        if !notifiedClosed {
            notifiedClosed = true
            onStateUpdate?(.cancelled)
        }
    }

    // MARK: SyncPeerTransport

    func sendFrameBytes(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, error != nil else { return }
                self.queue.async {
                    self.notifyChannelClosed()
                }
            })
        }
    }

    func closeTransport() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            self.notifyChannelClosed()
        }
    }
}

// MARK: - Host 监听器

/// Host 侧监听：Bonjour 广播 + 接受连接 → host 角色 SyncPeerSession。
final class SyncListener: @unchecked Sendable {
    /// Bonjour 服务类型（与 SyncBrowser 浏览类型一致；文档 §3）
    static let serviceType = "_qqplayer-sync._tcp"
    /// TXT 协议版本键
    static let txtProtoVersion = "1"

    /// 监听就绪（port 已定，可查）
    var onReady: ((UInt16) -> Void)?
    /// 监听失败/停止
    var onStopped: ((NWError?) -> Void)?
    /// 会话状态变化（新连接建会话起，含 ready/closed）
    var onSessionStateChange: ((SyncPeerSession, SyncSessionPhase) -> Void)?
    /// 会话关闭
    var onSessionClosed: ((SyncPeerSession, SyncSessionCloseReason) -> Void)?
    /// 待批准配对回调（转发给每个 host 会话；UI 设置后对后续会话生效）
    var pairApprovalHandler: ((SyncPeerSession, PendingPairRequest) -> Void)?
    /// 会话握手配置（超时等）
    var sessionConfig = SyncSessionConfiguration()

    private let localIdentity: SyncIdentity
    private let trustStore: any SyncTrustStore
    private let deviceName: String
    private let queue = DispatchQueue(label: "com.daxmate.qqplayer.sync.listener")
    private let lock = NSLock()
    private var listener: NWListener?
    private var channels: [UUID: NWPeerChannel] = [:]
    private let nonceRegistry = SyncPairingNonceRegistry()

    init(localIdentity: SyncIdentity, trustStore: any SyncTrustStore, deviceName: String) {
        self.localIdentity = localIdentity
        self.trustStore = trustStore
        self.deviceName = deviceName
    }

    /// 是否在监听。
    var isRunning: Bool { listener != nil }

    /// 配对 nonce 注册表（UI 展示 QR 时注册；验签成功自动消耗）。
    var pairingNonces: SyncPairingNonceRegistry { nonceRegistry }

    // MARK: 生命周期

    /// 开始监听（Bonjour 广播）。port 0 = 系统分配。
    func start(port: UInt16 = 0) throws {
        stop()
        let parameters = NWParameters.tcp
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        let txt = NWTXTRecord(["protoVer": Self.txtProtoVersion, "name": deviceName])
        listener.service = NWListener.Service(name: deviceName, type: Self.serviceType, txtRecord: txt)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let actualPort = listener.port?.rawValue {
                    self.onReady?(actualPort)
                }
            case let .failed(error):
                self.onStopped?(error)
            case .cancelled:
                self.onStopped?(nil)
            default:
                break
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// 停止监听并关闭全部会话。
    func stop() {
        lock.lock()
        let channelsToClose = Array(channels.values)
        channels.removeAll()
        lock.unlock()
        channelsToClose.forEach { $0.session?.cancel(reason: .userCancelled) }
        listener?.cancel()
        listener = nil
    }

    // MARK: 接受连接

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let channel = NWPeerChannel(connection: connection, queue: queue)
        let session = SyncPeerSession(
            role: .host,
            localIdentity: localIdentity,
            trustStore: trustStore,
            config: sessionConfig,
            pairingNonces: nonceRegistry,
            transport: channel
        )
        channel.session = session
        // 闭包弱捕获 session：闭包存在 session 上，强捕获会成环（session→closure→session）
        session.onStateChange = { [weak self, weak session] phase in
            guard let self, let session else { return }
            if phase == .closed {
                self.detachChannel(id: id)
            }
            self.onSessionStateChange?(session, phase)
        }
        session.onClosed = { [weak self, weak session] reason in
            guard let self, let session else { return }
            self.onSessionClosed?(session, reason)
        }
        session.pairApprovalHandler = pairApprovalHandler
        lock.lock()
        channels[id] = channel
        lock.unlock()
        channel.start()
    }

    private func detachChannel(id: UUID) {
        lock.lock()
        channels.removeValue(forKey: id)
        lock.unlock()
    }
}
