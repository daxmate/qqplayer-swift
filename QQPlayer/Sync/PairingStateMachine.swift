//
//  PairingStateMachine.swift
//  QQPlayer
//
//  配对流程纯逻辑状态机（M1 核心决策；无 IO/无 UI/无传输，全面单测）。
//  状态：idle → awaitingConfirmation(peerCandidate) → approved/rejected/expired/failed
//  事件：receivedQR / manualIDEntered / userConfirmedOnClient / userApprovedOnHost
//        / reject / expireCheck / cancel
//
//  规则（docs/lan-sync-design.md §4）：
//  - QR 候选做一致性校验：deviceID 规范化、公钥 base64/长度、指纹一致性
//    （deviceID == SHA256(pubKey) 指纹，由 DeviceID 提供）
//  - 一次性 nonce 防重放：候选进入 awaiting 起计时，确认/过期检查超过
//    nonceTTL 一律 expired（时间由调用方注入，纯函数可测）
//  - 重复配对（同 peerID 已存在）：事件携带 alreadyPaired → 候选标记
//    isReplacement，走"替换确认"路径——仍需用户显式确认，批准后由
//    DeviceStore upsert 整体替换旧记录（Machine 不碰存储，谁已配对由
//    调用方查 DeviceStore 后传入事件）
//  - reject/取消不落任何持久状态；cancel 回到 idle（机器可复用）
//
//  M2 映射约定：两端各持一个机器实例。Client：receivedQR(扫码载荷) →
//  awaitingConfirmation → 用户确认 userConfirmedOnClient → approved（随后经
//  传输层发 PairRequest）；Host：把收到的 PairRequest 映射为 receivedQR
//  （结构同构：deviceID+pubKey+nonce）→ 弹窗 → userApprovedOnHost → approved。
//  手输路径（§4.2）无对方公钥/nonce：候选公钥为 nil，指纹校验跳过，
//  完整公钥待 M2 握手响应补全后落库。
//

import Foundation

/// 配对失败原因（终态 failed 携带）。
enum PairingFailure: Error, Equatable, Sendable {
    /// QR 载荷结构非法（原因见关联值：协议版本不符/字段缺失等）
    case invalidQRPayload(String)
    /// 手输/载荷里的 Device ID 无法规范化（非法字符/长度）
    case invalidDeviceID(String)
    /// 公钥 base64 解码失败或长度非 32B
    case invalidPublicKey
    /// deviceID 与公钥指纹不一致（防冒充/防输错）
    case fingerprintMismatch
    /// 无候选（idle）时收到确认/批准类事件
    case notAwaitingConfirmation
}

/// 候选来源（QR 扫码 vs 手动输入）
enum PeerCandidateSource: Equatable, Sendable {
    case qr
    case manualInput
}

/// 待确认/已决的配对候选（对方设备信息，纯值）。
struct PeerCandidate: Equatable, Sendable {
    /// 规范化 Device ID（全量）
    let deviceID: String
    /// 展示名（QR: payload.hostName；手输路径握手前未知，空串占位）
    let displayName: String
    /// 对方公钥 raw（QR 路径有；手输路径 nil，待握手响应）
    let publicKeyRaw: Data?
    /// 会话一次性 nonce raw（QR 路径有；手输路径 nil）
    let sessionNonce: Data?
    let source: PeerCandidateSource
    /// 候选进入时间（epoch 秒，调用方注入；nonce 计时起点）
    let receivedAt: TimeInterval
    /// 同 peerID 已存在（重复配对 → 替换确认路径）
    let isReplacement: Bool
}

/// 配对状态机（纯逻辑值类型）。
struct PairingStateMachine: Sendable {
    enum State: Equatable, Sendable {
        case idle
        case awaitingConfirmation(PeerCandidate)
        case approved(PeerCandidate)
        case rejected(PeerCandidate)
        case expired(PeerCandidate)
        case failed(PairingFailure)
    }

    enum Event: Equatable, Sendable {
        /// 扫码收到 QR 载荷（alreadyPaired: 该 peerID 已在本端配对记录中）
        case receivedQR(PairQRPayload, at: TimeInterval, alreadyPaired: Bool)
        /// 手输对方 Device ID（原始输入，可含分隔符/空白/大小写）
        case manualIDEntered(String, at: TimeInterval, alreadyPaired: Bool)
        /// Client 侧用户在确认页点"确认"（流程 4.1 步骤 3）
        case userConfirmedOnClient(at: TimeInterval)
        /// Host 侧用户在弹窗点"批准"（流程 4.1 步骤 6）
        case userApprovedOnHost(at: TimeInterval)
        /// 用户拒绝当前候选
        case reject
        /// 超时检查（外部计时器驱动；未超时保持 awaiting）
        case expireCheck(at: TimeInterval)
        /// 用户取消当前配对（回 idle，机器可复用）
        case cancel
    }

    /// nonce 有效期（秒）。默认 300s；测试注入小值。
    let nonceTTL: TimeInterval
    private(set) var state: State

    init(nonceTTL: TimeInterval = 300, state: State = .idle) {
        self.nonceTTL = nonceTTL
        self.state = state
    }

    /// 是否处于等待用户确认。
    var isAwaitingConfirmation: Bool {
        if case .awaitingConfirmation = state { return true }
        return false
    }

    /// 处理一个事件（纯逻辑，无 IO；状态迁移见各 case 注释）。
    mutating func handle(_ event: Event) {
        switch event {
        case let .receivedQR(payload, at: now, alreadyPaired):
            do {
                let candidate = try candidate(fromQR: payload, receivedAt: now)
                state = .awaitingConfirmation(
                    withReplacementFlag(candidate, alreadyPaired: alreadyPaired)
                )
            } catch let failure as PairingFailure {
                state = .failed(failure)
            } catch {
                preconditionFailure("未预期的校验错误: \(error)")
            }

        case let .manualIDEntered(rawID, at: now, alreadyPaired):
            do {
                let candidate = try candidate(fromManualInput: rawID, receivedAt: now)
                state = .awaitingConfirmation(
                    withReplacementFlag(candidate, alreadyPaired: alreadyPaired)
                )
            } catch let failure as PairingFailure {
                state = .failed(failure)
            } catch {
                preconditionFailure("未预期的校验错误: \(error)")
            }

        case .userConfirmedOnClient(at: let now), .userApprovedOnHost(at: let now):
            guard case let .awaitingConfirmation(candidate) = state else {
                state = .failed(.notAwaitingConfirmation)
                return
            }
            if isExpired(candidate, at: now) {
                state = .expired(candidate)
            } else {
                state = .approved(candidate)
            }

        case .reject:
            guard case let .awaitingConfirmation(candidate) = state else { return }
            state = .rejected(candidate)

        case let .expireCheck(at: now):
            guard case let .awaitingConfirmation(candidate) = state else { return }
            if isExpired(candidate, at: now) {
                state = .expired(candidate)
            }

        case .cancel:
            if case .awaitingConfirmation = state {
                state = .idle
            }
        }
    }

    // MARK: - 候选构造（纯函数：校验失败抛 PairingFailure，不碰 state）

    private func candidate(fromQR payload: PairQRPayload, receivedAt now: TimeInterval) throws -> PeerCandidate {
        guard payload.protoVersion == SyncProtocolVersion.current else {
            throw PairingFailure.invalidQRPayload("协议版本不兼容：\(payload.protoVersion) != \(SyncProtocolVersion.current)")
        }
        guard let deviceID = DeviceID.normalized(payload.deviceID) else {
            throw PairingFailure.invalidDeviceID(payload.deviceID)
        }
        guard let publicKeyData = Data(base64Encoded: payload.publicKey),
              publicKeyData.count == DeviceID.fingerprintByteCount
        else {
            throw PairingFailure.invalidPublicKey
        }
        guard let nonce = Data(base64Encoded: payload.sessionNonce), !nonce.isEmpty else {
            throw PairingFailure.invalidQRPayload("sessionNonce 缺失或非法")
        }
        guard DeviceID.fingerprintMatches(deviceID: deviceID, publicKeyData: publicKeyData) else {
            throw PairingFailure.fingerprintMismatch
        }
        return PeerCandidate(
            deviceID: deviceID,
            displayName: payload.hostName,
            publicKeyRaw: publicKeyData,
            sessionNonce: nonce,
            source: .qr,
            receivedAt: now,
            isReplacement: false
        )
    }

    private func candidate(fromManualInput rawID: String, receivedAt now: TimeInterval) throws -> PeerCandidate {
        guard let deviceID = DeviceID.normalized(rawID) else {
            throw PairingFailure.invalidDeviceID(rawID)
        }
        // 手输路径无对方公钥/nonce：指纹校验与签名证明在 M2 握手响应完成
        return PeerCandidate(
            deviceID: deviceID,
            displayName: "",
            publicKeyRaw: nil,
            sessionNonce: nil,
            source: .manualInput,
            receivedAt: now,
            isReplacement: false
        )
    }

    private func withReplacementFlag(_ candidate: PeerCandidate, alreadyPaired: Bool) -> PeerCandidate {
        guard alreadyPaired, !candidate.isReplacement else { return candidate }
        return PeerCandidate(
            deviceID: candidate.deviceID,
            displayName: candidate.displayName,
            publicKeyRaw: candidate.publicKeyRaw,
            sessionNonce: candidate.sessionNonce,
            source: candidate.source,
            receivedAt: candidate.receivedAt,
            isReplacement: true
        )
    }

    private func isExpired(_ candidate: PeerCandidate, at now: TimeInterval) -> Bool {
        now - candidate.receivedAt > nonceTTL
    }
}

// MARK: - 批准候选 → 配对记录

extension PeerDevice {
    /// 由状态机批准的候选构造配对记录（调用方在 approved 态时使用）。
    /// 手输路径候选无公钥（peerPublicKey 为空串）：须等 M2 握手响应
    /// 拿到对方公钥后再落库，避免存入无法 pinning 的记录。
    init(candidate: PeerCandidate, role: PeerRole, pairedAt: Int64, notes: String? = nil) {
        peerID = candidate.deviceID
        peerPublicKey = candidate.publicKeyRaw?.base64EncodedString() ?? ""
        displayName = candidate.displayName
        self.role = role
        self.pairedAt = pairedAt
        lastSeenAt = pairedAt
        self.notes = notes
    }
}
