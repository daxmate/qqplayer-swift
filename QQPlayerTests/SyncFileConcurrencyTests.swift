//
//  SyncFileConcurrencyTests.swift
//  QQPlayerTests
//
//  阶段 C（2026-11-11）文件级并发单测（直接构造帧喂 receiver，不经会话加密链路）：
//  - 两文件交错 chunk（A1,B1,A2,B2…）→ 各自字节正确 + ack 累计正确 + 峰值并发 ≥ 2
//  - 并发中同 fileID 重复 meta → 只影响该文件（关旧 handle / 从头重收），另一文件继续
//  - 失败隔离：一个文件校验失败 → 另一个仍完成，终态各自记账
//  - 能力协商两分支：新端声明 maxConcurrentFiles=4；旧端不声明（nil ⇒ 发送端串行）
//  - 接收端并发上限：超出的新文件被拒（protocolError）
//  - 全局在途字节预算：canFit / reserve / release / 峰值语义
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncFileConcurrencyTests {
    // MARK: - 工具

    private final class Log: @unchecked Sendable {
        var acks: [FileAckPayload] = []
        var outcomes: [SyncFileReceiver.Outcome] = []
    }

    private func makeReceiver(_ capabilities: SyncFileTransferCapabilities? = nil)
        throws -> (receiver: SyncFileReceiver, dir: URL, log: Log) {
        let fixture = SessionFixture.pairedHandshake()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-sync-conc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: dir)
        if let capabilities { receiver.capabilityOverride = capabilities }
        let log = Log()
        receiver.onAckSent = { log.acks.append($0) }
        receiver.onCompletion = { log.outcomes.append($0) }
        return (receiver, dir, log)
    }

    private func meta(_ fileID: String, _ name: String, _ data: Data,
                      chunk: Int64) -> FileMetaPayload {
        FileMetaPayload(fileID: fileID, name: name, totalSize: Int64(data.count),
                        chunkSize: chunk, sha256Hex: SyncFileChecksum.sha256Hex(of: data))
    }

    private func feed(_ receiver: SyncFileReceiver, _ meta: FileMetaPayload) throws {
        receiver.handleInboundFrame(SyncFrame(type: .fileMeta,
                                              payload: try SyncFilePayloadCodec.encode(meta)))
    }

    private func feedChunk(_ receiver: SyncFileReceiver, _ fileID: String,
                           offset: Int64, data: Data) throws {
        let chunk = FileChunkPayload(fileID: fileID, offset: offset, data: data)
        receiver.handleInboundFrame(SyncFrame(type: .fileChunk,
                                              payload: try SyncFilePayloadCodec.encode(chunk)))
    }

    private func feedAll(_ receiver: SyncFileReceiver, fileID: String,
                         chunks: [Data], chunkSize: Int64) throws {
        for (index, part) in chunks.enumerated() {
            try feedChunk(receiver, fileID, offset: Int64(index) * chunkSize, data: part)
        }
    }

    private static func pattern(_ marker: UInt8, count: Int) -> Data {
        var bytes = Data(count: count)
        var state: UInt32 = UInt32(marker) << 24 | 0x5A5A
        for index in 0 ..< count {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes[index] = UInt8(truncatingIfNeeded: state >> 24) ^ marker
        }
        return bytes
    }

    private func split(_ data: Data, chunk: Int) -> [Data] {
        stride(from: 0, to: data.count, by: chunk).map { start in
            data.subdata(in: start ..< min(start + chunk, data.count))
        }
    }

    private func landed(_ dir: URL, _ name: String) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent(name))
    }

    // MARK: - 交集投递

    @Test("并发接收：两文件交错 chunk（A1,B1,A2,B2…）→ 各自字节正确、ack 累计正确")
    func interleavedChunksAcrossTwoFiles() throws {
        let (receiver, dir, log) = try makeReceiver()
        let chunk = 4096
        let dataA = Self.pattern(0xA1, count: chunk * 3)
        let dataB = Self.pattern(0xB2, count: chunk * 3)
        try feed(receiver, meta("conc-a", "a.bin", dataA, chunk: Int64(chunk)))
        try feed(receiver, meta("conc-b", "b.bin", dataB, chunk: Int64(chunk)))
        #expect(receiver.isActive)
        #expect(receiver.activeCount == 2)

        let partsA = split(dataA, chunk: chunk)
        let partsB = split(dataB, chunk: chunk)
        for index in 0 ..< max(partsA.count, partsB.count) {
            if index < partsA.count {
                try feedChunk(receiver, "conc-a", offset: Int64(index * chunk), data: partsA[index])
            }
            if index < partsB.count {
                try feedChunk(receiver, "conc-b", offset: Int64(index * chunk), data: partsB[index])
            }
        }

        #expect(log.outcomes.count == 2)
        #expect(try landed(dir, "a.bin") == dataA)
        #expect(try landed(dir, "b.bin") == dataB)
        let lastA = log.acks.last(where: { $0.fileID == "conc-a" })
        let lastB = log.acks.last(where: { $0.fileID == "conc-b" })
        #expect(lastA?.done == true)
        #expect(lastA?.receivedBytes == Int64(dataA.count))
        #expect(lastB?.done == true)
        #expect(lastB?.receivedBytes == Int64(dataB.count))
        #expect(receiver.concurrencyPeak >= 2)
        #expect(!receiver.isActive)
    }

    @Test("并发中同 fileID 重复 meta：该文件从头重收，另一文件不受影响")
    func repeatedMetaOnlyResetsThatFile() throws {
        let (receiver, dir, log) = try makeReceiver()
        let chunk = 4096
        let dataA = Self.pattern(0xA7, count: chunk * 2)
        let dataB = Self.pattern(0xB9, count: chunk * 2)
        let metaA = meta("same-a", "ra.bin", dataA, chunk: Int64(chunk))
        let metaB = meta("same-b", "rb.bin", dataB, chunk: Int64(chunk))
        try feed(receiver, metaA)
        try feed(receiver, metaB)

        let partsA = split(dataA, chunk: chunk)
        let partsB = split(dataB, chunk: chunk)
        try feedChunk(receiver, "same-a", offset: 0, data: partsA[0])
        try feedChunk(receiver, "same-b", offset: 0, data: partsB[0])

        // A 重启（同 fileID 新 meta）→ 只清 A 的状态，B 仍在途
        try feed(receiver, metaA)
        #expect(receiver.isActive)
        #expect(receiver.activeCount == 2)
        let restartAck = log.acks.last(where: { $0.fileID == "same-a" })
        #expect(restartAck?.receivedBytes == 0)

        try feedAll(receiver, fileID: "same-a", chunks: partsA, chunkSize: Int64(chunk))
        for index in 1 ..< partsB.count {
            try feedChunk(receiver, "same-b", offset: Int64(index * chunk), data: partsB[index])
        }

        #expect(log.outcomes.count == 2)
        #expect(try landed(dir, "ra.bin") == dataA)
        #expect(try landed(dir, "rb.bin") == dataB)
    }

    @Test("失败隔离：一个文件校验失败 → 另一个仍完成，终态各自记账")
    func checksumFailureIsIsolated() throws {
        let (receiver, dir, log) = try makeReceiver()
        let chunk = 4096
        let dataA = Self.pattern(0xC1, count: chunk * 2)
        let dataB = Self.pattern(0xD2, count: chunk * 2)
        try feed(receiver, meta("fail-a", "fa.bin", dataA, chunk: Int64(chunk)))
        try feed(receiver, meta("ok-b", "ob.bin", dataB, chunk: Int64(chunk)))

        var partsA = split(dataA, chunk: chunk)
        partsA[1] = Data(partsA[1].map { $0 ^ 0xFF })   // 篡改尾块：长度合法、内容错 → SHA 不匹配
        let partsB = split(dataB, chunk: chunk)

        try feedChunk(receiver, "fail-a", offset: 0, data: partsA[0])
        try feedChunk(receiver, "ok-b", offset: 0, data: partsB[0])
        try feedChunk(receiver, "fail-a", offset: Int64(chunk), data: partsA[1])
        try feedChunk(receiver, "ok-b", offset: Int64(chunk), data: partsB[1])

        #expect(log.outcomes.count == 2)
        let failedA = log.outcomes.contains { outcome in
            if case let .failed(.checksumMismatch(fileID)) = outcome { return fileID == "fail-a" }
            return false
        }
        #expect(failedA)
        let okB = log.outcomes.contains { outcome in
            if case let .received(file) = outcome { return file.fileID == "ok-b" }
            return false
        }
        #expect(okB)
        #expect(try landed(dir, "ob.bin") == dataB)
    }

    // MARK: - 能力协商 / 上限

    @Test("能力协商：新端 ack 声明并发文件数；旧端不声明（nil ⇒ 发送端串行）")
    func metaAckDeclaresConcurrency() throws {
        let modern = try makeReceiver()
        let data = Self.pattern(0x31, count: 16)
        try feed(modern.receiver, meta("neg-1", "n.bin", data, chunk: 4096))
        let modernAck = modern.log.acks.first
        #expect(modernAck?.maxConcurrentFiles == SyncFileTransfer.maxConcurrentFiles)
        #expect(modernAck?.maxInFlight == SyncFileTransfer.maxInFlight)

        let legacy = try makeReceiver(.legacy)
        try feed(legacy.receiver, meta("neg-2", "n2.bin", data, chunk: 4096))
        let legacyAck = legacy.log.acks.first
        #expect(legacyAck?.maxConcurrentFiles == nil)
        #expect(legacyAck?.maxInFlight == nil)
    }

    @Test("接收端并发上限：超出 maxConcurrentFiles 的新文件被拒（protocolError，在途不受影响）")
    func admissionRejectsBeyondLimit() throws {
        let (receiver, _, log) = try makeReceiver()
        let limit = SyncFileTransfer.maxConcurrentFiles
        for index in 0 ..< limit {
            let data = Self.pattern(UInt8(0x40 + index), count: 16)
            try feed(receiver, meta("cap-\(index)", "cap-\(index).bin", data, chunk: 4096))
        }
        #expect(receiver.activeCount == limit)
        let extra = Self.pattern(0x7F, count: 16)
        try feed(receiver, meta("cap-extra", "cap-extra.bin", extra, chunk: 4096))
        #expect(receiver.activeCount == limit)
        let rejected = log.acks.contains { $0.fileID == "cap-extra" && $0.error == .protocolError }
        #expect(rejected)
    }

    // MARK: - 全局在途字节

    @Test("全局在途字节上限：触顶拒绝预留（canFit=false），释放后可继续，峰值可查")
    func inFlightByteBudget() {
        let budget = SyncTransferBudget(byteLimit: 1000)
        #expect(budget.canFit(600))
        #expect(budget.reserve(600))
        #expect(!budget.canFit(500))
        #expect(!budget.reserve(500))
        #expect(budget.inFlightBytes == 600)
        #expect(budget.canFit(400))
        #expect(budget.reserve(400))
        #expect(budget.peakBytes == 1000)
        budget.release(600)
        #expect(budget.inFlightBytes == 400)
        budget.release(10_000) // 多释放不越界
        #expect(budget.inFlightBytes == 0)
    }
}
