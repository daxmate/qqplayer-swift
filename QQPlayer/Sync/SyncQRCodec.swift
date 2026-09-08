//
//  SyncQRCodec.swift
//  QQPlayer
//
//  局域网同步（S2, M1-UI）QR 载荷编解码 + 一次性 nonce 生成（纯逻辑，可单测）：
//  - SyncQRCodec：PairQRPayload ↔ JSON 文本（QR 码内容，utf8）
//  - SyncSessionNonce：一次性 16B nonce（base64；每次展示新码重新生成，
//    nonce 生命周期/过期检查归状态机，UI 只负责「生成一次、展示一次」）
//  - PairQRPayloadFactory：Host 侧由本机身份 + 展示名组装载荷（UI 薄封装，
//    默认值/字段组装收敛一处，避免各调用点手拼 Codable 结构）
//
//  契约（docs/lan-sync-design.md §4.1）：QR 内容 = PairQRPayload JSON，
//  base64 一律 standard 编码（PairingModels 注释约定）。
//

import Foundation
import Security

/// QR 载荷 JSON 编解码（QR 码文本 ↔ PairQRPayload）。
enum SyncQRCodec {
    /// 载荷 → JSON 文本（QR 码内容）。
    static func encode(_ payload: PairQRPayload) throws -> String {
        let data = try JSONEncoder().encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SyncQRCodecError.invalidUTF8
        }
        return text
    }

    /// JSON 文本 → 载荷。字段缺失/类型错/非 UTF-8 → 抛错
    /// （失败由调用方展示；协议/指纹等语义校验归 PairingStateMachine）。
    static func decode(_ json: String) throws -> PairQRPayload {
        guard let data = json.data(using: .utf8) else {
            throw SyncQRCodecError.invalidUTF8
        }
        return try JSONDecoder().decode(PairQRPayload.self, from: data)
    }
}

enum SyncQRCodecError: Error, Equatable {
    /// JSON 文本无法按 UTF-8 还原（扫码得到的是二进制/编码损坏内容）
    case invalidUTF8
}

/// 一次性会话 nonce（16B → base64 standard；扫码确认窗口防重放）。
enum SyncSessionNonce {
    static let byteCount = 16

    /// 生成新 nonce。SecRandomCopyBytes 系统级失败概率极低，失败视为
    /// 编程错误直接崩溃（同 SyncIdentity.generate 的 force_try 惯例）。
    static func makeNew() -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes 失败: \(status)")
        return Data(bytes).base64EncodedString()
    }
}

/// Host「添加设备」QR 载荷工厂（UI 只生成载荷；换 nonce = 换一张新码）。
enum PairQRPayloadFactory {
    /// 由本机身份组装当前展示载荷。
    static func make(hostName: String, identity: SyncIdentity, sessionNonce: String) -> PairQRPayload {
        PairQRPayload(
            protoVersion: SyncProtocolVersion.current,
            hostName: hostName,
            deviceID: identity.deviceID,
            publicKey: identity.publicKeyRaw.base64EncodedString(),
            sessionNonce: sessionNonce
        )
    }
}
