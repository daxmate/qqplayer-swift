//
//  SyncFileSender+Timing.swift
//  QQPlayer
//
//  发送端「每块往返」分段埋点（2026-11-13 诊断用，不改任何发送行为）。
//
//  为什么每块都要一行：既有汇总只有 ackWaitFirst / ackWaitLast，看不出形状——
//  而这次要定位的正是「前几块快、后几块各慢 200ms」这类分布（上传只有 3–5MB/s，
//  下载却 25–42MB/s，慢点落在「iPhone 收完 → 回 ack」这一段）。
//
//  约束：锁内只存数值（SyncChunkRoundTrip），拼串 + 落盘都在 perform 里（锁外）做。
//

import Foundation

extension SyncFileSender {
    /// 诊断：把本 ack 覆盖的块各记一份往返样本（**锁内调用**，只取数值、不拼串）。
    ///
    /// 口径：tx = 本块发出相对「本轮首块发出」的偏移，ackRx = 本块发出 → 本条 ack 到达。
    /// - Parameters:
    ///   - receivedBytes: 本 ack 声明的累计已收字节（覆盖到哪块就算哪块）
    ///   - now: 本 ack 的处理时刻（单调时钟秒）
    func collectChunkRoundTripsLocked(ackedThrough receivedBytes: Int64, at now: Double) {
        guard let current = active else { return }
        // 只认「不超过已发出字节」的进度：越界 ack 走协议错误路径，记往返只会误导。
        guard receivedBytes <= current.nextOffset else { return }
        let baseline = current.firstChunkSentUptime ?? now
        for chunk in current.inFlight where chunk.end <= receivedBytes {
            pendingChunkRoundTrips.append(SyncChunkRoundTrip(
                index: chunk.index,
                bytes: Int(chunk.length),
                txMs: SyncTransferTiming.deltaMs(from: baseline, to: chunk.sentUptime),
                ackRxMs: SyncTransferTiming.deltaMs(from: chunk.sentUptime, to: now)
            ))
        }
    }

    /// 诊断：把攒下的往返样本落盘（**锁外**；这里才拼串 + 写日志）。
    ///
    /// 前置条件：perform 只在锁外调用（SyncFileSender+Effects.swift 的不变式），
    /// 因此这里再加一次 lock 不会自锁。
    func flushChunkRoundTripDiag() {
        lock.lock()
        let rounds = pendingChunkRoundTrips
        pendingChunkRoundTrips.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !rounds.isEmpty, SyncConnectDiag.isTransferTracing else { return }
        for round in rounds {
            SyncConnectDiag.log(SyncTransferTiming.sendLine(
                idx: round.index,
                bytes: round.bytes,
                txMs: round.txMs,
                ackRxMs: round.ackRxMs
            ))
        }
    }
}
