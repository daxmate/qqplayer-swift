//
//  SyncTransferConcurrency.swift
//  QQPlayer
//
//  局域网同步（阶段 C，2026-11-11）文件级并发的两个共享件：
//  - SyncTransferConcurrencyPolicy：并发杠杆（同时推进的文件数 / 全局在途字节），全部可注入
//  - SyncTransferBudget：跨文件共享的**全局在途字节**预算（锁内决策、锁外执行）
//
//  为什么要有全局上限：每文件自带 8 块窗口（1MB/块），4 文件并发时理论在途峰值 32MB；
//  接收端要在内存里攒帧 + 解密 + 落盘，iPhone 上 32MB 峰值风险偏高 → 取 24MB 硬顶。
//  触顶时发送端**不排队等待**，直接停止派新块（nextSendLocked 返回 .stop），
//  等已有块 ack 回来再继续（沿用「锁内决策、锁外执行」，不引入新的 DispatchQueue 轮询）。
//
//  为什么并发度要协商：旧接收端不支持多 fileID 同时在途（会把第二个 file_meta 判成
//  protocolError）→ 发送端只在收到对端 `file_ack.maxConcurrentFiles` 声明后才并发；
//  未声明（旧端）一律串行，行为与 v1 完全一致（零回归）。
//

import Foundation

/// 文件级并发的两个杠杆（可注入；生产默认值见 `SyncFileTransfer`）。
struct SyncTransferConcurrencyPolicy: Equatable, Sendable {
    /// 同时推进的文件数上限（本端意愿；实际取 `min(本值, 对端声明, 待传队列)`）。
    ///
    /// 默认值 = `SyncFileTransfer.senderMaxConcurrentFiles`（2026-11-13 起为 1）：
    /// 所有文件共用一条 TCP 连接、一个接收窗口，并发只会排队，实测反而更慢。
    var maxConcurrentFiles: Int
    /// 全局在途字节上限（跨文件共享）。
    var inFlightByteLimit: Int

    init(
        maxConcurrentFiles: Int = SyncFileTransfer.senderMaxConcurrentFiles,
        inFlightByteLimit: Int = SyncFileTransfer.inFlightByteLimit
    ) {
        self.maxConcurrentFiles = max(1, maxConcurrentFiles)
        self.inFlightByteLimit = max(1, inFlightByteLimit)
    }

    /// 生产默认：4 文件 + 24MB 在途。
    static let `default` = SyncTransferConcurrencyPolicy()
}

/// 全局在途字节预算：多文件发送共用同一实例（由 `SyncLibraryPushController` 持有）。
///
/// 语义：`reserve` 是**同步判定**（够就扣、不够就返回 false，绝不排队等待）；
/// `release` 在块被 ack / 传输终止时调用。所有方法线程安全。
final class SyncTransferBudget: @unchecked Sendable {
    let byteLimit: Int
    private let lock = NSLock()
    private var inFlightBytesValue = 0
    private var peakBytesValue = 0

    init(byteLimit: Int = SyncFileTransfer.inFlightByteLimit) {
        self.byteLimit = max(1, byteLimit)
    }

    var inFlightBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlightBytesValue
    }

    /// 本轮峰值在途字节（诊断用）。
    var peakBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakBytesValue
    }

    /// 只读探测：当前预算还塞得下 `bytes` 吗（不扣；用来在**读块之前**决定是否停派）。
    func canFit(_ bytes: Int) -> Bool {
        guard bytes > 0 else { return true }
        lock.lock()
        defer { lock.unlock() }
        return inFlightBytesValue + bytes <= byteLimit
    }

    /// 尝试为一块预留 `bytes` 字节；返回 false = 触顶（调用方停止派新块，等 ack 释放）。
    @discardableResult
    func reserve(_ bytes: Int) -> Bool {
        guard bytes > 0 else { return true }
        lock.lock()
        defer { lock.unlock() }
        guard inFlightBytesValue + bytes <= byteLimit else { return false }
        inFlightBytesValue += bytes
        peakBytesValue = max(peakBytesValue, inFlightBytesValue)
        return true
    }

    /// 释放已确认/已终止块的预留字节。
    func release(_ bytes: Int) {
        guard bytes > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        inFlightBytesValue = max(0, inFlightBytesValue - bytes)
    }

    /// 清零（测试收尾用；正常路径靠 reserve/release 配平）。
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        inFlightBytesValue = 0
        peakBytesValue = 0
    }
}
