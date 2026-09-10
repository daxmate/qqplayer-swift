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
        targetFiles: [(String, Data)] = []
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
        var received: SyncFetchResult?
        fixture.clientSession.onApplicationFrame = { frame in
            if frame.type == .syncFetchResult {
                received = try? SyncFetchCodec.decode(SyncFetchResult.self, from: frame.payload)
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

        let result = try #require(received)
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
}
