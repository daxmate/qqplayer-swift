//
//  SyncLibrarySyncE2ETests.swift
//  QQPlayerTests
//
//  S2 M3-3b 端到端（内存回环会话，无模拟器/无网络）：
//    设备侧 = SyncLibraryPassiveHost（应答 manifest + 按路径回推，iOS 单一被动入口）
//    Mac 侧 = SyncLibraryPullController（R1b-2：发起方恒为 Mac）
//
//  覆盖三条：
//    ① 客户端缺 1 个文件 → 拉取后本地存在且 SHA-256 与源一致 + 入库入口被调用
//    ② 远端已删 → **本端一条都不删**（含原"受管"路径与"导入"路径），同步正常 done
//    ③ 越界路径请求（含 `..`）→ Host 计入 failed，不出曲库根
//
//  fixture 复用 SyncPeerSessionTestSupport.swift（SessionFixture 双 ready 回环）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

// MARK: - 落盘 spy（入库入口断言用）

private final class SyncSinkSpy: SyncLibrarySyncSink, @unchecked Sendable {
    private let lock = NSLock()
    private var indexedPaths: [String] = []

    var indexed: [String] {
        lock.lock()
        defer { lock.unlock() }
        return indexedPaths
    }

    func indexLandedFile(at url: URL) {
        lock.lock()
        indexedPaths.append(url.path)
        lock.unlock()
    }
}

// MARK: - 测试

@MainActor
struct SyncLibrarySyncE2ETests {
    // MARK: 夹具

    private struct Harness {
        let fixture: SessionFixture
        /// 设备侧曲库（内容源，被动端）
        let sourceRoot: URL
        /// Mac 侧曲库（落位目标）
        let targetRoot: URL
        let deviceManager: DatabaseManager
        let macManager: DatabaseManager
        /// 必须强持有：被动端以 [weak self] 挂接会话，创建后即弃会被 ARC 释放
        let deviceHost: SyncLibraryPassiveHost
        let sink: SyncSinkSpy
        /// Mac 侧拉取控制器（R1b-2：发起方恒为 Mac）
        let controller: SyncLibraryPullController
    }

    private func makeTempRoot(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-sync-m33b-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func writeFile(_ relativePath: String, in root: URL, data: Data) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        return url
    }

    private func silentData(_ marker: UInt8, count: Int) -> Data {
        Data(repeating: marker, count: count)
    }

    private func makeHarness(
        sourceFiles: [(String, Data)] = [],
        targetFiles: [(String, Data)] = [],
        recorder: FrameTypeRecorder? = nil
    ) throws -> Harness {
        let fixture = SessionFixture.pairedHandshake()
        let sourceRoot = try makeTempRoot("src")
        let targetRoot = try makeTempRoot("dst")
        for (path, data) in sourceFiles { try writeFile(path, in: sourceRoot, data: data) }
        for (path, data) in targetFiles { try writeFile(path, in: targetRoot, data: data) }

        let deviceManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try deviceManager.createTables()
        let macManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try macManager.createTables()

        // 设备侧装配（与 iOS `SyncLibraryPassiveHost` 装配同构：应答 manifest + 按路径回推）
        let deviceHost = SyncLibraryPassiveHost(
            libraryRoot: sourceRoot,
            sink: SyncSinkSpy(),
            database: deviceManager
        )
        _ = deviceHost.attach(to: fixture.clientSession)

        // 帧记录器须在 `start()` **之前**挂：既能证明「确实记到了本轮的请求帧」，
        // 也能证明「终态后没有多发出请求帧」（终态守卫用例）。
        if let recorder { recorder.attach(to: fixture.clientSession) }

        // Mac 侧装配（发起方）：拉取控制器 + 曲库描述符（测试用临时歌词库，不同步歌词）
        let sink = SyncSinkSpy()
        let lyricsStore = AlignedLyricsStore(directory: try makeTempRoot("mac-lyrics"))
        let descriptor = SyncLocalLibraryDescriptor.live(
            libraryRoot: targetRoot,
            rootName: "测试 Mac 曲库",
            database: macManager,
            lyricsStore: lyricsStore,
            lyricsMapping: .unresolved
        )
        let controller = SyncLibraryPullController(
            session: fixture.hostSession,
            descriptor: descriptor,
            sink: sink,
            configuration: SyncLibraryPullConfiguration(),
            lyricsStore: lyricsStore,
            lyricsMapping: .unresolved
        )
        try controller.start()

        return Harness(
            fixture: fixture,
            sourceRoot: sourceRoot,
            targetRoot: targetRoot,
            deviceManager: deviceManager,
            macManager: macManager,
            deviceHost: deviceHost,
            sink: sink,
            controller: controller
        )
    }

    // MARK: ① 拉取一致性

    @Test("端到端：客户端缺 1 个文件 → 拉取落位 + SHA-256 与源一致 + 入库入口被调用")
    func fetchesMissingFileToCompletion() throws {
        let payload = silentData(0x5A, count: 300_000) // 跨 2 个 256KB 块
        let harness = try makeHarness(sourceFiles: [("Album/01 Song.flac", payload)])

        let landed = harness.targetRoot.appendingPathComponent("Album/01 Song.flac")
        #expect(FileManager.default.fileExists(atPath: landed.path))
        #expect(try SyncFileChecksum.sha256Hex(ofFile: landed) == SyncFileChecksum.sha256Hex(ofFile: harness.sourceRoot.appendingPathComponent("Album/01 Song.flac")))
        #expect(harness.sink.indexed == [landed.path])

        guard case let .done(summary) = harness.controller.state else {
            Issue.record("期望 done，实际 \(harness.controller.state)")
            return
        }
        #expect(summary.completed == ["Album/01 Song.flac"])
        #expect(summary.failed.isEmpty)
        #expect(summary.requested == ["Album/01 Song.flac"])
    }

    // MARK: ② 远端已删 → 本端不删（不传播删除）

    @Test("★端到端：远端已删 → 本端一条都不删（受管路径与导入路径全部保留）")
    func keepsRemoteRemovedFilesLocally() throws {
        let shared = silentData(0x11, count: 4_096)
        let stale = silentData(0x22, count: 4_096)
        let imported = silentData(0x44, count: 2_048)
        let harness = try makeHarness(
            sourceFiles: [("Album/kept.flac", shared)],
            targetFiles: [
                ("Album/kept.flac", shared),
                ("Album/stale.flac", stale),
                ("Imported/manual.m4a", imported),
            ]
        )

        let kept = harness.targetRoot.appendingPathComponent("Album/kept.flac")
        let staleURL = harness.targetRoot.appendingPathComponent("Album/stale.flac")
        let importedURL = harness.targetRoot.appendingPathComponent("Imported/manual.m4a")
        // 远端仍有 → 一致；远端没有 → 本端保留（本地事务，绝不跨端删除）
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(FileManager.default.fileExists(atPath: staleURL.path))
        #expect(FileManager.default.fileExists(atPath: importedURL.path))
        // 无拉取动作：不落位、不入库
        #expect(harness.sink.indexed.isEmpty)

        guard case let .done(summary) = harness.controller.state else {
            Issue.record("期望 done，实际 \(harness.controller.state)")
            return
        }
        #expect(summary.completed.isEmpty)
        #expect(summary.failed.isEmpty)
        #expect(summary.requested.isEmpty)
    }

    // MARK: ③ 越界请求拒绝

    @Test("端到端：越界路径请求（绝对/`..`）→ Host 计入 failed，绝不出曲库根")
    func rejectsOutOfRootFetchRequests() throws {
        let fixture = SessionFixture.pairedHandshake()
        let sourceRoot = try makeTempRoot("src-escape")
        let outsideRoot = try makeTempRoot("outside")
        let secret = try writeFile("outside.flac", in: outsideRoot, data: silentData(0x77, count: 128))
        let hostManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try hostManager.createTables()

        let hostResponder = SyncLibraryFetchResponder(session: fixture.hostSession, libraryRoot: sourceRoot)

        // 捕获 client 收到的结果帧
        let receivedBox = FetchResultValueBox()
        fixture.clientSession.onApplicationFrame = { frame in
            if frame.type == .syncFetchResult {
                receivedBox.value = try? SyncFetchCodec.decode(SyncFetchResult.self, from: frame.payload)
            }
        }

        let request = SyncFetchRequest(
            relativePaths: [
                "../\(outsideRoot.lastPathComponent)/outside.flac",
                secret.path,
                "/etc/passwd",
            ]
        )
        try fixture.clientSession.sendApplicationFrame(
            type: .syncFetchRequest,
            payload: try SyncFetchCodec.encode(request)
        )

        let result = try #require(receivedBox.value)
        #expect(result.completed.isEmpty)
        #expect(result.failed.count == 3)
        #expect(result.failed.allSatisfy { $0.reason == SyncFetchFailureReason.invalidPath })
        // 请求路径如实回填（原样字符串）
        #expect(result.failed.map(\.relativePath).contains(secret.path))
        // 越界文件未被读出/落盘：曲库根内没有任何副本
        let leaked = sourceRoot.appendingPathComponent("outside.flac")
        #expect(!FileManager.default.fileExists(atPath: leaked.path))
        _ = hostResponder
    }

    // MARK: ④ 终态守卫：迟到帧不再参与重排（2026-09-22）

    @Test("★终态守卫：拉取轮 done 后迟到的 manifest_response 不改账目、不再发拉取请求")
    func pullIgnoresLateManifestAfterTerminal() throws {
        let recorder = FrameTypeRecorder()
        let harness = try makeHarness(
            sourceFiles: [("Album/01 Song.flac", silentData(0x5B, count: 4_096))],
            recorder: recorder
        )

        guard case let .done(before) = harness.controller.state else {
            Issue.record("期望 done，实际 \(harness.controller.state)")
            return
        }
        // 先证明记录器确实记到了本轮请求帧（否则下面的「没有多发」断言无意义）
        #expect(recorder.count(of: .syncFetchRequest) == 1)
        let stateBefore = harness.controller.state
        let beforeSummary = harness.controller.summary
        #expect(beforeSummary == before)

        // 终态后对端再回一帧 manifest_response，含一个本端没有的新路径：
        // 若钩子仍生效 → 重算计划、覆写 requested、重建 claims，并再发一帧 syncFetchRequest
        let late = SyncManifestResponse(
            entries: [
                ManifestEntry(
                    relativePath: "Album/late.flac",
                    size: 1_024,
                    mtimeMs: 0,
                    contentHash: String(repeating: "a", count: 64)
                ),
            ],
            rootName: "设备"
        )
        try harness.fixture.clientSession.sendApplicationFrame(
            type: .manifestResponse,
            payload: try SyncManifestCodec.encode(late)
        )

        #expect(harness.controller.summary == beforeSummary, "终态后 manifest 迟帧不得改账目（有序逐字比较）")
        #expect(harness.controller.summary.requested == ["Album/01 Song.flac"])
        #expect(harness.controller.state == stateBefore, "终态后状态不得变")
        #expect(recorder.count(of: .syncFetchRequest) == 1, "终态后不得再发拉取请求")
        _ = harness.fixture
    }

    @Test("★终态守卫：拉取轮 done 后迟到的 sync_fetch_result 不覆写 failed/reportedCompleted")
    func pullIgnoresLateFetchResultAfterTerminal() throws {
        let harness = try makeHarness(
            sourceFiles: [("Album/02 Song.flac", silentData(0x5C, count: 3_072))]
        )

        guard case let .done(before) = harness.controller.state else {
            Issue.record("期望 done，实际 \(harness.controller.state)")
            return
        }
        #expect(before.failed.isEmpty)
        #expect(before.reportedCompleted == ["Album/02 Song.flac"], "本轮结果帧已到达（收尾前账目基线）")

        // 终态后再注入一帧结果帧（带一份不同的失败/完成清单）：不得覆写账目
        let late = SyncFetchResult(
            completed: ["Ghost/other.flac"],
            failed: [
                SyncFileFetchFailure(
                    relativePath: "Ghost/missing.flac",
                    reason: SyncFetchFailureReason.notFound
                ),
            ]
        )
        try harness.fixture.clientSession.sendApplicationFrame(
            type: .syncFetchResult,
            payload: try SyncFetchCodec.encode(late)
        )

        #expect(harness.controller.summary.failed.isEmpty, "终态后 failed 不得被覆写")
        #expect(
            harness.controller.summary.reportedCompleted == ["Album/02 Song.flac"],
            "终态后 reportedCompleted 不得被覆写"
        )
        #expect(harness.controller.summary == before, "终态后账目逐字不变")
        #expect(harness.controller.state == .done(before))
    }

    @Test("★终态守卫：推送轮 done 后迟到的 manifest_response 不改账目、不再发推送声明")
    func pushIgnoresLateManifestAfterTerminal() throws {
        let payload = silentData(0x91, count: 2_048)
        let harness = try makePushHarness(macFiles: [("Pushed/new.flac", payload)])

        guard case let .done(before) = harness.controller.state else {
            Issue.record("期望 done，实际 \(harness.controller.state)")
            return
        }
        #expect(before.planned == ["Pushed/new.flac"])
        #expect(before.skipped.isEmpty)
        #expect(before.failed.isEmpty)
        #expect(before.completed == ["Pushed/new.flac"])
        #expect(harness.recorder.count(of: .libraryPushAnnounce) == 1)

        // 终态后再写入一个新文件：若钩子仍生效，它会被当成新的待推送计划项
        _ = try writeFile("Pushed/extra.flac", in: harness.macRoot, data: silentData(0x92, count: 777))
        let newURL = harness.macRoot.appendingPathComponent("Pushed/new.flac")
        let late = SyncManifestResponse(
            entries: [
                ManifestEntry(
                    relativePath: "Pushed/new.flac",
                    size: Int64(payload.count),
                    mtimeMs: 0,
                    contentHash: try SyncFileChecksum.sha256Hex(ofFile: newURL)
                ),
            ],
            rootName: "设备"
        )
        try harness.fixture.clientSession.sendApplicationFrame(
            type: .manifestResponse,
            payload: try SyncManifestCodec.encode(late)
        )

        #expect(harness.controller.summary == before, "终态后 manifest 迟帧不得改账目（有序逐字比较）")
        #expect(harness.controller.summary.planned == ["Pushed/new.flac"])
        #expect(harness.controller.summary.skipped.isEmpty)
        #expect(harness.controller.state == .done(before), "终态后状态不得变")
        #expect(harness.recorder.count(of: .libraryPushAnnounce) == 1, "终态后不得再发推送声明")
    }

    // MARK: ⑤ 轮内合法时序不回归（§3 陷阱：handleTransfer 不得加守卫）

    @Test("★轮内合法时序：结果帧先于最后一个文件落盘 → 最后落盘的文件仍记入 completed")
    func pullRecordsLandingAfterEarlyResultFrame() throws {
        let fixture = SessionFixture.pairedHandshake()
        let deviceRoot = try makeTempRoot("early-src")
        let targetRoot = try makeTempRoot("early-dst")
        let payload = silentData(0x7C, count: 5_000)
        let fileURL = try writeFile("Album/late.flac", in: deviceRoot, data: payload)
        let entry = ManifestEntry(
            relativePath: "Album/late.flac",
            size: Int64(payload.count),
            mtimeMs: 0,
            contentHash: try SyncFileChecksum.sha256Hex(ofFile: fileURL)
        )

        // 设备侧：先回结果帧再送文件（终态落在文件回调之前）
        let responder = EarlyResultFetchResponder(
            session: fixture.clientSession,
            fileURL: fileURL,
            entry: entry
        )
        responder.attach()

        let macManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try macManager.createTables()
        let sink = SyncSinkSpy()
        let macLyrics = AlignedLyricsStore(directory: try makeTempRoot("early-mac-lyrics"))
        let descriptor = SyncLocalLibraryDescriptor.live(
            libraryRoot: targetRoot,
            rootName: "测试 Mac 曲库",
            database: macManager,
            lyricsStore: macLyrics,
            lyricsMapping: .unresolved
        )
        let controller = SyncLibraryPullController(
            session: fixture.hostSession,
            descriptor: descriptor,
            sink: sink,
            configuration: SyncLibraryPullConfiguration(),
            lyricsStore: macLyrics,
            lyricsMapping: .unresolved
        )
        try controller.start()

        let landed = targetRoot.appendingPathComponent("Album/late.flac")
        guard case let .done(summary) = controller.state else {
            Issue.record("期望 done，实际 \(controller.state)")
            return
        }
        // 这条守住 §3 陷阱：给 `handleTransfer` 加终态守卫会让最后落盘的文件名目消失
        #expect(summary.completed == ["Album/late.flac"], "终态之后到达的落盘回调仍须记入 completed")
        #expect(summary.failed.isEmpty)
        #expect(summary.requested == ["Album/late.flac"])
        #expect(FileManager.default.fileExists(atPath: landed.path))
        #expect(sink.indexed == [landed.path])
        _ = responder
    }

    // MARK: 推送方向夹具

    private struct PushHarness {
        let fixture: SessionFixture
        /// Mac 侧曲库（推送源）
        let macRoot: URL
        /// 设备侧曲库（落位目标）
        let deviceRoot: URL
        let deviceHost: SyncLibraryPassiveHost
        let recorder: FrameTypeRecorder
        /// Mac 侧推送控制器（发起方）
        let controller: SyncLibraryPushController
    }

    /// 推送方向夹具（与 `scripts/sync-harness/main.swift` 的推送场景同构）：
    /// Mac = `SyncLibraryPushController`，设备 = `SyncLibraryPassiveHost`（已处理 `libraryPushAnnounce`）。
    private func makePushHarness(
        macFiles: [(String, Data)] = [],
        deviceFiles: [(String, Data)] = []
    ) throws -> PushHarness {
        let fixture = SessionFixture.pairedHandshake()
        let macRoot = try makeTempRoot("push-mac")
        let deviceRoot = try makeTempRoot("push-device")
        for (path, data) in macFiles { try writeFile(path, in: macRoot, data: data) }
        for (path, data) in deviceFiles { try writeFile(path, in: deviceRoot, data: data) }

        let deviceManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try deviceManager.createTables()
        let macManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try macManager.createTables()

        let deviceHost = SyncLibraryPassiveHost(
            libraryRoot: deviceRoot,
            sink: SyncSinkSpy(),
            database: deviceManager
        )
        _ = deviceHost.attach(to: fixture.clientSession)

        // 记录器须在 `start()` 之前挂：证明记到了本轮声明帧，也证明终态后没有多发
        let recorder = FrameTypeRecorder()
        recorder.attach(to: fixture.clientSession)

        let macLyrics = AlignedLyricsStore(directory: try makeTempRoot("push-mac-lyrics"))
        let descriptor = SyncLocalLibraryDescriptor.live(
            libraryRoot: macRoot,
            rootName: "测试 Mac 曲库",
            database: macManager,
            lyricsStore: macLyrics,
            lyricsMapping: .unresolved
        )
        let controller = SyncLibraryPushController(session: fixture.hostSession, descriptor: descriptor)
        try controller.start()

        return PushHarness(
            fixture: fixture,
            macRoot: macRoot,
            deviceRoot: deviceRoot,
            deviceHost: deviceHost,
            recorder: recorder,
            controller: controller
        )
    }
}

/// 测试侧 Sendable 盒子（2026-09-20 会话回调收口）：`onApplicationFrame` 标 `@Sendable` 后，
/// 闭包不能再捕获可变局部量 ⇒ 结果放盒子里。
private final class FetchResultValueBox: @unchecked Sendable {
    var value: SyncFetchResult?
}

// MARK: - manifest 钩子终态守卫（2026-09-22）

/// 会话入站帧类型记录器：断言「确已记到本轮帧」+「终态后没有多发出某类帧」。
/// 挂在 `SyncSessionAttachment`（会话分发链）上，owner 须由用例**强持有**（链项弱持有 owner）。
private final class FrameTypeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var types: [SyncFrameType] = []
    private var attachment: SyncSessionAttachment?

    /// 挂到会话（必须在目标轮次开始**之前**调用，否则记不到该轮次发出的帧）。
    func attach(to session: SyncPeerSession) {
        attachment = SyncSessionAttachment(session: session, owner: self) { [weak self] frame in
            guard let self else { return }
            self.lock.lock()
            self.types.append(frame.type)
            self.lock.unlock()
        }
    }

    func count(of type: SyncFrameType) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return types.filter { $0 == type }.count
    }
}

/// 设备侧应答器：**先回 `sync_fetch_result` 再送文件**——复刻「结果帧可能先于最后一个文件的
/// 落盘/入库回调到达」的真实时序（接收端先回 ack 再回调 `onCompletion`，见
/// `SyncFileReceiver` 动作序 / `SyncLibraryPullController.handleTransfer` 注释）。
///
/// 用途：钉住 §3 陷阱「`handleTransfer` **不得**加终态守卫」——加了守卫时最后落盘的文件
/// 名目会消失（`summary.completed` 缺一项），本用例即变红。
private final class EarlyResultFetchResponder: @unchecked Sendable {
    private let session: SyncPeerSession
    private let fileURL: URL
    private let entry: ManifestEntry
    private let sender: SyncFileSender
    private var attachment: SyncSessionAttachment?

    init(session: SyncPeerSession, fileURL: URL, entry: ManifestEntry) {
        self.session = session
        self.fileURL = fileURL
        self.entry = entry
        sender = SyncFileSender(session: session)
    }

    func attach() {
        attachment = SyncSessionAttachment(session: session, owner: self) { [weak self] frame in
            self?.handle(frame)
        }
    }

    private func handle(_ frame: SyncFrame) {
        switch frame.type {
        case .manifestRequest:
            let response = SyncManifestResponse(entries: [entry], rootName: "设备")
            try? session.sendApplicationFrame(
                type: .manifestResponse,
                payload: SyncManifestCodec.encode(response)
            )
        case .syncFetchRequest:
            // ① 先回结果帧：接收端状态先落 done（真实时序里 ack 先于落盘回调）
            let result = SyncFetchResult(completed: [], failed: [])
            try? session.sendApplicationFrame(
                type: .syncFetchResult,
                payload: SyncFetchCodec.encode(result)
            )
            // ② 再送文件：此刻轮次已终态，落盘回调仍必须记入 summary.completed
            try? sender.send(fileURL: fileURL, fileID: entry.contentHash ?? "")
        default:
            break
        }
    }
}
