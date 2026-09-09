//
//  SyncPeerSession.swift
//  QQPlayer
//
//  局域网同步（S2, M2a）单连接会话状态机核心。
//
//  状态机总览（处理逻辑见 SyncPeerSession+Frames.swift）：
//    idle → waitingForPeerHello →（已配对）ready
//                          ↘（未配对 Host）waitingForPairRequest
//                             → waitingForPairApproval →（批准）ready
//    client 侧：waitingForPairResponse →（approved）ready
//    任何状态 → closed(原因)
//
//  本文件职责：会话生命周期入口（transport 事件/发送 API/配对决定）、
//  加密发帧、超时调度、效果队列执行。收帧分发与各阶段处理器在
//  SyncPeerSession+Frames.swift（extension）；支撑类型见 SyncSessionModels.swift。
//
//  并发：@unchecked Sendable + NSLock（照现有 Services 并发风格）。网络回调
//  线程入 handleInboundData/handleTransportClosed；所有用户回调（onStateChange/
//  onClosed/pairApprovalHandler/onApplicationFrame/transport 发送）一律在锁外
//  的 flush 阶段执行——NSLock 不可重入，回调里再进会话 API 不会死锁。
//  纯逻辑测试：注入内存 SyncPeerTransport 回环，不经 NWConnection。
//

import CryptoKit
import Foundation

/// 单连接会话状态机（见文件头注释与 SyncPeerSession+Frames.swift）。
final class SyncPeerSession: @unchecked Sendable {
    /// 本端角色（host = 服务方；client = 发起方）
    let role: PeerRole
    /// 本端长期身份（Ed25519 + Device ID）
    let localIdentity: SyncIdentity
    /// 对端信任表（pinning 查询 + 配对落库）
    let trustStore: any SyncTrustStore
    /// 主机侧 QR nonce 池（client 角色为 nil）
    let pairingNonces: SyncPairingNonceRegistry?

    /// 底层通道（弱引用：channel 持有 session，session 不反向持有）
    weak var transport: (any SyncPeerTransport)?
    /// 阶段变化回调（含 .closed；在状态迁移线程同步触发，UI 层自行跳主线程）
    var onStateChange: ((SyncSessionPhase) -> Void)?
    /// 关闭回调（仅一次，携带原因）
    var onClosed: ((SyncSessionCloseReason) -> Void)?
    /// ready 后业务帧回调（file_meta/file_chunk/file_ack，payload 已解密；
    /// M2b 文件传输接入点。nil = 忽略）
    var onApplicationFrame: ((SyncFrame) -> Void)?
    /// Host 侧待批准配对回调（验签通过后触发；UI 层弹窗后调用
    /// approvePairing/rejectPairing）
    var pairApprovalHandler: ((SyncPeerSession, PendingPairRequest) -> Void)?

    // 会话握手配置（extension 文件（Frames）读取 clientDisplayName 发
    // PairRequest 用，故 internal）
    let config: SyncSessionConfiguration
    private let lock = NSLock()
    private var frameDecoder = SyncFrameDecoder()

    // 状态/握手内部态（锁保护；帧处理器在 extension 文件直接读写）
    var phaseValue: SyncSessionPhase = .idle
    var closeReasonValue: SyncSessionCloseReason = .userCancelled
    var myEphemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    var peerHelloValue: SyncHello?
    var pendingPairRequest: PairRequest?
    var expectedPeerID: String?
    var pairingCandidate: SyncPairingCandidate?
    var sendCipher: SyncCipher?
    var receiveCipher: SyncCipher?
    private var deadlineItem: DispatchWorkItem?

    // MARK: init / 公开查询

    init(
        role: PeerRole,
        localIdentity: SyncIdentity,
        trustStore: any SyncTrustStore,
        config: SyncSessionConfiguration = SyncSessionConfiguration(),
        pairingNonces: SyncPairingNonceRegistry? = nil,
        transport: (any SyncPeerTransport)? = nil
    ) {
        self.role = role
        self.localIdentity = localIdentity
        self.trustStore = trustStore
        self.config = config
        self.pairingNonces = pairingNonces
        self.transport = transport
    }

    var phase: SyncSessionPhase {
        lock.lock()
        defer { lock.unlock() }
        return phaseValue
    }

    var closeReason: SyncSessionCloseReason {
        lock.lock()
        defer { lock.unlock() }
        return closeReasonValue
    }

    /// 已配对/密钥就绪。
    var isReady: Bool { phase == .ready }

    // MARK: client 配对预期注入（transport ready 前调用）

    /// client：声明期望的对端（已配对主机 ID / 扫码候选）。二者可同时给，
    /// hello.peerDeviceID 取 expectedPeerDeviceID > candidate.deviceID > 空串。
    func setPairingExpectations(
        expectedPeerDeviceID: String?,
        candidate: SyncPairingCandidate?
    ) {
        lock.lock()
        expectedPeerID = expectedPeerDeviceID
        pairingCandidate = candidate
        lock.unlock()
    }

    // MARK: 传输事件入口（channel 调用）

    /// 连接就绪：发起/等待握手。
    func handleTransportReady() {
        lock.lock()
        var effects: [Effect] = []
        guard phaseValue == .idle else {
            lock.unlock()
            flush(effects)
            return
        }
        phaseValue = .waitingForPeerHello
        effects.append(.notifyState(phaseValue))
        do {
            switch role {
            case .host:
                scheduleDeadlineLocked()
            case .client:
                let ephemeral = Curve25519.KeyAgreement.PrivateKey()
                myEphemeralPrivateKey = ephemeral
                let peerBinding = expectedPeerID ?? pairingCandidate?.deviceID ?? ""
                let hello = try SyncHandshake.makeHello(
                    role: SyncHello.roleClient,
                    identity: localIdentity,
                    peerDeviceID: peerBinding,
                    ephemeralPublicKeyRaw: ephemeral.publicKey.rawRepresentation
                )
                effects.append(.send(try encodedHandshakeFrame(hello)))
                scheduleDeadlineLocked()
            }
        } catch {
            effects.append(contentsOf: closeEffectsLocked(.handshakeFailed(mapError(error))))
        }
        lock.unlock()
        flush(effects)
    }

    /// 通道收到原始字节（任意分块；内部拼帧后按阶段分发）。
    func handleInboundData(_ data: Data) {
        lock.lock()
        var effects: [Effect] = []
        defer {
            lock.unlock()
            flush(effects)
        }
        guard phaseValue != .closed, phaseValue != .idle else { return }
        let frames: [SyncFrame]
        do {
            frames = try frameDecoder.feed(data)
        } catch {
            effects.append(contentsOf: closeEffectsLocked(.protocolViolation("帧解码失败：\(error)")))
            return
        }
        for frame in frames {
            guard phaseValue != .closed else { break }
            effects.append(contentsOf: processFrameLocked(frame))
        }
    }

    /// 通道断开（EOF/失败/cancel）。会话已关闭时幂等忽略；
    /// 否则视为远端异常断开。
    func handleTransportClosed() {
        lock.lock()
        var effects: [Effect] = []
        if phaseValue != .closed {
            effects.append(contentsOf: closeEffectsLocked(.remoteClosed))
        }
        lock.unlock()
        flush(effects)
    }

    /// 本端主动关闭（UI 取消/清理）。
    func cancel(reason: SyncSessionCloseReason = .userCancelled) {
        lock.lock()
        let effects: [Effect] = phaseValue == .closed ? [] : closeEffectsLocked(reason)
        lock.unlock()
        flush(effects)
    }

    // MARK: ready 后发送

    /// 发送业务帧（file_meta/file_chunk/file_ack；加密）。未 ready / 类型非法抛错。
    func sendApplicationFrame(type: SyncFrameType, payload: Data) throws {
        guard [.fileMeta, .fileChunk, .fileAck].contains(type) else {
            throw SyncFrameError.invalidType(type.rawValue)
        }
        try sendEncryptedFrame(type: type, payload: payload)
    }

    /// 发送 ping（v1 无心跳语义，仅协议占位）。未 ready 抛错。
    func sendPing() throws {
        try sendEncryptedFrame(type: .ping, payload: Data())
    }

    /// 发送 bye 并优雅关闭。
    func sendBye() throws {
        try sendEncryptedFrame(type: .bye, payload: Data())
        cancel(reason: .userCancelled)
    }

    // MARK: 配对决定（Host 侧 UI 调用）

    /// 批准待批准配对：落 client 信任记录 → 回 approved → 派生密钥进 ready。
    func approvePairing(displayName: String?) {
        lock.lock()
        var effects: [Effect] = []
        defer {
            lock.unlock()
            flush(effects)
        }
        guard phaseValue == .waitingForPairApproval, let request = pendingPairRequest else { return }
        let name = displayName.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? DeviceID.formatted(request.clientDeviceID)
        let device = PeerDevice(
            peerID: request.clientDeviceID,
            peerPublicKey: request.clientPublicKey,
            displayName: name,
            role: .client,
            pairedAt: nowEpoch(),
            lastSeenAt: nowEpoch(),
            notes: nil
        )
        do {
            try trustStore.savePeer(device)
        } catch {
            effects.append(.send(encodedPairResponse(approved: false, reason: "信任表写入失败")))
            effects.append(contentsOf: closeEffectsLocked(.storageError("\(error)")))
            return
        }
        effects.append(.send(encodedPairResponse(approved: true, reason: nil)))
        applyReadyTransitionLocked(effects: &effects)
    }

    /// 拒绝待批准配对。
    func rejectPairing(reason: String?) {
        lock.lock()
        var effects: [Effect] = []
        defer {
            lock.unlock()
            flush(effects)
        }
        guard phaseValue == .waitingForPairApproval else { return }
        effects.append(.send(encodedPairResponse(approved: false, reason: reason)))
        effects.append(contentsOf: closeEffectsLocked(.pairingRejected(reason)))
    }

    // MARK: 内部辅助（锁内调用；extension 帧处理器共用）

    /// 置 closed 并返回效果（[状态通知, 关闭]；锁内调用）。
    func closeEffectsLocked(_ reason: SyncSessionCloseReason) -> [Effect] {
        guard phaseValue != .closed else { return [] }
        phaseValue = .closed
        closeReasonValue = reason
        cancelDeadlineLocked()
        return [.notifyState(phaseValue), .close(reason)]
    }

    /// 就绪后加密发送一帧（AAD = 帧头；锁内组装，锁外发送）。
    private func sendEncryptedFrame(type: SyncFrameType, payload: Data) throws {
        lock.lock()
        var effects: [Effect] = []
        defer {
            lock.unlock()
            flush(effects)
        }
        guard phaseValue == .ready else {
            throw SyncFrameError.invalidType(type.rawValue)
        }
        effects.append(.send(try sealEncryptedFrameLocked(type: type, plaintext: payload)))
    }

    /// 锁内加密组帧（ready 后；nonce 计数递增）。combined = nonce(12)+ct+tag(16)，
    /// 故加密后 payload 长度 = plaintext + 28，帧头可在加密前确定（AAD 一致）。
    private func sealEncryptedFrameLocked(type: SyncFrameType, plaintext: Data) throws -> Data {
        guard var cipher = sendCipher else {
            throw SyncHandshakeError.invalidMessage("会话密钥未就绪")
        }
        let payloadCount = plaintext.count + 28
        let header = Self.headerBytes(type: type, flags: [.encrypted], payloadCount: payloadCount)
        let sealed = try cipher.seal(plaintext: plaintext, aad: header)
        sendCipher = cipher
        var out = Data(capacity: header.count + sealed.count)
        out.append(header)
        out.append(sealed)
        return out
    }

    // MARK: 超时

    func scheduleDeadlineLocked() {
        cancelDeadlineLocked()
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleDeadline()
        }
        deadlineItem = workItem
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + config.handshakeTimeout,
            execute: workItem
        )
    }

    func cancelDeadlineLocked() {
        deadlineItem?.cancel()
        deadlineItem = nil
    }

    private func handleDeadline() {
        lock.lock()
        var effects: [Effect] = []
        if phaseValue == .waitingForPeerHello || phaseValue == .waitingForPairRequest {
            effects.append(contentsOf: closeEffectsLocked(.handshakeTimeout))
        }
        lock.unlock()
        flush(effects)
    }

    // MARK: 效果执行（锁外）

    private func flush(_ effects: [Effect]) {
        for effect in effects {
            switch effect {
            case let .send(data):
                guard !data.isEmpty else { continue }
                transport?.sendFrameBytes(data)
            case let .notifyState(phase):
                onStateChange?(phase)
            case let .close(reason):
                onClosed?(reason)
                transport?.closeTransport()
            case let .notifyApproval(pending):
                pairApprovalHandler?(self, pending)
            case let .notifyAppFrame(frame):
                onApplicationFrame?(frame)
            }
        }
    }
}
