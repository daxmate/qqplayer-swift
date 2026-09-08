//
//  DeviceID.swift
//  QQPlayer
//
//  Device ID = Ed25519 公钥 SHA-256 指纹（仿 Syncthing 设备 ID 模型，
//  docs/lan-sync-design.md §2）。纯函数、无 IO，重点单测。
//
//  编码约定：
//  - 全量值 = SHA256(公钥 raw 32B) → RFC4648 base32 大写无填充（52 字符）
//    —— QR 载荷 / 存储 / 协议一律用全量值
//  - 展示格式 = 每 7 字符一组、'-' 分隔（Syncthing 风格，末组 3 字符）
//  - 手输路径 = 去分隔符/空白 → 大写 → 校验字符集与长度 → 规范化全量值
//
//  base32 实现是本地最小的 RFC4648 编码器（系统框架无 base32；
//  禁引新 SPM 依赖），编解码均有 RFC 测试向量锁定。
//

import CryptoKit
import Foundation

enum DeviceID {
    /// 指纹摘要长度（SHA-256 = 32 字节）
    static let fingerprintByteCount = 32
    /// 全量 ID 长度（32 字节 → base32 无填充 = 52 字符）
    static let fullLength = 52
    /// 展示分组宽度（Syncthing 风格）
    static let groupWidth = 7
    /// RFC4648 base32 字母表（大写 A-Z + 2-7）
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    // MARK: - 公钥 → Device ID

    /// 由 Ed25519 公钥生成全量 Device ID（key.rawRepresentation 恒 32B）。
    static func make(fromPublicKey key: Curve25519.Signing.PublicKey) -> String {
        make(fromPublicKeyData: key.rawRepresentation)!
    }

    /// 由公钥 raw 数据生成全量 Device ID；数据非 32B 返回 nil。
    static func make(fromPublicKeyData data: Data) -> String? {
        guard data.count == fingerprintByteCount else { return nil }
        let digest = SHA256.hash(data: data)
        return base32Encode(Data(digest))
    }

    /// deviceID 与公钥指纹一致性校验（配对握手核心校验，docs §4）。
    /// deviceID 可带分隔符/空白（先规范化）；公钥数据非 32B 恒 false。
    static func fingerprintMatches(deviceID: String, publicKeyData data: Data) -> Bool {
        guard data.count == fingerprintByteCount,
              let canonical = normalized(deviceID),
              let expected = make(fromPublicKeyData: data)
        else { return false }
        return canonical == expected
    }

    // MARK: - 输入规范化 / 校验（手输路径）

    /// 手输输入 → 规范化全量 ID：
    /// 去 '-'/空白、统一大写、校验字符集与长度（52），失败返回 nil。
    static func normalized(_ input: String) -> String? {
        let stripped = input
            .uppercased()
            .filter { !$0.isWhitespace && $0 != "-" }
        guard stripped.count == fullLength else { return nil }
        guard let decoded = base32Decode(stripped), decoded.count == fingerprintByteCount else {
            return nil
        }
        // 规范回写：拒绝字符集合法但填充位非零的"怪"输入，保证全量值唯一形态
        return base32Encode(decoded)
    }

    /// 输入是否为合法 Device ID（等价于 normalized 非 nil）。
    static func isValid(_ input: String) -> Bool {
        normalized(input) != nil
    }

    // MARK: - 展示格式

    /// 全量 → 分组展示（每 7 字符一组，'-' 分隔；52 = 7×7 + 3，共 8 组）。
    /// 入参应为规范化全量值（调用方可先用 normalized 兜底）。
    static func formatted(_ fullID: String) -> String {
        let chars = Array(fullID)
        guard fullID.count == fullLength else { return fullID }
        var groups: [String] = []
        var index = 0
        while index < chars.count {
            let end = min(index + groupWidth, chars.count)
            groups.append(String(chars[index ..< end]))
            index = end
        }
        return groups.joined(separator: "-")
    }

    /// 首组 + 末组（手输后二次核对用，docs §4.2"比较首/尾组"）。
    /// 入参容忍分隔/空白/大小写（内部先规范化）；非法输入返回 nil。
    static func shortComparisonParts(_ fullID: String) -> (first: String, last: String)? {
        guard let canonical = normalized(fullID) else { return nil }
        let groups = formatted(canonical).split(separator: "-")
        guard let first = groups.first, let last = groups.last else { return nil }
        return (String(first), String(last))
    }

    // MARK: - RFC4648 base32（internal 供单测锁向量）

    /// 编码（无填充）。空输入 → 空串。
    static func base32Encode(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        var result = ""
        result.reserveCapacity((data.count * 8 + 4) / 5)
        var buffer: UInt32 = 0
        var bitCount = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                let index = Int((buffer >> bitCount) & 0x1F)
                result.append(alphabet[index])
            }
        }
        if bitCount > 0 {
            let index = Int((buffer << (5 - bitCount)) & 0x1F)
            result.append(alphabet[index])
        }
        return result
    }

    /// 解码（容忍填充 '='，容忍小写）。非法字符返回 nil。
    static func base32Decode(_ string: String) -> Data? {
        let chars = Array(string.uppercased())
        guard !chars.isEmpty else { return Data() }
        var result = Data()
        result.reserveCapacity(chars.count * 5 / 8)
        var buffer: UInt32 = 0
        var bitCount = 0
        for char in chars {
            if char == "=" { continue }
            guard let value = charValue(char) else { return nil }
            buffer = (buffer << 5) | value
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                result.append(UInt8((buffer >> bitCount) & 0xFF))
            }
        }
        // 尾部未用足比特位必须为零（拒绝非规范编码）
        if bitCount > 0, buffer & ((1 << bitCount) - 1) != 0 { return nil }
        return result
    }

    private static func charValue(_ char: Character) -> UInt32? {
        guard let scalar = char.unicodeScalars.first else { return nil }
        let value = scalar.value
        switch value {
        case 65 ... 90: return value - 65 // A-Z
        case 50 ... 55: return value - 24 // 2-7
        default: return nil
        }
    }
}
