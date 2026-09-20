//
//  SyncBrowser.swift
//  QQPlayer
//
//  局域网同步（S2, M2a）Client 侧传输层：浏览 Bonjour
//  （_qqplayer-sync._tcp）→ 解析结果（hostname/endpoint）→ connect(endpoint)
//  建 SyncPeerSession（client 角色）并发起握手；未配对时经扫码候选走配对流。
//
//  ⚠️ 发现层用 **DNS-SD C API**（`DNSServiceBrowse`），不用 `NWBrowser`：
//  2026-09-17 真机实测（iPhone 16 Pro / iOS 26，同一时刻同一网络同一进程）：
//  `DNSServiceBrowse` 与旧 `NetServiceBrowser` 都能立刻发现两台主机，而
//  **`NWBrowser` 一条结果都不交付**（App 原用 `NWParameters.tcp`、裸
//  `NWParameters()`、`includePeerToPeer=true` 三种参数均 0 结果；状态只到
//  `.ready`、从不进 `.waiting`，即非本地网络权限被拒）。该现象只在无 VPN
//  隧道时出现（有隧道时 NWBrowser 反而交付），而权限/解析/TCP 直连均正常
//  ——定位为 NWBrowser 自身问题，故绕开它。取证：`memory/knowledge/`
//  的 `ios-local-network-permission.md`。
//
//  Bonjour 广播内容不可信（TXT/服务名只用于展示），真实身份在握手里以
//  Device ID + Ed25519 指纹验证（TOFU pinning / QR 信任根）。网络行为需
//  真机验证（本里程碑只编译级），会话纯逻辑由内存 transport 单测覆盖。
//

import dnssd
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
    var onResultsChanged: (@Sendable ([SyncDiscoveredHost]) -> Void)?
    /// 浏览启动失败
    var onBrowseFailure: (@Sendable (NWError) -> Void)?

    private let localIdentity: SyncIdentity
    private let trustStore: any SyncTrustStore
    private let queue = DispatchQueue(label: "com.daxmate.qqplayer.sync.browser")
    private var browseRef: DNSServiceRef?
    /// 当前发现集（服务名 → 主机）；DNS-SD 回调可来自多接口，按名字去重
    private var discovered: [String: SyncDiscoveredHost] = [:]
    /// 合并窗口（增量回调攒够再通知）
    private var notifyWorkItem: DispatchWorkItem?
    /// 活动连接（session 由调用方持有；此处仅防止连接对象被释放）
    private var channels: [UUID: NWPeerChannel] = [:]
    private let lock = NSLock()

    init(localIdentity: SyncIdentity, trustStore: any SyncTrustStore) {
        self.localIdentity = localIdentity
        self.trustStore = trustStore
    }

    var isBrowsing: Bool {
        lock.lock()
        defer { lock.unlock() }
        return browseRef != nil
    }

    // MARK: 浏览

    /// 开始浏览（DNS-SD `DNSServiceBrowse`；回调经 `DNSServiceSetDispatchQueue` 落到本对象串行队列）。
    func startBrowsing() {
        stopBrowsing()
        var reference: DNSServiceRef?
        let started = DNSServiceBrowse(
            &reference,
            0,
            0,
            Self.serviceType,
            "local.",
            syncBrowserBrowseReply,
            Unmanaged.passUnretained(self).toOpaque()
        )
        guard started == kDNSServiceErr_NoError, let reference else {
            SyncConnectDiag.log("📡 DNS-SD 浏览启动失败 code=\(started)")
            onBrowseFailure?(NWError.dns(started))
            return
        }
        let queued = DNSServiceSetDispatchQueue(reference, queue)
        guard queued == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(reference)
            SyncConnectDiag.log("📡 DNS-SD setDispatchQueue 失败 code=\(queued)")
            onBrowseFailure?(NWError.dns(queued))
            return
        }
        lock.lock()
        browseRef = reference
        lock.unlock()
    }

    /// 停止浏览（活动连接不受影响）。释放排在自身队列上，避免与回调竞态。
    func stopBrowsing() {
        lock.lock()
        let reference = browseRef
        browseRef = nil
        discovered.removeAll()
        notifyWorkItem?.cancel()
        notifyWorkItem = nil
        lock.unlock()
        guard let reference else { return }
        // 指针本身不是 Sendable；转成 UInt 位模式进闭包（避免 non-Sendable 捕获告警）
        let bits = UInt(bitPattern: UnsafeMutableRawPointer(reference))
        queue.async {
            DNSServiceRefDeallocate(OpaquePointer(bitPattern: bits))
        }
    }

    /// DNS-SD 回调（已在 `queue` 上）：维护发现集 → 排序后通知调用方。
    fileprivate func handleBrowseReply(
        flags: DNSServiceFlags,
        errorCode: DNSServiceErrorType,
        serviceName: UnsafePointer<CChar>?,
        regtype: UnsafePointer<CChar>?,
        replyDomain: UnsafePointer<CChar>?
    ) {
        guard errorCode == kDNSServiceErr_NoError else {
            SyncConnectDiag.log("📡 DNS-SD 回调错误 code=\(errorCode)")
            return
        }
        guard let serviceName, let regtype, let replyDomain else { return }
        let name = String(cString: serviceName)
        let advertisedType = String(cString: regtype)
        let domain = String(cString: replyDomain)
        let isAdd = (flags & kDNSServiceFlagsAdd) != 0
        lock.lock()
        if isAdd {
            // ⚠️ DNS-SD 回调给的 regtype **带尾点**（`_qqplayer-sync._tcp.`），而
            // `NWEndpoint.service(type:)` 要的是**不带尾点**的类型（NWBrowser 原样给的
            // 就是不带点的）——照抄回调值会拼出多一个点的类型，解析必失败（2026-09-17 真机踩过）。
            discovered[name] = SyncDiscoveredHost(
                name: name,
                endpoint: .service(name: name, type: Self.serviceType, domain: domain, interface: nil)
            )
        } else {
            discovered.removeValue(forKey: name)
        }
        lock.unlock()
        scheduleResultsNotify(advertisedType: advertisedType)
    }

    /// 合并短窗口内的增量回调后再通知上层。
    ///
    /// 为什么：DNS-SD 是**逐条投递**的（cached 顺序不定）。上层若按「第一条结果」
    /// 就决策（连第一台主机），会抢跑——2026-09-17 真机踩过：先到的是一台
    /// **非同步主机**（Mac 上的 Python web 端也广播同一服务类型），连上即被
    /// 对端关闭，而每轮重试又都先撞它，真正的桌面端永远排不到。
    private func scheduleResultsNotify(advertisedType: String) {
        lock.lock()
        notifyWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.publishResults(advertisedType: advertisedType)
        }
        notifyWorkItem = work
        lock.unlock()
        queue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func publishResults(advertisedType: String) {
        lock.lock()
        let hosts = discovered.values.sorted { $0.name < $1.name }
        lock.unlock()
        let summary = hosts
            .map { "\($0.name)@\(SyncConnectDiag.describe($0.endpoint))" }
            .joined(separator: " | ")
        SyncConnectDiag.log("📡 browse settled(\(hosts.count))=[\(summary)] advertisedType=\(advertisedType)")
        onResultsChanged?(hosts)
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
        SyncConnectDiag.log(
            "🧭 connect target=\(SyncConnectDiag.describe(endpoint)) "
                + "expectedPeer=\(expectedPeerDeviceID.map { String($0.prefix(8)) } ?? "-") candidate=\(candidate != nil)"
        )
        // 共用同步 TCP 参数（noDelay；唯一入口 SyncTCPParameters，与 listener 同源）
        let connection = NWConnection(to: endpoint, using: SyncTCPParameters.make())
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

/// DNS-SD 浏览回调（**必须是顶层函数**才能转成 C 函数指针；形参列表由 C API 固定，
/// 8 个参数不可减，故在此关掉函数参数个数规则）；实例经 `context` 指回
/// （与 `startBrowsing` 的 `passUnretained` 配对）。
private func syncBrowserBrowseReply( // swiftlint:disable:this function_parameter_count
    _ sdRef: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ serviceName: UnsafePointer<CChar>?,
    _ regtype: UnsafePointer<CChar>?,
    _ replyDomain: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let browser = Unmanaged<SyncBrowser>.fromOpaque(context).takeUnretainedValue()
    browser.handleBrowseReply(
        flags: flags,
        errorCode: errorCode,
        serviceName: serviceName,
        regtype: regtype,
        replyDomain: replyDomain
    )
}
