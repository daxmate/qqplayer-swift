//
//  SyncPairingApprovalModel.swift
//  QQPlayer
//
//  局域网同步（S2, M2a）Host 侧批准卡模型——PendingPairRequest → 批准卡
//  呈现数据的纯映射（无 IO / 无 UI / 无传输，可单测）：
//  - SyncPairingApprovalCard：批准卡展示模型（设备名回退 / 来源 / 替换标记）
//  - PendingPairRequest 扩展：展示名解析（clientName 优先，空回退 ID 短格式）
//    + 生成 PeerCandidate（喂给 MacPairApprovalCardView / M1 PeerCandidate）
//
//  展示名语义（与 approvePairing 落库回退一致）：PairRequest.clientName
//  trim 后非空优先；空则回退 suggestedDisplayName（= DeviceID 分组短格式）。
//  isReplacement 由调用方查信任表后注入（本文件不做 IO）。
//

import Foundation

/// Host 侧待批准配对的批准卡模型（纯值，UI 呈现 + 批准动作输入）。
struct SyncPairingApprovalCard: Equatable, Sendable {
    /// 请求方 Device ID（全量）
    var deviceID: String
    /// 批准卡展示名（clientName trim 后非空优先；空回退 suggestedDisplayName，
    /// 恒非空——由构造方保证回退到 ID 短格式）
    var displayName: String
    /// 候选来源（v1 配流只有扫码路径；手输首连 M4 起才有 .manualInput）
    var source: PeerCandidateSource
    /// 同 peerID 已存在配对记录（批准 = 替换旧记录）
    var isReplacement: Bool
    /// 请求携带的展示名原文（未 trim；批准落库用，空 = 无真实设备名）
    var rawClientName: String?
    /// 请求携带的公钥 raw（批准落库用；decode 失败为 nil——网络请求已被
    /// SyncPairingMessages.validate 拦过，正常恒 32B）
    var clientPublicKeyRaw: Data?
}

// MARK: - PendingPairRequest → 批准卡（纯逻辑）

extension PendingPairRequest {
    /// 展示名解析：clientName trim 后非空优先，空回退 suggestedDisplayName。
    /// 与 approvePairing(displayName:) 的落库回退语义一致（trim → 空则 ID 短格式）。
    var approvalDisplayName: String {
        let trimmed = request.clientName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? suggestedDisplayName : trimmed
    }

    /// 映射为批准卡模型（isReplacement 由调用方查信任表后传入）。
    func makeApprovalCard(isReplacement: Bool) -> SyncPairingApprovalCard {
        SyncPairingApprovalCard(
            deviceID: request.clientDeviceID,
            displayName: approvalDisplayName,
            source: .qr, // v1 配流仅 QR nonce 路径可到达批准（见 Frames 验签）
            isReplacement: isReplacement,
            rawClientName: request.clientName,
            clientPublicKeyRaw: Data(base64Encoded: request.clientPublicKey)
        )
    }
}

// MARK: - 批准卡 → 呈现候选（PeerCandidate）

extension SyncPairingApprovalCard {
    /// 生成 M1 PeerCandidate（MacPairApprovalCardView 入参；sessionNonce 未知
    /// ——批准阶段请求只带签名不带原文，卡组件不展示 nonce）。
    func makePeerCandidate(receivedAt: TimeInterval) -> PeerCandidate {
        PeerCandidate(
            deviceID: deviceID,
            displayName: displayName,
            publicKeyRaw: clientPublicKeyRaw,
            sessionNonce: nil,
            source: source,
            receivedAt: receivedAt,
            isReplacement: isReplacement
        )
    }
}
