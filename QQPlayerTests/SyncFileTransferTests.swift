//
//  SyncFileTransferTests.swift
//  QQPlayerTests
//
//  S2 M2b：文件传输原语层端到端测试（sender ↔ receiver 经会话内存回环）。
//  复用 SyncPeerSessionTestSupport.swift 的 SessionFixture（双 ready 会话）。
//  覆盖：完整传输 / 多块大文件 / 空文件 / 断点续传（含半块残留 truncate）/
//        resume 状态不匹配后从头重传 / 幂等 / SHA-256 已知向量。
//  篡改块/乱序块等接收端单测在 SyncFileReceiverTests.swift（直驱帧，不经会话）。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 测试

struct SyncFileTransferTests {
    // MARK: 工具

    /// 确定性伪随机数据（LCG；可复现，便于排查）。
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
            .appendingPathComponent("qqp-sync-m2b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeSource(_ data: Data, into dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("src.bin")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// 线上帧类型计数（帧头 type 恒明文，第 9 字节；加密不影响）。
    private func countFrames(ofType type: SyncFrameType, in log: [Data]) -> Int {
        log.filter { $0.count >= 10 && $0[$0.startIndex + 8] == type.rawValue }.count
    }

    // MARK: 1. 完整传输（1 整块 + 1 尾块）

    @Test("完整传输（1 整块 + 尾块）：字节一致、无 .part、双方 done、进度按声明块大小推进")
    func fullTransferWholeChunkAndTail() throws {
        // 块大小由发送端声明（`SyncFileTransfer.chunkSize`）：用例按它取尺寸，不写死块
        // 字节数——否则改块大小就得改用例（历史教训：写死 262144 后调块大小会测不出新块）。
        // 断言看的是「接收端 ack 的推进量 == 发送端声明的块大小」，即窄义上的跨端契约。
        let chunkSize = SyncFileTransfer.chunkSize
        let tailBytes = 44_000
        let source = pseudoRandomData(Int(chunkSize) + tailBytes)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = try writeSource(source, into: dir)

        let fixture = SessionFixture.pairedHandshake()
        let receiverDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: receiverDir) }

        let box = TransferBox()
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: receiverDir)
        receiver.onCompletion = { box.receiverOutcome = $0 }
        receiver.onAckSent = { box.acks.append($0) }
        let sender = SyncFileSender(session: fixture.hostSession)
        sender.onCompletion = { box.senderOutcome = $0 }

        try sender.send(fileURL: sourceURL, fileID: "t1", name: "song.bin")

        #expect(box.senderOutcome == .succeeded)
        guard case let .received(receivedFile)? = box.receiverOutcome else {
            Issue.record("期望 received，实际 \(String(describing: box.receiverOutcome))")
            return
        }
        let finalURL = receivedFile.url
        #expect(try Data(contentsOf: finalURL) == source)
        #expect(!FileManager.default.fileExists(atPath: finalURL.path + ".part"))
        // 2 块：1 整块（= 声明块大小）+ 尾块
        #expect(countFrames(ofType: .fileChunk, in: fixture.hostChannel.sentLog) == 2)
        // ack 序列：meta(0) → 整块(chunkSize) → done(全量)。第一块推进量恰为一个声明块。
        #expect(box.acks.map(\.receivedBytes) == [0, chunkSize, Int64(source.count)])
        #expect(box.acks.last?.done == true)
    }

    // MARK: 2. 多块大文件（5 整块）

    @Test("多块 5 整块：完整传输、每块推进量 = 声明块大小")
    func multiBlockFiveWholeChunks() throws {
        // 任务包写“除块大小外不改判据”：这里尺寸改由声明块大小推导（原写死 262144×5），
        // 块数仍为 5，测的还是「多块停等往返 + 末块 done 字节对得上」。
        let chunkSize = SyncFileTransfer.chunkSize
        let source = pseudoRandomData(Int(chunkSize) * 5)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = try writeSource(source, into: dir)

        let fixture = SessionFixture.pairedHandshake()
        let receiverDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: receiverDir) }

        let box = TransferBox()
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: receiverDir)
        receiver.onCompletion = { box.receiverOutcome = $0 }
        receiver.onAckSent = { box.acks.append($0) }
        let sender = SyncFileSender(session: fixture.hostSession)
        sender.onCompletion = { box.senderOutcome = $0 }

        try sender.send(fileURL: sourceURL, fileID: "t2", name: "big.bin")

        #expect(box.senderOutcome == .succeeded)
        guard case let .received(receivedFile)? = box.receiverOutcome else {
            Issue.record("期望 received，实际 \(String(describing: box.receiverOutcome))")
            return
        }
        let finalURL = receivedFile.url
        #expect(try Data(contentsOf: finalURL) == source)
        #expect(!FileManager.default.fileExists(atPath: finalURL.path + ".part"))
        #expect(countFrames(ofType: .fileChunk, in: fixture.hostChannel.sentLog) == 5)
        // 5 整块：除末块 ack（done = 全量）外，每次进度 ack 都恰推进一个声明块
        let expectedAcks: [Int64] = [0, chunkSize, chunkSize * 2, chunkSize * 3, chunkSize * 4, Int64(source.count)]
        #expect(box.acks.map(\.receivedBytes) == expectedAcks)
        #expect(box.acks.last?.done == true)
    }

    // MARK: 3. 空文件

    @Test("空文件：直接 done，落 0 字节最终文件、无 .part")
    func emptyFile() throws {
        let source = Data()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = try writeSource(source, into: dir)

        let fixture = SessionFixture.pairedHandshake()
        let receiverDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: receiverDir) }

        let box = TransferBox()
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: receiverDir)
        receiver.onCompletion = { box.receiverOutcome = $0 }
        let sender = SyncFileSender(session: fixture.hostSession)
        sender.onCompletion = { box.senderOutcome = $0 }

        try sender.send(fileURL: sourceURL, fileID: "t3", name: "empty.dat")

        #expect(box.senderOutcome == .succeeded)
        guard case let .received(receivedFile)? = box.receiverOutcome else {
            Issue.record("期望 received，实际 \(String(describing: box.receiverOutcome))")
            return
        }
        let finalURL = receivedFile.url
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        #expect(try Data(contentsOf: finalURL).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: finalURL.path + ".part"))
        // 空文件只发 meta 不发块
        #expect(countFrames(ofType: .fileChunk, in: fixture.hostChannel.sentLog) == 0)
    }

    // MARK: 4. 断点续传（中断 → 新会话 startOffset 续传；含半块残留 truncate）

    @Test("断点续传：传 1 整块 + 半块残留后中断 → 新会话续传一致")
    func resumeAfterInterruptWithHalfTail() throws {
        // 1 整块 + 尾部零头。真实协议 ack 只在整块写完后发出，停等中断点永远是整块；
        // “中断在写块中途”留下的半块残留无法经协议自然产生，这里手工追加模拟
        // （覆盖 3.3 的 truncate 对齐路径）
        let chunkSize = SyncFileTransfer.chunkSize
        let tailBytes = 12_345
        let source = pseudoRandomData(Int(chunkSize) + tailBytes)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = try writeSource(source, into: dir)
        let fileID = "resume-1"
        let name = "song.bin"
        let sha = SyncFileChecksum.sha256Hex(of: source)

        // 阶段 1：手动喂 meta + 第 1 整块（无 sender，直接驱动 receiver）
        let fixture1 = SessionFixture.pairedHandshake()
        let receiverDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: receiverDir) }
        let box = TransferBox()
        let receiver1 = SyncFileReceiver(session: fixture1.clientSession, directory: receiverDir)
        receiver1.onCompletion = { box.phase1Outcome = $0 }

        let meta1 = FileMetaPayload(fileID: fileID, name: name, totalSize: Int64(source.count),
                                    chunkSize: chunkSize, sha256Hex: sha, startOffset: 0)
        receiver1.handleInboundFrame(SyncFrame(type: .fileMeta,
                                               payload: try SyncFilePayloadCodec.encode(meta1)))
        let block0 = source.prefix(Int(chunkSize))
        receiver1.handleInboundFrame(SyncFrame(type: .fileChunk,
                                               payload: try SyncFilePayloadCodec.encode(
                                                   FileChunkPayload(fileID: fileID, offset: 0, data: Data(block0))
                                               )))

        // 模拟中断在写第 2 块中途：.part 尾部残留半块垃圾
        let partURL = receiverDir.appendingPathComponent(name + ".part")
        #expect(FileManager.default.fileExists(atPath: partURL.path))
        let junk = pseudoRandomData(12_345)
        let partHandle = try FileHandle(forWritingTo: partURL)
        try partHandle.seekToEnd()
        try partHandle.write(contentsOf: junk)
        try partHandle.close()

        // 断连/取消：内存状态清理，.part 保留
        receiver1.cancel()
        guard case let .failed(.cancelled(cancelFileID))? = box.phase1Outcome else {
            Issue.record("期望 cancelled，实际 \(String(describing: box.phase1Outcome))")
            return
        }
        #expect(cancelFileID == fileID)
        #expect(FileManager.default.fileExists(atPath: partURL.path)) // .part 保留

        // 阶段 2：新会话 + 新 sender 以 startOffset=已收完整字节续传
        let fixture2 = SessionFixture.pairedHandshake()
        let receiver2 = SyncFileReceiver(session: fixture2.clientSession, directory: receiverDir)
        receiver2.onCompletion = { box.phase2Outcome = $0 }
        receiver2.onAckSent = { box.acks.append($0) }
        let sender2 = SyncFileSender(session: fixture2.hostSession)
        sender2.onCompletion = { box.senderOutcome = $0 }

        try sender2.send(fileURL: sourceURL, fileID: fileID, name: name,
                         startOffset: chunkSize)

        #expect(box.senderOutcome == .succeeded)
        #expect(box.acks.first?.receivedBytes == chunkSize) // 首 ack = 对齐后完整字节（truncate 生效）
        guard case let .received(receivedFile)? = box.phase2Outcome else {
            Issue.record("期望 received，实际 \(String(describing: box.phase2Outcome))")
            return
        }
        let finalURL = receivedFile.url
        #expect(try Data(contentsOf: finalURL) == source)
        #expect(!FileManager.default.fileExists(atPath: finalURL.path + ".part"))
    }

    // MARK: 5. resume 状态不匹配 → resumeMismatch → startOffset=0 从头重传成功

    @Test("resume 不匹配：.part 与 startOffset 不符 → resumeMismatch，随后从头重传成功")
    func resumeMismatchThenRestart() throws {
        // 文件 > 1 块，才有合法的 startOffset = chunkSize 可试（否则 send 前置校验直接拒）
        let chunkSize = SyncFileTransfer.chunkSize
        let source = pseudoRandomData(Int(chunkSize) + 100_000)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = try writeSource(source, into: dir)
        let fileID = "resume-mm"
        let name = "song.bin"

        let fixture = SessionFixture.pairedHandshake()
        let receiverDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: receiverDir) }

        // 预置一个与 startOffset 不符的 .part（如 500 字节垃圾）
        let partURL = receiverDir.appendingPathComponent(name + ".part")
        try pseudoRandomData(500).write(to: partURL)

        let box = TransferBox()
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: receiverDir)
        receiver.onCompletion = { box.receiverOutcomes.append($0) }
        let sender = SyncFileSender(session: fixture.hostSession)
        sender.onCompletion = { box.outcomes.append($0) }

        // 第一轮：startOffset=chunkSize 与本地 .part（500B）不符 → resumeMismatch
        try sender.send(fileURL: sourceURL, fileID: fileID, name: name,
                        startOffset: SyncFileTransfer.chunkSize)
        #expect(box.outcomes == [.failed(.resumeMismatch(fileID))])
        #expect(box.receiverOutcomes == [.failed(.resumeMismatch(fileID))]) // 接收端同步中止
        #expect(FileManager.default.fileExists(atPath: partURL.path)) // 中止不动盘

        // 第二轮：startOffset=0 从头重传（receiver 删残留 .part 重建）→ 成功
        try sender.send(fileURL: sourceURL, fileID: fileID, name: name, startOffset: 0)
        #expect(box.outcomes.last == .succeeded)
        if case let .received(receivedFile)? = box.receiverOutcomes.last {
            #expect(receivedFile.url == receiverDir.appendingPathComponent(name))
        } else {
            Issue.record("期望 received，实际 \(String(describing: box.receiverOutcomes))")
        }
        let finalURL = receiverDir.appendingPathComponent(name)
        #expect(try Data(contentsOf: finalURL) == source)
        #expect(!FileManager.default.fileExists(atPath: partURL.path))
    }

    // MARK: 6. 幂等（目标已完整存在同名同 sha → 直接 done，不重写不重传）

    @Test("幂等：目标已存在同 sha → 直接 done，文件不重写、0 块帧")
    func idempotentExistingFile() throws {
        // 尺寸 > 1 块：幂等真的省了块传输（而不是本来就只有 1 块）
        let source = pseudoRandomData(Int(SyncFileTransfer.chunkSize) + 44_000)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = try writeSource(source, into: dir)

        let fixture = SessionFixture.pairedHandshake()
        let receiverDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: receiverDir) }
        // 预置完整目标文件 + 旧 mtime（验证不被重写）
        let finalURL = receiverDir.appendingPathComponent("song.bin")
        try source.write(to: finalURL)
        let oldDate = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: finalURL.path)

        let box = TransferBox()
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: receiverDir)
        receiver.onCompletion = { box.receiverOutcome = $0 }
        let sender = SyncFileSender(session: fixture.hostSession)
        sender.onCompletion = { box.senderOutcome = $0 }

        try sender.send(fileURL: sourceURL, fileID: "idem", name: "song.bin")

        #expect(box.senderOutcome == .succeeded)
        guard case let .received(returnedFile)? = box.receiverOutcome else {
            Issue.record("期望 received，实际 \(String(describing: box.receiverOutcome))")
            return
        }
        #expect(returnedFile.url == finalURL)
        #expect(try Data(contentsOf: finalURL) == source)
        // 未被重写（mtime 保持旧值）；0 个块帧（没重传）
        let mtime = (try FileManager.default.attributesOfItem(atPath: finalURL.path))[.modificationDate] as? Date
        #expect(mtime == oldDate)
        #expect(countFrames(ofType: .fileChunk, in: fixture.hostChannel.sentLog) == 0)
        #expect(!FileManager.default.fileExists(atPath: finalURL.path + ".part"))
    }

    // MARK: 7. SHA-256 已知向量

    @Test("SHA-256：已知向量（数据 + 文件入口 + 空数据）")
    func sha256KnownVectors() throws {
        #expect(SyncFileChecksum.sha256Hex(of: Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(SyncFileChecksum.emptyHex
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SyncFileChecksum.sha256Hex(of: Data()) == SyncFileChecksum.emptyHex)
        #expect(SyncFileChecksum.isValidSHA256Hex(SyncFileChecksum.emptyHex))
        #expect(!SyncFileChecksum.isValidSHA256Hex("zz"))
        #expect(!SyncFileChecksum.isValidSHA256Hex(String(repeating: "0", count: 63)))

        // 文件入口与数据入口一致
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try writeSource(Data("abc".utf8), into: dir)
        #expect(try SyncFileChecksum.sha256Hex(ofFile: url) == SyncFileChecksum.sha256Hex(of: Data("abc".utf8)))
    }

    // MARK: 8. 复用调用方已算好的 SHA-256（省一次全文件读）

    @Test("precomputedSHA256：复用合法值 → 传输成功，sha 与调用方给的一致")
    func precomputedSHA256ReuseSucceeds() throws {
        let source = pseudoRandomData(8_000)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = try writeSource(source, into: dir)
        let sha = SyncFileChecksum.sha256Hex(of: source)

        let fixture = SessionFixture.pairedHandshake()
        let receiverDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: receiverDir) }

        let box = TransferBox()
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: receiverDir)
        receiver.onCompletion = { box.receiverOutcome = $0 }
        let sender = SyncFileSender(session: fixture.hostSession)
        sender.onCompletion = { box.senderOutcome = $0 }

        try sender.send(fileURL: sourceURL, fileID: "pre-1", name: "song.bin", precomputedSHA256: sha)

        #expect(box.senderOutcome == .succeeded)
        guard case let .received(receivedFile)? = box.receiverOutcome else {
            Issue.record("期望 received，实际 \(String(describing: box.receiverOutcome))")
            return
        }
        // 接收端落地的身份 sha 就是调用方声明的那一个（声明与实传同一个值）
        #expect(receivedFile.sha256Hex == sha)
        #expect(try Data(contentsOf: receivedFile.url) == source)
    }

    @Test("precomputedSHA256：传入错值 → 接收端仍校验内容 → checksumMismatch（不会静默落错数据）")
    func precomputedSHA256WrongValueStillCaughtOnReceive() throws {
        let source = pseudoRandomData(8_000)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = try writeSource(source, into: dir)
        let wrongSha = SyncFileChecksum.sha256Hex(of: Data("别的文件".utf8))

        let fixture = SessionFixture.pairedHandshake()
        let receiverDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: receiverDir) }

        let box = TransferBox()
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: receiverDir)
        receiver.onCompletion = { box.receiverOutcome = $0 }
        let sender = SyncFileSender(session: fixture.hostSession)
        sender.onCompletion = { box.senderOutcome = $0 }

        try sender.send(fileURL: sourceURL, fileID: "pre-2", name: "song.bin", precomputedSHA256: wrongSha)

        // 复用只是省一次本地读，不是绕过校验：接收端仍按内容算 SHA-256 并拒绝
        #expect(box.senderOutcome == .failed(.checksumMismatch("pre-2")))
        #expect(box.receiverOutcome == .failed(.checksumMismatch("pre-2")))
        #expect(!FileManager.default.fileExists(atPath: receiverDir.appendingPathComponent("song.bin").path))
    }

    @Test("precomputedSHA256：格式非法（调用方 bug）→ 前置抛 invalidArgument，不开传输")
    func precomputedSHA256MalformedThrows() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = try writeSource(pseudoRandomData(1_000), into: dir)

        let fixture = SessionFixture.pairedHandshake()
        let sender = SyncFileSender(session: fixture.hostSession)

        #expect(throws: SyncFileTransferError.invalidArgument("precomputedSHA256 非法：zz")) {
            try sender.send(fileURL: sourceURL, fileID: "pre-3", precomputedSHA256: "zz")
        }
        #expect(!sender.isActive)
    }
}

/// 测试侧 Sendable 盒子（2026-09-20 会话回调收口）：`onCompletion` / `onAckSent` 是 `@Sendable`
/// 类型 ⇒ 闭包不能再捕获可变局部量（`mutation of captured var in concurrently-executing code`），
/// 状态改放盒子里、闭包只写盒子（与 `SyncFileReceiverTests.ReceiverLog`、既有 `*Box` 同款）。
private final class TransferBox: @unchecked Sendable {
    var senderOutcome: SyncFileSender.Outcome?
    var receiverOutcome: SyncFileReceiver.Outcome?
    var phase1Outcome: SyncFileReceiver.Outcome?
    var phase2Outcome: SyncFileReceiver.Outcome?
    var acks: [FileAckPayload] = []
    var outcomes: [SyncFileSender.Outcome] = []
    var receiverOutcomes: [SyncFileReceiver.Outcome] = []
}
