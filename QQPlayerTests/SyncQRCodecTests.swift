//
//  SyncQRCodecTests.swift
//  QQPlayerTests
//
//  M1-UI QR 载荷编解码与 nonce 生成防回归：
//  - SyncQRCodec：PairQRPayload ↔ JSON 文本 roundtrip（含非 ASCII hostName）
//  - 载荷差异（hostName/nonce）→ JSON 文本不同（每次展示新码内容必变）
//  - SyncSessionNonce：每次生成互不相同、恒 16B（base64 解码长度）
//  - 坏输入（非 JSON/字段缺失/非 UTF-8）→ 抛错
//  - PairQRPayloadFactory：由本机身份组装的字段契约（deviceID/公钥 base64）
//

import CryptoKit
import Foundation
import Testing

@testable import QQPlayer

struct SyncQRCodecTests {
    /// 合法身份（随机密钥）
    private func makeIdentity() -> SyncIdentity {
        SyncIdentity.generate()
    }

    /// 合法载荷
    private func makePayload(
        identity: SyncIdentity,
        hostName: String = "Mac Studio",
        nonce: String = SyncSessionNonce.makeNew()
    ) -> PairQRPayload {
        PairQRPayloadFactory.make(hostName: hostName, identity: identity, sessionNonce: nonce)
    }

    // MARK: - Roundtrip

    @Test("QR 载荷 encode → decode 往返一致（ASCII hostName）")
    func encodeDecodeRoundtripASCII() throws {
        let identity = makeIdentity()
        let payload = makePayload(identity: identity, hostName: "Mac Studio")

        let text = try SyncQRCodec.encode(payload)
        let decoded = try SyncQRCodec.decode(text)

        #expect(decoded == payload)
        #expect(decoded.deviceID == identity.deviceID)
        #expect(decoded.hostName == "Mac Studio")
    }

    @Test("QR 载荷 encode → decode 往返一致（中文 hostName，UTF-8）")
    func encodeDecodeRoundtripCJK() throws {
        let identity = makeIdentity()
        let payload = makePayload(identity: identity, hostName: "张超的 MacBook Pro")

        let text = try SyncQRCodec.encode(payload)
        let decoded = try SyncQRCodec.decode(text)

        #expect(decoded == payload)
        #expect(decoded.hostName == "张超的 MacBook Pro")
    }

    @Test("工厂载荷字段契约：protoVersion=current / deviceID / 公钥 standard base64")
    func factoryFieldsContract() {
        let identity = makeIdentity()
        let payload = makePayload(identity: identity)

        #expect(payload.protoVersion == SyncProtocolVersion.current)
        #expect(payload.deviceID == identity.deviceID)
        #expect(payload.publicKey == identity.publicKeyRaw.base64EncodedString())
        #expect(payload.publicKey == Data(identity.publicKeyRaw).base64EncodedString())
        #expect(Data(base64Encoded: payload.sessionNonce)?.count == SyncSessionNonce.byteCount)
    }

    // MARK: - 载荷差异 → 文本差异

    @Test("hostName 不同 → QR JSON 文本不同")
    func differentHostNameYieldsDifferentText() throws {
        let identity = makeIdentity()
        let nonce = SyncSessionNonce.makeNew()
        let a = makePayload(identity: identity, hostName: "Mac A", nonce: nonce)
        let b = makePayload(identity: identity, hostName: "Mac B", nonce: nonce)

        let textA = try SyncQRCodec.encode(a)
        let textB = try SyncQRCodec.encode(b)
        #expect(textA != textB)
    }

    @Test("nonce 不同（同主机同身份）→ QR JSON 文本不同（刷新必出新码）")
    func differentNonceYieldsDifferentText() throws {
        let identity = makeIdentity()
        let payloadA = makePayload(identity: identity, nonce: SyncSessionNonce.makeNew())
        let payloadB = makePayload(identity: identity, nonce: SyncSessionNonce.makeNew())

        let textA = try SyncQRCodec.encode(payloadA)
        let textB = try SyncQRCodec.encode(payloadB)
        #expect(textA != textB)
        #expect(payloadA.sessionNonce != payloadB.sessionNonce)
    }

    // MARK: - nonce 生成

    @Test("nonce 每次生成互不相同")
    func nonceIsUniquePerCall() {
        let a = SyncSessionNonce.makeNew()
        let b = SyncSessionNonce.makeNew()
        #expect(a != b)
    }

    @Test("nonce 恒 16 字节（base64 解码后）")
    func nonceIs16Bytes() {
        let nonce = SyncSessionNonce.makeNew()
        #expect(Data(base64Encoded: nonce)?.count == 16)
    }

    // MARK: - 坏输入

    @Test("decode 非 JSON 文本 → 抛错")
    func decodeGarbageThrows() {
        #expect(throws: (any Error).self) {
            _ = try SyncQRCodec.decode("not-json-at-all-😀")
        }
    }

    @Test("decode 字段缺失（空对象）→ 抛错")
    func decodeMissingFieldsThrows() {
        #expect(throws: (any Error).self) {
            _ = try SyncQRCodec.decode(#"{"protoVersion":1}"#)
        }
    }

    @Test("encode 后文本可按 UTF-8 还原且可作 QR 内容")
    func encodedTextIsUTF8() throws {
        let payload = makePayload(identity: makeIdentity())
        let text = try SyncQRCodec.encode(payload)
        #expect(!text.isEmpty)
        #expect(String(data: try #require(text.data(using: .utf8)), encoding: .utf8) == text)
    }
}
