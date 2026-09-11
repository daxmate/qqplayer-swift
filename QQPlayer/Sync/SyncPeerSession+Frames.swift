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
                ephemeralPublicKeyRaw: ephemeral.publicKey.rawRepresentation
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
