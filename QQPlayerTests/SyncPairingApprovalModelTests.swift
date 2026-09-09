//
//  SyncPairingApprovalModelTests.swift
//  QQPlayerTests
//
//  S2 接线：Host 侧批准卡模型（PendingPairRequest → SyncPairingApprovalCard
//  → PeerCandidate）纯逻辑防回归：
//  - 展示名解析：clientName（trim 后非空）优先，空/空白回退 suggestedDisplayName
//  - 批准卡字段：deviceID / source(.qr) / isReplacement 透传 / publicKey 解码
//  - PeerCandidate 映射（MacPairApprovalCardView 入参）
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncPairingApprovalModelTests {
    // MARK: - Fixtures

    private static let sampleID = String(repeating: "ABCDEFG", count: 7) + "XYZ" // 52 字符占位

    private func makePending(
        clientName: String?,
        suggested: String = "建议展示名"
    ) -> PendingPairRequest {
        PendingPairRequest(
            request: PairRequest(
                clientDeviceID: Self.sampleID,
                clientPublicKey: Data(repeating: 7, count: 32).base64EncodedString(),
                nonceSignature: Data(repeating: 9, count: 64).base64EncodedString(),
                clientName: clientName
            ),
            suggestedDisplayName: suggested
        )
    }

    // MARK: - 展示名解析

    @Test("approvalDisplayName：clientName 非空优先")
    func displayNamePrefersClientName() {
        let pending = makePending(clientName: "张超的 iPhone")
        #expect(pending.approvalDisplayName == "张超的 iPhone")
    }

    @Test("approvalDisplayName：clientName 空白 → 回退 suggestedDisplayName")
    func displayNameFallsBackWhenBlank() {
        #expect(makePending(clientName: "   ").approvalDisplayName == "建议展示名")
        #expect(makePending(clientName: "").approvalDisplayName == "建议展示名")
        #expect(makePending(clientName: nil).approvalDisplayName == "建议展示名")
        // 首尾空白 trim，中间保留
        let pending = makePending(clientName: " 我的 iPhone ")
        #expect(pending.approvalDisplayName == "我的 iPhone")
    }

    // MARK: - 批准卡模型

    @Test("makeApprovalCard：字段映射 + source=.qr + isReplacement 透传")
    func approvalCardFields() {
        let card = makePending(clientName: "老婆的 iPhone")
            .makeApprovalCard(isReplacement: true)
        #expect(card.deviceID == Self.sampleID)
        #expect(card.displayName == "老婆的 iPhone")
        #expect(card.source == .qr) // v1 配流仅 QR nonce 路径可到达批准
        #expect(card.isReplacement == true)
        #expect(card.rawClientName == "老婆的 iPhone")
        #expect(card.clientPublicKeyRaw == Data(repeating: 7, count: 32))
    }

    @Test("makeApprovalCard：空白 clientName → displayName 回退，rawClientName 原样")
    func approvalCardBlankName() {
        let pending = makePending(clientName: "   ")
        let card = pending.makeApprovalCard(isReplacement: false)
        #expect(card.displayName == pending.suggestedDisplayName)
        #expect(card.rawClientName == "   ") // 原样保留（trim 归消费方）
        #expect(card.isReplacement == false)
    }

    // MARK: - PeerCandidate 映射（MacPairApprovalCardView 入参）

    @Test("makePeerCandidate：字段透传 + sessionNonce=nil（批准阶段无原文）")
    func peerCandidateMapping() throws {
        let card = makePending(clientName: "Mac 上的 iPhone")
            .makeApprovalCard(isReplacement: true)
        let candidate = card.makePeerCandidate(receivedAt: 1_700_000_000)
        #expect(candidate.deviceID == card.deviceID)
        #expect(candidate.displayName == card.displayName)
        #expect(candidate.publicKeyRaw == card.clientPublicKeyRaw)
        #expect(candidate.sessionNonce == nil)
        #expect(candidate.source == .qr)
        #expect(candidate.isReplacement == true)
        #expect(candidate.receivedAt == 1_700_000_000)
    }
}
