//
//  SyncTransferTiming.swift
//  QQPlayer
//
//  同步文件传输「分段计时埋点」（2026-11-13 立，诊断专用）。
//
//  背景：同一时段 iPhone→Mac 下载 25–42MB/s，Mac→iPhone 上传只有 3–5MB/s，
//  发送端 ackWaitLast ≈ 1.2–1.4s / 8 块 ⇒ 慢在「iPhone 收完数据 → 回 ack」这段。
//  本文件只负责**把这段切成可测的分段**：时间戳取单调时钟、拼成一行 key=value。
//
//  硬约束（任务包）：
//   - 只加诊断：不发新帧、不动窗口 / 块大小 / 重试 / 超时 / 线程模型；
//   - 每条 1 行，只在传输进行中落盘（门控见 `SyncConnectDiag.isTransferTracing`）；
//   - **不在锁内拼串**：调用方先取时间戳，出锁后再调本类型拼串 + 落盘；
//   - 毫秒统一 1 位小数（`%.1f` 语义，但**手工格式化**，不受 locale 影响）。
//
//  行格式（字段顺序固定；按空格切分后按 key=value 取值）：
//    rx    seq=<n> bytes=<m> dt=<ms|-> qdelay=<ms>          收包回调（dt 首帧为 -）
//    rxp   frames=<n> bytes=<m> parse=<ms> decrypt=<ms>      会话层拼帧 + 解密
//    tx    seq=<n> bytes=<m> q=<ms> kern=<ms>                出站：入队→send→contentProcessed
//    chunk idx=<n> bytes=<m> pre=<ms> write=<ms> ackEnqueue=<ms>
//    send  idx=<n> bytes=<m> tx=<ms> ackRx=<ms>
//
//  ackSent / sendDone 由 tx 行给出：contentProcessed 必然晚于应用层写日志，同一行写不出来。
//  对齐规则（两端一致）：
//    - 接收端：chunk 行之后紧跟的那条 tx 行（bytes 约 40–60B）= 该块 ack 的投递延迟；
//    - 发送端：send 行之后紧跟的那条 tx 行（bytes ≈ 块大小 + 38B）= 该块 contentProcessed 延迟。
//  iOS 侧所有行都经 SyncConnectDiag 的串行队列落盘，调用顺序 = 落盘顺序；macOS 走 stdout。
//  bytes 口径：chunk 行 = 该帧 payload 字节（文件字节 + 加密 tag + fileID 前缀），
//  send 行 = 本块文件字节数（差值是固定开销，故意不复用同一口径）。
//

import Foundation

/// 传输分段计时（纯函数 + 单调时钟；无状态，任意线程可用）。
enum SyncTransferTiming {
    /// 单调时钟（秒）：不受系统改时间影响，跨段相减得 ms。
    static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    /// 秒差 → 毫秒（保留 1 位小数，四舍五入；负数按数学四舍五入处理）。
    static func deltaMs(from start: Double, to end: Double) -> Double {
        decimal((end - start) * 1000)
    }

    /// 毫秒数值 → 1 位小数字符串（手工格式化：`String(format:)` 受 locale 影响）。
    static func ms(_ milliseconds: Double) -> String {
        render(decimal(milliseconds))
    }

    /// 1 位小数归一（.05 进位 / 避免 -0.0）。
    static func decimal(_ value: Double) -> Double {
        let scaled = (value * 10).rounded()
        return scaled == 0 ? 0 : scaled / 10
    }

    /// 归一后的数值 → 定长小数字符串（不依赖 locale）。
    static func render(_ value: Double) -> String {
        let scaled = Int((value * 10).rounded())
        let negative = scaled < 0
        let magnitude = negative ? -scaled : scaled
        let whole = magnitude / 10
        let fraction = magnitude % 10
        return "\(negative ? "-" : "")\(whole).\(fraction)"
    }

    // MARK: 行拼装（纯函数，单测覆盖）

    /// 收包回调：`dt` = 距上次回调（首帧传 nil → `-`），`qdelay` = 回调 → 串行队列执行。
    static func receiveLine(seq: Int, bytes: Int, sinceLastMs: Double?, queueDelayMs: Double) -> String {
        let dt = sinceLastMs.map { ms($0) } ?? "-"
        return "rx seq=\(seq) bytes=\(bytes) dt=\(dt) qdelay=\(ms(queueDelayMs))"
    }

    /// 会话层单次入站处理：拼帧/拆帧 + 解密。
    static func parseLine(frames: Int, bytes: Int, parseMs: Double, decryptMs: Double) -> String {
        "rxp frames=\(frames) bytes=\(bytes) parse=\(ms(parseMs)) decrypt=\(ms(decryptMs))"
    }

    /// 出站一帧：`q` = 入队 → connection.send，`kern` = send → contentProcessed。
    static func outboundLine(seq: Int, bytes: Int, queueDelayMs: Double, kernelMs: Double) -> String {
        "tx seq=\(seq) bytes=\(bytes) q=\(ms(queueDelayMs)) kern=\(ms(kernelMs))"
    }

    /// 接收端单块：`pre` = 帧入口 → 拿到锁，`write` = 写盘，`ackEnqueue` = 造 ack → 入队返回。
    static func chunkLine(idx: Int, bytes: Int, preMs: Double, writeMs: Double,
                          ackEnqueueMs: Double) -> String {
        "chunk idx=\(idx) bytes=\(bytes) pre=\(ms(preMs)) write=\(ms(writeMs)) ackEnqueue=\(ms(ackEnqueueMs))"
    }

    /// 发送端单块往返：`tx` = 相对本轮首块发出的偏移，`ackRx` = 本块发出 → 收到 ack。
    static func sendLine(idx: Int, bytes: Int, txMs: Double, ackRxMs: Double) -> String {
        "send idx=\(idx) bytes=\(bytes) tx=\(ms(txMs)) ackRx=\(ms(ackRxMs))"
    }
}

/// 会话层单次入站处理的分段快照（锁内只填数值，出锁后调 emitLine）。
struct SyncInboundTiming: Sendable {
    /// 本次回调拆出的完整帧数
    let frames: Int
    /// 本次回调收到的原始字节数（线上字节，含帧头 / 加密开销）
    let bytes: Int
    /// 拼帧 + 拆帧耗时（毫秒）
    let parseMs: Double
    /// 本次回调内所有 ready 帧的解密耗时合计（毫秒）
    let decryptMs: Double

    /// 门控 + 落盘（调用方保证在锁外调用：这里做字符串拼接与 IO）。
    func emitLine() {
        guard SyncConnectDiag.isTransferTracing else { return }
        SyncConnectDiag.log(SyncTransferTiming.parseLine(
            frames: frames,
            bytes: bytes,
            parseMs: parseMs,
            decryptMs: decryptMs
        ))
    }
}

/// 发送端「本块往返」快照（锁内只存数值，出锁后才拼串落盘）。
struct SyncChunkRoundTrip: Equatable, Sendable {
    /// 块序号（1 起，本轮内单调）
    let index: Int
    /// 本块文件字节数（不含帧头/加密开销）
    let bytes: Int
    /// 本块发出时刻 − 本轮首块发出时刻（毫秒）
    let txMs: Double
    /// 本块发出 → 收到覆盖它的 ack（毫秒）
    let ackRxMs: Double
}
