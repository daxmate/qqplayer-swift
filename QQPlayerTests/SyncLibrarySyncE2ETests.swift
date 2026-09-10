//
//  SyncLibrarySyncE2ETests.swift
//  QQPlayerTests
//
//  S2 M3-3b 端到端（内存回环会话，无模拟器/无网络）：
//    Host 侧 = SyncManifestPeer（manifest 提供者）+ SyncLibraryFetchResponder（按路径推送）
//              —— 与 MacSyncLibraryHost 的装配同构（后者 Mac target only，测试侧手工装配）
//    Client 侧 = SyncLibrarySyncController（对账 → 拉取 → 删除 → 落盘 + 入库 sink）
//
//  覆盖任务包块④四条：
//    ① 客户端缺 1 个文件 → 拉取后本地存在且 SHA-256 与源一致 + 入库入口被调用
//    ② 远端已删（本地多出且在受管集合内）→ toDelete 生效，本地副本被删
//    ③ 私有区/未受管路径 → 不删
//    ④ 越界路径请求（含 `..`）→ Host 计入 failed，不出曲库根
//
//  fixture 复用 SyncPeerSessionTestSupport.swift（SessionFixture 双 ready 回环）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

// MARK: - 落盘/删除 spy（入库入口断言用）

private final class SyncSinkSpy: SyncLibrarySyncSink, @unchecked Sendable {
    private let lock = NSLock()
    private var indexedPaths: [String] = []
    private var deletedPaths: [String] = []

    var indexed: [String] {
        lock.lock()
        defer { lock.unlock() }
        return indexedPaths
    }

    var deleted: [String] {
        lock.lock()
        defer { lock.unlock() }
        return deletedPaths
    }

    func indexLandedFile(at url: URL) {
        lock.lock()
        indexedPaths.append(url.path)
        lock.unlock()
    }

    func deleteLocalFile(at url: URL, stableId: String?) {
        lock.lock()
        deletedPaths.append(url.path)
        lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - 测试

@MainActor
struct SyncLibrarySyncE2ETests {
    // MARK: 夹具

    private struct Harness {
        let fixture: SessionFixture
        let sourceRoot: URL
        let targetRoot: URL
        let hostManager: DatabaseManager
        let clientManager: DatabaseManager
        /// 必须强持有：peer/responder 以 [weak self] 挂接会话，创建后即弃会被 ARC 释放
        let hostManifestPeer: SyncManifestPeer
        let hostResponder: SyncLibraryFetchResponder
        let sink: SyncSinkSpy
        let controller: SyncLibrarySyncController
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
        protectedPaths: Set<String> = []
    ) throws -> Harness {
        let fixture = SessionFixture.pairedHandshake()
        let sourceRoot = try makeTempRoot("src")
        let targetRoot = try makeTempRoot("dst")
        for (path, data) in sourceFiles { try writeFile(path, in: sourceRoot, data: data) }
        for (path, data) in targetFiles { try writeFile(path, in: targetRoot, data: data) }

        let hostManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try hostManager.createTables()
        let clientManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try clientManager.createTables()

        // Host 装配（与 MacSyncLibraryHost.attach 同构）
        let hostManifestPeer = SyncManifestPeer(session: fixture.hostSession)
        hostManifestPeer.localRootName = { "测试 Mac 曲库" }
        hostManifestPeer.localManifestProvider = { collection in
            SyncLocalLibraryScanner.entries(in: sourceRoot, collection: collection, database: hostManager)
        }
        let hostResponder = SyncLibraryFetchResponder(session: fixture.hostSession, libraryRoot: sourceRoot)

        // Client 装配
        let sink = SyncSinkSpy()
        var configuration = SyncLibrarySyncConfiguration()
        configuration.protectedRelativePaths = protectedPaths
        let controller = SyncLibrarySyncController(
            session: fixture.clientSession,
            libraryRoot: targetRoot,
            sink: sink,
            configuration: configuration,
            database: clientManager
        )
        try controller.start()

        return Harness(
            fixture: fixture,
            sourceRoot: sourceRoot,
            targetRoot: targetRoot,
            hostManager: hostManager,
            clientManager: clientManager,
            hostManifestPeer: hostManifestPeer,
            hostResponder: hostResponder,
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

    // MARK: ② 远端已删 → 本地删除

    @Test("端到端：远端已删（本地多出且受管）→ toDelete 生效，本地副本被删")
    func deletesRemoteRemovedFile() throws {
        let shared = silentData(0x11, count: 4_096)
        let stale = silentData(0x22, count: 4_096)
        let harness = try makeHarness(
            sourceFiles: [("Album/kept.flac", shared)],
            targetFiles: [
                ("Album/kept.flac", shared),
                ("Album/stale.flac", stale),
            ]
        )

        let kept = harness.targetRoot.appendingPathComponent("Album/kept.flac")
        let removed = harness.targetRoot.appendingPathComponent("Album/stale.flac")
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        #expect(harness.sink.deleted == [removed.path])

        guard case let .done(summary) = harness.controller.state else {
            Issue.record("期望 done，实际 \(harness.controller.state)")
            return
        }
        #expect(summary.deleted == ["Album/stale.flac"])
        #expect(summary.completed.isEmpty)
    }

    // MARK: ③ 私有区保护

    @Test("端到端：私有区/未受管路径 → 不删（受管副本照删）")
    func protectsPrivateZone() throws {
        let managed = silentData(0x33, count: 2_048)
        let priv = silentData(0x44, count: 2_048)
        let harness = try makeHarness(
            sourceFiles: [],
            targetFiles: [
                ("Album/managed.flac", managed),
                ("Imported/private.flac", priv),
            ],
            protectedPaths: ["Imported/private.flac"]
        )

        let removed = harness.targetRoot.appendingPathComponent("Album/managed.flac")
        let protected = harness.targetRoot.appendingPathComponent("Imported/private.flac")
        #expect(!FileManager.default.fileExists(atPath: removed.path))
        #expect(FileManager.default.fileExists(atPath: protected.path))
        #expect(harness.sink.deleted == [removed.path])

        guard case let .done(summary) = harness.controller.state else {
            Issue.record("期望 done，实际 \(harness.controller.state)")
            return
        }
        #expect(summary.deleted == ["Album/managed.flac"])
        #expect(summary.protectedSkipped == ["Imported/private.flac"])
    }

    // MARK: ④ 越界请求拒绝

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
