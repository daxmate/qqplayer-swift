//
//  SyncFileTransferModels.swift
//  QQPlayer
//
//  局域网同步（S2, M2b）文件传输协议载荷 + 错误模型（纯声明，无 IO）：
//  - FileMetaPayload：file_meta 帧（type 4）——传输声明（文件名/大小/分块/SHA-256/续传起点）
//  - FileChunkPayload：file_chunk 帧（type 5）——一块数据（offset 定位 + data base64）
//  - FileAckPayload：file_ack 帧（type 6）——接收端进度/结论（停等协议推进信号）
//  - FileTransferErrorCode：线上错误码（ack.error / 帧级中止原因）
//  - SyncFileTransferError：本端视角错误（含线上码映射；resumeMismatch 等供调用方做重试决策）
//
//  字段名与任务定案一致（可加字段不可改名）；分块大小固定 256KB。帧加密由 M2a
//  会话层完成；状态机见 SyncFileSender.swift / SyncFileReceiver.swift。
//

import Foundation

/// 文件传输常量（v1 定案）。
enum SyncFileTransfer {
    /// 分块大小（发送端定）。256KB 块 base64 后 ~342KB，远小于 16MB 帧限
    /// （v1 全 JSON 统一风格，性能优化不做）。
    static let chunkSize: Int64 = 262_144
}

/// file_meta 载荷：接收端据它做幂等 / 断点对齐 / 参数校验。
struct FileMetaPayload: Codable, Equatable, Sendable {
    /// 传输唯一 ID（调用方保证；M3 将用 content_hash，本里程碑只透传）
    var fileID: String
    /// 文件名（不含路径；接收端落盘名）
    var name: String
    /// 文件总字节数
    var totalSize: Int64
    /// 分块大小（发送端定，固定 262144）
    var chunkSize: Int64
    /// 全文件 SHA-256 小写 hex（发送前算好）
    var sha256Hex: String
    /// 续传起点（默认 0）
    var startOffset: Int64 = 0
}

/// file_chunk 载荷：一块数据（Data 经 JSON 自动 base64）。
struct FileChunkPayload: Codable, Equatable, Sendable {
    var fileID: String
    /// 块起点（对齐块边界；= 接收端已收完整字节数）
    var offset: Int64
    var data: Data
}

/// file_ack 载荷：停等协议推进信号。
/// receivedBytes = 接收端 .part 当前**完整**字节数（已对齐块边界）。
struct FileAckPayload: Codable, Equatable, Sendable {
    var fileID: String
    var receivedBytes: Int64
    var done: Bool
    var error: FileTransferErrorCode
}

/// 线上错误码（v1 定案枚举值）。
enum FileTransferErrorCode: String, Codable, Equatable, Sendable {
    case none
    case ioError
    case diskFull
    case checksumMismatch
    case resumeMismatch
    case cancelled
    case protocolError
}

/// 文件传输本端错误。与 FileTransferErrorCode 区分：本类型保留本地上下文
/// （文件路径/原因），并给调用方可编程的语义（如 resumeMismatch → startOffset=0 重试）。
enum SyncFileTransferError: Error, Equatable, Sendable {
    /// 会话未 ready（send 时检查）
    case sessionNotReady
    /// 本地文件不可读（不存在/读失败），附原因
    case fileUnavailable(String)
    /// 已有传输在进行（v1 单飞）
    case transferInProgress
    /// 调用参数非法（fileID/name/offset 等），附原因
    case invalidArgument(String)
    /// 本端 cancel 中止（.part 保留，之后可续传）
    case cancelled(String)
    /// 会话断连中止（.part 保留，之后可续传）
    case sessionClosed(String)
    /// 会话发送帧失败
    case sendFailed(String)
    /// 对端 IO 失败
    case ioError(String)
    /// 对端磁盘满
    case diskFull(String)
    /// 接收端校验失败（.part 已删；发送端可从头重发）
    case checksumMismatch(String)
    /// 接收端断点状态与请求不符（附 fileID；调用方可改 startOffset=0 重试一次）
    case resumeMismatch(String)
    /// 协议违例（对端 protocolError / 本地检出），附 fileID + 原因
    case protocolError(String, String)
}

/// 帧载荷 JSON 编解码（帧 payload = 载荷类型 JSON 字节）。
enum SyncFilePayloadCodec {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
