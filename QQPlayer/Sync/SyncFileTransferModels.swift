//
//  SyncFileTransferModels.swift
//  QQPlayer
//
//  局域网同步（S2, M2b）文件传输协议载荷 + 错误模型（纯声明，无 IO）：
//  - FileMetaPayload：file_meta 帧（type 4）——传输声明（文件名/大小/分块/SHA-256/续传起点）
//  - FileChunkPayload：file_chunk 帧（type 5）——一块数据（offset 定位 + data）
//    数据默认走 JSON（base64）；协商后走 flags bit1 的原始二进制（见 SyncFileChunkCodec）
//  - FileAckPayload：file_ack 帧（type 6）——接收端进度/结论（窗口推进信号 + 能力协商）
//  - FileTransferErrorCode：线上错误码（ack.error / 帧级中止原因）
//  - SyncFileTransferError：本端视角错误（含线上码映射；resumeMismatch 等供调用方做重试决策）
//
//  字段名与任务定案一致（可加字段不可改名）；分块大小由发送端声明
//  （`SyncFileTransfer.chunkSize`，接收端**只能**按 meta 声明值行事）。帧加密由 M2a
//  会话层完成；状态机见 SyncFileSender.swift / SyncFileReceiver.swift。
//

import Foundation

/// 文件传输常量（v1 定案）。
enum SyncFileTransfer {
    /// 分块大小（发送端定；接收端按 meta 声明值行事，不读本常量）。
    ///
    /// 2026-09-18 提速：256KB → 1MB。停等协议下吞吐 ≈ chunkSize ÷ 有效往返，每块
    /// 一次往返的固定开销（含 Nagle/delayed-ACK、Wi-Fi 唤醒、帧加解密与 JSON 编解码）
    /// 在「只传 3 首」时占大头——放大块把块数（= 往返次数）压到 1/4。
    /// 1MB 块 base64 后 ~1.37MB，仍远小于 16MB 帧限（`SyncFrame.maxPayloadSize`）；
    /// 保守起步；滑动窗口 / 二进制块见 2026-11-06 提速（`maxInFlight`）。
    static let chunkSize: Int64 = 1_048_576

    /// 滑动窗口深度上限（2026-11-06 提速，阶段 A）。
    ///
    /// 发送端最多这么多块同时在途未确认：8 × 1MB = 8MB —— 在途内存的**硬上限在这里**，
    /// 不随对端声明放大。接收端在应答 file_meta 的那条 file_ack 里声明自己能吃多深
    /// （`FileAckPayload.maxInFlight`），发送端取 `min(声明值, 本常量)`；旧接收端不声明
    /// → 发送端回退 1（停等，行为与 v1 完全一致）。
    static let maxInFlight = 8

    /// 文件级并发度上限（2026-11-11，阶段 C）。
    ///
    /// 每文件仍有自己的在途窗口（`maxInFlight`），这里限制**同时推进的文件数**：
    /// 单文件停等/窗口的瓶颈是「每块一次往返」，多文件同时在途才能把往返叠起来
    /// （家里 2.4G 穿墙 RTT 18-127ms 抖动时尤其明显）。
    /// 旧接收端不声明 → 发送端回退 1（串行）。
    static let maxConcurrentFiles = 4

    /// 全局在途字节上限（跨文件共享，防 iPhone 内存峰值）。
    ///
    /// 来源：4 文件 × 窗口 8 × 1MB = 32MB 的理论峰值对接收端（内存里攒一帧 + 解密缓冲）
    /// 偏大；取 24MB 作为硬顶（≈ 3 个满窗口文件的在途量），触顶后暂停派新块等 ack。
    static let inFlightByteLimit = 24 * 1024 * 1024
}

/// 一轮文件传输的实测计时（**纯值，无 IO**；落点见 `SyncConnectDiag.log`）。
///
/// 为什么带上 `chunkSize` / `chunks`：下一轮优化的判据是「往返次数 × 每次往返耗时」，
/// 而不是笼统的「慢」——先取到每文件的字节数/块数/耗时/块间等 ack 往返，再决定是否上
/// 滑动窗口或并发。发送端与接收端各记一行（同一 fileID 可两端对照）。
struct SyncTransferMetrics: Equatable, Sendable {
    /// 本端角色。
    enum Role: String, Equatable, Sendable {
        case send
        case receive
    }

    let role: Role
    /// 传输唯一 ID（`file_meta.fileID`）
    let fileID: String
    /// 本轮起点（0 = 从头；> 0 = 断点续传）
    let startOffset: Int64
    /// 本轮涉及的**整文件**总字节数
    let totalSize: Int64
    /// 发送端声明的分块大小（接收端据此断言「按声明值行事」）
    let chunkSize: Int64
    /// 本轮实际走完的块数
    let chunks: Int
    /// 本轮耗时（毫秒）
    let milliseconds: Int
    /// 块间等 ack 往返：首块 / 尾块（毫秒；接收端恒为 nil）。每块只记首末两次，
    /// 不刷屏（中间块的数量已由 `chunks` 表达）。
    let firstChunkWaitMs: Int?
    let lastChunkWaitMs: Int?
    let succeeded: Bool
    /// 失败时的简短原因（成功为 nil）
    let errorLine: String?
    /// 本轮实际采用的窗口深度（发送端；1 = 停等 / 旧对端。接收端恒为 nil）
    ///
    /// 三个字段用 `var` 而非 `let`：可选 `var` 在 memberwise init 里有隐式 nil 默认值，
    /// 既有构造点（接收端 metricsLocked 等）一行都不用改——「可选字段，旧调用点不破」。
    var window: Int?
    /// 在途块数峰值（发送端；用来判断窗口是否真的打满，而不是只配了 8 却一直发 1）
    var inFlightMax: Int?
    /// 本轮 file_chunk 载荷的实际字节数（两端都记）：与 `bytes` 对比即知 base64 的 33% 膨胀
    var wireBytes: Int?
    /// 本轮实际的文件并发度（发送端 = 本文件派发时的并发上限；接收端 = 收齐时的在途文件数）
    var concurrency: Int?
    /// 本文件占用的并发槽位（0 起；串行时恒为 0）
    var slot: Int?

    /// 单行日志（键=值，便于 grep/切分；一行一个文件）。
    var logLine: String {
        let mark = succeeded ? "✅" : "❌"
        let arrow = role == .send ? "📤" : "📥"
        let seconds = Double(milliseconds) / 1000
        // 速率按**本轮实际走过的字节**算（续传轮分母是剩余字节，不是 totalSize），
        // 用 totalSize - startOffset 做基准；秒数为 0 时不打印速率（避免 inf）
        let moved = max(0, totalSize - startOffset)
        var parts = [
            "\(arrow) transfer \(role.rawValue) \(mark)",
            "fileID=\(fileID)",
            "bytes=\(totalSize)",
            "moved=\(moved)",
            "startOffset=\(startOffset)",
            "chunkSize=\(chunkSize)",
            "chunks=\(chunks)",
            "ms=\(milliseconds)",
        ]
        if let window { parts.append("win=\(window)") }
        if let inFlightMax { parts.append("inFlightMax=\(inFlightMax)") }
        if let wireBytes { parts.append("wireBytes=\(wireBytes)") }
        if seconds > 0 {
            let mbPerSecond = Double(moved) / seconds / 1_048_576
            parts.append(String(format: "rate=%.2fMB/s", mbPerSecond))
        }
        if let first = firstChunkWaitMs { parts.append("ackWaitFirst=\(first)ms") }
        if let last = lastChunkWaitMs { parts.append("ackWaitLast=\(last)ms") }
        if let concurrency { parts.append("conc=\(concurrency)") }
        if let slot { parts.append("slot=\(slot)") }
        if let errorLine { parts.append("error=\(errorLine)") }
        return parts.joined(separator: " ")
    }
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

/// file_ack 载荷：传输推进信号（滑动窗口下每块一条，可能多条同时在途）。
/// receivedBytes = 接收端 .part 当前**完整**字节数（已对齐块边界）。
struct FileAckPayload: Codable, Equatable, Sendable {
    var fileID: String
    var receivedBytes: Int64
    var done: Bool
    var error: FileTransferErrorCode
    /// 接收端可接受的在途窗口深度（**能力协商**，只在应答 file_meta 那条 ack 里带）。
    /// nil = 对端不声明（旧端）→ 发送端回退停等。可选字段对旧端的 JSON 解码透明。
    var maxInFlight: Int?
    /// 接收端是否支持 file_chunk 二进制载荷（flags bit1）。nil = 旧端 → 继续 base64 JSON。
    var binaryChunks: Bool?
    /// 接收端可同时推进的文件数（**能力协商**，只在应答 file_meta 那条 ack 里带）。
    /// nil = 对端不声明（旧端）→ 发送端回退串行（一次只派一个文件，行为与现在完全一致）。
    var maxConcurrentFiles: Int?
    /// 接收端是否支持**合成探针**（T2 测速：8 MiB 临时文件，不进曲库）。
    /// nil = 旧端（不声明）→ 发送端**绝不发探针**（旧端会把它当普通文件落盘）。
    var probeCapable: Bool?
}

/// 接收端能力声明（`FileAckPayload` 的两个协商字段打包；测试注入 / 生产默认值共用）。
struct SyncFileTransferCapabilities: Equatable, Sendable {
    var maxInFlight: Int?
    var binaryChunks: Bool?
    /// 可同时推进的文件数（nil = 旧端 → 串行）。
    var maxConcurrentFiles: Int?
    /// 合成探针支持（nil = 旧端 → 发送端不发探针）。
    var probeCapable: Bool?

    /// 生产默认：窗口 8 + 二进制块 + 4 文件并发 + 探针可用。
    static let current = SyncFileTransferCapabilities(
        maxInFlight: SyncFileTransfer.maxInFlight,
        binaryChunks: true,
        maxConcurrentFiles: SyncFileTransfer.maxConcurrentFiles,
        probeCapable: true
    )
    /// 旧端（不声明任何能力）：发送端据此回退停等 + base64 + 串行 + 不发探针。
    static let legacy = SyncFileTransferCapabilities(
        maxInFlight: nil, binaryChunks: nil, maxConcurrentFiles: nil, probeCapable: nil
    )
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
    /// 对端不支持合成探针（旧端 / 能力关闭）。**只在探针链路出现**，普通文件永不使用；
    /// 旧发送端从不会发探针 ⇒ 不会收到本码。
    case probeUnsupported
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
    /// 对端不声明探针能力（旧端）→ 探针自身中止；**与同步结论无关**。
    case probeUnsupported(String)
    /// 协议违例（对端 protocolError / 本地检出），附 fileID + 原因
    case protocolError(String, String)
}

/// file_chunk 二进制载荷编解码（阶段 B，2026-11-06）。
///
/// 线上（**加密前**的明文载荷；帧头 flags bit1 = 原始二进制）：
///   `fileIDLen(UInt16 BE) | fileID(UTF8) | data`
///
/// 为什么不再走 JSON：`FileChunkPayload.data` 是 `Data`，`JSONEncoder` 会编成 base64
/// 字符串 —— 线上体积 ×1.33，且每块多一次 base64 编解码。二进制格式把这块开销抹掉，
/// 帧本身（magic/len/type/flags/加密）完全不变。
///
/// 迁移口径：接收端在 file_ack 里声明 `binaryChunks`，发送端**只在对端声明后才用**；
/// 旧对端继续收 base64 JSON（旧解码器看到 bit1 帧会当 JSON 解码失败，故必须协商）。
/// 二进制块没有 offset 字段：TCP 有序 + 发送端保序 ⇒ 接收端按「当前已收字节」隐式定位。
enum SyncFileChunkCodec {
    /// 编码为二进制块载荷；fileID 超 UInt16 长度上限返回 nil（调用方按协议错误处理）。
    static func encodeBinary(fileID: String, data: Data) -> Data? {
        let idBytes = Data(fileID.utf8)
        guard !idBytes.isEmpty, idBytes.count <= Int(UInt16.max) else { return nil }
        var out = Data(capacity: 2 + idBytes.count + data.count)
        out.append(UInt8((idBytes.count >> 8) & 0xFF))
        out.append(UInt8(idBytes.count & 0xFF))
        out.append(idBytes)
        out.append(data)
        return out
    }

    /// 解码二进制块载荷；长度前缀越界 / fileID 非 UTF-8 / 空 fileID → nil（调用方报协议错误）。
    /// 严格校验：`2 + 前缀长度 ≤ 载荷长度`，绝不越界读（`payload[..]` 一律走受检区间）。
    static func decodeBinary(_ payload: Data) -> (fileID: String, data: Data)? {
        guard payload.count >= 2 else { return nil }
        let start = payload.startIndex
        let idLength = Int(payload[start]) << 8 | Int(payload[start + 1])
        guard idLength > 0, payload.count >= 2 + idLength else { return nil }
        let idStart = start + 2
        let idEnd = idStart + idLength
        guard let fileID = String(data: Data(payload[idStart ..< idEnd]), encoding: .utf8),
              !fileID.isEmpty
        else { return nil }
        return (fileID, Data(payload[idEnd...]))
    }
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
