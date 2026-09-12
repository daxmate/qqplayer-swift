//
//  SyncSessionModels.swift
//  QQPlayer
//
//  局域网同步（S2, M2a）会话支撑类型：信任表抽象、配对 nonce 注册表、
//  会话阶段/关闭原因/配置、传输通道协议。纯声明层，无业务逻辑；
//  会话状态机本体见 SyncPeerSession.swift（核心）+ SyncPeerSession+Frames.swift（帧处理）。
//

import CryptoKit
import Foundation

// MARK: - 信任表抽象（握手 pinning / 配对落库用）

/// 对端长期公钥查询 + 配对记录读写（TOFU 信任列表的传输层视图）。
/// 生产实现 = DeviceStore（见本文件 extension）；测试用内存 mock。
protocol SyncTrustStore: Sendable {
    /// 按 Device ID 查对方 Ed25519 公钥 raw（32B）；未配对返回 nil。
    /// 抛错 = 存储层故障（区别于"无记录"）。
    func peerPublicKey(deviceID: String) throws -> Data?
    /// 落一条配对记录（Host 批准后存 client；client 收到 approved 后存 host）。
    func savePeer(_ device: PeerDevice) throws
    /// 撤销配对（备用接口；本里程碑不主动调用）。
    func removePeer(deviceID: String) throws
}

/// DeviceStore → SyncTrustStore 适配（extension 在新文件，不改 M1-Core 原文件）。
extension DeviceStore: SyncTrustStore {
    func peerPublicKey(deviceID: String) throws -> Data? {
        guard let record = try byPeerID(deviceID) else { return nil }
        return Data(base64Encoded: record.peerPublicKey)
    }

    func savePeer(_ device: PeerDevice) throws {
        try upsert(device)
    }

    func removePeer(deviceID: String) throws {
        try remove(peerID: deviceID)
    }
}

// MARK: - 配对 nonce 注册表（Host 侧）

/// Host 侧一次性 QR nonce 池：UI 展示"添加设备"QR 时注册 nonce，
/// 收到 pair_request 后逐一验签，命中即消耗（防重放）。线程安全。
final class SyncPairingNonceRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Data] = []

    /// 当前未消耗 nonce 数。
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    /// 注册一个 nonce（去重幂等）。
    func register(_ nonce: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !nonce.isEmpty, !pending.contains(nonce) else { return }
        pending.append(nonce)
    }

    /// 消耗一个 nonce（配对完成后作废）。
    func consume(_ nonce: Data) {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll { $0 == nonce }
    }

    /// 清空（UI 关闭配对流）。
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
    }

    /// 用 PairRequest 的公钥对每个 pending nonce 验签，首个命中即消耗并返回；
    /// 全部不中返回 nil（= 无效/过期 nonce 签名）。
    func matchingNonce(for request: PairRequest) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let publicKeyData = Data(base64Encoded: request.clientPublicKey),
              let signature = Data(base64Encoded: request.nonceSignature)
        else { return nil }
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else {
            return nil
        }
        for nonce in pending where publicKey.isValidSignature(signature, for: nonce) {
            pending.removeAll { $0 == nonce }
            return nonce
        }
        return nil
    }
}

// MARK: - 会话阶段 / 关闭原因 / 配置

/// 会话阶段（公开状态机视图）。
enum SyncSessionPhase: Equatable, Sendable {
    /// 未开始（等 transport ready）
    case idle
    /// 已发/在等对端 hello（client 等 server hello；host 等 client hello）
    case waitingForPeerHello
    /// host：对端未配对，已回 hello，等 pair_request
    case waitingForPairRequest
    /// host：pair_request 验签通过，等用户批准（UI 决定，无超时）
    case waitingForPairApproval
    /// client：已发 pair_request，等 pair_response
    case waitingForPairResponse
    /// 密钥就绪，可收发业务帧
    case ready
    /// 已关闭（closeReason 见 SyncSessionCloseReason）
    case closed
}

/// 会话关闭原因（onClosed 回调携带）。
enum SyncSessionCloseReason: Equatable, Sendable {
    /// 本端主动关闭（用户取消 / UI 关闭连接）
    case userCancelled
    /// 对端关闭（传输层断开，未收 bye）
    case remoteClosed
    /// 收到对端 bye 帧
    case receivedBye
    /// 握手超时（对端 hello / pair_request 未按时到达）
    case handshakeTimeout
    /// 握手失败（签名无效/身份不匹配/角色不符等）
    case handshakeFailed(SyncHandshakeError)
    /// 对端不在信任表且无配对流（client 侧遇未配对 host）
    case peerUntrusted(String)
    /// 配对被拒（PairResponse.approved = false，附 reason）
    case pairingRejected(String?)
    /// 信任表读写失败
    case storageError(String)
    /// 协议违例（类型/加密位/阶段不符）
    case protocolViolation(String)
    /// 传输层错误（channel 失败）
    case transportError
}

/// 会话配置（握手超时可注入；测试用小值）。
struct SyncSessionConfiguration: Sendable, Equatable {
    /// 等待对端响应（hello/pair_request）的超时
    var handshakeTimeout: TimeInterval = 10
    /// 本机展示名（两端会话配置均可注入：host 发 hello / client 发 hello + PairRequest
    /// 时携带；名字由调用方注入——iOS 用 `LocalDeviceNameStore.shared.name`，
    /// 共享/纯逻辑文件不触 UIKit）。纯展示字段，不参与签名。
    var clientDisplayName: String?
}

/// client 发起配对所需信息（QR 扫码产物；M1 PeerCandidate.approved 转来）。
/// 信任根 = 扫码瞬间物理在场：hostDeviceID + 公钥来自 QR，sessionNonce 一次性。
struct SyncPairingCandidate: Equatable, Sendable {
    var deviceID: String
    var publicKeyRaw: Data
    var sessionNonce: Data
    var hostName: String
}

/// 待批准配对请求（Host 侧 pairApprovalHandler 入参）。
struct PendingPairRequest: Equatable, Sendable {
    /// M1 PairRequest（clientDeviceID/clientPublicKey/nonceSignature）
    var request: PairRequest
    /// 建议展示名（Device ID 分组短格式；批准时可覆盖为真实设备名）
    var suggestedDisplayName: String
}

// MARK: - 传输通道抽象

/// 帧字节通道（Network 适配器实现；会话测试用内存回环）。
/// 线程要求：sendFrameBytes/closeTransport 可在任意线程调用。
protocol SyncPeerTransport: AnyObject {
    /// 发送一帧完整线上字节。
    func sendFrameBytes(_ data: Data)
    /// 关闭底层通道（幂等）。
    func closeTransport()
}
