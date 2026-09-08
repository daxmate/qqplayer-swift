//
//  DeviceIDTests.swift
//  QQPlayerTests
//
//  Device ID 纯函数防回归（S2, M1）：
//  - RFC4648 base32 编解码向量（系统框架无 base32，本地实现必须锁向量）
//  - 公钥 → SHA-256 指纹 → 全量 ID（52 字符，确定性/区分性/非法长度）
//  - 输入规范化（去分隔/空白、大小写、字符集/长度校验）
//  - 展示分组（7 字符组 + '-'，Syncthing 风格）与首/尾组二次核对
//  - 指纹一致性校验（fingerprintMatches）
//
//  全部纯函数，无 Keychain/DB/IO；时间无关。
//

import CryptoKit
import Foundation
import Testing

@testable import QQPlayer

struct DeviceIDBase32Tests {
    // RFC4648 §10 base32 测试向量（无填充形式）
    @Test("RFC4648 base32 编码向量")
    func rfcEncodeVectors() {
        #expect(DeviceID.base32Encode(Data("".utf8)).isEmpty)
        #expect(DeviceID.base32Encode(Data("f".utf8)) == "MY")
        #expect(DeviceID.base32Encode(Data("fo".utf8)) == "MZXQ")
        #expect(DeviceID.base32Encode(Data("foo".utf8)) == "MZXW6")
        #expect(DeviceID.base32Encode(Data("foob".utf8)) == "MZXW6YQ")
        #expect(DeviceID.base32Encode(Data("fooba".utf8)) == "MZXW6YTB")
        #expect(DeviceID.base32Encode(Data("foobar".utf8)) == "MZXW6YTBOI")
    }

    @Test("RFC4648 base32 解码向量（含容忍填充与小写）")
    func rfcDecodeVectors() {
        #expect(DeviceID.base32Decode("MY") == Data("f".utf8))
        #expect(DeviceID.base32Decode("MZXW6YQ") == Data("foob".utf8))
        #expect(DeviceID.base32Decode("MZXW6YTBOI") == Data("foobar".utf8))
        #expect(DeviceID.base32Decode("mzxw6ytboi") == Data("foobar".utf8)) // 小写
        #expect(DeviceID.base32Decode("MZXW6===") == Data("fo".utf8)) // 带填充
    }

    @Test("base32 解码拒绝非法字符/非零填充位")
    func decodeRejectsInvalid() {
        #expect(DeviceID.base32Decode("MZXW6YTB0") == nil) // '0' 不在字母表
        #expect(DeviceID.base32Decode("MZXW6YTB1") == nil) // '1' 不在字母表
        #expect(DeviceID.base32Decode("MZXW6YTB8") == nil) // '8' 不在字母表
        #expect(DeviceID.base32Decode("MZXW6YTB9") == nil) // '9' 不在字母表
        #expect(DeviceID.base32Decode("A!@#$") == nil)
    }

    @Test("base32 编解码往返：随机 32 字节一致")
    func roundtripRandomBytes() {
        for _ in 0 ..< 20 {
            let bytes = (0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) }
            let data = Data(bytes)
            let encoded = DeviceID.base32Encode(data)
            #expect(encoded.count == 52)
            #expect(DeviceID.base32Decode(encoded) == data)
        }
    }
}

struct DeviceIDGenerationTests {
    private func makePublicKey() -> Curve25519.Signing.PublicKey {
        Curve25519.Signing.PrivateKey().publicKey
    }

    @Test("公钥 → ID：52 字符且确定性")
    func deterministicAndLength() {
        let key = makePublicKey()
        let id1 = DeviceID.make(fromPublicKey: key)
        let id2 = DeviceID.make(fromPublicKey: key)
        #expect(id1.count == DeviceID.fullLength)
        #expect(id1 == id2)
        #expect(DeviceID.isValid(id1))
    }

    @Test("不同公钥 → 不同 ID")
    func distinctKeysDistinctIDs() {
        let idA = DeviceID.make(fromPublicKey: makePublicKey())
        let idB = DeviceID.make(fromPublicKey: makePublicKey())
        #expect(idA != idB)
    }

    @Test("公钥 raw 长度非 32B → nil")
    func rejectsWrongKeyLength() {
        #expect(DeviceID.make(fromPublicKeyData: Data(repeating: 0, count: 31)) == nil)
        #expect(DeviceID.make(fromPublicKeyData: Data(repeating: 0, count: 33)) == nil)
        #expect(DeviceID.make(fromPublicKeyData: Data()) == nil)
    }
}

struct DeviceIDNormalizationTests {
    private func makeCanonical() -> String {
        DeviceID.make(fromPublicKey: Curve25519.Signing.PrivateKey().publicKey)
    }

    @Test("分隔/空白/大小写归一 → 全量值")
    func normalizeDisplayVariants() {
        let canonical = makeCanonical()
        let formatted = DeviceID.formatted(canonical)
        #expect(formatted.contains("-"))
        // 带分隔符、空格、小写的展示形态都能归一回全量值
        #expect(DeviceID.normalized(formatted) == canonical)
        #expect(DeviceID.normalized(canonical.lowercased()) == canonical)
        let spaced = canonical.enumerated().map { $0.offset % 10 == 0 ? " \($0.element)" : String($0.element) }.joined()
        #expect(DeviceID.normalized(spaced) == canonical)
    }

    @Test("非法输入 → nil：长度错/字符集外/乱码")
    func normalizeRejectsInvalid() {
        let canonical = makeCanonical()
        #expect(DeviceID.normalized("") == nil)
        #expect(DeviceID.normalized(String(canonical.dropLast())) == nil) // 51 字符
        #expect(DeviceID.normalized(canonical + "A") == nil) // 53 字符
        let withZero = canonical.prefix(10) + "0" + canonical.dropFirst(11)
        #expect(DeviceID.normalized(String(withZero)) == nil) // '0' 非法字符
        #expect(DeviceID.normalized("这不是设备ID") == nil)
        #expect(!DeviceID.isValid("garbage-id"))
    }

    @Test("normalized 输出恒为规范形态（幂等）")
    func normalizationIsIdempotent() throws {
        let canonical = makeCanonical()
        let once = try #require(DeviceID.normalized(DeviceID.formatted(canonical)))
        #expect(DeviceID.normalized(once) == once)
    }
}

struct DeviceIDFormattingTests {
    private func makeCanonical() -> String {
        DeviceID.make(fromPublicKey: Curve25519.Signing.PrivateKey().publicKey)
    }

    @Test("展示分组：52 = 7×7 + 3，'-' 分隔 8 组")
    func formattedGroups() {
        let formatted = DeviceID.formatted(makeCanonical())
        let groups = formatted.split(separator: "-")
        #expect(groups.count == 8)
        #expect(groups.prefix(7).allSatisfy { $0.count == DeviceID.groupWidth })
        #expect(groups.last?.count == 3)
        #expect(formatted.count == DeviceID.fullLength + 7)
    }

    @Test("首/尾组二次核对：与格式化结果一致")
    func shortComparisonParts() throws {
        let canonical = makeCanonical()
        let parts = try #require(DeviceID.shortComparisonParts(canonical))
        let groups = DeviceID.formatted(canonical).split(separator: "-")
        #expect(parts.first == String(groups.first!))
        #expect(parts.last == String(groups.last!))
        // 非法输入 → nil；带分隔符输入容忍（内部先规范化）
        #expect(DeviceID.shortComparisonParts("bad-input") == nil)
        let parts2 = try #require(DeviceID.shortComparisonParts(DeviceID.formatted(canonical)))
        #expect(parts2.first == parts.first)
        #expect(parts2.last == parts.last)
    }
}

struct DeviceIDFingerprintTests {
    @Test("指纹一致：同公钥/同 ID true")
    func matchingFingerprint() {
        let key = Curve25519.Signing.PrivateKey()
        let id = DeviceID.make(fromPublicKey: key.publicKey)
        #expect(DeviceID.fingerprintMatches(deviceID: id, publicKeyData: key.publicKey.rawRepresentation))
        // 展示形态输入也接受（内部先规范化）
        #expect(DeviceID.fingerprintMatches(deviceID: DeviceID.formatted(id), publicKeyData: key.publicKey.rawRepresentation))
    }

    @Test("指纹不一致：异公钥/错 ID/坏数据 false")
    func mismatchingFingerprint() {
        let keyA = Curve25519.Signing.PrivateKey()
        let keyB = Curve25519.Signing.PrivateKey()
        let idA = DeviceID.make(fromPublicKey: keyA.publicKey)
        #expect(!DeviceID.fingerprintMatches(deviceID: idA, publicKeyData: keyB.publicKey.rawRepresentation))
        #expect(!DeviceID.fingerprintMatches(deviceID: "garbage", publicKeyData: keyA.publicKey.rawRepresentation))
        #expect(!DeviceID.fingerprintMatches(deviceID: idA, publicKeyData: Data(repeating: 1, count: 16))) // 非 32B
    }
}
