//
//  SyncPeerSession+Frames.swift
//  QQPlayer
//
//  局域网同步（S2, M2a）会话收帧分发与各阶段处理器（SyncPeerSession extension）。
//
//  与核心文件的分工：本文件只做"锁内的纯状态迁移 + 产出效果队列"（Effect），
//  效果（发帧/状态通知/关闭/回调）由核心的 flush 在锁外执行——因此处理器内
//  可以直接读写会话内部状态而无需再取锁。调用链：
//    handleInboundData（核心，持锁）→ processFrameLocked（本文件）→ 按阶段处理器
//
//  阶段语义（完整协议见 SyncCrypto.swift 文件头）：
//  - client 先发 hello（peerDeviceID = 期望主机/扫码候选/空），host 应答
//  - 已配对：双方 TOFU pinning 验证签名（host 允许 client 空绑定；host hello
//    必须绑定 client ID——反反射）
//  - 未配对（host 信任表无此 client）：host 回 hello 后等 pair_request；
//    client 凭扫码候选（QR 公钥）验 host hello → 发 PairRequest（QR nonce 签名）
//    → host 验 nonce → 待批准回调 → 批准后双向落信任表 → 派生密钥进 ready
//  - ready：业务帧（type ≥ ping）必须加密；ping 忽略（v1 无心跳）、
//    bye 优雅关闭、file_* 解密后转 onApplicationFrame（M2b 接入点）
//

import CryptoKit
import Foundation

// MARK: - 效果队列

/// 锁内状态迁移的产出物；由核心 flush 在锁外逐一执行。
enum Effect {
    /// 外发一帧完整线上字节
    case send(Data)
    /// 阶段变化通知（onStateChange）
    case notifyState(SyncSessionPhase)
    /// 关闭（onClosed + transport 关闭）
    case close(SyncSessionCloseReason)
    /// 待批准配对通知（pairApprovalHandler）
    case notifyApproval(PendingPairRequest)
    /// ready 后业务帧（payload 已解密；onApplicationFrame）
    case notifyAppFrame(SyncFrame)
}

extension SyncPeerSession {
    // MARK: 收帧分发（按阶段路由）

    func processFrameLocked(_ frame: SyncFrame) -> [Effect] {
        switch phaseValue {
        case .idle, .closed:
            return closeEffectsLocked(.protocolViolation("阶段外收到帧"))

        case .waitingForPeerHello:
            guard !frame.isEncrypted, frame.type == .handshake else {
                return closeEffectsLocked(.protocolViolation("握手阶段收到非明文 handshake 帧"))
            }
            do {
                let hello: SyncHello = try decodeJSON(SyncHello.self, from: frame.payload)
                switch role {
                case .host:
                    return processClientHelloLocked(hello)
                case .client:
                    return processServerHelloLocked(hello)
                }
            } catch {
                return closeEffectsLocked(.handshakeFailed(mapError(error)))
            }

        case .waitingForPairRequest:
            return processPairRequestLocked(frame)

        case .waitingForPairResponse:
            return processPairResponseLocked(frame)

        case .waitingForPairApproval:
            // 等用户决定期间忽略业务帧；bye/断开由传输层事件处理
            return []

        case .ready:
            return processReadyFrameLocked(frame)
        }
    }

    // MARK: Host 侧握手/配对

    private func processClientHelloLocked(_ hello: SyncHello) -> [Effect] {
        guard hello.role == SyncHello.roleClient else {
            return closeEffectsLocked(.handshakeFailed(.identityMismatch("首帧角色应为 client")))
        }
        guard SyncHandshake.isValidDeviceID(hello.deviceID) else {
            return closeEffectsLocked(.handshakeFailed(.invalidMessage("client Device ID 非法")))
        }
        let knownPublicKey: Data?
        do {
            knownPublicKey = try trustStore.peerPublicKey(deviceID: hello.deviceID)
        } catch {
            return closeEffectsLocked(.storageError("\(error)"))
        }
        do {
            if let knownPublicKey {
                // 已配对：先 TOFU pinning 验证 client 签名（通过才回 hello/派生密钥）
                try SyncHandshake.verifyHello(
                    hello,
                    signerPublicKeyRaw: knownPublicKey,
                    expectedRole: SyncHello.roleClient,
                    expectedPeerDeviceID: localIdentity.deviceID,
                    allowEmptyPeerBinding: true
                )
            }
            peerHelloValue = hello
            let ephemeral = Curve25519.KeyAgreement.PrivateKey()
            myEphemeralPrivateKey = ephemeral
            let myHello = try SyncHandshake.makeHello(
                role: SyncHello.roleHost,
                identity: localIdentity,
                peerDeviceID: hello.deviceID,
                ephemeralPublicKeyRaw: ephemeral.publicKey.rawRepresentation,
                name: config.clientDisplayName
            )
            var effects = [Effect.send(try encodedHandshakeFrame(myHello))]
            if knownPublicKey != nil {
                applyReadyTransitionLocked(effects: &effects)
            } else {
                // 未配对：先回 hello，等 pair_request（QR nonce 签名认证）
                phaseValue = .waitingForPairRequest
                effects.append(.notifyState(phaseValue))
                scheduleDeadlineLocked()
            }
            return effects
        } catch {
            return closeEffectsLocked(.handshakeFailed(mapError(error)))
        }
    }

    private func processPairRequestLocked(_ frame: SyncFrame) -> [Effect] {
        guard !frame.isEncrypted, frame.type == .pairRequest else {
            return closeEffectsLocked(.protocolViolation("等待配对阶段收到非法帧"))
        }
        let request: PairRequest
        do {
            request = try decodeJSON(PairRequest.self, from: frame.payload)
            try SyncPairingMessages.validate(request)
        } catch let failure as PairingFailure {
            let reason = "配对请求校验失败：\(failure)"
            return [.send(encodedPairResponse(approved: false, reason: reason))]
                + closeEffectsLocked(.pairingRejected(reason))
        } catch {
            let reason = "配对请求解析失败"
            return [.send(encodedPairResponse(approved: false, reason: reason))]
                + closeEffectsLocked(.pairingRejected(reason))
        }
        // 与握手 hello 的身份必须一致（防配流劫持）
        guard request.clientDeviceID == peerHelloValue?.deviceID else {
            let reason = "配对请求与握手身份不一致"
            return [.send(encodedPairResponse(approved: false, reason: reason))]
                + closeEffectsLocked(.pairingRejected(reason))
        }
        // 一次性 QR nonce 验签（证明持有 clientPublicKey 对应私钥 + 扫码在场）
        guard let registry = pairingNonces,
              registry.matchingNonce(for: request) != nil
        else {
            let reason = "无效或过期的 nonce 签名"
            return [.send(encodedPairResponse(approved: false, reason: reason))]
                + closeEffectsLocked(.pairingRejected(reason))
        }
        pendingPairRequest = request
        phaseValue = .waitingForPairApproval
        cancelDeadlineLocked()
        return [.notifyState(phaseValue), .notifyApproval(PendingPairRequest(
            request: request,
            suggestedDisplayName: DeviceID.formatted(request.clientDeviceID)
        ))]
    }

    // MARK: Client 侧握手/配对

    private func processServerHelloLocked(_ hello: SyncHello) -> [Effect] {
        guard hello.role == SyncHello.roleHost else {
            return closeEffectsLocked(.handshakeFailed(.identityMismatch("对端角色应为 host")))
        }
        guard SyncHandshake.isValidDeviceID(hello.deviceID) else {
            return closeEffectsLocked(.handshakeFailed(.invalidMessage("host Device ID 非法")))
        }
        if let expectedPeerID, expectedPeerID != hello.deviceID {
            return closeEffectsLocked(.handshakeFailed(.identityMismatch(
                "期望主机 \(expectedPeerID)，实际 \(hello.deviceID)"
            )))
        }
        let knownPublicKey: Data?
        do {
            knownPublicKey = try trustStore.peerPublicKey(deviceID: hello.deviceID)
        } catch {
            return closeEffectsLocked(.storageError("\(error)"))
        }
        do {
            // ⚠️ 直通 ready 仅限「无扫码候选的普通重连」：本地信任记录存在 ≠ 对方也
            // 信任本端（2026-09-09 真机 bug：iOS 曾预写本地记录 → 客户端误判已配对
            // → 跳过 pairRequest 直接 ready，而 host 查自己信任表无此 client → 一直
            // 等 pairRequest → 永不弹窗/落库）。带 candidate = 用户本次扫码配对意图，
            // 必须走 pairRequest 让 host 批准（host 有记录则 approvePairing 覆盖）。
            if let knownPublicKey, pairingCandidate == nil {
                // 已配对重连：pinning 验证 host 签名（host hello 必须绑定本端 ID）
                try SyncHandshake.verifyHello(
                    hello,
                    signerPublicKeyRaw: knownPublicKey,
                    expectedRole: SyncHello.roleHost,
                    expectedPeerDeviceID: localIdentity.deviceID,
                    allowEmptyPeerBinding: false
                )
                peerHelloValue = hello
                var effects: [Effect] = []
                applyReadyTransitionLocked(effects: &effects)
                return effects
            }
            // 扫码配对（有候选）或未配对：候选公钥即 QR 信任根 → 发 pairRequest
            guard let candidate = pairingCandidate, candidate.deviceID == hello.deviceID else {
                return closeEffectsLocked(.peerUntrusted(hello.deviceID))
            }
            try SyncHandshake.verifyHello(
                hello,
                signerPublicKeyRaw: candidate.publicKeyRaw,
                expectedRole: SyncHello.roleHost,
                expectedPeerDeviceID: localIdentity.deviceID,
                allowEmptyPeerBinding: false
            )
            peerHelloValue = hello
            // QR 信任成立 → 发 PairRequest（对 candidate.sessionNonce 签名）
            let request = try SyncPairingMessages.makePairRequest(
                identity: localIdentity,
                sessionNonce: candidate.sessionNonce,
                clientName: config.clientDisplayName
            )
            let payload = try JSONEncoder().encode(request)
            let frameData = try encodedFrame(type: .pairRequest, encrypted: false, payload: payload)
            phaseValue = .waitingForPairResponse
            cancelDeadlineLocked()
            return [.send(frameData), .notifyState(phaseValue)]
        } catch {
            return closeEffectsLocked(.handshakeFailed(mapError(error)))
        }
    }

    private func processPairResponseLocked(_ frame: SyncFrame) -> [Effect] {
        guard !frame.isEncrypted, frame.type == .pairResponse else {
            return closeEffectsLocked(.protocolViolation("等待答复阶段收到非法帧"))
        }
        let response: PairResponse
        do {
            response = try decodeJSON(PairResponse.self, from: frame.payload)
        } catch {
            let reason = "配对答复解析失败"
            return closeEffectsLocked(.pairingRejected(reason))
        }
        guard response.approved,
              let candidate = pairingCandidate,
              let hostHello = peerHelloValue,
              hostHello.deviceID == candidate.deviceID
        else {
            return closeEffectsLocked(.pairingRejected(response.reason))
        }
        // 批准 → 落 host 信任记录（公钥来自 QR 候选，host 签名已验）
        let device = PeerDevice(
            peerID: candidate.deviceID,
            peerPublicKey: candidate.publicKeyRaw.base64EncodedString(),
            displayName: candidate.hostName,
            role: .host,
            pairedAt: nowEpoch(),
            lastSeenAt: nowEpoch(),
            notes: nil
        )
        do {
            try trustStore.savePeer(device)
        } catch {
            return closeEffectsLocked(.storageError("\(error)"))
        }
        var effects: [Effect] = []
        applyReadyTransitionLocked(effects: &effects)
        return effects
    }

    // MARK: ready 收帧

    private func processReadyFrameLocked(_ frame: SyncFrame) -> [Effect] {
        guard frame.isEncrypted else {
            return closeEffectsLocked(.protocolViolation("ready 后业务帧必须加密"))
        }
        guard var cipher = receiveCipher else {
            return closeEffectsLocked(.protocolViolation("会话密钥未就绪"))
        }
        let plaintext: Data
        do {
            plaintext = try cipher.open(
                frame.payload,
                aad: Self.headerBytes(type: frame.type, flags: frame.flags, payloadCount: frame.payload.count)
            )
            receiveCipher = cipher
        } catch {
            return closeEffectsLocked(.handshakeFailed(mapError(error)))
        }
        switch frame.type {
        case .ping:
            // v1 不做心跳（任务定案：断连即清）：ping 忽略不回复，避免
            // 单 type 回显造成 ping-pong 死循环；keepalive 语义留 M4 引入
            return []
        case .bye:
            return closeEffectsLocked(.receivedBye)
        case .fileMeta, .fileChunk, .fileAck, .changeLogPull, .changeLogPush,
             .manifestRequest, .manifestResponse, .syncFetchRequest, .syncFetchResult,
             .libraryPushAnnounce, .peerLibraryRequest, .peerLibraryResponse:
            let delivered = SyncFrame(type: frame.type, flags: [], payload: plaintext)
            return [.notifyAppFrame(delivered)]
        case .handshake, .pairRequest, .pairResponse:
            return closeEffectsLocked(.protocolViolation("ready 阶段收到握手/配对帧"))
        }
    }

    // MARK: 就绪迁移 / 帧组装辅助

    /// 就绪迁移：派生方向密钥、初始化双方向 cipher、取消超时（锁内调用）。
    /// internal：核心文件 approvePairing/process* 均调用。
    func applyReadyTransitionLocked(effects: inout [Effect]) {
        guard let myEphemeral = myEphemeralPrivateKey,
              let peerHello = peerHelloValue,
              let peerEphemeralRaw = peerHello.ephemeralPublicKeyRaw
        else {
            effects.append(contentsOf: closeEffectsLocked(.protocolViolation("密钥派生前置缺失")))
            return
        }
        do {
            let keys = try SyncKeyExchange.deriveDirectionKeys(
                myEphemeralPrivateKey: myEphemeral,
                peerEphemeralPublicKeyRaw: peerEphemeralRaw
            )
            switch role {
            case .host:
                sendCipher = SyncCipher(key: keys.hostToClient)
                receiveCipher = SyncCipher(key: keys.clientToHost)
            case .client:
                sendCipher = SyncCipher(key: keys.clientToHost)
                receiveCipher = SyncCipher(key: keys.hostToClient)
            }
            phaseValue = .ready
            cancelDeadlineLocked()
            effects.append(.notifyState(phaseValue))
        } catch {
            effects.append(contentsOf: closeEffectsLocked(.handshakeFailed(mapError(error))))
        }
    }

    /// 帧头 10B（AAD 与收端重组必须逐字节一致）。
    static func headerBytes(type: SyncFrameType, flags: SyncFrameFlags, payloadCount: Int) -> Data {
        var out = Data(capacity: SyncFrame.headerLength)
        out.append(SyncFrame.magic)
        withUnsafeBytes(of: UInt32(payloadCount).bigEndian) { out.append(contentsOf: $0) }
        out.append(type.rawValue)
        out.append(flags.rawValue)
        return out
    }

    func encodedHandshakeFrame(_ hello: SyncHello) throws -> Data {
        try encodedFrame(type: .handshake, encrypted: false, payload: JSONEncoder().encode(hello))
    }

    func encodedPairResponse(approved: Bool, reason: String?) -> Data {
        // 拒绝路径也必须送达：PairResponse 是 Codable 结构，编码恒成功
        // swiftlint:disable:next force_try
        try! encodedFrame(
            type: .pairResponse,
            encrypted: false,
            payload: JSONEncoder().encode(PairResponse(approved: approved, reason: reason))
        )
    }

    func encodedFrame(type: SyncFrameType, encrypted: Bool, payload: Data) throws -> Data {
        guard payload.count <= SyncFrame.maxPayloadSize else {
            throw SyncFrameError.encodePayloadTooLarge(payload.count)
        }
        let flags: SyncFrameFlags = encrypted ? [.encrypted] : []
        var out = Self.headerBytes(type: type, flags: flags, payloadCount: payload.count)
        out.append(payload)
        return out
    }

    func decodeJSON<T: Decodable>(_ type: T.Type, from payload: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: payload)
        } catch {
            throw SyncHandshakeError.invalidMessage("JSON 解码失败：\(error)")
        }
    }

    func mapError(_ error: Error) -> SyncHandshakeError {
        if let handshake = error as? SyncHandshakeError { return handshake }
        return .invalidMessage("\(error)")
    }

    func nowEpoch() -> Int64 {
        Int64(Date().timeIntervalSince1970)
    }
}

// MARK: - 会话事件分发链（修 🟡F1：链上任一 handler 释放不得让其它 handler 收不到事件）

/// 槽位名（每条会话一个槽位一条链）。
enum SyncSessionEventSlot {
    /// `session.onApplicationFrame`（ready 后业务帧）
    static let applicationFrame = "applicationFrame"
    /// `session.onClosed`（会话关闭）
    static let closed = "closed"
}

/// 链挂接句柄：`detach()` 摘除自己那一项。
/// 幂等；**随持有者释放自动摘除**（所以不需要"保活池"，链也不会无限变长）。
final class SyncEventHandlerToken: @unchecked Sendable {
    private let lock = NSLock()
    private var removal: (() -> Void)?

    init(removal: @escaping () -> Void) {
        self.removal = removal
    }

    /// 摘除（幂等）。摘除后链上其它 handler 照常收到事件。
    func detach() {
        lock.lock()
        let action = removal
        removal = nil
        lock.unlock()
        action?()
    }

    deinit {
        detach()
    }
}

/// 会话事件分发链：把此前**各 peer 各自复制一份**的"把自己挂进 `session.onApplicationFrame` /
/// `onClosed` 闭包链"收敛成单一实现，并修掉它的释放语义缺陷。
///
/// 旧写法（本仓库此前 7 处同构复制）：
/// ```swift
/// priorAppHandler = session.onApplicationFrame
/// session.onApplicationFrame = { [weak self] frame in
///     guard let self, self.forwardingEnabled else {
///         self?.priorAppHandler?(frame)   // ← self 已释放：什么也不做，prior 永远收不到帧
///         return
///     }
///     self.handleInboundFrame(frame)
///     self.priorAppHandler?(frame)
/// }
/// ```
/// 后果（🟡F1）：链上任一 peer 释放 → **挂接更早的 handler 在本次会话余下时间全部收不到帧**
/// （整段静默失效，不报错）。生产触发点：`SyncCollectionSyncCoordinator` 计划完成 /
/// 失败 / 超时即 `manifestPeer = nil`，链头释放后更早挂接的 `SyncChangeLogPeer` 等收不到帧
/// ——拉取方向"跟歌走"的 `change_log_push` 应答被丢弃 → 播放数据永不落库、游标永不推进。
///
/// 新语义（链结构与释放语义）：
/// - 每个 (会话, 槽位) **一条链**，槽位里只装**一个**稳定分发闭包（首次挂接时装一次）；
///   此后所有挂接都是往链里加一项，彼此无关；
/// - 链项 = (owner 弱持有, handler 强持有)：owner 被释放 → 该项静默并在下次分发前摘除，
///   **其余 handler 照常收到事件**（F1 的修复点）；
/// - 分发顺序与旧链一致：后挂接的先处理，最后是会话原有 handler（调用方注释里的"先己后彼"）；
/// - `SyncEventHandlerToken.detach()` 摘除自己的项：**与其它项的增删顺序无关**（不依赖
///   "自己是不是链头"，也不会误拆后挂的链）；token 释放即摘除，链长度只随存活 handler 数增长；
/// - 强持有语义：槽位闭包强持有链（会话活着 = 链活着）；链只**弱**持有会话
///   （避免 会话 → 闭包 → 链 → 会话 环）；链项强持有 handler、弱持有 owner。
final class SyncEventHandlerChain<Event>: @unchecked Sendable {
    typealias Handler = (Event) -> Void

    /// 链项：owner 弱持有（释放即静默），handler 强持有。
    private final class Entry {
        weak var owner: AnyObject?
        let handler: Handler

        init(owner: AnyObject, handler: @escaping Handler) {
            self.owner = owner
            self.handler = handler
        }
    }

    private let lock = NSLock()
    /// 所属会话（弱持有：仅用于注册表归属与回收，不参与分发）。
    private weak var session: AnyObject?
    /// 挂接顺序（先挂在前 → 分发时倒序）。
    private var entries: [Entry] = []
    /// 会话槽位原有 handler（链尾，最后调用）。
    private let baseHandler: Handler?

    private init(session: AnyObject, baseHandler: Handler?) {
        self.session = session
        self.baseHandler = baseHandler
    }

    /// 会话槽位访问器（读当前 handler / 装分发闭包）。
    struct SlotAccess {
        let readCurrent: () -> Handler?
        let install: (Handler?) -> Void
    }

    /// 把 handler 挂到 (会话, 槽位) 的链上；返回可摘除句柄。
    /// 链不存在时先 `readCurrent()` 取会话原有 handler 作链尾，再 `install()` 装分发闭包。
    static func attach(
        owner: AnyObject,
        session: AnyObject,
        slot: String,
        access: SlotAccess,
        handler: @escaping Handler
    ) -> SyncEventHandlerToken {
        let chain = SyncEventHandlerChainRegistry.chain(session: session, slot: slot, eventType: Event.self) {
            let created = SyncEventHandlerChain<Event>(session: session, baseHandler: access.readCurrent())
            access.install(created.dispatcher())
            return created
        }
        let entry = Entry(owner: owner, handler: handler)
        chain.append(entry)
        return SyncEventHandlerToken { [weak chain] in
            chain?.remove(entry)
        }
    }

    /// 当前链项数（诊断/测试用）。
    var handlerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private func append(_ entry: Entry) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    private func remove(_ entry: Entry) {
        lock.lock()
        entries.removeAll { $0 === entry }
        lock.unlock()
    }

    /// 装进会话槽位的分发闭包：强持有链（链随会话存活）。
    private func dispatcher() -> Handler {
        { event in self.dispatch(event) }
    }

    /// 倒序调用存活链项，最后调用会话原有 handler。
    /// 调用 handler **不持锁**（handler 内可能摘除/挂接其它 handler、甚至释放 peer）。
    private func dispatch(_ event: Event) {
        lock.lock()
        entries.removeAll { $0.owner == nil } // owner 已释放 → 摘除（链长度只随存活 handler 增长）
        let handlers = entries.map(\.handler)
        let base = baseHandler
        lock.unlock()
        for handler in handlers.reversed() {
            handler(event)
        }
        base?(event)
    }
}

/// 链注册表：按 (会话, 槽位, 事件类型) 唯一持有链。
/// 会话先于链释放时惰性回收（链只被槽位闭包强持有 → 会话没了链就没了）。
enum SyncEventHandlerChainRegistry {
    /// 注册表存储：`static let` 不可变绑定 + `@unchecked Sendable` 箱体
    /// （Swift 6 严格并发不允许 nonisolated 的全局可变静态属性）。
    private final class Store: @unchecked Sendable {
        var chains: [String: WeakChain] = [:]
    }

    private static let lock = NSLock()
    private static let store = Store()

    private final class WeakChain {
        weak var value: AnyObject?

        init(_ value: AnyObject) {
            self.value = value
        }
    }

    static func chain<Event>(
        session: AnyObject,
        slot: String,
        eventType: Any.Type,
        make: () -> SyncEventHandlerChain<Event>
    ) -> SyncEventHandlerChain<Event> {
        let key = "\(ObjectIdentifier(session))|\(slot)|\(ObjectIdentifier(eventType))"
        lock.lock()
        defer { lock.unlock() }
        // 回收：会话/槽位闭包已释放的链
        var chains = store.chains.filter { $0.value.value != nil }
        if let existing = chains[key]?.value as? SyncEventHandlerChain<Event> {
            return existing
        }
        // 首次挂接：创建 + 装槽位（在锁内做，避免并发挂接出现两条链互相覆盖槽位）。
        let created = make()
        chains[key] = WeakChain(created)
        store.chains = chains
        return created
    }
}

/// peer/session 组件的槽位挂接门面：一次挂接应用帧 / 关闭两个槽位，统一走分发链。
/// 用法：`attachment = SyncSessionAttachment(session: session, owner: self) { [weak self] frame in ... }`
/// 释放 `attachment`（或本实例释放）即自动摘除；也可显式 `detach()`。
final class SyncSessionAttachment: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [SyncEventHandlerToken] = []

    init(
        session: SyncPeerSession,
        owner: AnyObject,
        onFrame: ((SyncFrame) -> Void)? = nil,
        onClosed: ((SyncSessionCloseReason) -> Void)? = nil
    ) {
        if let onFrame {
            tokens.append(SyncEventHandlerChain.attach(
                owner: owner,
                session: session,
                slot: SyncSessionEventSlot.applicationFrame,
                access: SyncEventHandlerChain<SyncFrame>.SlotAccess(
                    readCurrent: { session.onApplicationFrame },
                    install: { session.onApplicationFrame = $0 }
                ),
                handler: onFrame
            ))
        }
        if let onClosed {
            tokens.append(SyncEventHandlerChain.attach(
                owner: owner,
                session: session,
                slot: SyncSessionEventSlot.closed,
                access: SyncEventHandlerChain<SyncSessionCloseReason>.SlotAccess(
                    readCurrent: { session.onClosed },
                    install: { session.onClosed = $0 }
                ),
                handler: onClosed
            ))
        }
    }

    /// 摘除全部挂接（幂等）。
    func detach() {
        lock.lock()
        let current = tokens
        tokens = []
        lock.unlock()
        current.forEach { $0.detach() }
    }

    deinit {
        detach()
    }
}
