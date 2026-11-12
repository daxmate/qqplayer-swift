//
//  SyncFileSender+Probe.swift
//  QQPlayer
//
//  T2：发送端的「探针门控」与「终态记账」小工具（从 SyncFileSender.swift 拆出，
//  控制主文件行数预算；行为全在主状态机里调用，本文件不持状态）。
//
import Foundation

extension SyncFileSender {
    /// 探针能力门控（**唯一入口**）：对端没在 meta ack 里声明 `probeCapable` → 中止。
    /// 旧端会把 probe 当普通文件落盘，故必须在发块之前拦住。
    ///
    /// `chunksSent == 0` 是「这条 ack 是 meta 应答」的判据：能力字段只在 meta ack 里带，
    /// 后续块的 ack 不带（若逐条判定会在第一块 ack 上误杀）。
    func probeGatingFailure(_ ack: FileAckPayload, fileID: String,
                            chunksSent: Int) -> SyncFileTransferError? {
        guard chunksSent == 0 else { return nil }
        guard SyncProbe.isProbeFileID(fileID), ack.probeCapable != true else { return nil }
        return .probeUnsupported(fileID)
    }
}

extension SyncSenderActive {
    /// 首块发出时补记单调时钟基线（探针计时用），并更新末块时刻。
    mutating func noteChunkSent(at now: Date) {
        if firstChunkSentAt == nil {
            firstChunkSentAt = now
            firstChunkSentUptime = ProcessInfo.processInfo.systemUptime
        }
        lastChunkSentAt = now
    }
}
