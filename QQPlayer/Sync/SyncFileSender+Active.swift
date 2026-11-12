//
//  SyncFileSender+Active.swift
//  QQPlayer
//
//  发送端单文件传输的本轮状态（原 `SyncFileSender.Active`，2026-11 T2 拆出：
//  主文件行数预算 600 行，拆出后仍以 `SyncFileSender.Active` 类型别名引用，调用点零改动）。
//
import Foundation

/// 已发出但未确认的块（窗口占位；`end` = 该块末字节的绝对偏移）。
struct SyncSenderSentChunk {
    let offset: Int64, length: Int64
    var end: Int64 { offset + length }
}

/// 一轮单文件上传的在途状态（锁定持有：所有可变字段只在 `SyncFileSender.lock` 内改）。
struct SyncSenderActive {
    let fileID: String
    let fileURL: URL
    let totalSize: Int64
    let name: String
    /// 本轮**声明**的块大小（= file_meta.chunkSize；读块用它，不读常量）
    let chunkSize: Int64
    /// 本轮起点（> 0 = 断点续传）/ 开始时刻（诊断）
    let startOffset: Int64
    let startedAt: Date
    var handle: FileHandle?
    /// 最近一次**推进**的 ack 的 receivedBytes（重复/滞后 ack 的判定基线）
    var lastAckBytes: Int64?
    /// 下一个要发的字节偏移（严格有序、连续；窗口内可多块在途）
    var nextOffset: Int64
    /// 在途未确认的块（按发送顺序；窗口占用 = `inFlight.count`）
    var inFlight: [SyncSenderSentChunk]
    /// 窗口深度（1 = 停等 / 旧对端；应答 file_meta 的 ack 协商后可能 > 1）
    var window: Int
    /// 在途块数峰值（诊断：判断窗口是否真的打满）
    var inFlightMax: Int
    /// file_chunk 载荷累计字节（诊断：看 base64 的 33% 膨胀）
    var wireBytes: Int
    /// 是否走二进制块载荷（对端在 ack 里声明才开）
    var binaryChunks: Bool
    /// 已发出的块数（诊断用）
    var chunksSent: Int
    /// 首块/末块发出时刻 + 对应往返（秒；只留首末两次，不逐块刷屏）
    var firstChunkSentAt: Date?
    /// 首块发出时刻（**单调时钟**，探针计时基线：不受系统改时间影响）。
    var firstChunkSentUptime: TimeInterval?
    var lastChunkSentAt: Date?
    var firstChunkWait: TimeInterval?
    var lastChunkWait: TimeInterval?
}
