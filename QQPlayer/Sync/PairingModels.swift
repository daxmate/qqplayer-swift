//
//  PairingModels.swift
//  QQPlayer
//
//  局域网同步（S2, M1）配对协议消息模型（纯 Codable 契约，平台无关）：
//  - PairQRPayload：Host「添加设备」展示的 QR 内容
//  - PairRequest：Client → Host 的配对请求（M2 传输层使用；本里程碑只锁模型）
//  - PairResponse：Host → Client 的批准/拒绝答复（M2 传输层使用）
//  - PeerDevice：已配对设备记录（TOFU 信任列表一条，落 sync_device 表，见 DeviceStore）
//
//  设计依据 docs/lan-sync-design.md §2/§4：Ed25519 TOFU；Device ID = 公钥
//  SHA-256 指纹；QR 与存储用全量值；私钥不出设备。
//  约定：base64 一律 standard 编码（非 url-safe）；时间字段 Int64 epoch 秒
//  （与库内现有 Int64 时间戳惯例一致，Date 展示转换留给 UI 层）。
//

import Foundation
@preconcurrency import GRDB

/// 协议版本。QR/请求校验用；升版在此加常量并做兼容判断（M2 起）。
enum SyncProtocolVersion {
    static let current = 1
}

/// 端角色（配对记录中"对方设备"的角色：host = 内容生产端/服务端，client = 移动端）。
/// 存储为 sync_device.role 的 TEXT 原值（沿用 eq_preset.preset_type 的 String 枚举惯例）。
enum PeerRole: String, Codable, Equatable, Sendable {
    case host
    case client
}

/// Host「添加设备」展示的 QR 载荷。
/// 信任根 = 扫码瞬间的物理在场（QR 即带外可信通道）；sessionNonce 一次性防重放。
/// 字段均为全量值（不截断/不分组），展示格式化由 DeviceID 负责。
struct PairQRPayload: Codable, Equatable, Sendable {
    var protoVersion: Int
    var hostName: String
    var deviceID: String // 全量 Device ID（base32 无分隔，52 字符）
    var publicKey: String // Ed25519 公钥 raw（32B）base64
    var sessionNonce: String // 一次性 nonce，base64
}

/// Client → Host 的配对请求（4.1 步骤 4；M2 传输层发送）。
/// nonceSignature = 对会话 nonce 的 Ed25519 签名（证明私钥持有，防冒名）。
struct PairRequest: Codable, Equatable, Sendable {
    var clientDeviceID: String
    var clientPublicKey: String // base64
    var nonceSignature: String // base64
    /// 客户端展示名（S2 接线新增，可选；仅用于 Host 批准卡/落库展示名，
    /// 不作安全凭据）。旧端缺失该字段解码为 nil，向后兼容。
    var clientName: String?

    /// 兼容既有调用点：clientName 缺省为 nil（旧端行为）。
    init(clientDeviceID: String, clientPublicKey: String, nonceSignature: String, clientName: String? = nil) {
        self.clientDeviceID = clientDeviceID
        self.clientPublicKey = clientPublicKey
        self.nonceSignature = nonceSignature
        self.clientName = clientName
    }
}

/// Host → Client 的配对答复（4.1 步骤 6；M2 传输层返回）。
struct PairResponse: Codable, Equatable, Sendable {
    var approved: Bool
    var reason: String?
}

/// 已配对设备记录（"信任对方公钥"列表一条，docs §2）。
/// 同时作 GRDB Record 落 sync_device 表（编码键 = 列名，见 CodingKeys）。
/// 删除该记录即撤销配对；重新配对 = 同 peerID upsert（替换确认路径）。
struct PeerDevice: Codable, Equatable, FetchableRecord, PersistableRecord {
    var peerID: String // 对方 Device ID（全量）
    var peerPublicKey: String // 对方 Ed25519 公钥 base64（TLS pinning 依据）
    var displayName: String
    var role: PeerRole
    var pairedAt: Int64 // epoch 秒
    var lastSeenAt: Int64 // epoch 秒（最近一次成功连接，M2 刷新）
    var notes: String?

    static let databaseTableName = "sync_device"

    // snake_case 列名即 JSON 键（与库内既有 Record 模型同惯例）
    enum CodingKeys: String, CodingKey {
        case peerID = "peer_id"
        case peerPublicKey = "peer_public_key"
        case displayName = "display_name"
        case role
        case pairedAt = "paired_at"
        case lastSeenAt = "last_seen_at"
        case notes
    }
}
