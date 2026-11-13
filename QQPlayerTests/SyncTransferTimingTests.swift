//
//  SyncTransferTimingTests.swift
//  QQPlayerTests
//
//  同步传输分段埋点的**纯拼串**口径测试（2026-11-13 立）：
//  - 毫秒归一/渲染不受 locale 影响（小数点不能变成逗号 / 阿拉伯数字）
//  - 五种日志行的字段顺序与格式稳定（maintainer 拉回日志后按格式解析，格式不能漂）
//  - 首帧无 dt 时用 '-' 占位（解析方据此区分「没有上一帧」与「间隔 0」）
//
//  为什么只测拼串：埋点的时间戳来自 ProcessInfo.systemUptime，端到端时序只能真机取；
//  这里锁住的是**格式契约**（解析侧依赖它），不冒充时序验证。
//

import Testing

@testable import QQPlayer

struct SyncTransferTimingTests {
    // MARK: - 毫秒渲染

    @Test("毫秒保留 1 位小数并四舍五入")
    func msRounding() {
        #expect(SyncTransferTiming.ms(0) == "0.0")
        #expect(SyncTransferTiming.ms(1.2345) == "1.2")
        #expect(SyncTransferTiming.ms(1.25) == "1.3")
        #expect(SyncTransferTiming.ms(0.05) == "0.1")
        #expect(SyncTransferTiming.ms(123.44) == "123.4")
    }

    @Test("负毫秒不出现 -0.0")
    func msNegativeZero() {
        #expect(SyncTransferTiming.ms(-0.04) == "0.0")
        #expect(SyncTransferTiming.ms(-1.26) == "-1.3")
    }

    @Test("秒差换算成毫秒")
    func deltaMs() {
        #expect(SyncTransferTiming.ms(SyncTransferTiming.deltaMs(from: 100, to: 100.25)) == "250.0")
        #expect(SyncTransferTiming.ms(SyncTransferTiming.deltaMs(from: 100.5, to: 100)) == "-500.0")
    }

    // MARK: - 五种行

    @Test("rx 行：首帧 dt=-，字段顺序固定")
    func receiveLineWithoutBaseline() {
        let line = SyncTransferTiming.receiveLine(seq: 1, bytes: 131_072, sinceLastMs: nil, queueDelayMs: 0.4)
        #expect(line == "rx seq=1 bytes=131072 dt=- qdelay=0.4")
    }

    @Test("rx 行：非首帧带 dt")
    func receiveLineWithBaseline() {
        let line = SyncTransferTiming.receiveLine(seq: 12, bytes: 40, sinceLastMs: 12.34, queueDelayMs: 1.05)
        #expect(line == "rx seq=12 bytes=40 dt=12.3 qdelay=1.1")
    }

    @Test("rxp 行：拼帧与解密分开")
    func parseLine() {
        let line = SyncTransferTiming.parseLine(frames: 1, bytes: 131_082, parseMs: 0.8, decryptMs: 1.1)
        #expect(line == "rxp frames=1 bytes=131082 parse=0.8 decrypt=1.1")
    }

    @Test("tx 行：队列段与内核段分开")
    func outboundLine() {
        let line = SyncTransferTiming.outboundLine(seq: 7, bytes: 42, queueDelayMs: 0.2, kernelMs: 2.5)
        #expect(line == "tx seq=7 bytes=42 q=0.2 kern=2.5")
    }

    @Test("chunk 行：写盘与 ack 入队分开")
    func chunkLine() {
        let line = SyncTransferTiming.chunkLine(idx: 3, bytes: 1_048_576, preMs: 0.6, writeMs: 2.2,
                                                ackEnqueueMs: 0.5)
        #expect(line == "chunk idx=3 bytes=1048576 pre=0.6 write=2.2 ackEnqueue=0.5")
    }

    @Test("send 行：相对首块的发出偏移 + 本块往返")
    func sendLine() {
        let line = SyncTransferTiming.sendLine(idx: 8, bytes: 1_048_576, txMs: 1500.4, ackRxMs: 210.5)
        #expect(line == "send idx=8 bytes=1048576 tx=1500.4 ackRx=210.5")
    }

    // MARK: - 样本快照

    @Test("往返样本可等值比较（用于列表整理）")
    func roundTripEquatable() {
        let a = SyncChunkRoundTrip(index: 1, bytes: 1024, txMs: 0, ackRxMs: 12.5)
        let b = SyncChunkRoundTrip(index: 1, bytes: 1024, txMs: 0, ackRxMs: 12.5)
        #expect(a == b)
    }
}
