//
//  SyncTransferIdentityTests.swift
//  QQPlayerTests
//
//  2026-09-12 审计 B1 修复（W2 包）回归用例——只覆盖本包引入的新语义：
//    🔴T1 认领绑定传输级身份（同名不同目录 + 前一条失败被跳过 → 不错位）
//    🟡T2 每条 announced 条目都有终态；finishBatch 恰一次且幂等（含暂存歌词收尾）
//    🟡T3 落位原子替换；失败保留本端原文件
//    🟡T4 file_meta 解码失败回 protocolError；发送端 ack 超时；等主机答复阶段超时
//    🟡T5 续传对齐 truncate 失败走明确失败路径（不静默继续）
//
//  fixture 复用 SyncPeerSessionTestSupport.swift（SessionFixture 双 ready 回环）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

// MARK: - 夹具

/// 入库入口 spy（断言落位后确实走了既有入库入口）。
private final class TransferSinkSpy: SyncLibrarySyncSink, @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []

    var indexed: [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    func indexLandedFile(at url: URL) {
        lock.lock()
        paths.append(url.path)
        lock.unlock()
    }
}

/// 引用语义盒子（跨线程读写；避免闭包按值捕获 var 造成断言全盲）。
private final class W2Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?

    var value: T? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ new: T) {
        lock.lock()
        stored = new
        lock.unlock()
    }
}

/// 计数器盒子（批次回调计数）。
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

/// 开关盒子（歌曲映射「先解析不出、收尾时能解析出」）。
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isOn: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func turnOn() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

// MARK: - 用例

struct SyncTransferIdentityTests {
    // MARK: 工具

    private func makeTempRoot(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-w2-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeFile(_ relativePath: String, in root: URL, data: Data) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        return url
    }

    private func makeManager() throws -> DatabaseManager {
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        try manager.createTables()
        return manager
    }

    private func metaFrame(_ meta: FileMetaPayload) throws -> SyncFrame {
        SyncFrame(type: .fileMeta, payload: try SyncFilePayloadCodec.encode(meta))
    }

    // MARK: 🔴T1 认领表（纯逻辑）

    @Test("🔴T1 认领表按传输级身份认领：同名多条不按到达序猜")
    func claimTableBindsTransferIdentity() {
        let a = SyncPushEntry(
            relativePath: "A/01 Song.flac", transferName: "01 Song.flac",
            fileID: "hashA", sha256Hex: "hashA", size: 1
        )
        let b = SyncPushEntry(
            relativePath: "B/01 Song.flac", transferName: "01 Song.flac",
            fileID: "hashB", sha256Hex: "hashB", size: 1
        )

        // B 先到：按身份认领到 B（旧实现按名取首个 → 会错认成 A）
        var table = SyncPushClaimTable(entries: [a, b])
        #expect(table.claim(fileID: "hashB", sha256Hex: "hashB", transferName: "01 Song.flac") == "B/01 Song.flac")
        #expect(table.claim(fileID: "hashA", sha256Hex: "hashA", transferName: "01 Song.flac") == "A/01 Song.flac")
        #expect(table.isEmpty)

        // 身份不符且同名多条 → 拒绝落位（宁可不落也不错位）
        var ambiguous = SyncPushClaimTable(entries: [a, b])
        #expect(ambiguous.claim(fileID: "hashX", sha256Hex: "hashX", transferName: "01 Song.flac") == nil)
        #expect(!ambiguous.isEmpty)

        // 对端未指纹（身份留空）→ 同名唯一时按名兜底
        let unknown = SyncPushEntry(
            relativePath: "C/only.flac", transferName: "only.flac",
            fileID: "", sha256Hex: "", size: 1
        )
        var fallback = SyncPushClaimTable(entries: [unknown])
        #expect(fallback.claim(fileID: "whatever", sha256Hex: "whatever", transferName: "only.flac") == "C/only.flac")

        // 失败归因：按身份取走条目（同一身份只能归因一次）
        var failure = SyncPushClaimTable(entries: [a, b])
        #expect(failure.claimFailure(fileID: "hashA") == "A/01 Song.flac")
        #expect(failure.claimFailure(fileID: "hashA") == nil)
        #expect(failure.remainingRelativePaths == ["B/01 Song.flac"])
    }

    // MARK: 🔴T1 推送方向端到端

    @Test("🔴T1 推送：同名前一条发送失败被跳过 → 后一条仍落到自己的路径")
    func pushSkipFirstSameNameLandsAtOwnPath() throws {
        let deviceRoot = try makeTempRoot("push-name")
        let macRoot = try makeTempRoot("push-name-mac")
        let dataA = Data(repeating: 0xA1, count: 4_096)
        let dataB = Data(repeating: 0xB2, count: 4_096)
        let urlA = try writeFile("A/01 Song.flac", in: macRoot, data: dataA)
        let urlB = try writeFile("B/01 Song.flac", in: macRoot, data: dataB)
        let hashA = try SyncFileChecksum.sha256Hex(ofFile: urlA)
        let hashB = try SyncFileChecksum.sha256Hex(ofFile: urlB)

        let entryA = SyncPushEntry(
            relativePath: "A/01 Song.flac", transferName: "01 Song.flac",
            fileID: hashA, sha256Hex: hashA, size: Int64(dataA.count)
        )
        let entryB = SyncPushEntry(
            relativePath: "B/01 Song.flac", transferName: "01 Song.flac",
            fileID: hashB, sha256Hex: hashB, size: Int64(dataB.count)
        )

        let fixture = SessionFixture.pairedHandshake()
        let host = SyncLibraryPassiveHost(
            libraryRoot: deviceRoot,
            sink: TransferSinkSpy(),
            database: try makeManager(),
            lyricsStore: AlignedLyricsStore(directory: try makeTempRoot("push-lyrics")),
            lyricsMapping: .unresolved
        )
        #expect(host.attach(to: fixture.clientSession))
        try fixture.hostSession.sendApplicationFrame(
            type: .libraryPushAnnounce,
            payload: try SyncPushCodec.encode(SyncLibraryPushAnnounce(entries: [entryA, entryB]))
        )

        // 模拟发送端在 A 上失败后 continue：只送出 B（传输名与 A 相同）
        let sender = SyncFileSender(session: fixture.hostSession)
        try sender.send(fileURL: urlB, fileID: hashB, name: entryB.transferName)

        let landedB = deviceRoot.appendingPathComponent("B/01 Song.flac")
        #expect(FileManager.default.fileExists(atPath: landedB.path))
        #expect(try Data(contentsOf: landedB) == dataB)
        #expect(!FileManager.default.fileExists(atPath: deviceRoot.appendingPathComponent("A/01 Song.flac").path))
        #expect(host.summary.landed == ["B/01 Song.flac"])
    }

    // MARK: 🔴T1 拉取方向端到端

    @Test("🔴T1 拉取：同名前一条（不可读）被跳过 → 后一条仍落到自己的路径")
    func pullSkipFirstSameNameLandsAtOwnPath() throws {
        let deviceRoot = try makeTempRoot("pull-name")
        let targetRoot = try makeTempRoot("pull-name-target")
        let dataA = Data(repeating: 0xA1, count: 3_000)
        let dataB = Data(repeating: 0xB2, count: 3_000)
        let urlA = try writeFile("A/01 Song.flac", in: deviceRoot, data: dataA)
        _ = try writeFile("B/01 Song.flac", in: deviceRoot, data: dataB)
        // A 不可读：应答端 content_hash / 现算 SHA-256 都拿不到 → 该条发送失败被跳过
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: urlA.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: urlA.path)
        }

        let fixture = SessionFixture.pairedHandshake()
        let deviceHost = SyncLibraryPassiveHost(
            libraryRoot: deviceRoot,
            sink: TransferSinkSpy(),
            database: try makeManager(),
            lyricsStore: AlignedLyricsStore(directory: try makeTempRoot("pull-device-lyrics")),
            lyricsMapping: .unresolved
        )
        #expect(deviceHost.attach(to: fixture.clientSession))

        let sink = TransferSinkSpy()
        let manager = try makeManager()
        let clientLyrics = AlignedLyricsStore(directory: try makeTempRoot("pull-client-lyrics"))
        let descriptor = SyncLocalLibraryDescriptor(
            libraryRoot: targetRoot,
            rootName: "测试 Mac 曲库",
            lyricsRoot: clientLyrics.directory,
            sourceFiles: { SyncLocalLibraryScanner.sourceFiles(in: targetRoot, database: manager) },
            lyricsEntries: { [] },
            contentHash: { relativePath in
                DatabaseManager.contentHashIfFilePresent(
                    atPath: targetRoot.appendingPathComponent(relativePath).path
                )
            },
            lyricsFileName: { _ in nil }
        )
        let controller = SyncLibraryPullController(
            session: fixture.hostSession,
            descriptor: descriptor,
            sink: sink,
            lyricsMapping: .unresolved
        )
        try controller.start()

        let landedB = targetRoot.appendingPathComponent("B/01 Song.flac")
        #expect(FileManager.default.fileExists(atPath: landedB.path))
        #expect(try Data(contentsOf: landedB) == dataB)
        #expect(!FileManager.default.fileExists(atPath: targetRoot.appendingPathComponent("A/01 Song.flac").path))
        if case let .done(summary) = controller.state {
            #expect(summary.completed == ["B/01 Song.flac"])
        } else {
            Issue.record("期望 done，实际 \(controller.state)")
        }
    }

    // MARK: 🟡T2 批次账目

    @Test("🟡T2 落位失败的条目也进终态账目 → 本批必然收尾")
    func batchCompletesWhenEntryFailsToLand() throws {
        let deviceRoot = try makeTempRoot("t2-land")
        // `Blocked` 是文件：条目落到 `Blocked/x.flac` → 建目录失败 → 落位失败
        _ = try writeFile("Blocked", in: deviceRoot, data: Data([0x01]))
        let macRoot = try makeTempRoot("t2-land-mac")
        let payload = Data(repeating: 0x77, count: 1_024)
        let url = try writeFile("src.flac", in: macRoot, data: payload)
        let hash = try SyncFileChecksum.sha256Hex(ofFile: url)
        let entry = SyncPushEntry(
            relativePath: "Blocked/x.flac", transferName: "x.flac",
            fileID: hash, sha256Hex: hash, size: Int64(payload.count)
        )

        let fixture = SessionFixture.pairedHandshake()
        let host = SyncLibraryPassiveHost(
            libraryRoot: deviceRoot,
            sink: TransferSinkSpy(),
            database: try makeManager(),
            lyricsStore: AlignedLyricsStore(directory: try makeTempRoot("t2-land-lyrics")),
            lyricsMapping: .unresolved
        )
        #expect(host.attach(to: fixture.clientSession))
        let batches = Counter()
        host.onBatchCompleted = { _ in batches.increment() }

        try fixture.hostSession.sendApplicationFrame(
            type: .libraryPushAnnounce,
            payload: try SyncPushCodec.encode(SyncLibraryPushAnnounce(entries: [entry]))
        )
        let sender = SyncFileSender(session: fixture.hostSession)
        try sender.send(fileURL: url, fileID: hash, name: entry.transferName)

        let summary = host.summary
        #expect(summary.batchCompleted)
        #expect(summary.accountedEntries == 1)
        #expect(summary.failed.count == 1)
        #expect(summary.failed.first?.relativePath == "Blocked/x.flac")
        #expect(summary.failed.first?.reason == SyncPushFailureReason.landFailed)
        #expect(batches.count == 1)
    }

    @Test("🟡T2 会话结束时未送达条目记失败终态，本批恰收尾一次")
    func batchClosesOnSessionEndWithTerminalFailure() throws {
        let deviceRoot = try makeTempRoot("t2-abandon")
        let macRoot = try makeTempRoot("t2-abandon-mac")
        let dataA = Data(repeating: 0x31, count: 2_048)
        let urlA = try writeFile("A/a.flac", in: macRoot, data: dataA)
        let hashA = try SyncFileChecksum.sha256Hex(ofFile: urlA)
        let entryA = SyncPushEntry(
            relativePath: "A/a.flac", transferName: "a.flac",
            fileID: hashA, sha256Hex: hashA, size: Int64(dataA.count)
        )
        // B 声明了但发送端从未送出（本地不可读被跳过）
        let entryB = SyncPushEntry(
            relativePath: "B/b.flac", transferName: "b.flac",
            fileID: "hashB", sha256Hex: "hashB", size: 512
        )

        let fixture = SessionFixture.pairedHandshake()
        let host = SyncLibraryPassiveHost(
            libraryRoot: deviceRoot,
            sink: TransferSinkSpy(),
            database: try makeManager(),
            lyricsStore: AlignedLyricsStore(directory: try makeTempRoot("t2-abandon-lyrics")),
            lyricsMapping: .unresolved
        )
        #expect(host.attach(to: fixture.clientSession))
        let batches = Counter()
        host.onBatchCompleted = { _ in batches.increment() }

        try fixture.hostSession.sendApplicationFrame(
            type: .libraryPushAnnounce,
            payload: try SyncPushCodec.encode(SyncLibraryPushAnnounce(entries: [entryA, entryB]))
        )
        let sender = SyncFileSender(session: fixture.hostSession)
        try sender.send(fileURL: urlA, fileID: hashA, name: entryA.transferName)
        #expect(!host.summary.batchCompleted) // 只到了一条：本批还开着

        // 会话结束（对端断开）→ 未送达条目落终态 + 本批收尾
        fixture.hostSession.handleTransportClosed()

        let summary = host.summary
        #expect(summary.batchCompleted)
        #expect(summary.accountedEntries == 2)
        let failedPaths = summary.failed.map(\.relativePath)
        #expect(failedPaths.contains("B/b.flac"))
        #expect(!failedPaths.contains("")) // 失败条目归属到声明路径（不再是无主失败）
        #expect(batches.count == 1)
    }

    @Test("🟡T2 本批有落位失败也照样收尾：暂存歌词在收尾时完成映射")
    func pendingLyricsResolveAtBatchFinishDespiteFailure() throws {
        let deviceRoot = try makeTempRoot("t2-lyrics-device")
        _ = try writeFile("Blocked", in: deviceRoot, data: Data([0x01]))
        let macRoot = try makeTempRoot("t2-lyrics-mac")
        let songHash = String(repeating: "b", count: 64)
        let lyricsData = try JSONEncoder().encode(
            Lyrics(
                plainLyrics: "待映射歌词",
                syncedLyrics: [LyricsLine(timestamp: 1, text: "待映射歌词")],
                isInstrumental: false,
                source: .lrclib
            )
        )
        let lyricsURL = try writeFile("lyrics.json", in: macRoot, data: lyricsData)
        let lyricsHash = try SyncFileChecksum.sha256Hex(ofFile: lyricsURL)
        let lyricsEntry = SyncPushEntry(
            relativePath: "@lyrics/\(songHash).json",
            transferName: "\(songHash).json",
            fileID: songHash,
            sha256Hex: lyricsHash,
            size: Int64(lyricsData.count)
        )
        let blockedPayload = Data(repeating: 0x77, count: 512)
        let blockedURL = try writeFile("blocked.flac", in: macRoot, data: blockedPayload)
        let blockedHash = try SyncFileChecksum.sha256Hex(ofFile: blockedURL)
        let blockedEntry = SyncPushEntry(
            relativePath: "Blocked/x.flac", transferName: "x.flac",
            fileID: blockedHash, sha256Hex: blockedHash, size: Int64(blockedPayload.count)
        )

        let lyricsStore = AlignedLyricsStore(directory: try makeTempRoot("t2-lyrics-store"))
        let resolvable = FlagBox()
        let mapping = SyncLyricsContentMapping(
            contentHashForStableId: { _ in songHash },
            stableIdForContentHash: { _ in resolvable.isOn ? "device-sid" : nil }
        )
        let fixture = SessionFixture.pairedHandshake()
        let host = SyncLibraryPassiveHost(
            libraryRoot: deviceRoot,
            sink: TransferSinkSpy(),
            database: try makeManager(),
            lyricsStore: lyricsStore,
            lyricsMapping: mapping
        )
        #expect(host.attach(to: fixture.clientSession))

        try fixture.hostSession.sendApplicationFrame(
            type: .libraryPushAnnounce,
            payload: try SyncPushCodec.encode(SyncLibraryPushAnnounce(entries: [lyricsEntry, blockedEntry]))
        )
        let sender = SyncFileSender(session: fixture.hostSession)
        // 歌词先到：本端此时还解析不出 stableId → 暂存
        try sender.send(fileURL: lyricsURL, fileID: songHash, name: lyricsEntry.transferName)
        #expect(lyricsStore.stableIds().isEmpty)
        // 收尾前变成可解析（模拟同批歌曲已入库）
        resolvable.turnOn()
        // 第二条落位失败（旧语义下本批永不收尾 → 暂存歌词被丢）
        try sender.send(fileURL: blockedURL, fileID: blockedHash, name: blockedEntry.transferName)

        #expect(host.summary.batchCompleted)
        #expect(try lyricsStore.read(forStableId: "device-sid")?.plainLyrics == "待映射歌词")
        #expect(host.summary.landed.contains(lyricsEntry.relativePath))
    }

    // MARK: 🟡T3 落位原子替换

    @Test("🟡T3 落位原子替换：失败保留本端原文件")
    func landingKeepsLocalOriginalOnFailure() throws {
        let root = try makeTempRoot("t3")
        let old = Data(repeating: 0x11, count: 64)
        let dest = try writeFile("Album/song.flac", in: root, data: old)
        // 源缺失 → 替换失败；本端既有文件必须原样保留（旧实现先删后移会丢文件）
        let missingSource = root.appendingPathComponent(".sync-incoming/ghost.flac")
        #expect(throws: (any Error).self) {
            try SyncLibraryLanding.moveAtomically(from: missingSource, to: dest)
        }
        #expect(try Data(contentsOf: dest) == old)

        // 目标已存在 → 原子替换为新内容
        let incoming = try writeFile(".sync-incoming/new.flac", in: root, data: Data(repeating: 0x22, count: 64))
        try SyncLibraryLanding.moveAtomically(from: incoming, to: dest)
        #expect(try Data(contentsOf: dest) == Data(repeating: 0x22, count: 64))
        #expect(!FileManager.default.fileExists(atPath: incoming.path))

        // 目标不存在 → 直接搬过去
        let fresh = try writeFile(".sync-incoming/fresh.flac", in: root, data: Data(repeating: 0x33, count: 8))
        let newDest = root.appendingPathComponent("Fresh/fresh.flac")
        try FileManager.default.createDirectory(
            at: newDest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try SyncLibraryLanding.moveAtomically(from: fresh, to: newDest)
        #expect(try Data(contentsOf: newDest) == Data(repeating: 0x33, count: 8))
    }

    // MARK: 🟡T4 解码失败 / 超时

    @Test("🟡T4 file_meta 解码失败 → 回 protocolError（不再静默悬挂）")
    func metaDecodeFailureAnswersProtocolError() throws {
        let dir = try makeTempRoot("t4-meta")
        let fixture = SessionFixture.pairedHandshake()
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: dir)
        let acks = W2Box<[FileAckPayload]>()
        receiver.onAckSent = { ack in
            var items = acks.value ?? []
            items.append(ack)
            acks.set(items)
        }

        // fileID 可取、其余字段类型损坏 → 严格解码失败
        try fixture.hostSession.sendApplicationFrame(
            type: .fileMeta,
            payload: Data(#"{"fileID":"abc","name":123,"totalSize":"x"}"#.utf8)
        )
        #expect(acks.value?.last?.fileID == "abc")
        #expect(acks.value?.last?.error == .protocolError)
        #expect(!receiver.isActive)

        // 连 fileID 都取不出 → 不回 ack（发送端由 ack 超时兜底）
        try fixture.hostSession.sendApplicationFrame(type: .fileMeta, payload: Data("[1,2,3]".utf8))
        #expect(acks.value?.count == 1)
    }

    @Test("🟡T4 发送端 ack 超时 → 失败并清状态（可重试，不留悬挂）")
    func senderTimesOutWithoutAck() async throws {
        let fixture = SessionFixture.pairedHandshake()
        let sourceURL = try writeFile(
            "src.bin", in: try makeTempRoot("t4-src"),
            data: Data(repeating: 0x5A, count: 1_024)
        )
        let sender = SyncFileSender(session: fixture.hostSession, ackTimeout: 0.15)
        let outcome = W2Box<SyncFileSender.Outcome>()
        sender.onCompletion = { outcome.set($0) }

        try sender.send(fileURL: sourceURL, fileID: "t4-timeout", name: "src.bin")
        #expect(sender.isActive) // 已发 meta，等 ack（对端无接收端 → 永远等不到）

        // 等超时回调落地：轮询而非固定 sleep——CI runner 线程饥饿时，注入的 0.15s 定时器
        // 可能远晚于标称时间才被调度，固定 sleep 会假失败（2026-09-12 CI 实测）。
        let timedOut = await waitUntil { outcome.value != nil }
        #expect(timedOut, "等待 file_ack 超时未在 10s 内落地")

        guard case let .failed(error)? = outcome.value else {
            Issue.record("期望超时失败，实际 \(String(describing: outcome.value))")
            return
        }
        if case let .protocolError(fileID, reason) = error {
            #expect(fileID == "t4-timeout")
            #expect(reason.contains("超时"))
        } else {
            Issue.record("期望 protocolError，实际 \(error)")
        }
        #expect(!sender.isActive) // 状态已清 → 可重试
    }

    /// CI 线程饥饿下的等待：轮询到条件成立（默认 10s 上限）。
    ///
    /// 为什么不用固定 `Task.sleep`：注入超时（0.15s/0.2s）虽短，但 CI runner 上定时器
    /// 可能远晚于标称时间才被调度 → 固定 sleep 会假失败（2026-09-12 CI 实测）。
    /// 条件始终不成立时返回 false，由调用方的 #expect 给出可读失败信息（真缺陷不被掩盖）。
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 10,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @Test("🟡T4 等主机答复阶段有超时 → client 不再永久卡在「配对中」")
    func clientPairResponseTimesOut() async throws {
        let fixture = SessionFixture.make(config: SyncSessionConfiguration(handshakeTimeout: 0.2))
        let nonce = Data((0 ..< 16).map { UInt8($0) })
        fixture.hostSession.pairingNonces?.register(nonce)
        fixture.clientSession.setPairingExpectations(
            expectedPeerDeviceID: nil,
            candidate: SyncPairingCandidate(
                deviceID: fixture.hostIdentity.deviceID,
                publicKeyRaw: fixture.hostIdentity.publicKeyRaw,
                sessionNonce: nonce,
                hostName: "MacBook Pro"
            )
        )

        fixture.hostSession.handleTransportReady()
        fixture.clientSession.handleTransportReady()
        #expect(fixture.clientSession.phase == .waitingForPairResponse)
        #expect(fixture.hostSession.phase == .waitingForPairApproval)

        // 同上：轮询到 client 因握手超时关闭（CI 定时器调度可能远晚于标称 0.2s）
        let closed = await waitUntil { fixture.clientSession.phase == .closed }
        #expect(closed, "握手超时未在 10s 内关闭 client 会话")

        #expect(fixture.clientSession.phase == .closed)
        #expect(fixture.clientSession.closeReason == .handshakeTimeout)
        // 人工批准阶段**故意**不设超时：主机仍在等用户点弹窗
        #expect(fixture.hostSession.phase == .waitingForPairApproval)
    }

    // MARK: 🟡T5 续传对齐失败

    @Test("🟡T5 续传对齐 truncate 失败 → 明确失败（不再静默按错误偏移续写）")
    func realignFailureFailsExplicitly() throws {
        let dir = try makeTempRoot("t5")
        let name = "s.bin"
        let partURL = dir.appendingPathComponent(name + ".part")
        try Data(repeating: 0x33, count: 100).write(to: partURL) // 半块残留：100 > alignDown(100, 64)

        let fixture = SessionFixture.pairedHandshake()
        let receiver = SyncFileReceiver(session: fixture.clientSession, directory: dir)
        let acks = W2Box<[FileAckPayload]>()
        receiver.onAckSent = { ack in
            var items = acks.value ?? []
            items.append(ack)
            acks.set(items)
        }
        let outcome = W2Box<SyncFileReceiver.Outcome>()
        receiver.onCompletion = { outcome.set($0) }
        // 注入对齐失败（真实环境对应 truncate/打开句柄失败的 IO 错误）
        receiver.partAlignmentHook = { _, _ in
            throw SyncFileTransferError.ioError("注入的断点对齐失败")
        }

        receiver.handleInboundFrame(try metaFrame(FileMetaPayload(
            fileID: "t5",
            name: name,
            totalSize: 1_024,
            chunkSize: 64,
            sha256Hex: String(repeating: "a", count: 64),
            startOffset: 64
        )))

        #expect(acks.value?.last?.error == .ioError)
        #expect(acks.value?.last?.receivedBytes == 0)
        #expect(acks.value?.last?.done == false)
        #expect(outcome.value == .failed(.ioError("t5")))
        #expect(!receiver.isActive) // 状态已清
        #expect(FileManager.default.fileExists(atPath: partURL.path)) // .part 保留（可重试）
    }
}
