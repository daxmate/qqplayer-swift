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

    // MARK: 1. 完整传输（300KB：1 整块 + 1 尾块）

    @Test("完整传输 300KB：字节一致、无 .part、双方 done")
    func fullTransfer300KB() throws {
        let source = pseudoRandomData(300_000)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = try writeSource(source, into: dir)

        let fixture = SessionFixture.pairedHandshake()
        let receiverDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: receiverDir) }

        var senderOutcome: SyncFileSender.Outcome?
        var receiverOutcome: SyncFileReceiver.Outcome?
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: receiverDir)
        receiver.onCompletion = { receiverOutcome = $0 }
        let sender = SyncFileSender(session: fixture.hostSession)
        sender.onCompletion = { senderOutcome = $0 }

        try sender.send(fileURL: sourceURL, fileID: "t1", name: "song.bin")

        #expect(senderOutcome == .succeeded)
        guard case let .received(finalURL)? = receiverOutcome else {
            Issue.record("期望 received，实际 \(String(describing: receiverOutcome))")
            return
        }
        #expect(try Data(contentsOf: finalURL) == source)
        #expect(!FileManager.default.fileExists(atPath: finalURL.path + ".part"))
        // 2 块：262144 + 尾块
        #expect(countFrames(ofType: .fileChunk, in: fixture.hostChannel.sentLog) == 2)
    }

    // MARK: 2. 多块大文件（5 整块）

    @Test("多块 5 整块（1_310_720B）：完整传输")
    func multiBlockFiveWholeChunks() throws {
        // 任务包写“1.2MB（5 块整）”：262144 × 5 = 1_310_720B ≈ 1.25MB，
        // 与 1.2MB 表述矛盾——取 5 整块精确值（“5 块整”语义优先）
        let source = pseudoRandomData(Int(SyncFileTransfer.chunkSize) * 5)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = try writeSource(source, into: dir)

        let fixture = SessionFixture.pairedHandshake()
        let receiverDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: receiverDir) }

        var senderOutcome: SyncFileSender.Outcome?
        var receiverOutcome: SyncFileReceiver.Outcome?
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: receiverDir)
        receiver.onCompletion = { receiverOutcome = $0 }
        let sender = SyncFileSender(session: fixture.hostSession)
        sender.onCompletion = { senderOutcome = $0 }

        try sender.send(fileURL: sourceURL, fileID: "t2", name: "big.bin")

        #expect(senderOutcome == .succeeded)
        guard case let .received(finalURL)? = receiverOutcome else {
            Issue.record("期望 received，实际 \(String(describing: receiverOutcome))")
            return
        }
        #expect(try Data(contentsOf: finalURL) == source)
        #expect(!FileManager.default.fileExists(atPath: finalURL.path + ".part"))
        #expect(countFrames(ofType: .fileChunk, in: fixture.hostChannel.sentLog) == 5)
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

        var senderOutcome: SyncFileSender.Outcome?
        var receiverOutcome: SyncFileReceiver.Outcome?
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: receiverDir)
        receiver.onCompletion = { receiverOutcome = $0 }
        let sender = SyncFileSender(session: fixture.hostSession)
        sender.onCompletion = { senderOutcome = $0 }

        try sender.send(fileURL: sourceURL, fileID: "t3", name: "empty.dat")

        #expect(senderOutcome == .succeeded)
        guard case let .received(finalURL)? = receiverOutcome else {
            Issue.record("期望 received，实际 \(String(describing: receiverOutcome))")
            return
        }
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        #expect(try Data(contentsOf: finalURL).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: finalURL.path + ".part"))
        // 空文件只发 meta 不发块
        #expect(countFrames(ofType: .fileChunk, in: fixture.hostChannel.sentLog) == 0)
    }

    // MARK: 4. 断点续传（中断 → 新会话 startOffset 续传；含半块残留 truncate）

    @Test("断点续传：传 1 整块 + 半块残留后中断 → 新会话续传一致")
    func resumeAfterInterruptWithHalfTail() throws {
        // 600KB ≈ 2.3 块。真实协议 ack 只在整块写完后发出，停等中断点永远是整块；
        // “中断在写块中途”留下的半块残留无法经协议自然产生，这里手工追加模拟
        // （覆盖 3.3 的 truncate 对齐路径）
        let source = pseudoRandomData(600_000)
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceURL = try writeSource(source, into: dir)
        let fileID = "resume-1"
        let name = "song.bin"
        let chunkSize = SyncFileTransfer.chunkSize
        let sha = SyncFileChecksum.sha256Hex(of: source)

        // 阶段 1：手动喂 meta + 第 1 整块（无 sender，直接驱动 receiver）
        let fixture1 = SessionFixture.pairedHandshake()
        let receiverDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: receiverDir) }
        var phase1Outcome: SyncFileReceiver.Outcome?
        let receiver1 = SyncFileReceiver(session: fixture1.clientSession, directory: receiverDir)
        receiver1.onCompletion = { phase1Outcome = $0 }

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
        guard case let .failed(.cancelled(cancelFileID))? = phase1Outcome else {
            Issue.record("期望 cancelled，实际 \(String(describing: phase1Outcome))")
            return
        }
        #expect(cancelFileID == fileID)
        #expect(FileManager.default.fileExists(atPath: partURL.path)) // .part 保留

        // 阶段 2：新会话 + 新 sender 以 startOffset=已收完整字节续传
        let fixture2 = SessionFixture.pairedHandshake()
        var phase2Outcome: SyncFileReceiver.Outcome?
        var senderOutcome: SyncFileSender.Outcome?
        var acks: [FileAckPayload] = []
        let receiver2 = SyncFileReceiver(session: fixture2.clientSession, directory: receiverDir)
        receiver2.onCompletion = { phase2Outcome = $0 }
        receiver2.onAckSent = { acks.append($0) }
        let sender2 = SyncFileSender(session: fixture2.hostSession)
        sender2.onCompletion = { senderOutcome = $0 }

        try sender2.send(fileURL: sourceURL, fileID: fileID, name: name,
                         startOffset: chunkSize)

        #expect(senderOutcome == .succeeded)
        #expect(acks.first?.receivedBytes == chunkSize) // 首 ack = 对齐后完整字节（truncate 生效）
        guard case let .received(finalURL)? = phase2Outcome else {
            Issue.record("期望 received，实际 \(String(describing: phase2Outcome))")
            return
        }
        #expect(try Data(contentsOf: finalURL) == source)
        #expect(!FileManager.default.fileExists(atPath: finalURL.path + ".part"))
    }

    // MARK: 5. resume 状态不匹配 → resumeMismatch → startOffset=0 从头重传成功

    @Test("resume 不匹配：.part 与 startOffset 不符 → resumeMismatch，随后从头重传成功")
    func resumeMismatchThenRestart() throws {
        let source = pseudoRandomData(300_000)
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

        var outcomes: [SyncFileSender.Outcome] = []
        var receiverOutcomes: [SyncFileReceiver.Outcome] = []
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: receiverDir)
        receiver.onCompletion = { receiverOutcomes.append($0) }
        let sender = SyncFileSender(session: fixture.hostSession)
        sender.onCompletion = { outcomes.append($0) }

        // 第一轮：startOffset=262144 与本地 .part（500B）不符 → resumeMismatch
        try sender.send(fileURL: sourceURL, fileID: fileID, name: name,
                        startOffset: SyncFileTransfer.chunkSize)
        #expect(outcomes == [.failed(.resumeMismatch(fileID))])
        #expect(receiverOutcomes == [.failed(.resumeMismatch(fileID))]) // 接收端同步中止
        #expect(FileManager.default.fileExists(atPath: partURL.path)) // 中止不动盘

        // 第二轮：startOffset=0 从头重传（receiver 删残留 .part 重建）→ 成功
        try sender.send(fileURL: sourceURL, fileID: fileID, name: name, startOffset: 0)
        #expect(outcomes.last == .succeeded)
        #expect(receiverOutcomes.last == .received(receiverDir.appendingPathComponent(name)))
        let finalURL = receiverDir.appendingPathComponent(name)
        #expect(try Data(contentsOf: finalURL) == source)
        #expect(!FileManager.default.fileExists(atPath: partURL.path))
    }

    // MARK: 6. 幂等（目标已完整存在同名同 sha → 直接 done，不重写不重传）

    @Test("幂等：目标已存在同 sha → 直接 done，文件不重写、0 块帧")
    func idempotentExistingFile() throws {
        let source = pseudoRandomData(300_000)
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

        var senderOutcome: SyncFileSender.Outcome?
        var receiverOutcome: SyncFileReceiver.Outcome?
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: receiverDir)
        receiver.onCompletion = { receiverOutcome = $0 }
        let sender = SyncFileSender(session: fixture.hostSession)
        sender.onCompletion = { senderOutcome = $0 }

        try sender.send(fileURL: sourceURL, fileID: "idem", name: "song.bin")

        #expect(senderOutcome == .succeeded)
        guard case let .received(returnedURL)? = receiverOutcome else {
            Issue.record("期望 received，实际 \(String(describing: receiverOutcome))")
            return
        }
        #expect(returnedURL == finalURL)
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
}
