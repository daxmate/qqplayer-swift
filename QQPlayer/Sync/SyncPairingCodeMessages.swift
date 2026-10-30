//
//  SyncPairingCodeMessages.swift
//  QQPlayer
//
//  局域网同步 · 批 1（2026-10-30）6 位配对码的**线上消息模型 + 纯校验**。
//
//  线上帧（SyncFrameType，明文，均在配对阶段）：
//  - pairCodeSubmit(17)   client → host：{clientDeviceID, clientPublicKey, clientName?, code}
//  - pairCodeResponse(18) host → client：{accepted, reason?, hostDeviceID?, hostPublicKey?,
//                        sessionNonce?}
//
//  握手时序（码通过后仍走既有 PairRequest，不新增信任根）：
//    client: hello → pairCodeSubmit → [pairCodeResponse] → pairRequest（对 nonce 签名）
//            → pairResponse → ready
//    host  : hello → 校验码 → pairCodeResponse(accepted + nonce) → pairRequest 验签
//            → 批准卡 → approvePairing → pairResponse → ready
//
//  base64 一律 standard（与 PairingModels/SyncHello 同约定）；deviceID 全量值。
//

import Foundation

// MARK: - 线上消息

/// client → host：提交 6 位配对码（首次提交即含本机身份，供 host 记录失败计数）。
struct PairCodeSubmit: Codable, Equatable, Sendable {
    var clientDeviceID: String
    var clientPublicKey: String // base64（32B Ed25519 raw）
    var clientName: String?
    var code: String // 用户输入的 6 位数字（未归一时也接受，host 侧再归一）
}

/// host → client：码校验结果。accepted = true 时附带 host 身份与一次性 nonce。
struct PairCodeResponsePayload: Codable, Equatable, Sendable {
    var accepted: Bool
    /// 失败原因码（SyncPairingCodeFailure.rawValue / protocol_error）；成功时 nil
    var reason: String?
    var hostDeviceID: String?
    var hostPublicKey: String? // base64（32B Ed25519 raw）
    var sessionNonce: String? // base64；成功时必填
    /// 结构类失败的诊断细节（protocol_error 时非空；不参与 UI 判断）
    var detail: String?
}

// MARK: - 构造 / 校验

/// 配对码消息纯逻辑（与 SyncPairingMessages 同风格：无 IO、可单测）。
enum SyncPairingCodeMessages {
    /// 结构类失败（消息本身不合法）的 reason 码
    static let protocolErrorReason = "protocol_error"

    /// Client 构造提交帧。
    static func makeSubmit(
        identity: SyncIdentity,
        code: String,
        clientName: String? = nil
    ) -> PairCodeSubmit {
        PairCodeSubmit(
            clientDeviceID: identity.deviceID,
            clientPublicKey: identity.publicKeyRaw.base64EncodedString(),
            clientName: clientName,
            code: code
        )
    }

    /// 结构校验提交帧：Device ID 规范化、公钥 32B、ID == 公钥指纹、码形似 6 位数字。
    /// 失败抛 M1 PairingFailure（与扫码候选校验同语义）。
    static func validate(_ submit: PairCodeSubmit) throws {
        guard DeviceID.normalized(submit.clientDeviceID) != nil else {
            throw PairingFailure.invalidDeviceID(submit.clientDeviceID)
        }
        guard let publicKey = Data(base64Encoded: submit.clientPublicKey),
              publicKey.count == DeviceID.fingerprintByteCount
        else {
            throw PairingFailure.invalidPublicKey
        }
        guard DeviceID.fingerprintMatches(deviceID: submit.clientDeviceID, publicKeyData: publicKey) else {
            throw PairingFailure.fingerprintMismatch
        }
        guard SyncPairingCodeStore.normalizedInput(submit.code) != nil else {
            throw PairingFailure.invalidQRPayload("配对码格式非法")
        }
    }

    /// Host 构造「码通过」答复（附本机身份 + 本次一次性 nonce）。
    static func accepted(identity: SyncIdentity, nonce: Data) -> PairCodeResponsePayload {
        PairCodeResponsePayload(
            accepted: true,
            reason: nil,
            hostDeviceID: identity.deviceID,
            hostPublicKey: identity.publicKeyRaw.base64EncodedString(),
            sessionNonce: nonce.base64EncodedString(),
            detail: nil
        )
    }

    /// Host 构造「码不通过」答复。
    static func rejected(_ failure: SyncPairingCodeFailure) -> PairCodeResponsePayload {
        PairCodeResponsePayload(
            accepted: false,
            reason: failure.rawValue,
            hostDeviceID: nil,
            hostPublicKey: nil,
            sessionNonce: nil,
            detail: nil
        )
    }

    /// 结构类失败答复（消息本身不合法）。
    static func protocolError(message: String) -> PairCodeResponsePayload {
        PairCodeResponsePayload(
            accepted: false,
            reason: protocolErrorReason,
            hostDeviceID: nil,
            hostPublicKey: nil,
            sessionNonce: nil,
            detail: message
        )
    }

    /// 失败原因码 → UI 文案 key（client 侧弹错误用；未知码回落通用 key）。
    static func messageKey(forReason reason: String?) -> String {
        guard let reason else { return "sync_pair_code_failed_generic" }
        switch SyncPairingCodeFailure(rawValue: reason) {
        case .noActiveCode:
            return "sync_pair_code_failed_no_active"
        case .expired:
            return "sync_pair_code_failed_expired"
        case .alreadyUsed:
            return "sync_pair_code_failed_used"
        case .mismatch:
            return "sync_pair_code_failed_mismatch"
        case .rateLimited:
            return "sync_pair_code_failed_rate_limited"
        case nil:
            return "sync_pair_code_failed_generic"
        }
    }
}
