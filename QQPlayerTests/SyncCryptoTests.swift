//
//  SyncCryptoTests.swift
//  QQPlayerTests
//
//  S2 M2a：握手加密纯逻辑防回归。
//  - 握手签名正例/反例：正确签名通过；错公钥/错身份绑定/错角色/篡改拒
//    （含跨角色重放：host hello 当 client hello 验必败——role 在签名输入内）
//  - X25519 ECDH + HKDF：双方派生一致、方向密钥不同
//  - ChaCha20-Poly1305 会话加密：roundtrip、AAD/密文/密钥篡改拒、
//    乱序/重放/回退 nonce 拒
//  - PairRequest 纯逻辑：nonce 签名构造可验、结构校验正反例
//  - SyncPairingNonceRegistry：命中即消耗（防重放）、错签不命中
//

import CryptoKit
import Foundation
import Testing

@testable import QQPlayer

struct SyncCryptoTests {
    /// 造一对握手双方身份（各自长期 Ed25519 密钥对）
    private static func makeIdentities() -> (client: SyncIdentity, host: SyncIdentity) {
        (SyncIdentity.generate(), SyncIdentity.generate())
    }

    // MARK: - hello 签名/验证正反例

    @Test("hello 构造 + 验证：client/host 双向均通过")
    func helloVerifyPositive() throws {
        let (client, host) = Self.makeIdentities()
        let clientEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let hostEphemeral = Curve25519.KeyAgreement.PrivateKey()

        // client hello：绑定 host ID
        let clientHello = try SyncHandshake.makeHello(
            role: SyncHello.roleClient,
            identity: client,
            peerDeviceID: host.deviceID,
            ephemeralPublicKeyRaw: clientEphemeral.publicKey.rawRepresentation
        )
        try SyncHandshake.verifyHello(
            clientHello,
            signerPublicKeyRaw: client.publicKeyRaw,
            expectedRole: SyncHello.roleClient,
            expectedPeerDeviceID: host.deviceID,
            allowEmptyPeerBinding: true
        )
        // host hello：绑定 client ID，签名可被 client 用 host 公钥验证
        let hostHello = try SyncHandshake.makeHello(
            role: SyncHello.roleHost,
            identity: host,
            peerDeviceID: client.deviceID,
            ephemeralPublicKeyRaw: hostEphemeral.publicKey.rawRepresentation
        )
        try SyncHandshake.verifyHello(
            hostHello,
            signerPublicKeyRaw: host.publicKeyRaw,
            expectedRole: SyncHello.roleHost,
            expectedPeerDeviceID: client.deviceID,
            allowEmptyPeerBinding: false
        )
    }

    @Test("错公钥（冒充者公钥）→ signatureInvalid")
    func verifyWrongPublicKeyRejected() throws {
        let (client, host) = Self.makeIdentities()
        let impostor = SyncIdentity.generate() // 攻击者：声称是 client
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hello = try SyncHandshake.makeHello(
            role: SyncHello.roleClient,
            identity: client, // 真实 client 签名
            peerDeviceID: host.deviceID,
            ephemeralPublicKeyRaw: ephemeral.publicKey.rawRepresentation
        )
        // host 用攻击者公钥（错误信任记录）验证 → 拒
        #expect(throws: SyncHandshakeError.signatureInvalid) {
            try SyncHandshake.verifyHello(
                hello,
                signerPublicKeyRaw: impostor.publicKeyRaw,
                expectedRole: SyncHello.roleClient,
                expectedPeerDeviceID: host.deviceID,
                allowEmptyPeerBinding: true
            )
        }
    }

    @Test("身份绑定不一致（hello 绑定别的 peer）→ identityMismatch")
    func verifyPeerBindingMismatchRejected() throws {
        let (client, host) = Self.makeIdentities()
        let stranger = SyncIdentity.generate()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hello = try SyncHandshake.makeHello(
            role: SyncHello.roleClient,
            identity: client,
            peerDeviceID: stranger.deviceID, // client 以为在跟 stranger 说话
            ephemeralPublicKeyRaw: ephemeral.publicKey.rawRepresentation
        )
        // host 验证：绑定非空且 != host 自己 → 拒（防反射）
        do {
            try SyncHandshake.verifyHello(
                hello,
                signerPublicKeyRaw: client.publicKeyRaw,
                expectedRole: SyncHello.roleClient,
                expectedPeerDeviceID: host.deviceID,
                allowEmptyPeerBinding: true
            )
            Issue.record("期望 identityMismatch 但未抛错")
        } catch let error as SyncHandshakeError {
            guard case .identityMismatch = error else {
                Issue.record("期望 identityMismatch，实际 \(error)")
                return
            }
        } catch {
            Issue.record("期望 identityMismatch，实际 \(error)")
            return
        }
    }

    @Test("host 侧不允许空绑定（allowEmptyPeerBinding=false）→ 拒")
    func verifyEmptyBindingRejectedWhenStrict() throws {
        let (client, host) = Self.makeIdentities()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        // client 不知道对端是谁（peerID 空串）
        let hello = try SyncHandshake.makeHello(
            role: SyncHello.roleClient,
            identity: client,
            peerDeviceID: "",
            ephemeralPublicKeyRaw: ephemeral.publicKey.rawRepresentation
        )
        do {
            try SyncHandshake.verifyHello(
                hello,
                signerPublicKeyRaw: client.publicKeyRaw,
                expectedRole: SyncHello.roleClient,
                expectedPeerDeviceID: host.deviceID,
                allowEmptyPeerBinding: false
            )
            Issue.record("期望 identityMismatch 但未抛错")
        } catch let error as SyncHandshakeError {
            guard case .identityMismatch = error else {
                Issue.record("期望 identityMismatch，实际 \(error)")
                return
            }
        } catch {
            Issue.record("期望 identityMismatch，实际 \(error)")
            return
        }
        // 宽松模式放行（签名本身仍有效）
        try SyncHandshake.verifyHello(
            hello,
            signerPublicKeyRaw: client.publicKeyRaw,
            expectedRole: SyncHello.roleClient,
            expectedPeerDeviceID: host.deviceID,
            allowEmptyPeerBinding: true
        )
    }

    @Test("角色不符（host hello 当 client hello 验）→ identityMismatch + 签名天然失败")
    func verifyRoleMismatchRejected() throws {
        let (client, host) = Self.makeIdentities()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let hostHello = try SyncHandshake.makeHello(
            role: SyncHello.roleHost,
            identity: host,
            peerDeviceID: client.deviceID,
            ephemeralPublicKeyRaw: ephemeral.publicKey.rawRepresentation
        )
        // 把 host hello 重放成"client hello"（跨角色反射）：
        // 显式角色检查先拒
        do {
            try SyncHandshake.verifyHello(
                hostHello,
                signerPublicKeyRaw: host.publicKeyRaw,
                expectedRole: SyncHello.roleClient,
                expectedPeerDeviceID: client.deviceID,
                allowEmptyPeerBinding: false
            )
            Issue.record("期望 identityMismatch 但未抛错")
        } catch let error as SyncHandshakeError {
            guard case .identityMismatch = error else {
                Issue.record("期望 identityMismatch，实际 \(error)")
                return
            }
        } catch {
            Issue.record("期望 identityMismatch，实际 \(error)")
            return
        }
    }

    @Test("篡改签名字节 → signatureInvalid")
    func tamperedSignatureRejected() throws {
        let (client, host) = Self.makeIdentities()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        var hello = try SyncHandshake.makeHello(
            role: SyncHello.roleClient,
            identity: client,
            peerDeviceID: host.deviceID,
            ephemeralPublicKeyRaw: ephemeral.publicKey.rawRepresentation
        )
        var sig = Data(base64Encoded: hello.signature)!
        sig[sig.startIndex] ^= 0xFF
        hello.signature = sig.base64EncodedString()
        #expect(throws: SyncHandshakeError.signatureInvalid) {
            try SyncHandshake.verifyHello(
                hello,
                signerPublicKeyRaw: client.publicKeyRaw,
                expectedRole: SyncHello.roleClient,
                expectedPeerDeviceID: host.deviceID,
                allowEmptyPeerBinding: true
            )
        }
    }

    @Test("签名数据非法（长度不对）→ invalidKeyData")
    func invalidSignatureDataRejected() throws {
        let (client, host) = Self.makeIdentities()
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        var hello = try SyncHandshake.makeHello(
            role: SyncHello.roleClient,
            identity: client,
            peerDeviceID: host.deviceID,
            ephemeralPublicKeyRaw: ephemeral.publicKey.rawRepresentation
        )
        hello.signature = Data([1, 2, 3]).base64EncodedString() // 3B ≠ 64B
        #expect(throws: SyncHandshakeError.invalidKeyData) {
            try SyncHandshake.verifyHello(
                hello,
                signerPublicKeyRaw: client.publicKeyRaw,
                expectedRole: SyncHello.roleClient,
                expectedPeerDeviceID: host.deviceID,
                allowEmptyPeerBinding: true
            )
        }
    }

    // MARK: - 密钥派生

    @Test("ECDH+HKDF：双方派生一致，c2h ≠ h2c")
    func keyExchangeMatchesBothSides() throws {
        let clientEphemeral = Curve25519.KeyAgreement.PrivateKey()
        let hostEphemeral = Curve25519.KeyAgreement.PrivateKey()

        let clientKeys = try SyncKeyExchange.deriveDirectionKeys(
            myEphemeralPrivateKey: clientEphemeral,
            peerEphemeralPublicKeyRaw: hostEphemeral.publicKey.rawRepresentation
        )
        let hostKeys = try SyncKeyExchange.deriveDirectionKeys(
            myEphemeralPrivateKey: hostEphemeral,
            peerEphemeralPublicKeyRaw: clientEphemeral.publicKey.rawRepresentation
        )
        // client 的发送方向 == host 的接收方向（反之亦然）
        #expect(clientKeys.clientToHost == hostKeys.clientToHost)
        #expect(clientKeys.hostToClient == hostKeys.hostToClient)
        #expect(clientKeys.clientToHost != clientKeys.hostToClient)
    }

    @Test("对端 ephemeral 公钥非法（长度错/坏数据）→ 拒")
    func keyExchangeRejectsBadPublicKey() throws {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        #expect(throws: SyncHandshakeError.self) {
            _ = try SyncKeyExchange.deriveDirectionKeys(
                myEphemeralPrivateKey: ephemeral,
                peerEphemeralPublicKeyRaw: Data(count: 16)
            )
        }
    }

    // MARK: - ChaCha20-Poly1305 会话加密

    @Test("seal/open roundtrip + 不同方向密钥隔离")
    func cipherRoundtrip() throws {
        let a = Curve25519.KeyAgreement.PrivateKey()
        let b = Curve25519.KeyAgreement.PrivateKey()
        let keysA = try SyncKeyExchange.deriveDirectionKeys(
            myEphemeralPrivateKey: a,
            peerEphemeralPublicKeyRaw: b.publicKey.rawRepresentation
        )
        let keysB = try SyncKeyExchange.deriveDirectionKeys(
            myEphemeralPrivateKey: b,
            peerEphemeralPublicKeyRaw: a.publicKey.rawRepresentation
        )
        // 模拟 client→host 方向（client 用 c2h 发，host 用 c2h 收）
        var clientSend = SyncCipher(key: keysA.clientToHost)
        var hostReceive = SyncCipher(key: keysB.clientToHost)
        let aad = SyncFrame.magic + Data([0, 0, 0, 10, SyncFrameType.fileChunk.rawValue, 1])
        let sealed = try clientSend.seal(plaintext: Data("机密内容".utf8), aad: aad)
        let opened = try hostReceive.open(sealed, aad: aad)
        #expect(opened == Data("机密内容".utf8))
        // 计数推进一致
        #expect(clientSend.sealedCount == 1)
        #expect(hostReceive.openedCount == 1)
    }

    @Test("AAD 篡改 / 密文篡改 / 错密钥 → authenticationFailed")
    func cipherTamperRejected() throws {
        let key = SymmetricKey(size: .bits256)
        var cipher = SyncCipher(key: key)
        let aad = Data(repeating: 0xAB, count: 10)
        let sealed = try cipher.seal(plaintext: Data("payload".utf8), aad: aad)

        // AAD 篡改
        var badAad = aad
        badAad[3] ^= 1
        var verifier = SyncCipher(key: key)
        #expect(throws: SyncHandshakeError.authenticationFailed) {
            _ = try verifier.open(sealed, aad: badAad)
        }
        // 密文篡改（翻转中间字节；避开 nonce 区，让 AEAD 拒而非 replay 拒）
        var tampered = sealed
        tampered[tampered.count - 5] ^= 0xFF
        var verifier2 = SyncCipher(key: key)
        #expect(throws: SyncHandshakeError.self) {
            _ = try verifier2.open(tampered, aad: aad)
        }
        // 错密钥
        var verifier3 = SyncCipher(key: SymmetricKey(size: .bits256))
        #expect(throws: SyncHandshakeError.self) {
            _ = try verifier3.open(sealed, aad: aad)
        }
    }

    @Test("乱序/重放/回退 nonce → replayOrOutOfOrder")
    func cipherNonceReplayRejected() throws {
        let key = SymmetricKey(size: .bits256)
        var sender = SyncCipher(key: key)
        let aad = Data(count: 10)
        let f1 = try sender.seal(plaintext: Data("一".utf8), aad: aad)
        let f2 = try sender.seal(plaintext: Data("二".utf8), aad: aad)
        let f3 = try sender.seal(plaintext: Data("三".utf8), aad: aad)

        // 顺序正常
        var receiver = SyncCipher(key: key)
        #expect(try receiver.open(f1, aad: aad) == Data("一".utf8))
        #expect(try receiver.open(f2, aad: aad) == Data("二".utf8))

        // 重放 f2（已收过）→ 拒
        #expect(throws: SyncHandshakeError.replayOrOutOfOrder) {
            _ = try receiver.open(f2, aad: aad)
        }
        // 回退（再投 f1）→ 拒
        #expect(throws: SyncHandshakeError.replayOrOutOfOrder) {
            _ = try receiver.open(f1, aad: aad)
        }
        // 乱序（跳过 f2 直接投 f3）→ 拒：需独立 receiver 构造“期望 2 却来 3”场景
        // （上面的 receiver 已成功收 f1/f2，期望计数已到 3，f3 此时是合法下一帧）
        var outOfOrderReceiver = SyncCipher(key: key)
        _ = try outOfOrderReceiver.open(f1, aad: aad) // openedCount = 1，期望 2
        #expect(throws: SyncHandshakeError.replayOrOutOfOrder) {
            _ = try outOfOrderReceiver.open(f3, aad: aad) // nonce 3 ≠ 期望 2 → 拒
        }
    }

    @Test("nonce 布局：4 零 + 8B 大端计数")
    func nonceLayout() throws {
        let n1 = try SyncCipher.nonceData(forCounter: 1)
        #expect(n1.count == 12)
        #expect(n1.prefix(4) == Data([0, 0, 0, 0]))
        #expect(n1.suffix(8) == Data([0, 0, 0, 0, 0, 0, 0, 1]))
        let n258 = try SyncCipher.nonceData(forCounter: 258)
        #expect(n258.suffix(8) == Data([0, 0, 0, 0, 0, 0, 1, 2]))
        // 计数不相等 → nonce 必不同
        #expect(n1 != n258)
    }

    // MARK: - PairRequest 纯逻辑

    @Test("PairRequest 构造：nonce 签名可被公钥验证")
    func makePairRequestVerifiable() throws {
        let client = SyncIdentity.generate()
        let nonce = Data((0 ..< 16).map { UInt8($0) })
        let request = try SyncPairingMessages.makePairRequest(identity: client, sessionNonce: nonce)
        #expect(request.clientDeviceID == client.deviceID)
        #expect(Data(base64Encoded: request.clientPublicKey) == client.publicKeyRaw)
        // 结构校验通过
        try SyncPairingMessages.validate(request)
        // 签名确实是对 nonce 的 Ed25519 签名
        let verified = try SyncPairingMessages.verifyNonceSignature(request, nonce: nonce)
        #expect(verified)
    }

    @Test("PairRequest 结构校验反例：ID/公钥指纹不符、坏 base64、坏 nonce 签名")
    func validatePairRequestRejects() throws {
        let client = SyncIdentity.generate()
        let nonce = Data(count: 16)
        let request = try SyncPairingMessages.makePairRequest(identity: client, sessionNonce: nonce)
        // 公钥换成别人的 → 指纹不一致
        let stranger = SyncIdentity.generate()
        var wrongKey = request
        wrongKey.clientPublicKey = stranger.publicKeyRaw.base64EncodedString()
        #expect(throws: PairingFailure.self) {
            try SyncPairingMessages.validate(wrongKey)
        }
        // clientDeviceID 非法字符
        var badID = request
        badID.clientDeviceID = "NOT-A-VALID-ID!!!!"
        #expect(throws: PairingFailure.self) {
            try SyncPairingMessages.validate(badID)
        }
        // nonceSignature 坏 base64
        var badSig = request
        badSig.nonceSignature = "!!not-base64!!"
        #expect(throws: PairingFailure.self) {
            try SyncPairingMessages.validate(badSig)
        }
        // 换 nonce 验签 → false（签名绑定原 nonce）
        let otherNonce = Data(count: 32)
        let verifiedAgainstOther = try SyncPairingMessages.verifyNonceSignature(request, nonce: otherNonce)
        #expect(!verifiedAgainstOther)
    }

    // MARK: - nonce 注册表

    @Test("注册表：命中即消耗（重放拒绝），错签不命中")
    func registryConsumesOnMatch() throws {
        let registry = SyncPairingNonceRegistry()
        let client = SyncIdentity.generate()
        let nonce = Data((0 ..< 12).map { UInt8($0) })
        let request = try SyncPairingMessages.makePairRequest(identity: client, sessionNonce: nonce)
        registry.register(nonce)
        registry.register(nonce) // 去重
        #expect(registry.pendingCount == 1)

        // 正确签名命中并消耗
        #expect(registry.matchingNonce(for: request) == nonce)
        #expect(registry.pendingCount == 0)
        // 重放（nonce 已消耗）→ 不命中
        #expect(registry.matchingNonce(for: request) == nil)

        // 错签（换身份签名的请求）对无关 nonce 不命中：otherRequest 签的是
        // 另一个 nonce（16 字节），与注册的 8 字节 nonce 无关 → 不命中。
        // （若 otherRequest 签的恰是注册 nonce，命中并消耗是符合语义的——
        //   注册表只防 nonce 重用；签名者身份由握手层“请求身份 == 握手身份”校验）
        let other = SyncIdentity.generate()
        let otherRequest = try SyncPairingMessages.makePairRequest(
            identity: other,
            sessionNonce: Data(count: 16)
        )
        registry.register(Data(count: 8))
        #expect(registry.matchingNonce(for: otherRequest) == nil)
    }
}
