//
//  SyncPairingCodeFlowTests.swift
//  QQPlayerTests
//
//  批 1（2026-10-30）6 位配对码的**会话级端到端**：码提交 → nonce → PairRequest 验签
//  → host 批准 → 双向落库 + 双 ready；失败路径的明确原因码。
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncPairingCodeFlowTests {
    @Test("码配对：提交码 → 拿 nonce → 签 PairRequest → 批准 → 双 ready + 双向落库")
    func pairingCodeFlowApproved() throws {
        let store = SyncPairingCodeStore()
        let fixture = SessionFixture.make(pairingCodeStore: store)
        let issue = store.generate()
        fixture.hostSession.pairingNonces?.register(
            issue.nonce,
            ttl: SyncPairingCodeStore.defaultTTL
        )
        let expectedClientID = fixture.clientIdentity.deviceID
        fixture.hostSession.pairApprovalHandler = { session, pending in
            #expect(pending.request.clientDeviceID == expectedClientID)
            session.approvePairing(displayName: pending.request.clientName)
        }
        fixture.clientSession.setPairingExpectations(expectedPeerDeviceID: nil, candidate: nil)
        fixture.clientSession.setPairingCode(issue.code)

        fixture.hostSession.handleTransportReady()
        fixture.clientSession.handleTransportReady()

        #expect(fixture.hostSession.phase == .ready)
        #expect(fixture.clientSession.phase == .ready)
        #expect(fixture.hostTrust.contains(deviceID: expectedClientID))
        #expect(fixture.clientTrust.contains(deviceID: fixture.hostIdentity.deviceID))
        // 码已单次使用
        #expect(store.activeCode == issue.code)
        if case let .failure(failure) = store.verify(code: issue.code, peerID: expectedClientID) {
            #expect(failure == .alreadyUsed)
        } else {
            Issue.record("码应只能使用一次")
        }
    }

    @Test("码配对：错误码 → 客户端拿到 mismatch 文案 key 并关闭")
    func pairingCodeFlowWrongCode() throws {
        let store = SyncPairingCodeStore()
        let fixture = SessionFixture.make(pairingCodeStore: store)
        _ = store.generate()
        fixture.clientSession.setPairingExpectations(expectedPeerDeviceID: nil, candidate: nil)
        fixture.clientSession.setPairingCode("000000")

        fixture.hostSession.handleTransportReady()
        fixture.clientSession.handleTransportReady()

        #expect(fixture.clientSession.phase == .closed)
        guard case let .pairingRejected(detail) = fixture.clientSession.closeReason else {
            Issue.record("应为 pairingRejected，实际 \(fixture.clientSession.closeReason)")
            return
        }
        #expect(detail == "sync_pair_code_failed_mismatch")
    }

    @Test("码配对：对方没有有效码 → no_active_code 文案 key")
    func pairingCodeFlowNoActiveCode() throws {
        let store = SyncPairingCodeStore()
        let fixture = SessionFixture.make(pairingCodeStore: store)
        fixture.clientSession.setPairingExpectations(expectedPeerDeviceID: nil, candidate: nil)
        fixture.clientSession.setPairingCode("123456")

        fixture.hostSession.handleTransportReady()
        fixture.clientSession.handleTransportReady()

        #expect(fixture.clientSession.phase == .closed)
        guard case let .pairingRejected(detail) = fixture.clientSession.closeReason else {
            Issue.record("应为 pairingRejected，实际 \(fixture.clientSession.closeReason)")
            return
        }
        #expect(detail == "sync_pair_code_failed_no_active")
    }

    @Test("码配对：码过期 → expired 文案 key")
    func pairingCodeFlowExpired() throws {
        let clock = SyncPairingCodeCheckClock()
        let store = SyncPairingCodeStore(now: { clock.now })
        let fixture = SessionFixture.make(pairingCodeStore: store)
        let issue = store.generate()
        fixture.hostSession.pairingNonces?.register(issue.nonce, ttl: SyncPairingCodeStore.defaultTTL)
        // 时间推进到码过期之后（非nonce校验阶段即可判定）
        clock.now = clock.now.addingTimeInterval(SyncPairingCodeStore.defaultTTL + 1)
        fixture.clientSession.setPairingExpectations(expectedPeerDeviceID: nil, candidate: nil)
        fixture.clientSession.setPairingCode(issue.code)

        fixture.hostSession.handleTransportReady()
        fixture.clientSession.handleTransportReady()

        guard case let .pairingRejected(detail) = fixture.clientSession.closeReason else {
            Issue.record("应为 pairingRejected，实际 \(fixture.clientSession.closeReason)")
            return
        }
        #expect(detail == "sync_pair_code_failed_expired")
    }
}

/// 可推进的测试时钟（SessionFixture 侧不假设时间源）。
private final class SyncPairingCodeCheckClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_700_000_000)
}
