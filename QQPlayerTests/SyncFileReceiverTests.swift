//
//  SyncFileReceiverTests.swift
//  QQPlayerTests
//
//  S2 M2b：接收端状态机单测——不经会话加密链路，直接构造帧喂
//  SyncFileReceiver.handleInboundFrame（发 ack 仍走 client 会话，host 侧无人听，
//  由 onAckSent 钩子断言 ack 内容）。覆盖任务包 3.2 的异常/校验路径：
//  篡改块→checksumMismatch、乱序块→protocolError、参数非法→protocolError、
//  无 meta 先到块、receiver 不收 ack、同 fileID 重启、resume 边界态。
//  成功路径 E2E 见 SyncFileTransferTests.swift。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 测试

struct SyncFileReceiverTests {
    // MARK: 工具

    /// 确定性伪随机数据（与 SyncFileTransferTests 同款 LCG）。
    private func pseudoRandomData(_ count: Int) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count)
        var state: UInt32 = 0x5EED_2026
        for _ in 0 ..< count {
            state = state &* 1_664_525 &+ 1_013_904_223
            bytes.append(UInt8(truncatingIfNeeded: state >> 24))
        }
        return Data(bytes)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-sync-m2b-rx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func metaFrame(_ meta: FileMetaPayload) throws -> SyncFrame {
        SyncFrame(type: .fileMeta, payload: try SyncFilePayloadCodec.encode(meta))
    }

    private func chunkFrame(_ chunk: FileChunkPayload) throws -> SyncFrame {
        SyncFrame(type: .fileChunk, payload: try SyncFilePayloadCodec.encode(chunk))
    }

    private func ackFrame(_ ack: FileAckPayload) throws -> SyncFrame {
        SyncFrame(type: .fileAck, payload: try SyncFilePayloadCodec.encode(ack))
    }

    /// 回调日志（引用语义盒子）。⚠️ 不能把数组按值随 tuple 返回：闭包捕获的 var 是
    /// 装箱存储，return 时拷贝的是当时的空值，之后闭包 append 只写 box——测试侧永远
    /// 读不到（曾致全套 ack/outcome 断言全盲，CI 全红）。class 承载引用共享。
    private final class ReceiverLog {
        var acks: [FileAckPayload] = []
        var outcomes: [SyncFileReceiver.Outcome] = []
    }

    /// 一套可直驱的 receiver：client 会话就绪，receiver 落盘到临时目录。
    private func makeReceiver(_ name: String = "song.bin") throws
        -> (receiver: SyncFileReceiver, dir: URL, log: ReceiverLog) {
        let fixture = SessionFixture.pairedHandshake()
        let dir = try makeTempDir()
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: dir)
        let log = ReceiverLog()
        receiver.onAckSent = { log.acks.append($0) }
        receiver.onCompletion = { log.outcomes.append($0) }
        return (receiver, dir, log)
    }

    private func fileExists(_ dir: URL, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    // MARK: 篡改块 → checksumMismatch（.part 删除、无最终文件）

    @Test("篡改块：中途改某 chunk 数据 → 校验失败 checksumMismatch、.part 删除")
    func tamperedChunkChecksumMismatch() throws {
        let source = pseudoRandomData(300_000) // 2 块
        let (receiver, dir, log) = try makeReceiver()
        let fileID = "tamper"
        let name = "song.bin"

        receiver.handleInboundFrame(try metaFrame(FileMetaPayload(
            fileID: fileID, name: name, totalSize: Int64(source.count),
            chunkSize: SyncFileTransfer.chunkSize,
            sha256Hex: SyncFileChecksum.sha256Hex(of: source), startOffset: 0
        )))
        // 第 1 块原样
        receiver.handleInboundFrame(try chunkFrame(FileChunkPayload(
            fileID: fileID, offset: 0, data: Data(source.prefix(Int(SyncFileTransfer.chunkSize)))
        )))
        // 第 2 块篡改（末尾翻转 16 字节）
        var tampered = Data(source.dropFirst(Int(SyncFileTransfer.chunkSize)))
        for i in (tampered.count - 16) ..< tampered.count {
            tampered[i] ^= 0xFF
        }
        receiver.handleInboundFrame(try chunkFrame(FileChunkPayload(
            fileID: fileID, offset: SyncFileTransfer.chunkSize, data: Data(tampered)
        )))

        #expect(log.acks.last?.error == .checksumMismatch)
        #expect(log.acks.last?.fileID == fileID)
        #expect(log.outcomes == [.failed(.checksumMismatch(fileID))])
        #expect(!fileExists(dir, name + ".part"))
        #expect(!fileExists(dir, name))
    }

    // MARK: 乱序/跳 offset → protocolError

    @Test("乱序块：跳过 offset 0 直接发块 1 → protocolError 中止")
    func outOfOrderChunkProtocolError() throws {
        let source = pseudoRandomData(300_000)
        let (receiver, dir, log) = try makeReceiver()
        let fileID = "order"

        receiver.handleInboundFrame(try metaFrame(FileMetaPayload(
            fileID: fileID, name: "song.bin", totalSize: Int64(source.count),
            chunkSize: SyncFileTransfer.chunkSize,
            sha256Hex: SyncFileChecksum.sha256Hex(of: source), startOffset: 0
        )))
        // 直接发第 2 块（期望 offset 0）
        receiver.handleInboundFrame(try chunkFrame(FileChunkPayload(
            fileID: fileID, offset: SyncFileTransfer.chunkSize,
            data: Data(source.prefix(Int(SyncFileTransfer.chunkSize)))
        )))

        #expect(log.acks.last?.error == .protocolError)
        guard case let .failed(.protocolError(id, _))? = log.outcomes.last else {
            Issue.record("期望 protocolError，实际 \(String(describing: log.outcomes))")
            return
        }
        #expect(id == fileID)
        #expect(!receiver.isActive)
        #expect(!fileExists(dir, "song.bin"))
    }

    @Test("超长块（> chunkSize）→ protocolError 中止")
    func oversizedChunkProtocolError() throws {
        let source = pseudoRandomData(300_000)
        let (receiver, _, log) = try makeReceiver()
        let fileID = "oversize"

        receiver.handleInboundFrame(try metaFrame(FileMetaPayload(
            fileID: fileID, name: "song.bin", totalSize: Int64(source.count),
            chunkSize: SyncFileTransfer.chunkSize,
            sha256Hex: SyncFileChecksum.sha256Hex(of: source), startOffset: 0
        )))
        receiver.handleInboundFrame(try chunkFrame(FileChunkPayload(
            fileID: fileID, offset: 0,
            data: pseudoRandomData(Int(SyncFileTransfer.chunkSize) + 1)
        )))
        #expect(log.acks.last?.error == .protocolError)
        #expect(!receiver.isActive)
    }

    // MARK: receiver 不收 ack（忽略且不影响后续）

    @Test("receiver 不收 ack：静默忽略，后续正常收完")
    func ackFrameIgnored() throws {
        let source = pseudoRandomData(1_000) // 单块内
        let (receiver, _, log) = try makeReceiver()
        let fileID = "ackin"
        let name = "song.bin"

        // 先喂一个 stray ack（无活动传输也不崩）
        receiver.handleInboundFrame(try ackFrame(FileAckPayload(
            fileID: "stray", receivedBytes: 0, done: false, error: .none
        )))
        #expect(log.acks.isEmpty)
        #expect(log.outcomes.isEmpty)

        // 正常传输不受影响
        receiver.handleInboundFrame(try metaFrame(FileMetaPayload(
            fileID: fileID, name: name, totalSize: Int64(source.count),
            chunkSize: SyncFileTransfer.chunkSize,
            sha256Hex: SyncFileChecksum.sha256Hex(of: source), startOffset: 0
        )))
        receiver.handleInboundFrame(try chunkFrame(FileChunkPayload(
            fileID: fileID, offset: 0, data: source
        )))
        #expect(log.acks.last?.done == true)
        #expect(log.acks.last?.receivedBytes == Int64(source.count))
        guard case let .received(finalURL)? = log.outcomes.last else {
            Issue.record("期望 received，实际 \(String(describing: log.outcomes))")
            return
        }
        #expect(try Data(contentsOf: finalURL) == source)
    }

    // MARK: meta 参数非法 → protocolError

    @Test("非法 meta（chunkSize 0 / 坏 sha / name 含路径 / 负 totalSize / 0 字节非空 sha）→ protocolError")
    func invalidMetaProtocolError() throws {
        let source = pseudoRandomData(1_000)
        let (receiver, _, log) = try makeReceiver()
        let validSha = SyncFileChecksum.sha256Hex(of: source)

        let invalidMetas: [(FileMetaPayload, String)] = [
            (FileMetaPayload(fileID: "m1", name: "a.bin", totalSize: 1_000, chunkSize: 0,
                             sha256Hex: validSha, startOffset: 0), "chunkSize=0"),
            (FileMetaPayload(fileID: "m2", name: "a.bin", totalSize: 1_000, chunkSize: 262_144,
                             sha256Hex: "zz", startOffset: 0), "sha 非法"),
            (FileMetaPayload(fileID: "m3", name: "a/b.bin", totalSize: 1_000, chunkSize: 262_144,
                             sha256Hex: validSha, startOffset: 0), "name 含路径"),
            (FileMetaPayload(fileID: "m4", name: "a.bin", totalSize: -1, chunkSize: 262_144,
                             sha256Hex: validSha, startOffset: 0), "totalSize 负"),
            (FileMetaPayload(fileID: "m5", name: "", totalSize: 1_000, chunkSize: 262_144,
                             sha256Hex: validSha, startOffset: 0), "name 空"),
            (FileMetaPayload(fileID: "m6", name: "a.bin", totalSize: 0, chunkSize: 262_144,
                             sha256Hex: validSha, startOffset: 0), "0 字节但 sha 非空数据"),
            (FileMetaPayload(fileID: "m7", name: "a.bin", totalSize: 1_000, chunkSize: 262_144,
                             sha256Hex: validSha, startOffset: 100_000), "startOffset > totalSize"),
            (FileMetaPayload(fileID: "m8", name: "a.bin", totalSize: 1_000, chunkSize: 262_144,
                             sha256Hex: validSha, startOffset: -1), "startOffset 负"),
            (FileMetaPayload(fileID: "m9", name: "a.bin", totalSize: 1_000, chunkSize: 262_144,
                             sha256Hex: validSha, startOffset: 100), "startOffset 不对齐"),
            (FileMetaPayload(fileID: "m10", name: "a.bin", totalSize: 1_000, chunkSize: 20 * 1024 * 1024,
                             sha256Hex: validSha, startOffset: 0), "chunkSize > 16MB"),
        ]
        for (meta, label) in invalidMetas {
            receiver.handleInboundFrame(try metaFrame(meta))
            #expect(log.acks.last?.error == .protocolError, "\(label) 应 protocolError")
            #expect(log.acks.last?.fileID == meta.fileID)
        }
        #expect(log.outcomes.isEmpty) // 非法 meta 未开始传输 → 无本地结论
        #expect(!receiver.isActive)
    }

    // MARK: 无 meta 先到块 → protocolError

    @Test("无 meta 先到块 → protocolError ack")
    func chunkWithoutMetaProtocolError() throws {
        let (receiver, _, log) = try makeReceiver()
        receiver.handleInboundFrame(try chunkFrame(FileChunkPayload(
            fileID: "orphan", offset: 0, data: pseudoRandomData(100)
        )))
        #expect(log.acks.last?.error == .protocolError)
        #expect(log.acks.last?.fileID == "orphan")
        #expect(log.outcomes.isEmpty)
    }

    // MARK: 同 fileID 新 meta = 发送端重启（传输中）

    @Test("传输中同 fileID 新 meta（startOffset=0）→ 重启从头收，最终一致")
    func sameFileMetaRestart() throws {
        let source = pseudoRandomData(300_000) // 2 块
        let (receiver, dir, log) = try makeReceiver()
        let fileID = "restart"
        let name = "song.bin"
        let meta = FileMetaPayload(fileID: fileID, name: name, totalSize: Int64(source.count),
                                   chunkSize: SyncFileTransfer.chunkSize,
                                   sha256Hex: SyncFileChecksum.sha256Hex(of: source), startOffset: 0)

        // 第 1 轮：收 1 块后（传输中）同 fileID 从头重启
        receiver.handleInboundFrame(try metaFrame(meta))
        receiver.handleInboundFrame(try chunkFrame(FileChunkPayload(
            fileID: fileID, offset: 0, data: Data(source.prefix(Int(SyncFileTransfer.chunkSize)))
        )))
        #expect(receiver.isActive)
        receiver.handleInboundFrame(try metaFrame(meta)) // 重启
        // 旧 .part 已删，从头收 2 块
        receiver.handleInboundFrame(try chunkFrame(FileChunkPayload(
            fileID: fileID, offset: 0, data: Data(source.prefix(Int(SyncFileTransfer.chunkSize)))
        )))
        receiver.handleInboundFrame(try chunkFrame(FileChunkPayload(
            fileID: fileID, offset: SyncFileTransfer.chunkSize,
            data: Data(source.dropFirst(Int(SyncFileTransfer.chunkSize)))
        )))

        #expect(log.acks.last?.done == true)
        guard case let .received(finalURL)? = log.outcomes.last else {
            Issue.record("期望 received，实际 \(String(describing: log.outcomes))")
            return
        }
        #expect(try Data(contentsOf: finalURL) == source)
        #expect(!fileExists(dir, name + ".part"))
    }

    // MARK: resume 边界态

    @Test("无 .part 且 startOffset>0 → resumeMismatch（resume 数据源缺失）")
    func resumeWithoutPartMismatch() throws {
        let source = pseudoRandomData(300_000)
        let (receiver, _, log) = try makeReceiver()
        receiver.handleInboundFrame(try metaFrame(FileMetaPayload(
            fileID: "nopart", name: "song.bin", totalSize: Int64(source.count),
            chunkSize: SyncFileTransfer.chunkSize,
            sha256Hex: SyncFileChecksum.sha256Hex(of: source),
            startOffset: SyncFileTransfer.chunkSize
        )))
        #expect(log.acks.last?.error == .resumeMismatch)
        #expect(log.outcomes == [.failed(.resumeMismatch("nopart"))])
    }

    @Test(".part 已含全部字节（上一轮收齐未改名）→ meta 直达校验改名 done")
    func resumePartCompleteVerifyAndRename() throws {
        // 收齐未改名只能发生在块边界收齐瞬间（startOffset == totalSize == 块整数倍）
        let source = pseudoRandomData(Int(SyncFileTransfer.chunkSize)) // 1 整块
        let (receiver, dir, log) = try makeReceiver()
        let fileID = "complete-part"
        let name = "song.bin"
        // .part 已收齐（模拟收完最后一块但未及改名的中断）
        let partURL = dir.appendingPathComponent(name + ".part")
        try source.write(to: partURL)

        receiver.handleInboundFrame(try metaFrame(FileMetaPayload(
            fileID: fileID, name: name, totalSize: Int64(source.count),
            chunkSize: SyncFileTransfer.chunkSize,
            sha256Hex: SyncFileChecksum.sha256Hex(of: source),
            startOffset: Int64(source.count)
        )))
        #expect(log.acks.last?.done == true)
        guard case let .received(finalURL)? = log.outcomes.last else {
            Issue.record("期望 received，实际 \(String(describing: log.outcomes))")
            return
        }
        #expect(try Data(contentsOf: finalURL) == source)
        #expect(!fileExists(dir, name + ".part"))
    }

    @Test(".part 已含全部字节但 sha 不符 → 删 .part + checksumMismatch")
    func resumePartCompleteChecksumMismatch() throws {
        let source = pseudoRandomData(Int(SyncFileTransfer.chunkSize))
        let (receiver, dir, log) = try makeReceiver()
        let fileID = "bad-part"
        let name = "song.bin"
        // .part 是损坏数据（与声明 sha 不符）——注意 pseudoRandomData 每次调用同种子
        // 确定性输出，直接再调一次得到的是相同数据，必须先翻转字节再落盘
        let partURL = dir.appendingPathComponent(name + ".part")
        var corrupted = pseudoRandomData(Int(SyncFileTransfer.chunkSize))
        corrupted[0] ^= 0xFF
        try corrupted.write(to: partURL)

        receiver.handleInboundFrame(try metaFrame(FileMetaPayload(
            fileID: fileID, name: name, totalSize: Int64(source.count),
            chunkSize: SyncFileTransfer.chunkSize,
            sha256Hex: SyncFileChecksum.sha256Hex(of: source),
            startOffset: Int64(source.count)
        )))
        #expect(log.acks.last?.error == .checksumMismatch)
        #expect(log.outcomes == [.failed(.checksumMismatch(fileID))])
        #expect(!fileExists(dir, name + ".part"))
        #expect(!fileExists(dir, name))
    }
}
