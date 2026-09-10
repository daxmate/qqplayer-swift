//
//  SyncFrame.swift
//  QQPlayer
//
//  局域网同步（S2, M2a）帧协议编解码——纯函数、无 IO、全面单测。
//
//  线上格式（与 docs/lan-sync-design.md §5 对齐，头部恒明文）：
//    magic(4B "QQP1") | length(4B big-endian = payload 字节数)
//    | type(1B) | flags(1B) | payload(N)
//  - flags bit0(0x01) = encrypted：握手/配对帧（type 0/1/2）在会话密钥建立前
//    以明文帧发送；建立后业务帧（type ≥ 3）一律置位并加密 payload。
//  - payload 加密采用 ChaCha20-Poly1305，AAD = 完整 10B 帧头（见 SyncCrypto）。
//  - 最大帧 16MB（解码越界保护 + 编码拒绝），防止恶意 length 前缀撑爆内存。
//
//  类型表（v1）：0=handshake 1=pair_request 2=pair_response 3=ping
//   4=file_meta 5=file_chunk 6=file_ack 7=bye（4-6 由 M2b 文件传输使用，
//   M2a 会话层只转发给 onApplicationFrame 回调）。
//  类型表（v2，M4-1 增量追加）：8=change_log_pull 9=change_log_push（播放数据
//  同步增量拉取/推送；payload 为 JSON，会话层解密后同样经 onApplicationFrame
//  转发，由 SyncChangeLogPeer 解码并接 LWW 对账，见 SyncChangeLogPeer.swift）。
//  类型表（v3，M3-3a 增量追加）：10=manifest_request 11=manifest_response（文件
//  同步 manifest 拉取/应答；payload 为 JSON，会话层解密后经 onApplicationFrame
//  转发，由 SyncManifestPeer 解码，见 SyncManifestPeer.swift）。
//  类型表（v4，M3-3b 增量追加）：12=sync_fetch_request 13=sync_fetch_result（文件
//  同步「按路径拉取」请求/结果；payload 为 JSON，会话层解密后同样经
//  onApplicationFrame 转发，Host 侧由 SyncLibraryFetchResponder 应答、Client 侧由
//  SyncLibrarySyncController 消费，见 SyncLibrarySyncModels.swift）。

import Foundation

/// 帧协议错误。
enum SyncFrameError: Error, Equatable, Sendable {
    /// 前 4B 不是 "QQP1"
    case invalidMagic
    /// 数据不足 10B 帧头
    case truncatedHeader
    /// payload 未收全（length 前缀声明了 N 字节）
    case truncatedPayload(declared: Int, available: Int)
    /// 声明的 payload 超过 16MB 上限
    case payloadTooLarge(Int)
    /// type 不在 SyncFrameType 枚举内
    case invalidType(UInt8)
    /// 待编码 payload 超过 16MB 上限
    case encodePayloadTooLarge(Int)
}

/// 帧类型（线上 1B 值，见文件头注释）。
enum SyncFrameType: UInt8, Equatable, Sendable, CaseIterable {
    case handshake = 0
    case pairRequest = 1
    case pairResponse = 2
    case ping = 3
    case fileMeta = 4
    case fileChunk = 5
    case fileAck = 6
    case bye = 7
    case changeLogPull = 8
    case changeLogPush = 9
    case manifestRequest = 10
    case manifestResponse = 11
    case syncFetchRequest = 12
    case syncFetchResult = 13
}

/// 帧 flags（bit0 = encrypted）。
struct SyncFrameFlags: OptionSet, Equatable, Sendable {
    let rawValue: UInt8

    /// payload 已用会话密钥加密
    static let encrypted = SyncFrameFlags(rawValue: 0x01)
}

/// 一帧（值类型，编解码纯函数）。
struct SyncFrame: Equatable, Sendable {
    /// 帧 magic（"QQP1"，ASCII 4B）
    static let magic = Data("QQP1".utf8)
    /// 帧头长度（magic 4 + length 4 + type 1 + flags 1）
    static let headerLength = 10
    /// payload 上限 16MB（解码越界保护 / 编码拒绝共用）
    static let maxPayloadSize = 16 * 1024 * 1024

    let type: SyncFrameType
    let flags: SyncFrameFlags
    let payload: Data

    var isEncrypted: Bool { flags.contains(.encrypted) }

    init(type: SyncFrameType, flags: SyncFrameFlags = [], payload: Data = Data()) {
        self.type = type
        self.flags = flags
        self.payload = payload
    }

    /// 编码为线上字节（magic|len|type|flags|payload）。
    func encode() throws -> Data {
        guard payload.count <= Self.maxPayloadSize else {
            throw SyncFrameError.encodePayloadTooLarge(payload.count)
        }
        var out = Data(capacity: Self.headerLength + payload.count)
        out.append(Self.magic)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { out.append(contentsOf: $0) }
        out.append(type.rawValue)
        out.append(flags.rawValue)
        out.append(payload)
        return out
    }

    /// 从字节流前缀解码单帧（data 须含完整一帧；多余字节忽略，流式拼帧用
    /// SyncFrameDecoder）。返回 (帧, 消耗字节数)。数据不足一帧抛 truncated*。
    static func decode(from data: Data) throws -> (frame: SyncFrame, consumed: Int) {
        guard data.count >= headerLength else {
            throw SyncFrameError.truncatedHeader
        }
        guard data.prefix(4) == magic else {
            throw SyncFrameError.invalidMagic
        }
        let length = Int(
            UInt32(data[data.startIndex + 4]) << 24
                | UInt32(data[data.startIndex + 5]) << 16
                | UInt32(data[data.startIndex + 6]) << 8
                | UInt32(data[data.startIndex + 7])
        )
        guard length <= maxPayloadSize else {
            throw SyncFrameError.payloadTooLarge(length)
        }
        let total = headerLength + length
        guard data.count >= total else {
            throw SyncFrameError.truncatedPayload(declared: length, available: data.count - headerLength)
        }
        let typeValue = data[data.startIndex + 8]
        guard let type = SyncFrameType(rawValue: typeValue) else {
            throw SyncFrameError.invalidType(typeValue)
        }
        let flags = SyncFrameFlags(rawValue: data[data.startIndex + 9])
        let payload = data.subdata(in: (data.startIndex + headerLength) ..< (data.startIndex + total))
        return (SyncFrame(type: type, flags: flags, payload: payload), total)
    }
}

/// 流式拼帧解码器（Network 层把任意分块的字节喂进来，输出完整帧）。
/// 值类型：跨线程使用时由持有方保证串行（会话锁内调用）。
struct SyncFrameDecoder {
    private var buffer = Data()

    init() {}

    /// 追加一块字节，解出其中所有完整帧。残缺帧留在缓冲等下一块。
    /// 帧头/长度校验失败（magic 错 / 超 16MB / type 非法）抛错——流的损坏
    /// 不可恢复，由调用方终结连接。
    mutating func feed(_ chunk: Data) throws -> [SyncFrame] {
        buffer.append(chunk)
        var frames: [SyncFrame] = []
        while true {
            // 少于 10B：等待更多数据（也可能是永远残缺的短连接——由调用方超时兜底）
            guard buffer.count >= SyncFrame.headerLength else { break }
            // magic 校验放在整帧收齐前先做一次，尽早识别错流
            guard buffer.prefix(4) == SyncFrame.magic else {
                throw SyncFrameError.invalidMagic
            }
            do {
                let result = try SyncFrame.decode(from: buffer)
                frames.append(result.frame)
                buffer.removeFirst(result.consumed)
            } catch SyncFrameError.truncatedPayload {
                break // 帧体未收全，等下一块
            }
        }
        return frames
    }

    /// 剩余缓冲字节数（诊断/测试用）。
    var bufferedCount: Int { buffer.count }
}
