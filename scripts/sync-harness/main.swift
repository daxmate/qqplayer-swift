//
//  main.swift — M3-3b 无模拟器本地 harness（**不参与 App target 编译**）
//
//  用 swiftc 直编生产源码 + 本目录夹具，真跑与 QQPlayerTests 同构的断言：
//  帧 12/13 编解码、请求路径规范化/解析、应答器解析计划、控制器状态机/对账映射、
//  以及四条端到端场景（拉取一致性 / 远端已删删除 / 私有区保护 / 越界拒绝）。
//
//  运行：scripts/run-local-sync-tests.sh
//

import Foundation

// MARK: - 迷你断言

var checks = 0
var failures: [String] = []

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("  ✅ \(label)")
    } else {
        print("  ❌ \(label)")
        failures.append(label)
    }
}

func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    checks += 1
    if actual == expected {
        print("  ✅ \(label)")
    } else {
        print("  ❌ \(label)\n      期望: \(expected)\n      实际: \(actual)")
        failures.append(label)
    }
}

func section(_ title: String) {
    print("\n▶︎ \(title)")
}

// MARK: - 夹具

func tempRoot(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("qqp-sync-harness-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
func writeFile(_ relativePath: String, in root: URL, data: Data) throws -> URL {
    let url = root.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url)
    return url
}

func silentData(_ marker: UInt8, count: Int) -> Data { Data(repeating: marker, count: count) }

/// 同步 spy sink（生产 sink 走 Task hop，harness 要立即断言）
final class SinkSpy: SyncLibrarySyncSink, @unchecked Sendable {
    private let lock = NSLock()
    private var indexedPaths: [String] = []
    private var deletedPaths: [String] = []

    var indexed: [String] {
        lock.lock(); defer { lock.unlock() }; return indexedPaths
    }

    var deleted: [String] {
        lock.lock(); defer { lock.unlock() }; return deletedPaths
    }

    func indexLandedFile(at url: URL) {
        lock.lock(); indexedPaths.append(url.path); lock.unlock()
    }

    func deleteLocalFile(at url: URL, stableId: String?) {
        lock.lock(); deletedPaths.append(url.path); lock.unlock()
        try? FileManager.default.removeItem(at: url)
    }
}

struct Harness {
    let fixture: SessionFixture
    let sourceRoot: URL
    let targetRoot: URL
    let hostManifestPeer: SyncManifestPeer
    let hostResponder: SyncLibraryFetchResponder
    let sink: SinkSpy
    let controller: SyncLibrarySyncController
}

func makeHarness(
    sourceFiles: [(String, Data)] = [],
    targetFiles: [(String, Data)] = [],
    protectedPaths: Set<String> = []
) throws -> Harness {
    let fixture = SessionFixture.pairedHandshake()
    let sourceRoot = try tempRoot("src")
    let targetRoot = try tempRoot("dst")
    for (path, data) in sourceFiles { try writeFile(path, in: sourceRoot, data: data) }
    for (path, data) in targetFiles { try writeFile(path, in: targetRoot, data: data) }

    let hostManager = DatabaseManager()
    let hostManifestPeer = SyncManifestPeer(session: fixture.hostSession)
    hostManifestPeer.localRootName = { "测试 Mac 曲库" }
    hostManifestPeer.localManifestProvider = { collection in
        SyncLocalLibraryScanner.entries(in: sourceRoot, collection: collection, database: hostManager)
    }
    let hostResponder = SyncLibraryFetchResponder(session: fixture.hostSession, libraryRoot: sourceRoot)

    let sink = SinkSpy()
    var configuration = SyncLibrarySyncConfiguration()
    configuration.protectedRelativePaths = protectedPaths
    let controller = SyncLibrarySyncController(
        session: fixture.clientSession,
        libraryRoot: targetRoot,
        sink: sink,
        configuration: configuration,
        database: DatabaseManager()
    )
    try controller.start()

    return Harness(
        fixture: fixture,
        sourceRoot: sourceRoot,
        targetRoot: targetRoot,
        hostManifestPeer: hostManifestPeer,
        hostResponder: hostResponder,
        sink: sink,
        controller: controller
    )
}

func entry(_ path: String, hash: String?, stableId: String? = nil) -> ManifestEntry {
    ManifestEntry(relativePath: path, size: 10, mtimeMs: 0, contentHash: hash, stableId: stableId)
}

// MARK: - ① 协议帧 + 模型

section("① 帧 12/13 + 拉取协议模型")
checkEqual(SyncFrameType.syncFetchRequest.rawValue, 12, "syncFetchRequest = 12")
checkEqual(SyncFrameType.syncFetchResult.rawValue, 13, "syncFetchResult = 13")
checkEqual(SyncFrameType.manifestResponse.rawValue, 11, "既有 manifestResponse = 11 未被挪动")

do {
    let request = SyncFetchRequest(collection: .tracks(["s1"]), relativePaths: ["Album/01.flac"])
    let data = try SyncFetchCodec.encode(request)
    checkEqual(try SyncFetchCodec.decode(SyncFetchRequest.self, from: data), request, "SyncFetchRequest roundtrip")
    let frame = try SyncFrame(type: .syncFetchRequest, flags: .encrypted, payload: data).encode()
    let (decoded, consumed) = try SyncFrame.decode(from: frame)
    checkEqual(consumed, frame.count, "帧解码消耗字节数一致")
    checkEqual(decoded.type, SyncFrameType.syncFetchRequest, "帧类型解码")

    let result = SyncFetchResult(
        completed: ["b.flac", "a.flac", "b.flac"],
        failed: [
            SyncFileFetchFailure(relativePath: "z.flac", reason: SyncFetchFailureReason.notFound),
            SyncFileFetchFailure(relativePath: "c.flac", reason: SyncFetchFailureReason.invalidPath),
        ]
    )
    checkEqual(result.completed, ["a.flac", "b.flac"], "结果 completed 排序去重")
    checkEqual(result.failed.map(\.relativePath), ["c.flac", "z.flac"], "结果 failed 排序")
} catch {
    check(false, "帧/模型 roundtrip 抛错：\(error)")
}

let normalizeInput = [
    "Album/01 Song.flac", "/etc/passwd", "../escape.flac", "Album/../secret", "", "   ",
    "./Album/01 Song.flac", "Album/02 Song.flac",
]
checkEqual(
    SyncFetchRequest.normalize(normalizeInput),
    ["Album/01 Song.flac", "Album/02 Song.flac"],
    "请求列表规范化（拒非法 / 去重 / 升序）"
)

do {
    let json = #"{"collection":{"kind":"all","ids":[]},"relativePaths":["../escape.flac","ok.flac"]}"#
    let request = try SyncFetchCodec.decode(SyncFetchRequest.self, from: Data(json.utf8))
    checkEqual(request.relativePaths, ["../escape.flac", "ok.flac"], "解码保留原始非法路径（不静默丢弃）")
} catch {
    check(false, "解码原始路径抛错：\(error)")
}

// MARK: - ② 路径解析 / 应答器计划

section("② 路径解析 + 应答器解析计划")
do {
    let root = URL(fileURLWithPath: "/tmp/qqp-harness-root", isDirectory: true)
    checkEqual(
        SyncLibraryPathResolver.resolve(relativePath: "Album/./01.flac", root: root),
        .resolved(root.appendingPathComponent("Album/01.flac")),
        "根内路径解析为绝对 URL"
    )
    for bad in ["/etc/passwd", "../escape.flac", "a/../../escape.flac", "", ".", ".."] {
        checkEqual(
            SyncLibraryPathResolver.resolve(relativePath: bad, root: root),
            .rejected(SyncFetchFailureReason.invalidPath),
            "非法路径拒绝：\(bad.isEmpty ? "<空>" : bad)"
        )
    }

    let planRoot = try tempRoot("plan")
    try writeFile("inside.flac", in: planRoot, data: silentData(0x01, count: 16))
    let outsideRoot = try tempRoot("plan-outside")
    let outsideFile = try writeFile("secret.flac", in: outsideRoot, data: silentData(0x02, count: 16))
    try FileManager.default.createSymbolicLink(
        at: planRoot.appendingPathComponent("escape.flac"),
        withDestinationURL: outsideFile
    )
    try FileManager.default.createSymbolicLink(
        at: planRoot.appendingPathComponent("alias.flac"),
        withDestinationURL: planRoot.appendingPathComponent("inside.flac")
    )

    let plan = SyncLibraryFetchResponder.makePlan(
        relativePaths: ["/etc/passwd", "../outside.flac", "", "missing.flac", "escape.flac", "alias.flac", "inside.flac", "alias.flac"],
        root: planRoot
    )
    let reasons = Dictionary(uniqueKeysWithValues: plan.failures.map { ($0.relativePath, $0.reason) })
    checkEqual(reasons["/etc/passwd"], SyncFetchFailureReason.invalidPath, "绝对路径 → invalidPath")
    checkEqual(reasons["../outside.flac"], SyncFetchFailureReason.invalidPath, "`..` → invalidPath")
    checkEqual(reasons[""], SyncFetchFailureReason.invalidPath, "空路径 → invalidPath")
    checkEqual(reasons["missing.flac"], SyncFetchFailureReason.notFound, "不存在 → notFound")
    checkEqual(reasons["escape.flac"], SyncFetchFailureReason.outOfRoot, "软链逃逸 → outOfRoot")
    checkEqual(plan.files.map(\.relativePath), ["alias.flac", "inside.flac"], "根内文件（含根内软链）放行")
    checkEqual(plan.files.count, 2, "重复请求只处理一次")
} catch {
    check(false, "应答器计划抛错：\(error)")
}

// MARK: - ③ 控制器状态机 + 对账映射

section("③ 状态机 + 对账 → 计划（含私有区保护）")
check(SyncLibrarySyncStateMachine.canTransition(from: .idle, to: .requestingManifest), "idle → requestingManifest 允许")
check(SyncLibrarySyncStateMachine.canTransition(from: .fetching, to: .applyingDeletes), "fetching → applyingDeletes 允许")
check(SyncLibrarySyncStateMachine.canTransition(from: .applyingDeletes, to: .done(SyncLibrarySyncSummary())), "applyingDeletes → done 允许")
check(!SyncLibrarySyncStateMachine.canTransition(from: .idle, to: .fetching), "idle → fetching 拒绝（越级）")
check(SyncLibrarySyncStateMachine.canTransition(from: .fetching, to: .failed("x")), "非终态 → failed 允许")
check(!SyncLibrarySyncStateMachine.canTransition(from: .done(SyncLibrarySyncSummary()), to: .failed("x")), "终态后迁移拒绝")

do {
    var config = SyncLibrarySyncConfiguration()
    let remote = SyncManifestResponse(entries: [
        entry("changed.flac", hash: "new"),
        entry("missing.flac", hash: "h3"),
        entry("same.flac", hash: "h1"),
    ])
    let local = [entry("same.flac", hash: "h1"), entry("changed.flac", hash: "old")]
    let plan = SyncLibrarySyncPlanner.plan(remote: remote, local: local, configuration: config)
    checkEqual(plan.fetchRequest?.relativePaths, ["changed.flac", "missing.flac"], "本地缺失/内容不同 → 拉取列表")
    checkEqual(plan.unchanged.map(\.relativePath), ["same.flac"], "内容一致 → unchanged")

    // 私有区保护
    config.protectedRelativePaths = ["Imported/private.flac"]
    let protectedPlan = SyncLibrarySyncPlanner.plan(
        remote: SyncManifestResponse(entries: []),
        local: [entry("Album/synced.flac", hash: "h1"), entry("Imported/private.flac", hash: "h2")],
        configuration: config
    )
    checkEqual(protectedPlan.deletes.map(\.relativePath), ["Album/synced.flac"], "私有区不进删除列表")
    checkEqual(protectedPlan.protectedSkipped.map(\.relativePath), ["Imported/private.flac"], "私有区记为 protectedSkipped")

    // 未受管集合
    var scoped = SyncLibrarySyncConfiguration()
    scoped.collection = .tracks(["s1"])
    let scopedPlan = SyncLibrarySyncPlanner.plan(
        remote: SyncManifestResponse(entries: []),
        local: [entry("selected.flac", hash: "h1", stableId: "s1"), entry("other.flac", hash: "h2", stableId: "s2")],
        configuration: scoped
    )
    checkEqual(scopedPlan.deletes.map(\.relativePath), ["selected.flac"], "未受管集合条目不删")

    check(
        !SyncLibrarySyncPlanner.mayDelete(
            entry("Imported/private.flac", hash: "h2"),
            configuration: config,
            local: [entry("Imported/private.flac", hash: "h2")]
        ),
        "执行期复核：私有区 mayDelete = false"
    )
} catch {
    check(false, "对账计划抛错：\(error)")
}

// MARK: - ④ 端到端① 拉取一致性

section("④ 端到端：缺文件 → 拉取落位 + SHA 一致 + 入库入口被调用")
do {
    let payload = silentData(0x5A, count: 300_000) // 跨 2 个 256KB 块
    let harness = try makeHarness(sourceFiles: [("Album/01 Song.flac", payload)])
    let landed = harness.targetRoot.appendingPathComponent("Album/01 Song.flac")
    let sourceFile = harness.sourceRoot.appendingPathComponent("Album/01 Song.flac")
    check(FileManager.default.fileExists(atPath: landed.path), "落盘文件存在")
    let landedHash = try SyncFileChecksum.sha256Hex(ofFile: landed)
    let sourceHash = try SyncFileChecksum.sha256Hex(ofFile: sourceFile)
    checkEqual(landedHash, sourceHash, "SHA-256 与源一致")
    checkEqual(harness.sink.indexed, [landed.path], "入库入口被调用（落位路径）")
    if case let .done(summary) = harness.controller.state {
        checkEqual(summary.completed, ["Album/01 Song.flac"], "summary.completed")
        check(summary.failed.isEmpty, "summary.failed 为空")
        checkEqual(summary.requested, ["Album/01 Song.flac"], "summary.requested")
    } else {
        check(false, "状态应为 done，实际 \(harness.controller.state)")
    }
    _ = harness.hostManifestPeer
    _ = harness.hostResponder
} catch {
    check(false, "端到端① 抛错：\(error)")
}

// MARK: - ⑤ 端到端② 远端已删 → 本地删除

section("⑤ 端到端：远端已删 → toDelete 生效")
do {
    let shared = silentData(0x11, count: 4_096)
    let stale = silentData(0x22, count: 4_096)
    let harness = try makeHarness(
        sourceFiles: [("Album/kept.flac", shared)],
        targetFiles: [("Album/kept.flac", shared), ("Album/stale.flac", stale)]
    )
    let kept = harness.targetRoot.appendingPathComponent("Album/kept.flac")
    let removed = harness.targetRoot.appendingPathComponent("Album/stale.flac")
    check(FileManager.default.fileExists(atPath: kept.path), "远端仍在的文件保留")
    check(!FileManager.default.fileExists(atPath: removed.path), "远端已消失的本地副本被删")
    checkEqual(harness.sink.deleted, [removed.path], "删除走 sink（含 DB 行）")
    if case let .done(summary) = harness.controller.state {
        checkEqual(summary.deleted, ["Album/stale.flac"], "summary.deleted")
    } else {
        check(false, "状态应为 done，实际 \(harness.controller.state)")
    }
    _ = harness.hostManifestPeer
    _ = harness.hostResponder
} catch {
    check(false, "端到端② 抛错：\(error)")
}

// MARK: - ⑥ 端到端③ 私有区保护

section("⑥ 端到端：私有区 → 不删")
do {
    let harness = try makeHarness(
        sourceFiles: [],
        targetFiles: [
            ("Album/managed.flac", silentData(0x33, count: 2_048)),
            ("Imported/private.flac", silentData(0x44, count: 2_048)),
        ],
        protectedPaths: ["Imported/private.flac"]
    )
    let removed = harness.targetRoot.appendingPathComponent("Album/managed.flac")
    let protected = harness.targetRoot.appendingPathComponent("Imported/private.flac")
    check(!FileManager.default.fileExists(atPath: removed.path), "受管副本被删")
    check(FileManager.default.fileExists(atPath: protected.path), "私有区文件保留")
    checkEqual(harness.sink.deleted, [removed.path], "sink 只收到受管删除")
    if case let .done(summary) = harness.controller.state {
        checkEqual(summary.deleted, ["Album/managed.flac"], "summary.deleted 只含受管")
        checkEqual(summary.protectedSkipped, ["Imported/private.flac"], "summary.protectedSkipped 记录私有区")
    } else {
        check(false, "状态应为 done，实际 \(harness.controller.state)")
    }
    _ = harness.hostManifestPeer
    _ = harness.hostResponder
} catch {
    check(false, "端到端③ 抛错：\(error)")
}

// MARK: - ⑦ 端到端④ 越界请求拒绝

section("⑦ 端到端：越界路径请求 → Host 计入 failed，不出曲库根")
do {
    let fixture = SessionFixture.pairedHandshake()
    let sourceRoot = try tempRoot("src-escape")
    let outsideRoot = try tempRoot("outside")
    let secret = try writeFile("outside.flac", in: outsideRoot, data: silentData(0x77, count: 128))
    let hostResponder = SyncLibraryFetchResponder(session: fixture.hostSession, libraryRoot: sourceRoot)

    var received: SyncFetchResult?
    fixture.clientSession.onApplicationFrame = { frame in
        if frame.type == .syncFetchResult {
            received = try? SyncFetchCodec.decode(SyncFetchResult.self, from: frame.payload)
        }
    }

    let request = SyncFetchRequest(relativePaths: [
        "../\(outsideRoot.lastPathComponent)/outside.flac",
        secret.path,
        "/etc/passwd",
    ])
    try fixture.clientSession.sendApplicationFrame(
        type: .syncFetchRequest,
        payload: try SyncFetchCodec.encode(request)
    )

    if let result = received {
        check(result.completed.isEmpty, "越界请求 completed 为空")
        checkEqual(result.failed.count, 3, "三条越界请求全部计入 failed")
        check(result.failed.allSatisfy { $0.reason == SyncFetchFailureReason.invalidPath }, "原因均为 invalidPath")
        check(result.failed.map(\.relativePath).contains(secret.path), "失败记录回填原始请求路径")
    } else {
        check(false, "未收到 sync_fetch_result")
    }
    check(!FileManager.default.fileExists(atPath: sourceRoot.appendingPathComponent("outside.flac").path), "曲库根内无越界文件副本")
    _ = hostResponder
} catch {
    check(false, "端到端④ 抛错：\(error)")
}

// MARK: - 汇总

print("\n================ 结果 ================")
print("断言总数：\(checks)")
print("失败：\(failures.count)")
for failure in failures {
    print("  ❌ \(failure)")
}
if failures.isEmpty {
    print("✅ 全部通过")
    exit(0)
} else {
    exit(1)
}
