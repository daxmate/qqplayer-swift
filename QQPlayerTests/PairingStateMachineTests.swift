//
//  PairingStateMachineTests.swift
//  QQPlayerTests
//
//  配对状态机（S2, M1）纯逻辑全面防回归：
//    正常流（QR 扫码确认 / Host 批准）/ 重复配对替换路径 / nonce 过期 /
//    校验失败（版本/ID/公钥/nonce/指纹）/ 拒绝 / 取消 / 机器复用。
//  时间全部注入（TimeInterval），无 IO、无真实时钟，确定性测试。
//

import CryptoKit
import Foundation
import Testing

@testable import QQPlayer

struct PairingStateMachineTests {
    // MARK: - Fixtures

    /// 合法 QR 载荷（随机密钥 + 随机 nonce）
    private func makePayload(
        key: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey(),
        hostName: String = "MacBook Pro",
        nonce: Data = Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }),
        protoVersion: Int = SyncProtocolVersion.current
    ) -> PairQRPayload {
        PairQRPayload(
            protoVersion: protoVersion,
            hostName: hostName,
            deviceID: DeviceID.make(fromPublicKey: key.publicKey),
            publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
            sessionNonce: nonce.base64EncodedString()
        )
    }

    // MARK: - 正常流（QR 扫码）

    @Test("扫码合法 QR → awaitingConfirmation，候选字段完整")
    mutating func qrScanEntersAwaiting() {
        let key = Curve25519.Signing.PrivateKey()
        let nonce = Data((0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) })
        let payload = makePayload(key: key, hostName: "Mac Studio", nonce: nonce)

        var machine = PairingStateMachine(nonceTTL: 300)
        machine.handle(.receivedQR(payload, at: 1_000, alreadyPaired: false))

        guard case let .awaitingConfirmation(candidate) = machine.state else {
            Issue.record("应为 awaitingConfirmation，实际 \(machine.state)")
            return
        }
        #expect(candidate.deviceID == DeviceID.make(fromPublicKey: key.publicKey))
        #expect(candidate.displayName == "Mac Studio")
        #expect(candidate.publicKeyRaw == key.publicKey.rawRepresentation)
        #expect(candidate.sessionNonce == nonce)
        #expect(candidate.source == .qr)
        #expect(candidate.receivedAt == 1_000)
        #expect(!candidate.isReplacement)
    }

    @Test("Client 确认（TTL 内）→ approved")
    mutating func clientConfirmApproves() {
        let payload = makePayload()
        var machine = PairingStateMachine(nonceTTL: 300)
        machine.handle(.receivedQR(payload, at: 1_000, alreadyPaired: false))

        machine.handle(.userConfirmedOnClient(at: 1_010))

        guard case let .approved(candidate) = machine.state else {
            Issue.record("应为 approved，实际 \(machine.state)")
            return
        }
        #expect(candidate.deviceID == DeviceID.normalized(payload.deviceID))
    }

    @Test("Host 批准（TTL 内）→ approved")
    mutating func hostApprovalApproves() {
        let payload = makePayload(hostName: "iPhone")
        var machine = PairingStateMachine(nonceTTL: 300)
        machine.handle(.receivedQR(payload, at: 2_000, alreadyPaired: false))

        machine.handle(.userApprovedOnHost(at: 2_005))

        if case let .approved(candidate) = machine.state {
            #expect(candidate.displayName == "iPhone")
        } else {
            Issue.record("应为 approved，实际 \(machine.state)")
        }
    }

    // MARK: - nonce 过期

    @Test("确认在 TTL 边界内 → approved；超过 → expired")
    mutating func confirmBoundaryAndExpiry() {
        // 边界：now - receivedAt == TTL → 未过期，批准
        var machine = PairingStateMachine(nonceTTL: 300)
        machine.handle(.receivedQR(makePayload(), at: 1_000, alreadyPaired: false))
        machine.handle(.userConfirmedOnClient(at: 1_300))
        if case let .approved(candidate) = machine.state {
            #expect(candidate.receivedAt == 1_000)
        } else {
            Issue.record("TTL 边界内应 approved，实际 \(machine.state)")
        }

        // 超过 TTL → expired
        var machine2 = PairingStateMachine(nonceTTL: 300)
        machine2.handle(.receivedQR(makePayload(), at: 1_000, alreadyPaired: false))
        machine2.handle(.userConfirmedOnClient(at: 1_301))
        if case let .expired(candidate) = machine2.state {
            #expect(candidate.receivedAt == 1_000)
        } else {
            Issue.record("超过 TTL 应 expired，实际 \(machine2.state)")
        }
    }

    @Test("nonce 过期：确认超过 TTL → expired 且携带候选")
    mutating func expiredOnLateConfirm() {
        var machine = PairingStateMachine(nonceTTL: 300)
        let payload = makePayload()
        machine.handle(.receivedQR(payload, at: 1_000, alreadyPaired: false))

        machine.handle(.userConfirmedOnClient(at: 1_301))

        guard case let .expired(candidate) = machine.state else {
            Issue.record("应为 expired，实际 \(machine.state)")
            return
        }
        #expect(candidate.deviceID == DeviceID.normalized(payload.deviceID))
    }

    @Test("expireCheck：未超时保持 awaiting，超时转 expired")
    mutating func expireCheckTransitions() {
        var machine = PairingStateMachine(nonceTTL: 60)
        machine.handle(.receivedQR(makePayload(), at: 100, alreadyPaired: false))

        machine.handle(.expireCheck(at: 159)) // 59s < 60s
        #expect(machine.isAwaitingConfirmation)

        machine.handle(.expireCheck(at: 161)) // 61s > 60s
        if case let .expired(candidate) = machine.state {
            #expect(candidate.receivedAt == 100)
        } else {
            Issue.record("应为 expired，实际 \(machine.state)")
        }
    }

    // MARK: - 校验失败

    @Test("QR 指纹不一致 → failed(.fingerprintMismatch)")
    mutating func fingerprintMismatchFails() {
        let payloadKey = Curve25519.Signing.PrivateKey()
        let otherKey = Curve25519.Signing.PrivateKey()
        let payload = makePayload(key: payloadKey) // deviceID 属 payloadKey
        // 换成另一把公钥，deviceID 与指纹必然不一致
        let tampered = PairQRPayload(
            protoVersion: payload.protoVersion,
            hostName: payload.hostName,
            deviceID: payload.deviceID,
            publicKey: otherKey.publicKey.rawRepresentation.base64EncodedString(),
            sessionNonce: payload.sessionNonce
        )

        var machine = PairingStateMachine()
        machine.handle(.receivedQR(tampered, at: 1_000, alreadyPaired: false))

        #expect(machine.state == .failed(.fingerprintMismatch))
    }

    @Test("QR 载荷 deviceID 非法 → failed(.invalidDeviceID)")
    mutating func qrInvalidDeviceIDFails() {
        let key = Curve25519.Signing.PrivateKey()
        let payload = PairQRPayload(
            protoVersion: SyncProtocolVersion.current,
            hostName: "H",
            deviceID: "not-a-valid-id",
            publicKey: key.publicKey.rawRepresentation.base64EncodedString(),
            sessionNonce: Data([1]).base64EncodedString()
        )

        var machine = PairingStateMachine()
        machine.handle(.receivedQR(payload, at: 1_000, alreadyPaired: false))

        #expect(machine.state == .failed(.invalidDeviceID("not-a-valid-id")))
    }

    @Test("QR 载荷公钥非法（非 base64 / 长度非 32B）→ failed(.invalidPublicKey)")
    mutating func qrInvalidPublicKeyFails() {
        let key = Curve25519.Signing.PrivateKey()
        let id = DeviceID.make(fromPublicKey: key.publicKey)

        // 非 base64
        let badEncoding = PairQRPayload(
            protoVersion: SyncProtocolVersion.current, hostName: "H",
            deviceID: id, publicKey: "!!!not-base64!!!",
            sessionNonce: Data([1]).base64EncodedString()
        )
        var machine = PairingStateMachine()
        machine.handle(.receivedQR(badEncoding, at: 1_000, alreadyPaired: false))
        #expect(machine.state == .failed(.invalidPublicKey))

        // base64 合法但长度非 32B（16 字节）
        let wrongLength = PairQRPayload(
            protoVersion: SyncProtocolVersion.current, hostName: "H",
            deviceID: id, publicKey: Data(repeating: 0, count: 16).base64EncodedString(),
            sessionNonce: Data([1]).base64EncodedString()
        )
        var machine2 = PairingStateMachine()
        machine2.handle(.receivedQR(wrongLength, at: 1_000, alreadyPaired: false))
        #expect(machine2.state == .failed(.invalidPublicKey))
    }

    @Test("QR 载荷 nonce 非法 / 协议版本不符 → failed(.invalidQRPayload)")
    mutating func qrInvalidNonceOrVersionFails() {
        let key = Curve25519.Signing.PrivateKey()
        let id = DeviceID.make(fromPublicKey: key.publicKey)
        let pubB64 = key.publicKey.rawRepresentation.base64EncodedString()

        // nonce 非 base64
        var machine = PairingStateMachine()
        machine.handle(.receivedQR(PairQRPayload(
            protoVersion: SyncProtocolVersion.current, hostName: "H",
            deviceID: id, publicKey: pubB64, sessionNonce: "!!"
        ), at: 1_000, alreadyPaired: false))
        if case .failed(.invalidQRPayload) = machine.state {} else {
            Issue.record("应为 invalidQRPayload，实际 \(machine.state)")
        }

        // 协议版本超前
        var machine2 = PairingStateMachine()
        machine2.handle(.receivedQR(makePayload(protoVersion: SyncProtocolVersion.current + 1), at: 1_000, alreadyPaired: false))
        if case .failed(.invalidQRPayload) = machine2.state {} else {
            Issue.record("应为 invalidQRPayload（版本），实际 \(machine2.state)")
        }
    }

    // MARK: - 手输路径

    @Test("手输合法 ID → awaiting（无公钥/nonce，source=manualInput）")
    mutating func manualEntryAwaiting() {
        let key = Curve25519.Signing.PrivateKey()
        let canonical = DeviceID.make(fromPublicKey: key.publicKey)

        var machine = PairingStateMachine()
        machine.handle(.manualIDEntered(canonical, at: 1_000, alreadyPaired: false))

        guard case let .awaitingConfirmation(candidate) = machine.state else {
            Issue.record("应为 awaitingConfirmation，实际 \(machine.state)")
            return
        }
        #expect(candidate.deviceID == canonical)
        #expect(candidate.publicKeyRaw == nil)
        #expect(candidate.sessionNonce == nil)
        #expect(candidate.source == .manualInput)
        #expect(candidate.displayName.isEmpty)
    }

    @Test("手输展示格式（分隔符/小写）自动规范化")
    mutating func manualEntryNormalizesDisplayFormat() {
        let canonical = DeviceID.make(fromPublicKey: Curve25519.Signing.PrivateKey().publicKey)
        let formattedLower = DeviceID.formatted(canonical).lowercased()

        var machine = PairingStateMachine()
        machine.handle(.manualIDEntered(formattedLower, at: 1_000, alreadyPaired: false))

        guard case let .awaitingConfirmation(candidate) = machine.state else {
            Issue.record("应为 awaitingConfirmation，实际 \(machine.state)")
            return
        }
        #expect(candidate.deviceID == canonical)
    }

    @Test("手输非法 ID → failed(.invalidDeviceID)")
    mutating func manualEntryInvalidFails() {
        var machine = PairingStateMachine()
        machine.handle(.manualIDEntered("WAY-TOO-SHORT", at: 1_000, alreadyPaired: false))
        #expect(machine.state == .failed(.invalidDeviceID("WAY-TOO-SHORT")))

        var machine2 = PairingStateMachine()
        machine2.handle(.manualIDEntered("", at: 1_000, alreadyPaired: false))
        #expect(machine2.state == .failed(.invalidDeviceID("")))
    }

    @Test("手输路径确认后也可批准（TTL 计时同 QR）")
    mutating func manualEntryConfirmApproves() {
        let canonical = DeviceID.make(fromPublicKey: Curve25519.Signing.PrivateKey().publicKey)
        var machine = PairingStateMachine(nonceTTL: 300)
        machine.handle(.manualIDEntered(canonical, at: 5_000, alreadyPaired: false))

        machine.handle(.userConfirmedOnClient(at: 5_100))
        guard case let .approved(candidate) = machine.state else {
            Issue.record("应为 approved，实际 \(machine.state)")
            return
        }
        #expect(candidate.deviceID == canonical)
        #expect(candidate.publicKeyRaw == nil)
    }

    // MARK: - 拒绝 / 取消 / 无候选事件

    @Test("用户拒绝 → rejected 携带候选")
    mutating func rejectTransitions() {
        var machine = PairingStateMachine()
        let payload = makePayload(hostName: "拒绝我")
        machine.handle(.receivedQR(payload, at: 1_000, alreadyPaired: false))

        machine.handle(.reject)

        guard case let .rejected(candidate) = machine.state else {
            Issue.record("应为 rejected，实际 \(machine.state)")
            return
        }
        #expect(candidate.displayName == "拒绝我")
    }

    @Test("取消 → 回 idle（无候选时 cancel 无操作）")
    mutating func cancelResetsToIdle() {
        var machine = PairingStateMachine()
        machine.handle(.receivedQR(makePayload(), at: 1_000, alreadyPaired: false))
        #expect(machine.isAwaitingConfirmation)

        machine.handle(.cancel)
        #expect(machine.state == .idle)

        // idle 下 cancel/reject/expireCheck 均无操作
        machine.handle(.cancel)
        machine.handle(.reject)
        machine.handle(.expireCheck(at: 9_999))
        #expect(machine.state == .idle)
    }

    @Test("无候选（idle）时确认/批准 → failed(.notAwaitingConfirmation)")
    mutating func confirmWhileIdleFails() {
        var machine = PairingStateMachine()
        machine.handle(.userConfirmedOnClient(at: 1_000))
        #expect(machine.state == .failed(.notAwaitingConfirmation))

        var machine2 = PairingStateMachine()
        machine2.handle(.userApprovedOnHost(at: 1_000))
        #expect(machine2.state == .failed(.notAwaitingConfirmation))
    }

    @Test("终态后再收新 QR → 重新开始（机器可复用）")
    mutating func machineReusableAfterTerminal() {
        var machine = PairingStateMachine()
        // 指纹失败终态：换公钥但 deviceID 未变
        var tampered = makePayload(hostName: "坏")
        tampered.publicKey = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        machine.handle(.receivedQR(tampered, at: 100, alreadyPaired: false))
        #expect(machine.state == .failed(.fingerprintMismatch))

        // 再来一把好 QR → awaiting
        machine.handle(.receivedQR(makePayload(hostName: "好"), at: 200, alreadyPaired: false))
        guard case let .awaitingConfirmation(candidate) = machine.state else {
            Issue.record("终态后应可复用，实际 \(machine.state)")
            return
        }
        #expect(candidate.displayName == "好")
    }

    // MARK: - 重复配对（替换确认路径）

    @Test("重复配对（同 peerID 已存在）→ awaiting 且 isReplacement=true，批准后仍带标记")
    mutating func duplicatePairingReplacementPath() {
        var machine = PairingStateMachine(nonceTTL: 300)
        let payload = makePayload(hostName: "已配对设备")
        machine.handle(.receivedQR(payload, at: 1_000, alreadyPaired: true))

        guard case let .awaitingConfirmation(candidate) = machine.state else {
            Issue.record("应为 awaitingConfirmation，实际 \(machine.state)")
            return
        }
        #expect(candidate.isReplacement)

        // 替换路径仍需用户显式确认：拒绝可中止
        machine.handle(.reject)
        #expect(machine.state == .rejected(candidate))

        // 重走替换路径并批准 → approved 携带 isReplacement 标记（落库 = upsert 替换）
        var machine2 = PairingStateMachine(nonceTTL: 300)
        machine2.handle(.receivedQR(payload, at: 1_000, alreadyPaired: true))
        machine2.handle(.userConfirmedOnClient(at: 1_010))
        guard case let .approved(approvedCandidate) = machine2.state else {
            Issue.record("应为 approved，实际 \(machine2.state)")
            return
        }
        #expect(approvedCandidate.isReplacement)
    }

    @Test("首次配对（未配对过）→ isReplacement=false")
    mutating func firstPairingNotReplacement() {
        var machine = PairingStateMachine()
        machine.handle(.receivedQR(makePayload(), at: 1_000, alreadyPaired: false))
        guard case let .awaitingConfirmation(candidate) = machine.state else { return }
        #expect(!candidate.isReplacement)
    }

    // MARK: - 候选 → 配对记录

    @Test("QR 候选构造 PeerDevice：字段完整映射（含 role/pairedAt）")
    mutating func peerDeviceFromQRCandidate() {
        let key = Curve25519.Signing.PrivateKey()
        let payload = makePayload(key: key, hostName: "Mac Studio")
        var machine = PairingStateMachine()
        machine.handle(.receivedQR(payload, at: 1_000, alreadyPaired: false))
        machine.handle(.userConfirmedOnClient(at: 1_010))
        guard case let .approved(candidate) = machine.state else {
            Issue.record("应为 approved，实际 \(machine.state)")
            return
        }

        let device = PeerDevice(candidate: candidate, role: .client, pairedAt: 1_010, notes: "客厅")
        #expect(device.peerID == candidate.deviceID)
        #expect(device.peerPublicKey == key.publicKey.rawRepresentation.base64EncodedString())
        #expect(device.displayName == "Mac Studio")
        #expect(device.role == .client)
        #expect(device.pairedAt == 1_010)
        #expect(device.lastSeenAt == 1_010)
        #expect(device.notes == "客厅")
    }

    @Test("手输候选构造 PeerDevice：公钥待补（空串占位，防未 pinning 记录落库前被识别）")
    mutating func peerDeviceFromManualCandidate() {
        let canonical = DeviceID.make(fromPublicKey: Curve25519.Signing.PrivateKey().publicKey)
        var machine = PairingStateMachine()
        machine.handle(.manualIDEntered(canonical, at: 1_000, alreadyPaired: false))
        machine.handle(.userApprovedOnHost(at: 1_010))
        guard case let .approved(candidate) = machine.state else {
            Issue.record("应为 approved，实际 \(machine.state)")
            return
        }

        let device = PeerDevice(candidate: candidate, role: .host, pairedAt: 1_010)
        #expect(device.peerID == canonical)
        #expect(device.peerPublicKey.isEmpty) // M2 握手响应补全
        #expect(device.role == .host)
    }
}
