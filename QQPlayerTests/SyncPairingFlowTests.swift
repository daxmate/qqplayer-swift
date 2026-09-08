//
//  SyncPairingFlowTests.swift
//  QQPlayerTests
//
//  M1-UI 配对流程接线薄层 + 列表数据源辅助防回归：
//  - SyncPairingFlow：扫码 JSON / 手输文本 → 状态机事件映射（保真/失败抛错）
//  - approved 候选 → PeerDevice(role:.host) 落库对象构造（扫码路径端到端）
//  - SyncDeviceList：hosts 角色过滤 / ID 短格式 / 空名兜底
//  - PairingFailure.localizedKey：全部失败原因都有本地化 key 契约
//

import CryptoKit
import Foundation
import Testing

@testable import QQPlayer

struct SyncPairingFlowTests {
    // MARK: - Fixtures

    private func makeIdentity() -> SyncIdentity {
        SyncIdentity.generate()
    }

    /// 端到端扫码流 → approved 候选（machine 状态由 UI 持有，测试驱动同一路径）
    private func approvedCandidate(
        hostName: String = "Mac Studio",
        alreadyPaired: Bool = false
    ) throws -> PeerCandidate {
        let identity = makeIdentity()
        let payload = PairQRPayloadFactory.make(
            hostName: hostName,
            identity: identity,
            sessionNonce: SyncSessionNonce.makeNew()
        )
        let json = try SyncQRCodec.encode(payload)
        var machine = PairingStateMachine()
        machine.handle(try SyncPairingFlow.qrEvent(
            from: json,
            alreadyPaired: alreadyPaired,
            at: 1_000
        ))
        machine.handle(.userConfirmedOnClient(at: 1_010))
        guard case let .approved(candidate) = machine.state else {
            Issue.record("应为 approved，实际 \(machine.state)")
            throw SyncPairingFlowTestsError.notApproved
        }
        return candidate
    }

    private enum SyncPairingFlowTestsError: Error {
        case notApproved
    }

    // MARK: - SyncPairingFlow（接线薄层）

    @Test("合法 QR JSON → receivedQR 事件，载荷与 alreadyPaired 保真")
    func qrEventMapping() throws {
        let identity = makeIdentity()
        let payload = PairQRPayloadFactory.make(
            hostName: "Mac Pro",
            identity: identity,
            sessionNonce: SyncSessionNonce.makeNew()
        )
        let json = try SyncQRCodec.encode(payload)

        let event = try SyncPairingFlow.qrEvent(from: json, alreadyPaired: true, at: 42)
        guard case let .receivedQR(mapped, at: at, alreadyPaired: paired) = event else {
            Issue.record("事件应为 receivedQR，实际 \(event)")
            return
        }
        #expect(mapped == payload)
        #expect(at == 42)
        #expect(paired)
    }

    @Test("非法 QR JSON（字段缺失）→ qrEvent 抛错（UI 展示 failed 路径）")
    func qrEventInvalidJSONThrows() {
        #expect(throws: (any Error).self) {
            _ = try SyncPairingFlow.qrEvent(from: #"{"protoVersion":2}"#, alreadyPaired: false, at: 1)
        }
    }

    @Test("手输文本（含分隔符）→ manualIDEntered 事件原样保真")
    func manualEventMapping() {
        let raw = "ABCDEFG-2345678-ABCDEFG-2345678-ABCDEFG-2345678-ABCDEFG-2345678-ABC"
        let event = SyncPairingFlow.manualEvent(from: raw, alreadyPaired: false, at: 7)
        guard case let .manualIDEntered(id, at: at, alreadyPaired: paired) = event else {
            Issue.record("事件应为 manualIDEntered，实际 \(event)")
            return
        }
        #expect(id == raw)
        #expect(at == 7)
        #expect(!paired)
    }

    // MARK: - approved → 落库对象（扫码路径）

    @Test("approved 候选 → PeerDevice(role:.host)：公钥 base64 完整、名称/角色正确")
    func approvedCandidateToHostDevice() throws {
        let candidate = try approvedCandidate(hostName: "Mac Studio")

        let device = PeerDevice(candidate: candidate, role: .host, pairedAt: 1_010)
        #expect(device.peerID == candidate.deviceID)
        #expect(device.role == .host)
        #expect(device.displayName == "Mac Studio")
        #expect(device.peerPublicKey == candidate.publicKeyRaw?.base64EncodedString())
        #expect(device.peerPublicKey.isEmpty == false)
        #expect(device.pairedAt == 1_010)
        #expect(device.lastSeenAt == 1_010)
    }

    @Test("approved 候选（重配对路径）→ isReplacement 标记透传到落库对象")
    func replacementCandidateStillStores() throws {
        let candidate = try approvedCandidate(alreadyPaired: true)
        #expect(candidate.isReplacement)

        let device = PeerDevice(candidate: candidate, role: .host, pairedAt: 1_010)
        #expect(device.peerID == candidate.deviceID)
    }

    // MARK: - SyncDeviceList（列表数据源）

    private func makeDevice(
        peerID: String = "ABCDEFG234567ABCDEFG234567ABCDEFG234567ABCDEFG23",
        displayName: String = "主机",
        role: PeerRole,
        publicKey: String = "ZmFrZUtleQ=="
    ) -> PeerDevice {
        PeerDevice(
            peerID: peerID,
            peerPublicKey: publicKey,
            displayName: displayName,
            role: role,
            pairedAt: 1_000,
            lastSeenAt: 1_000,
            notes: nil
        )
    }

    @Test("hosts：只保留 role == .host 记录，排序稳定")
    func hostsFilter() {
        let hostA = makeDevice(displayName: "Mac A", role: .host)
        let client = makeDevice(displayName: "iPhone", role: .client)
        let hostB = makeDevice(displayName: "Mac B", role: .host)

        let hosts = SyncDeviceList.hosts(in: [client, hostA, hostB])
        #expect(hosts.count == 2)
        #expect(hosts.map(\.displayName) == ["Mac A", "Mac B"])
    }

    @Test("hosts：空列表/全 client 均返回空")
    func hostsFilterEmpty() {
        #expect(SyncDeviceList.hosts(in: []).isEmpty)
        #expect(SyncDeviceList.hosts(in: [makeDevice(role: .client)]).isEmpty)
    }

    @Test("shortIDText：合法全量 ID → 首组 … 末组")
    func shortIDTextFormat() {
        let device = makeDevice(role: .host)
        let text = SyncDeviceList.shortIDText(device)
        #expect(text == "ABCDEFG … 23")
    }

    @Test("shortIDText：非规范 ID → nil（展示层自行兜底）")
    func shortIDTextInvalidReturnsNil() {
        let device = makeDevice(peerID: "short-id", role: .host)
        #expect(SyncDeviceList.shortIDText(device) == nil)
    }

    @Test("displayName：空名（手输候选握手前）→ 未知设备占位文案")
    func displayNameFallback() {
        let device = makeDevice(displayName: "", role: .host)
        #expect(SyncDeviceList.displayName(device) == "sync_unknown_device".localized)
    }

    // MARK: - 失败原因 → 本地化 key

    @Test("全部 PairingFailure case 都有 sync_ 前缀本地化 key")
    func failureLocalizedKeyContract() {
        let failures: [PairingFailure] = [
            .invalidQRPayload("x"),
            .invalidDeviceID("x"),
            .invalidPublicKey,
            .fingerprintMismatch,
            .notAwaitingConfirmation,
        ]
        for failure in failures {
            let key = failure.localizedKey
            #expect(key.hasPrefix("sync_failure_"))
            #expect(!key.localized.isEmpty)
            #expect(key.localized != key, "本地化缺失：\(key) 原文泄漏")
        }
    }
}
