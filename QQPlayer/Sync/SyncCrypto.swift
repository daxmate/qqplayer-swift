//
//  SyncCrypto.swift
//  QQPlayer
//
//  局域网同步（S2, M2a）握手与会话加密——纯 CryptoKit，无证书（相对
//  docs/lan-sync-design.md §5 的 TLS+自签证书方案改用 HomeKit 同款
//  应用层加密，见任务包设计定案）：
//
//  握手（连接建立后、业务帧前，type=0 明文帧内交换 SyncHello）：
//    1. 双方各生成 ephemeral X25519 密钥对
//    2. 交换 SyncHello：ephemeral 公钥 + 各自 Ed25519 长期签名
//       sig = sign(ephemeralPub ‖ peerDeviceID ‖ role)
//       - peerDeviceID：签名方"以为在跟谁说话"的 Device ID（防反射/防错连）；
//         client 首连未知时可为空串（配对路径由 QR nonce 签名另行认证）
//       - role ∈ {"client","host"}：绑定方向，防跨角色重放
//    3. 各自验证：对端签名有效（用配对记录里对端 Ed25519 公钥 pinning）；
//       对端 peerDeviceID 绑定校验：非空时必须 == 本端 Device ID
//    4. X25519 ECDH → HKDF-SHA256 → 双向 ChaCha20-Poly1305 会话密钥
//       （client→host / host→client 各一；AAD = 帧头）
//
//  帧加密：ChaCha20-Poly1305，12B nonce = 4 零 + 8B 大端递增计数器
//  （方向独立计数）；CryptoKit 的 ChaChaPoly.SealedBox.combined 内嵌
//  nonce（nonce‖ciphertext‖tag），收方先比对 nonce == 期望值再解密，
//  乱序/重放/计数回退一律拒（.replayOrOutOfOrder）。
//
//  协议注入：本文件全部为纯逻辑/值类型，握手双方身份、信任表由调用方
//  （SyncPeerSession）注入，单测直接覆盖正反例。
//

import CryptoKit
import Foundation

// MARK: - 错误

/// 握手/会话加密错误。
enum SyncHandshakeError: Error, Equatable, Sendable {
    /// 载荷结构损坏（JSON/base64/字段非法，附原因）
    case invalidMessage(String)
    /// 公钥/签名数据无法解码或长度不对
    case invalidKeyData
    /// Ed25519 签名验证失败（对端不持有其声称的私钥）
    case signatureInvalid
    /// 身份绑定不一致（对端 hello.peerDeviceID 非空且 ≠ 本端 ID / 角色不符）——防反射
    case identityMismatch(String)
    /// 握手超时（对端 hello/配对答复未在期限内到达）
    case handshakeTimeout
    /// 会话密钥派生失败（对端 ephemeral 公钥非法）
    case keyAgreementFailed
    /// AEAD 认证失败（密文被篡改/密钥不符）
    case authenticationFailed
    /// nonce 乱序/重放/回退（期望计数对不上）
    case replayOrOutOfOrder
}

// MARK: - 握手消息

/// 握手 hello 消息（type=0 帧 payload 的 JSON 形态；字段全量值，
/// 二进制经 standard base64——与 M1 PairingModels 同约定）。
struct SyncHello: Codable, Equatable, Sendable {
    /// 签名方角色（client = 连接发起方）
    static let roleClient = "client"
    /// 签名方角色（host = 服务方）
    static let roleHost = "host"

    /// 签名方角色：client / host
    var role: String
    /// 签名方长期 Device ID（全量 base32，52 字符）
    var deviceID: String
    /// 签名方"以为在跟谁说话"的 Device ID（空串 = 未知；host hello 恒为 client ID）
    var peerDeviceID: String
    /// ephemeral X25519 公钥 raw（32B）base64
    var ephemeralPublicKey: String
    /// Ed25519 签名（64B）base64，输入 = ephemeralPub ‖ peerDeviceID ‖ role
    var signature: String
    /// 发送方展示名（本机设备名，如 "dax's iPhone"）。
    /// **纯展示、不参与签名**（签名输入只含 ephemeralPub ‖ peerDeviceID ‖ role）：
    /// 篡改名字不会破坏验签，只影响对端展示/落库的 display_name——
    /// 语义与 `PairRequest.clientName` 一致（Host 落库展示用）。
    /// 旧端无该字段 → 解码得 nil（合成的 Codable 用 decodeIfPresent），语义 = 不带名。
    var name: String?

    /// ephemeral 公钥 raw（解码失败返回 nil）
    var ephemeralPublicKeyRaw: Data? {
        Data(base64Encoded: ephemeralPublicKey)
    }
}

// MARK: - 握手纯逻辑

/// 握手纯逻辑（签名构造/验证/密钥派生；无 IO、无状态，单测全覆盖）。
enum SyncHandshake {
    /// 签名输入 = ephemeralPub(32B) ‖ peerDeviceID(utf8) ‖ role(utf8)
    static func signingInput(ephemeralPublicKeyRaw: Data, peerDeviceID: String, role: String) -> Data {
        var input = Data()
        input.append(ephemeralPublicKeyRaw)
        input.append(Data(peerDeviceID.utf8))
        input.append(Data(role.utf8))
        return input
    }

    /// 构造本方 hello（role 决定方向语义；deviceID = identity 的 ID）。
    /// peerDeviceID 传"签名方以为的对端 ID"（host 必须传 client ID；client
    /// 已配对/扫码路径传 host ID，未知可传空串）。
    /// name：本机展示名（两端都可带；纯展示、不进签名输入，nil = 不带名）。
    static func makeHello(
        role: String,
        identity: SyncIdentity,
        peerDeviceID: String,
        ephemeralPublicKeyRaw: Data,
        name: String? = nil
    ) throws -> SyncHello {
        guard ephemeralPublicKeyRaw.count == 32 else {
            throw SyncHandshakeError.invalidKeyData
        }
        let input = signingInput(
            ephemeralPublicKeyRaw: ephemeralPublicKeyRaw,
            peerDeviceID: peerDeviceID,
            role: role
        )
        let signature = try identity.signingKey().signature(for: input)
        return SyncHello(
            role: role,
            deviceID: identity.deviceID,
            peerDeviceID: peerDeviceID,
            ephemeralPublicKey: ephemeralPublicKeyRaw.base64EncodedString(),
            signature: signature.base64EncodedString(),
            name: name
        )
    }

    /// 验证对端 hello：
    /// - role / deviceID / 数据形态合法性
    /// - 签名有效性（signerPublicKeyRaw = 配对记录里的对端长期公钥，TOFU pinning）
    /// - 绑定检查：expectedRole 须与 hello.role 一致（跨角色重放即败）；
    ///   expectedPeerDeviceID（本端 ID）非空时，hello.peerDeviceID 若非空必须相等，
    ///   allowEmptyPeerBinding=true 允许对端空绑定（首连未知场景）
    static func verifyHello(
        _ hello: SyncHello,
        signerPublicKeyRaw: Data,
        expectedRole: String,
        expectedPeerDeviceID: String,
        allowEmptyPeerBinding: Bool
    ) throws {
        guard hello.role == expectedRole else {
            throw SyncHandshakeError.identityMismatch("角色不符：收到 \(hello.role)，期望 \(expectedRole)")
        }
        guard signerPublicKeyRaw.count == 32 else {
            throw SyncHandshakeError.invalidKeyData
        }
        guard let ephemeralRaw = hello.ephemeralPublicKeyRaw, ephemeralRaw.count == 32,
              let signature = Data(base64Encoded: hello.signature), signature.count == 64
        else {
            throw SyncHandshakeError.invalidKeyData
        }
        // 身份绑定（防反射核心）：对端声明在与"谁"握手
        if !hello.peerDeviceID.isEmpty, hello.peerDeviceID != expectedPeerDeviceID {
            throw SyncHandshakeError.identityMismatch(
                "对端绑定 \(hello.peerDeviceID)，本端为 \(expectedPeerDeviceID)"
            )
        }
        if hello.peerDeviceID.isEmpty, !allowEmptyPeerBinding {
            throw SyncHandshakeError.identityMismatch("对端未绑定本端身份（peerDeviceID 为空）")
        }
        // 签名覆盖 ephemeral + peerID + role；用配对公钥 pinning 验证
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: signerPublicKeyRaw)
        let input = signingInput(
            ephemeralPublicKeyRaw: ephemeralRaw,
            peerDeviceID: hello.peerDeviceID,
            role: hello.role
        )
        guard publicKey.isValidSignature(signature, for: input) else {
            throw SyncHandshakeError.signatureInvalid
        }
    }

    /// 校验签名输入里的设备 ID 形态是否合法（结构层校验，供会话在
    /// 无法验证签名前先拦截垃圾输入）。
    static func isValidDeviceID(_ deviceID: String) -> Bool {
        DeviceID.normalized(deviceID) != nil
    }
}

// MARK: - 会话密钥派生

/// 双向会话密钥（client→host 与 host→client 各一 32B ChaCha20-Poly1305 密钥）。
struct SyncDirectionKeys: Equatable, Sendable {
    let clientToHost: SymmetricKey
    let hostToClient: SymmetricKey
}

/// X25519 ECDH + HKDF-SHA256 派生。
enum SyncKeyExchange {
    private static let masterInfo = "qqplayer-sync/v1/master"
    private static let c2hInfo = "qqplayer-sync/v1/dir/c2h"
    private static let h2cInfo = "qqplayer-sync/v1/dir/h2c"

    /// 双方各持 (本方 ephemeral 私钥, 对端 hello 里的 ephemeral 公钥) 调用本函数，
    /// 得到同一组方向密钥（Diffie-Hellman 对称性由 CryptoKit 保证，测试锁定）。
    static func deriveDirectionKeys(
        myEphemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        peerEphemeralPublicKeyRaw: Data
    ) throws -> SyncDirectionKeys {
        guard peerEphemeralPublicKeyRaw.count == 32 else {
            throw SyncHandshakeError.invalidKeyData
        }
        let peerPublicKey: Curve25519.KeyAgreement.PublicKey
        do {
            peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeralPublicKeyRaw)
        } catch {
            throw SyncHandshakeError.keyAgreementFailed
        }
        let shared: SharedSecret
        do {
            shared = try myEphemeralPrivateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        } catch {
            throw SyncHandshakeError.keyAgreementFailed
        }
        let master = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(masterInfo.utf8),
            outputByteCount: 32
        )
        let c2h = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master,
            salt: Data(),
            info: Data(c2hInfo.utf8),
            outputByteCount: 32
        )
        let h2c = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: master,
            salt: Data(),
            info: Data(h2cInfo.utf8),
            outputByteCount: 32
        )
        return SyncDirectionKeys(clientToHost: c2h, hostToClient: h2c)
    }
}

// MARK: - 会话加密（ChaCha20-Poly1305 + 方向 nonce 计数）

/// 单向 ChaCha20-Poly1305 会话加密器（值类型；发送/接收各持一个实例，
/// 由 SyncPeerSession 在锁内使用，nonce 方向独立递增）。
///
/// nonce 布局：12B = 4B 零前缀 ‖ 8B 大端计数器（首帧 counter=1）。
/// ChaChaPoly.SealedBox.combined = nonce‖ciphertext‖tag（nonce 内嵌线上）。
/// 收方先校验内嵌 nonce == 期望计数再解密：乱序/重放/回退 → .replayOrOutOfOrder。
struct SyncCipher {
    private let key: SymmetricKey
    /// 已加密帧数（下一帧 counter = sealedCount + 1）
    private(set) var sealedCount: UInt64 = 0
    /// 已解密帧数（下一帧期望 counter = openedCount + 1）
    private(set) var openedCount: UInt64 = 0

    init(key: SymmetricKey) {
        self.key = key
    }

    /// counter → 12B nonce（4 零 + 8B 大端）。
    static func nonceData(forCounter counter: UInt64) throws -> Data {
        var data = Data(count: 4)
        var bigEndian = counter.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
        return data
    }

    /// 加密（AAD = 帧头 10B，见 SyncPeerSession 组装）。返回可直接写入
    /// 帧 payload 的 combined（nonce‖ct‖tag）。
    mutating func seal(plaintext: Data, aad: Data) throws -> Data {
        let counter = sealedCount + 1
        let nonce = try ChaChaPoly.Nonce(data: Self.nonceData(forCounter: counter))
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        sealedCount = counter
        return box.combined
    }

    /// 解密。先比对内嵌 nonce 与期望计数（乱序/重放/回退 → throw），再 AEAD 校验。
    mutating func open(_ combined: Data, aad: Data) throws -> Data {
        let expectedCounter = openedCount + 1
        let box: ChaChaPoly.SealedBox
        do {
            box = try ChaChaPoly.SealedBox(combined: combined)
        } catch {
            throw SyncHandshakeError.authenticationFailed
        }
        // nonce 在认证前可被篡改——这里只做计数比对（预期值来自方向计数），
        // 篡改后的 nonce 必然 != 期望 → 拒；等值但密文被改 → 下方 AEAD 拒。
        let embedded = box.nonce.withUnsafeBytes { Data($0) }
        guard embedded == (try Self.nonceData(forCounter: expectedCounter)) else {
            throw SyncHandshakeError.replayOrOutOfOrder
        }
        do {
            let plaintext = try ChaChaPoly.open(box, using: key, authenticating: aad)
            openedCount = expectedCounter
            return plaintext
        } catch {
            throw SyncHandshakeError.authenticationFailed
        }
    }
}

// MARK: - 配对消息纯逻辑（PairRequest 构造/校验；M2a 配对流）

/// PairRequest/非 QR nonce 校验纯逻辑。nonceSignature = 对会话 nonce 的
/// Ed25519 签名（证明私钥持有，防冒名），nonce 来自扫码载荷（M1 §4.1）。
enum SyncPairingMessages {
    /// Client 构造 PairRequest：clientDeviceID / clientPublicKey 取自身份，
    /// nonceSignature = signingKey() 对 sessionNonce 原始字节签名。
    /// clientName：本机展示名（可选；Host 批准卡/落库展示用，不参与验签）。
    static func makePairRequest(
        identity: SyncIdentity,
        sessionNonce: Data,
        clientName: String? = nil
    ) throws -> PairRequest {
        let signature = try identity.signingKey().signature(for: sessionNonce)
        return PairRequest(
            clientDeviceID: identity.deviceID,
            clientPublicKey: identity.publicKeyRaw.base64EncodedString(),
            nonceSignature: signature.base64EncodedString(),
            clientName: clientName
        )
    }

    /// 结构校验 PairRequest（Device ID 规范化、公钥 32B、ID==公钥指纹一致）。
    /// 失败抛 M1 PairingFailure（与扫码候选校验同语义，防垃圾输入）。
    static func validate(_ request: PairRequest) throws {
        guard DeviceID.normalized(request.clientDeviceID) != nil else {
            throw PairingFailure.invalidDeviceID(request.clientDeviceID)
        }
        guard let publicKey = Data(base64Encoded: request.clientPublicKey),
              publicKey.count == DeviceID.fingerprintByteCount
        else {
            throw PairingFailure.invalidPublicKey
        }
        guard DeviceID.fingerprintMatches(deviceID: request.clientDeviceID, publicKeyData: publicKey) else {
            throw PairingFailure.fingerprintMismatch
        }
        guard let signature = Data(base64Encoded: request.nonceSignature), signature.count == 64 else {
            throw PairingFailure.invalidQRPayload("nonceSignature 缺失或非法")
        }
    }

    /// Host 侧验证 nonceSignature：用 PairRequest 携带的公钥验证签名确实是
    /// 对 `nonce`（Host 展示 QR 时生成的一次性 nonce）的签名。
    static func verifyNonceSignature(_ request: PairRequest, nonce: Data) throws -> Bool {
        guard let publicKeyData = Data(base64Encoded: request.clientPublicKey),
              let signature = Data(base64Encoded: request.nonceSignature)
        else {
            throw SyncHandshakeError.invalidKeyData
        }
        let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
        return publicKey.isValidSignature(signature, for: nonce)
    }
}
