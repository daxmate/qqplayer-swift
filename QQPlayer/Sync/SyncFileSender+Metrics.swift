//
//  SyncFileSender+Metrics.swift
//  QQPlayer
//
//  发送端计时/错误映射（从 SyncFileSender 拆出的纯取值逻辑）：
//  - `metricsLocked`：本轮计时行（含 2026-11-11 起的 conc= / slot= 并发字段）
//  - `localError` / `errorCode(for:)`：线上错误码 → 本端错误的唯一映射
//  - `fileSize` / `activeID`：小工具（锁内/锁外语义见各自注释）
//
//  为什么单独一文件：主类已经接近结构预算棘轮的单文件上限（> 600 行即被 CI 拦），
//  这些函数不碰状态机，拆出来零风险。
//

import Foundation

extension SyncFileSender {
    /// 本轮实测计时（锁内取快照：只读 `current`，不动状态）。
    func metricsLocked(_ current: Active, succeeded: Bool,
                       error: SyncFileTransferError?) -> SyncTransferMetrics {
        SyncTransferMetrics(
            role: .send,
            fileID: current.fileID,
            startOffset: current.startOffset,
            totalSize: current.totalSize,
            chunkSize: current.chunkSize,
            chunks: current.chunksSent,
            milliseconds: Int(Date().timeIntervalSince(current.startedAt) * 1000),
            firstChunkWaitMs: current.firstChunkWait.map { Int($0 * 1000) },
            lastChunkWaitMs: current.lastChunkWait.map { Int($0 * 1000) },
            succeeded: succeeded,
            errorLine: error.map { "\($0)" },
            window: current.window,
            inFlightMax: current.inFlightMax,
            wireBytes: current.wireBytes,
            concurrency: metricConcurrency,
            slot: metricSlot
        )
    }

    func localError(_ code: FileTransferErrorCode, fileID: String) -> SyncFileTransferError {
        switch code {
        case .none: return .protocolError(fileID, "对端 ack 错误码缺失")
        case .ioError: return .ioError(fileID)
        case .diskFull: return .diskFull(fileID)
        case .checksumMismatch: return .checksumMismatch(fileID)
        case .resumeMismatch: return .resumeMismatch(fileID)
        case .cancelled: return .cancelled(fileID)
        case .protocolError: return .protocolError(fileID, "对端协议中止")
        case .probeUnsupported: return .probeUnsupported(fileID)
        }
    }

    func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
    }

    func activeID() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return active?.fileID
    }
}
