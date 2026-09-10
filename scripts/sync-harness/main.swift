//
//  main.swift — M3-3b 无模拟器本地 harness（**不参与 App target 编译**）
//
//  用 swiftc 直编生产源码 + 本目录夹具，真跑与 QQPlayerTests 同构的断言：
//  帧 12/13 编解码、请求路径规范化/解析、应答器解析计划、控制器状态机/对账映射、
//  四条既有端到端场景（拉取一致性 / 远端已删删除 / 私有区保护 / 越界拒绝），
//  以及 M4-2b（aligned 歌词库 / 随歌同步 / 越界拒读 / 只补不删）。
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

    var indexed: [String] {
        lock.lock(); defer { lock.unlock() }; return indexedPaths
    }

    func indexLandedFile(at url: URL) {
        lock.lock(); indexedPaths.append(url.path); lock.unlock()
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
    /// 两端 aligned 歌词库（M4-2b）
    let hostLyricsStore: AlignedLyricsStore
    let clientLyricsStore: AlignedLyricsStore
}

/// aligned 歌词夹具：歌曲 stableId ↔ 歌曲 content_hash + 要预置的歌词文件。
struct LyricsFixture {
    var songHashByStableId: [String: String] = [:]
    var files: [(stableId: String, lyrics: Lyrics)] = []
}

/// 内存映射（harness 里模拟两端 DB 的 stable_id ↔ content_hash）。
func mapping(of fixture: LyricsFixture?) -> SyncLyricsContentMapping {
    guard let fixture else { return .unresolved }
    let table = fixture.songHashByStableId
    return SyncLyricsContentMapping(
        contentHashForStableId: { table[$0] },
        stableIdForContentHash: { hash in table.first { $0.value == hash }?.key }
    )
}

func sampleLyrics(_ text: String) -> Lyrics {
    Lyrics(
        plainLyrics: text,
        syncedLyrics: [LyricsLine(timestamp: 1.0, text: text)],
        isInstrumental: false,
        source: .lrclib
    )
}

func makeHarness(
    sourceFiles: [(String, Data)] = [],
    targetFiles: [(String, Data)] = [],
    hostLyrics: LyricsFixture? = nil,
    clientLyrics: LyricsFixture? = nil
) throws -> Harness {
    let fixture = SessionFixture.pairedHandshake()
    let sourceRoot = try tempRoot("src")
    let targetRoot = try tempRoot("dst")
    for (path, data) in sourceFiles { try writeFile(path, in: sourceRoot, data: data) }
    for (path, data) in targetFiles { try writeFile(path, in: targetRoot, data: data) }

    let hostLyricsStore = AlignedLyricsStore(directory: try tempRoot("host-lyrics"))
    let clientLyricsStore = AlignedLyricsStore(directory: try tempRoot("client-lyrics"))
    for (stableId, lyrics) in (hostLyrics?.files ?? []) {
        try hostLyricsStore.write(lyrics, forStableId: stableId)
    }
    for (stableId, lyrics) in (clientLyrics?.files ?? []) {
        try clientLyricsStore.write(lyrics, forStableId: stableId)
    }
    let hostMapping = mapping(of: hostLyrics)
    let clientMapping = mapping(of: clientLyrics)

    let hostManager = DatabaseManager()
    let hostManifestPeer = SyncManifestPeer(session: fixture.hostSession)
    hostManifestPeer.localRootName = { "测试 Mac 曲库" }
    hostManifestPeer.localManifestProvider = { collection in
        SyncLocalLibraryScanner.entries(
            in: sourceRoot,
            lyricsStore: hostLyricsStore,
            lyricsMapping: hostMapping,
            collection: collection,
            database: hostManager
        )
    }
    let hostResponder = SyncLibraryFetchResponder(
        session: fixture.hostSession,
        roots: SyncFetchRoots(libraryRoot: sourceRoot, lyricsRoot: hostLyricsStore.directory),
        lyricsFileNameProvider: { wirePath in
            guard let songHash = SyncLyricsNamespace.songContentHash(fromWirePath: wirePath),
                  let stableId = hostMapping.stableIdForContentHash(songHash)
            else { return nil }
            return "\(stableId).json"
        }
    )

    let sink = SinkSpy()
    let configuration = SyncLibrarySyncConfiguration()
    let controller = SyncLibrarySyncController(
        session: fixture.clientSession,
        libraryRoot: targetRoot,
        sink: sink,
        configuration: configuration,
        database: DatabaseManager(),
        lyricsStore: clientLyricsStore,
        lyricsMapping: clientMapping
    )
    try controller.start()

    return Harness(
        fixture: fixture,
        sourceRoot: sourceRoot,
        targetRoot: targetRoot,
        hostManifestPeer: hostManifestPeer,
        hostResponder: hostResponder,
        sink: sink,
        controller: controller,
        hostLyricsStore: hostLyricsStore,
        clientLyricsStore: clientLyricsStore
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
        relativePaths: [
            "/etc/passwd", "../outside.flac", "", "", "missing.flac", "escape.flac",
            "alias.flac", "./inside.flac", "inside.flac", "alias.flac",
        ],
        root: planRoot
    )
    let reasons = Dictionary(uniqueKeysWithValues: plan.failures.map { ($0.relativePath, $0.reason) })
    checkEqual(reasons["/etc/passwd"], SyncFetchFailureReason.invalidPath, "绝对路径 → invalidPath")
    checkEqual(reasons["../outside.flac"], SyncFetchFailureReason.invalidPath, "`..` → invalidPath")
    checkEqual(reasons[""], SyncFetchFailureReason.invalidPath, "空路径 → invalidPath")
    checkEqual(reasons["missing.flac"], SyncFetchFailureReason.notFound, "不存在 → notFound")
    checkEqual(reasons["escape.flac"], SyncFetchFailureReason.outOfRoot, "软链逃逸 → outOfRoot")
    checkEqual(plan.failures.count, 5, "重复的非法请求只报一次失败")
    checkEqual(plan.files.map(\.relativePath), ["alias.flac", "inside.flac"], "根内文件（含根内软链）放行")
    checkEqual(plan.files.count, 2, "重复请求只处理一次（含 ./ 前缀等价路径）")
} catch {
    check(false, "应答器计划抛错：\(error)")
}

// MARK: - ③ 控制器状态机 + 对账映射

section("③ 状态机 + 对账 → 计划（只补齐，不删除）")
check(SyncLibrarySyncStateMachine.canTransition(from: .idle, to: .requestingManifest), "idle → requestingManifest 允许")
check(SyncLibrarySyncStateMachine.canTransition(from: .requestingManifest, to: .fetching), "requestingManifest → fetching 允许")
check(SyncLibrarySyncStateMachine.canTransition(from: .requestingManifest, to: .done(SyncLibrarySyncSummary())), "requestingManifest → done 允许（无待拉取）")
check(SyncLibrarySyncStateMachine.canTransition(from: .fetching, to: .done(SyncLibrarySyncSummary())), "fetching → done 允许")
check(!SyncLibrarySyncStateMachine.canTransition(from: .idle, to: .fetching), "idle → fetching 拒绝（越级）")
check(SyncLibrarySyncStateMachine.canTransition(from: .fetching, to: .failed("x")), "非终态 → failed 允许")
check(!SyncLibrarySyncStateMachine.canTransition(from: .done(SyncLibrarySyncSummary()), to: .failed("x")), "终态后迁移拒绝")

do {
    let config = SyncLibrarySyncConfiguration()
    let remote = SyncManifestResponse(entries: [
        entry("changed.flac", hash: "new"),
        entry("missing.flac", hash: "h3"),
        entry("same.flac", hash: "h1"),
    ])
    let local = [entry("same.flac", hash: "h1"), entry("changed.flac", hash: "old")]
    let plan = SyncLibrarySyncPlanner.plan(remote: remote, local: local, configuration: config)
    checkEqual(plan.fetchRequest?.relativePaths, ["changed.flac", "missing.flac"], "本地缺失/内容不同 → 拉取列表")
    checkEqual(plan.unchanged.map(\.relativePath), ["same.flac"], "内容一致 → unchanged")

    // 不传播删除：远端已消失的本地条目（含导入区）不进任何待处理列表
    let noDeletePlan = SyncLibrarySyncPlanner.plan(
        remote: SyncManifestResponse(entries: []),
        local: [entry("Album/synced.flac", hash: "h1"), entry("Imported/private.flac", hash: "h2")],
        configuration: config
    )
    checkEqual(noDeletePlan.fetchRequest, nil, "远端已删 → 无待拉取动作（本端保留）")
    checkEqual(noDeletePlan.unchanged, [], "远端已删 → unchanged 为空")

    // 集合选择不影响本端存留
    var scoped = SyncLibrarySyncConfiguration()
    scoped.collection = .tracks(["s1"])
    let scopedPlan = SyncLibrarySyncPlanner.plan(
        remote: SyncManifestResponse(entries: []),
        local: [entry("selected.flac", hash: "h1", stableId: "s1"), entry("other.flac", hash: "h2", stableId: "s2")],
        configuration: scoped
    )
    checkEqual(scopedPlan.fetchRequest, nil, "集合选择不产生任何删除/拉取动作")
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

section("⑤ 端到端：远端已删 → 本端保留（不传播删除）")
do {
    let shared = silentData(0x11, count: 4_096)
    let stale = silentData(0x22, count: 4_096)
    let imported = silentData(0x44, count: 2_048)
    let harness = try makeHarness(
        sourceFiles: [("Album/kept.flac", shared)],
        targetFiles: [
            ("Album/kept.flac", shared),
            ("Album/stale.flac", stale),
            ("Imported/private.flac", imported),
        ]
    )
    let kept = harness.targetRoot.appendingPathComponent("Album/kept.flac")
    let keptStale = harness.targetRoot.appendingPathComponent("Album/stale.flac")
    let keptImported = harness.targetRoot.appendingPathComponent("Imported/private.flac")
    check(FileManager.default.fileExists(atPath: kept.path), "远端仍在的文件保留")
    check(FileManager.default.fileExists(atPath: keptStale.path), "远端已消失的本地副本保留（不传播删除）")
    check(FileManager.default.fileExists(atPath: keptImported.path), "导入区文件同样保留")
    checkEqual(harness.sink.indexed, [], "无拉取动作 → 入库入口未被调用")
    if case let .done(summary) = harness.controller.state {
        checkEqual(summary.completed, [], "summary.completed 为空")
        checkEqual(summary.requested, [], "summary.requested 为空（无待拉取）")
        check(summary.failed.isEmpty, "summary.failed 为空")
    } else {
        check(false, "状态应为 done，实际 \(harness.controller.state)")
    }
    _ = harness.hostManifestPeer
    _ = harness.hostResponder
} catch {
    check(false, "端到端② 抛错：\(error)")
}

// MARK: - ⑥ 端到端③ 越界请求拒绝

section("⑥ 端到端：越界路径请求 → Host 计入 failed，不出曲库根")
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

// MARK: - ⑧ aligned 歌词库单一入口（Part A）

section("⑦ aligned 歌词库：读/写/删/枚举 + 类型标记")
do {
    let store = AlignedLyricsStore(directory: try tempRoot("aligned-store"))
    let lyrics = sampleLyrics("第一行\n第二行")
    try store.write(lyrics, forStableId: "sid-1")
    try store.write(sampleLyrics("B"), forStableId: "sid-2")

    let readBack = try store.read(forStableId: "sid-1")
    checkEqual(readBack?.plainLyrics, lyrics.plainLyrics, "写入后可读回（形态与 manual 同构）")
    checkEqual(readBack?.source, .lrclib, "source 字段随文件保留")
    checkEqual(store.stableIds(), ["sid-1", "sid-2"], "枚举按 stableId 升序")
    checkEqual(store.entries().count, 2, "entries 含两条")
    check(store.contains(forStableId: "sid-1"), "contains 命中")
    check(try store.read(forStableId: "nope") == nil, "未写入的 stableId 读出 nil")

    try store.delete(forStableId: "sid-1")
    check(!store.contains(forStableId: "sid-1"), "删除后文件消失")
    try store.delete(forStableId: "sid-1")
    check(true, "重复删除幂等")
    checkEqual(store.stableIds(), ["sid-2"], "删除后枚举只剩一条")

    var caught = false
    do { try store.write(lyrics, forStableId: "../escape") } catch { caught = true }
    check(caught, "非法 stableId（含 /）拒绝写入（防路径穿越）")
    checkEqual(AlignedLyricsStore.isValidStableId(".."), false, "stableId = .. 非法")

    // 接收侧安装：先校验可解码，再字节原样落位
    let incoming = try tempRoot("lyrics-incoming")
    let good = incoming.appendingPathComponent("good.json")
    try JSONEncoder().encode(sampleLyrics("收到的歌词")).write(to: good)
    try store.install(receivedFileAt: good, forStableId: "sid-9")
    checkEqual(try store.read(forStableId: "sid-9")?.plainLyrics, "收到的歌词", "install 安装收到的歌词文件")
    check(!FileManager.default.fileExists(atPath: good.path), "install 是移动（不留临时文件）")

    let bad = incoming.appendingPathComponent("bad.json")
    try Data("not json".utf8).write(to: bad)
    var installCaught = false
    do { try store.install(receivedFileAt: bad, forStableId: "sid-10") } catch { installCaught = true }
    check(installCaught, "install 拒绝坏字节（不写坏库）")
    check(!store.contains(forStableId: "sid-10"), "坏字节未落库")

    // 类型标记：只有 aligned 参与同步
    check(LyricsStoreKind.aligned.synchronizesWithLibrary, "aligned 参与同步")
    check(!LyricsStoreKind.manual.synchronizesWithLibrary, "manual 不参与同步")
    check(!LyricsStoreKind.network.synchronizesWithLibrary, "network 不参与同步")
    checkEqual(LyricsStoreKind.synchronizedKinds, [.aligned], "参与同步的种类只有 aligned")
    let dirNames = Set(LyricsStoreKind.allCases.map(\.directoryName))
    checkEqual(dirNames.count, 3, "三类歌词库目录命名空间互不重叠")
} catch {
    check(false, "⑧ 抛错：\(error)")
}

// MARK: - ⑨ 歌词命名空间 + manifest 纳入

section("⑧ 歌词命名空间 + manifest 含歌词条目")
do {
    checkEqual(
        SyncLyricsNamespace.wirePath(songContentHash: "abc123"),
        "@lyrics/abc123.json",
        "歌曲 content_hash → wire 路径"
    )
    checkEqual(
        SyncLyricsNamespace.songContentHash(fromWirePath: "@lyrics/abc123.json"),
        "abc123",
        "wire 路径 → 歌曲 content_hash"
    )
    check(SyncLyricsNamespace.isLyricsPath("./@lyrics/abc123.json"), "./ 前缀仍识别为歌词路径")
    check(!SyncLyricsNamespace.isLyricsPath("Album/01.flac"), "曲库路径不是歌词路径")
    for bad in ["@lyrics/../x.json", "@lyrics/a/b.json", "@lyrics/.json", "@lyrics/abc123.flac"] {
        check(
            SyncLyricsNamespace.songContentHash(fromWirePath: bad) == nil,
            "非法歌词路径取不到 hash：\(bad)"
        )
    }

    let store = AlignedLyricsStore(directory: try tempRoot("manifest-lyrics"))
    try store.write(sampleLyrics("有指纹"), forStableId: "s1")
    try store.write(sampleLyrics("无指纹"), forStableId: "s2")
    let mapping = SyncLyricsContentMapping(
        contentHashForStableId: { ["s1": "hash-1"][$0] },
        stableIdForContentHash: { $0 == "hash-1" ? "s1" : nil }
    )
    let entries = SyncAlignedLyricsManifest.entries(store: store, mapping: mapping)
    checkEqual(entries.count, 1, "指纹缺失的歌词条目不进 manifest")
    checkEqual(entries.first?.relativePath, "@lyrics/hash-1.json", "manifest 路径 = @lyrics/{歌曲 content_hash}.json")
    checkEqual(entries.first?.stableId, "s1", "manifest 携带本端 stableId（单端引用）")
    check(entries.first?.contentHash?.isEmpty == false, "manifest contentHash = 歌词文件自身 SHA-256")

    let filtered = SyncAlignedLyricsManifest.entries(
        store: store,
        mapping: mapping,
        collection: .tracks(["s1"])
    )
    checkEqual(filtered.map(\.relativePath), ["@lyrics/hash-1.json"], "歌词条目受同一集合过滤")
    let filteredOut = SyncAlignedLyricsManifest.entries(
        store: store,
        mapping: mapping,
        collection: .tracks(["other"])
    )
    check(filteredOut.isEmpty, "未入选集合的歌词条目不出现")

    let noMapping = SyncAlignedLyricsManifest.entries(store: store, mapping: .unresolved)
    check(noMapping.isEmpty, "映射未解析时歌词不同步（开关默认关）")
} catch {
    check(false, "⑨ 抛错：\(error)")
}

// MARK: - ⑩ 歌词路径越界 / 软链逃逸仍被拒

section("⑨ 歌词根：越界与软链逃逸仍被拒")
do {
    let lyricsRoot = try tempRoot("lyr-root")
    let outsideRoot = try tempRoot("lyr-outside")
    let outsideFile = try writeFile("secret.json", in: outsideRoot, data: Data("{}".utf8))
    try Data("{}".utf8).write(to: lyricsRoot.appendingPathComponent("s1.json"))
    try FileManager.default.createSymbolicLink(
        at: lyricsRoot.appendingPathComponent("escape.json"),
        withDestinationURL: outsideFile
    )
    let roots = SyncFetchRoots(libraryRoot: try tempRoot("lyr-lib"), lyricsRoot: lyricsRoot)

    func provider(_ wirePath: String) -> String? {
        guard let hash = SyncLyricsNamespace.songContentHash(fromWirePath: wirePath) else { return nil }
        switch hash {
        case "s1": return "s1.json"
        case "escape": return "escape.json"
        case "outside": return "../" + outsideRoot.lastPathComponent + "/secret.json"
        case "absolute": return outsideFile.path
        default: return nil
        }
    }

    let plan = SyncLibraryFetchResponder.makePlan(
        relativePaths: [
            "@lyrics/s1.json", "@lyrics/escape.json", "@lyrics/outside.json",
            "@lyrics/absolute.json", "@lyrics/missing.json", "@lyrics/../etc/passwd", "@lyrics/a/b.json",
            "@lyrics/s1.json",
        ],
        roots: roots,
        lyricsFileNameProvider: provider
    )
    let reasons = Dictionary(plan.failures.map { ($0.relativePath, $0.reason) }, uniquingKeysWith: { a, _ in a })
    checkEqual(plan.files.map(\.relativePath), ["@lyrics/s1.json"], "歌词根内文件放行（含重复请求去重）")
    checkEqual(reasons["@lyrics/escape.json"], SyncFetchFailureReason.outOfRoot, "歌词根内软链指向根外 → outOfRoot")
    checkEqual(
        reasons["@lyrics/outside.json"],
        SyncFetchFailureReason.notFound,
        "映射给出带 .. 的名字 → 拒（绝不拿它拼根外路径）"
    )
    checkEqual(reasons["@lyrics/absolute.json"], SyncFetchFailureReason.notFound, "映射给出绝对路径 → 拒")
    checkEqual(reasons["@lyrics/missing.json"], SyncFetchFailureReason.notFound, "映射不到 → notFound")
    checkEqual(reasons["@lyrics/../etc/passwd"], SyncFetchFailureReason.invalidPath, "带 .. 的歌词路径 → invalidPath")
    checkEqual(reasons["@lyrics/a/b.json"], SyncFetchFailureReason.invalidPath, "嵌套歌词路径 → invalidPath")
    checkEqual(plan.files.map(\.url), [lyricsRoot.appendingPathComponent("s1.json")], "解析到歌词根内绝对 URL")

    // 未配置歌词根：歌词请求一律 notFound（不落回曲库根尝试）
    let noLyrics = SyncLibraryFetchResponder.makePlan(
        relativePaths: ["@lyrics/s1.json"],
        roots: .libraryOnly(roots.libraryRoot),
        lyricsFileNameProvider: provider
    )
    checkEqual(
        noLyrics.failures.map(\.reason),
        [SyncFetchFailureReason.notFound],
        "未接线歌词根 → notFound（不读曲库根）"
    )
    check(!FileManager.default.fileExists(atPath: roots.libraryRoot.appendingPathComponent("@lyrics/s1.json").path), "曲库根内不会出现歌词副本")
} catch {
    check(false, "⑩ 抛错：\(error)")
}

// MARK: - ⑪ 端到端：歌词随歌同步（映射落盘 / 无歌丢弃）

section("⑩ 端到端：aligned 歌词随歌同步 → 落本端歌词库")
do {
    let song = silentData(0x61, count: 4_096)
    let songHash = try SyncFileChecksum.sha256Hex(ofFile: {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash-helper-\(UUID().uuidString)")
        try? song.write(to: url)
        return url
    }())
    var hostLyrics = LyricsFixture()
    hostLyrics.songHashByStableId = ["host-sid": songHash]
    hostLyrics.files = [("host-sid", sampleLyrics("随歌同步的歌词"))]

    var clientLyrics = LyricsFixture()
    clientLyrics.songHashByStableId = ["client-sid": songHash]

    let harness = try makeHarness(
        sourceFiles: [("Album/01 Song.flac", song)],
        hostLyrics: hostLyrics,
        clientLyrics: clientLyrics
    )
    let installed = try harness.clientLyricsStore.read(forStableId: "client-sid")
    checkEqual(installed?.plainLyrics, "随歌同步的歌词", "歌词按 content_hash 映射落到本端 stableId（不是对端 stableId）")
    check(!harness.clientLyricsStore.contains(forStableId: "host-sid"), "不按对端 stableId 落库")
    checkEqual(harness.sink.indexed.count, 1, "曲库文件仍经入库入口（歌词不走曲库入库）")
    if case let .done(summary) = harness.controller.state {
        check(summary.completed.contains("@lyrics/\(songHash).json"), "summary.completed 含歌词条目")
        check(summary.orphanLyricsSkipped.isEmpty, "无孤儿歌词")
    } else {
        check(false, "状态应为 done，实际 \(harness.controller.state)")
    }
    check(FileManager.default.fileExists(atPath: harness.targetRoot.appendingPathComponent("Album/01 Song.flac").path), "歌曲同时落盘")
    let incoming = harness.targetRoot.appendingPathComponent(".sync-incoming")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: incoming.path)) ?? []
    checkEqual(leftovers, [], "落地目录无残渣")
} catch {
    check(false, "⑪ 抛错：\(error)")
}

// MARK: - ⑫ 端到端：本端无对应歌曲 → 丢弃不写孤儿

section("⑪ 端到端：本端没有对应歌曲 → 歌词不落库（不写孤儿）")
do {
    let song = silentData(0x62, count: 4_096)
    let tempHashFile = FileManager.default.temporaryDirectory.appendingPathComponent("hash-helper-\(UUID().uuidString)")
    try song.write(to: tempHashFile)
    let songHash = try SyncFileChecksum.sha256Hex(ofFile: tempHashFile)

    var hostLyrics = LyricsFixture()
    hostLyrics.songHashByStableId = ["host-sid": songHash]
    hostLyrics.files = [("host-sid", sampleLyrics("孤立歌词"))]

    // 客户端映射里没有这首歌（模拟新设备首轮：歌还没入库）
    var clientLyrics = LyricsFixture()
    clientLyrics.songHashByStableId = [:]

    let harness = try makeHarness(
        sourceFiles: [],
        hostLyrics: hostLyrics,
        clientLyrics: clientLyrics
    )
    checkEqual(harness.clientLyricsStore.stableIds(), [], "未落任何歌词（不写孤儿）")
    if case let .done(summary) = harness.controller.state {
        checkEqual(summary.orphanLyricsSkipped, ["@lyrics/\(songHash).json"], "记账为 orphanLyricsSkipped")
    } else {
        check(false, "状态应为 done，实际 \(harness.controller.state)")
    }
    let incoming = harness.targetRoot.appendingPathComponent(".sync-incoming")
    let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: incoming.path)) ?? []
    checkEqual(leftovers, [], "丢弃后落地目录无残渣")
} catch {
    check(false, "⑫ 抛错：\(error)")
}

// MARK: - ⑬ 端到端：对端已删 → 本端歌词保留（不传播删除）

section("⑫ 端到端：对端已删 → 本端 aligned 歌词保留（删除不传播）")
do {
    let song = silentData(0x63, count: 4_096)
    let tempHashFile = FileManager.default.temporaryDirectory.appendingPathComponent("hash-helper-\(UUID().uuidString)")
    try song.write(to: tempHashFile)
    let songHash = try SyncFileChecksum.sha256Hex(ofFile: tempHashFile)

    var clientLyrics = LyricsFixture()
    clientLyrics.songHashByStableId = ["client-sid": songHash]
    clientLyrics.files = [("client-sid", sampleLyrics("要保留的歌词"))]

    // 对端已经把这首歌（连同它的歌词）删掉了
    let harness = try makeHarness(
        sourceFiles: [],
        targetFiles: [("Album/gone.flac", song)],
        clientLyrics: clientLyrics
    )
    checkEqual(harness.clientLyricsStore.stableIds(), ["client-sid"], "远端没有的歌词不被删")
    checkEqual(
        try harness.clientLyricsStore.read(forStableId: "client-sid")?.plainLyrics,
        "要保留的歌词",
        "歌词内容原样保留（删除只由本端用户发起）"
    )
    if case let .done(summary) = harness.controller.state {
        check(summary.requested.isEmpty && summary.completed.isEmpty, "远端已删的歌词 → 本端零动作（删除不跨端传播）")
        check(!summary.orphanLyricsSkipped.contains("@lyrics/\(songHash).json"), "本端已有的歌词不会被当孤儿丢弃")
    } else {
        check(false, "状态应为 done，实际 \(harness.controller.state)")
    }

    // 规划层：远端缺失的歌词条目永不转化为删除（含全库镜像 .all 配置）
    let plan = SyncLibrarySyncPlanner.plan(
        remote: SyncManifestResponse(entries: []),
        local: [entry("@lyrics/\(songHash).json", hash: "h", stableId: "client-sid")],
        configuration: SyncLibrarySyncConfiguration()
    )
    checkEqual(plan.fetchRequest, nil, "规划层：远端没有的歌词 → 无动作，不留任何待办（只补不删）")
} catch {
    check(false, "⑬ 抛错：\(error)")
}

section("⑬ 隔离：同步无删除出口；manual / network 不被触")
do {
    let documents = try tempRoot("documents")
    let alignedDir = documents.appendingPathComponent("lyrics-aligned")
    let manualDir = documents.appendingPathComponent("lyrics-manual")
    let networkDir = documents.appendingPathComponent("lyrics-cache/tracks")
    for dir in [alignedDir, manualDir, networkDir] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let manualFile = manualDir.appendingPathComponent("sid.json")
    let networkFile = networkDir.appendingPathComponent("sid.json")
    try Data("manual".utf8).write(to: manualFile)
    try Data("network".utf8).write(to: networkFile)

    let store = AlignedLyricsStore(directory: alignedDir)
    try store.write(sampleLyrics("本端已有"), forStableId: "sid")

    // 同步层已无删除出口（生产 sink 只剩入库一个方法）：删歌不连带清歌词
    let trackFile = documents.appendingPathComponent("track.flac")
    try silentData(0x01, count: 32).write(to: trackFile)
    _ = LibraryIndexerSyncSink()

    check(store.contains(forStableId: "sid"), "本端 aligned 歌词保持存在（同步不删）")
    checkEqual(store.stableIds(), ["sid"], "aligned 库内容不变")
    checkEqual(try String(contentsOf: manualFile, encoding: .utf8), "manual", "manual 歌词未被动过")
    checkEqual(try String(contentsOf: networkFile, encoding: .utf8), "network", "network 缓存未被动过")
} catch {
    check(false, "⑭ 抛错：\(error)")
}

// MARK: - ⑭ changeLog 删除不传播策略

section("⑭ changeLog 删除不传播：发送侧过滤 + 接收侧忽略（v2 §12b-7）")

do {
    // ① 发送侧：delete 不上线（本地 outbox 照记）。
    //    生产接线：SyncChangeLogPeer.handlePull → SyncChangeLogDeletionPolicy.transmittableIndexes，
    //    应答游标仍推进到 maxOutboxID，onPullHandled 计数 = 过滤前的 outbox 增量行数。
    func policyRow(_ key: String, _ op: String) -> SyncChangeLogPolicyRow {
        SyncChangeLogPolicyRow(entity: "favorite", rowKey: key, op: op)
    }

    let deleteOnly = [policyRow("a", "delete"), policyRow("b", "delete")]
    checkEqual(
        SyncChangeLogDeletionPolicy.transmittableIndexes(rows: deleteOnly),
        [],
        "发送侧：纯 delete 序列上线条目为空（永不上线）"
    )

    let addThenRemove = [policyRow("a", "upsert"), policyRow("a", "delete")]
    checkEqual(
        SyncChangeLogDeletionPolicy.transmittableIndexes(rows: addThenRemove),
        [],
        "发送侧：同键 upsert→delete（末尾 delete）时更早的 upsert 也不上线（不复活已删状态）"
    )

    let removeThenAdd = [policyRow("a", "delete"), policyRow("a", "upsert")]
    checkEqual(
        SyncChangeLogDeletionPolicy.transmittableIndexes(rows: removeThenAdd),
        [1],
        "发送侧：同键 delete→upsert（末尾 upsert）时只过滤 delete，最新状态照上"
    )

    let mixedKeys = [policyRow("a", "upsert"), policyRow("b", "upsert"), policyRow("a", "delete")]
    checkEqual(
        SyncChangeLogDeletionPolicy.transmittableIndexes(rows: mixedKeys),
        [1],
        "发送侧：键间互不影响（A 键末尾 delete → A 键全部不上线，B 键照上）"
    )

    checkEqual(addThenRemove.count, 2, "发送侧：本端 outbox 增量行数 = 过滤前条目数（含被过滤的 delete），计数不受影响")
    checkEqual(
        SyncChangeLogDeletionPolicy.transmittableIndexes(rows: [policyRow("a", "play_history")]),
        [0],
        "发送侧：非 delete 的 op 不误伤（不拦）"
    )

    // ② 接收侧：delete 一律忽略（拦截在 localize 之前，不进挂起表、不进 LWW、不删本地行）。
    let inboundOps = ["upsert", "delete", "delete", "upsert"]
    let keptOps = inboundOps.filter { !SyncChangeLogDeletionPolicy.shouldIgnore(op: $0) }
    checkEqual(keptOps, ["upsert", "upsert"], "接收侧：delete 被忽略、upsert 不受影响")
    checkEqual(inboundOps.count - keptOps.count, 2, "接收侧：被忽略的 delete 计数 = 2（不挂起、不删本地行）")
    check(
        !SyncChangeLogDeletionPolicy.shouldIgnore(op: "play_history"),
        "接收侧：非 delete 的 op 不误伤（不被忽略）"
    )

    // ③ 同一事实源三处消费点语义一致（发送过滤 / 接收忽略 / 应用层兜底）。
    let deleteOp = SyncChangeLogDeletionPolicy.deleteOperation
    check(SyncChangeLogDeletionPolicy.isDelete(op: deleteOp), "isDelete(delete) = true")
    check(!SyncChangeLogDeletionPolicy.isDelete(op: "upsert"), "isDelete(upsert) = false")
    check(!SyncChangeLogDeletionPolicy.isTransmittable(op: deleteOp), "发送侧：delete 不上线")
    check(SyncChangeLogDeletionPolicy.shouldIgnore(op: deleteOp), "接收侧：delete 一律忽略")
    check(
        SyncChangeLogDeletionPolicy.shouldIgnore(op: deleteOp)
            == !SyncChangeLogDeletionPolicy.isTransmittable(op: deleteOp),
        "发送侧过滤与接收侧忽略同源同判（delete 恒真，upsert 恒假）"
    )

    // ④ 线协议 op 常量：本 harness 无法编 SyncChangeOp（SyncDataSyncModels.swift 依赖
    //    GRDB 的 Database/Column/Record，而 GRDBShim 只提供两个空协议）→ 退回纯字符串
    //    断言，不硬塞依赖；与 SyncChangeOp.delete.rawValue 的真实对齐由 QQPlayerTests
    //    契约用例（SyncChangeLogFrameTests.deletionPolicyContract）在 CI 兜底。
    checkEqual(SyncChangeLogDeletionPolicy.deleteOperation, "delete", "线协议 delete op 字符串 = \"delete\"")
    check(SyncChangeLogDeletionPolicy.isDelete(op: "delete"), "字符串 \"delete\" 判为删除")
}

// MARK: - ⑮ 推送声明模型 + 认领表（纯逻辑，R1b-1）

/// 收结果帧的小夹具（假 Mac 侧收 sync_fetch_result）。
final class ResultTap {
    private let lock = NSLock()
    private var stored: SyncFetchResult?
    private var prior: ((SyncFrame) -> Void)?

    init(session: SyncPeerSession) {
        prior = session.onApplicationFrame
        session.onApplicationFrame = { [weak self] frame in
            guard let self else { return }
            if frame.type == .syncFetchResult,
               let decoded = try? SyncFetchCodec.decode(SyncFetchResult.self, from: frame.payload) {
                self.lock.lock()
                self.stored = decoded
                self.lock.unlock()
            }
            self.prior?(frame)
        }
    }

    var value: SyncFetchResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// 内存数据的 SHA-256（与落到磁盘后的文件哈希同口径）。
func sha256Hex(of data: Data) throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("qqp-hash-\(UUID().uuidString)")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    return try SyncFileChecksum.sha256Hex(ofFile: url)
}

section("⑮ 推送声明模型 + 认领表（纯逻辑）")
do {
    check(
        SyncPushEntry.make(relativePath: "../escape.flac", fileID: "h", sha256Hex: "h", size: 1) == nil,
        "`..` 逃逸路径不能构造声明条目"
    )
    check(
        SyncPushEntry.make(relativePath: "/abs.flac", fileID: "h", sha256Hex: "h", size: 1) == nil,
        "绝对路径不能构造声明条目"
    )
    check(
        SyncPushEntry.make(relativePath: "Album/.hidden.flac", fileID: "h", sha256Hex: "h", size: 1) == nil,
        "隐藏文件（点开头）不能构造声明条目"
    )
    checkEqual(
        SyncPushEntry.make(relativePath: "Album/./01.flac", fileID: "h", sha256Hex: "h", size: 1)?.relativePath,
        "Album/01.flac",
        "声明路径规范化（与对账键同口径）"
    )
    let good = SyncPushEntry.make(relativePath: "Album/01 Song.flac", fileID: "abc", sha256Hex: "abc", size: 10)
    checkEqual(good?.transferName, "01 Song.flac", "传输名 = 路径末段（单段）")
    check(good?.isStructurallyValid == true, "自洽条目通过结构校验")

    let dup = SyncPushEntry(
        relativePath: "Album/01.flac", transferName: "01.flac", fileID: "a", sha256Hex: "a", size: 1
    )
    let invalid = SyncPushEntry(
        relativePath: "../x.flac", transferName: "x.flac", fileID: "b", sha256Hex: "b", size: 1
    )
    let announce = SyncLibraryPushAnnounce(entries: [dup, invalid, dup])
    checkEqual(announce.entries.map(\.relativePath), ["Album/01.flac"], "声明构造：非法丢弃 + 同路径去重")
    check(!announce.isEmpty, "声明非空")
    check(SyncLibraryPushAnnounce(entries: []).isEmpty, "空声明 isEmpty")

    let a = SyncPushEntry(relativePath: "A/dup.flac", transferName: "dup.flac", fileID: "a", sha256Hex: "a", size: 1)
    let b = SyncPushEntry(relativePath: "B/dup.flac", transferName: "dup.flac", fileID: "b", sha256Hex: "b", size: 1)
    var table = SyncPushClaimTable(entries: [a, b])
    checkEqual(table.claim(transferName: "dup.flac"), "A/dup.flac", "同名多路径：首个未认领")
    checkEqual(table.claim(transferName: "dup.flac"), "B/dup.flac", "同名多路径：第二个未认领")
    check(table.claim(transferName: "dup.flac") == nil, "认领完 → nil")
    check(table.isEmpty, "认领表已取空")
    var unknownTable = SyncPushClaimTable(entries: [a])
    check(
        unknownTable.claim(transferName: "unknown.flac") == nil,
        "未声明的传输名 → nil（不落位）"
    )

    let payload = try SyncPushCodec.encode(announce)
    checkEqual(try SyncPushCodec.decode(SyncLibraryPushAnnounce.self, from: payload), announce, "帧 14 载荷编解码往返")
    checkEqual(SyncFrameType.libraryPushAnnounce.rawValue, 14, "新帧从 14 起编号")
    checkEqual(SyncFrameType.syncFetchResult.rawValue, 13, "既有帧值语义不变（10-13 保持）")
} catch {
    check(false, "⑮ 抛错：\(error)")
}

// MARK: - ⑯ 被动端：应答 Mac 的 manifest / 文件请求

section("⑯ 被动端：应答 Mac 的 manifest / 文件请求（含越界拒读）")
do {
    let song = silentData(0x71, count: 300_000)
    let songHash = try sha256Hex(of: song)
    let deviceRoot = try tempRoot("device-lib")
    try writeFile("Album/01 Song.flac", in: deviceRoot, data: song)
    try writeFile("Imported/device-only.flac", in: deviceRoot, data: silentData(0x72, count: 1_024))
    let outsideRoot = try tempRoot("device-outside")
    let outsideFile = try writeFile("secret.flac", in: outsideRoot, data: silentData(0x77, count: 32))
    try FileManager.default.createSymbolicLink(
        at: deviceRoot.appendingPathComponent("escape.flac"),
        withDestinationURL: outsideFile
    )
    let deviceLyrics = AlignedLyricsStore(directory: try tempRoot("device-lyrics"))
    try deviceLyrics.write(sampleLyrics("设备侧对齐歌词"), forStableId: "dev-sid")
    var fixtureMap = LyricsFixture()
    fixtureMap.songHashByStableId = ["dev-sid": songHash]
    let deviceMapping = mapping(of: fixtureMap)

    let fixture = SessionFixture.pairedHandshake()
    let sink = SinkSpy()
    let host = SyncLibraryPassiveHost(
        libraryRoot: deviceRoot,
        sink: sink,
        database: DatabaseManager(),
        lyricsStore: deviceLyrics,
        lyricsMapping: deviceMapping
    )
    check(host.attach(to: fixture.clientSession), "被动端接线成功（应答 + 接收）")

    // ① Mac 请求 manifest → 本端应答（曲库 + 歌词命名空间，升序）
    let macPeer = SyncManifestPeer(session: fixture.hostSession)
    var manifestResponse: SyncManifestResponse?
    macPeer.onManifestReceived = { manifestResponse = $0 }
    try macPeer.requestManifest()
    checkEqual(
        manifestResponse?.entries.map(\.relativePath) ?? [],
        ["@lyrics/\(songHash).json", "Album/01 Song.flac", "Imported/device-only.flac"],
        "manifest 应答 = 本端曲库 + aligned 歌词（升序）"
    )

    // ② Mac 请求文件（从设备下载）→ 本端回推内容 + 越界一律拒
    let macIncoming = try tempRoot("mac-incoming")
    let macReceiver = SyncFileReceiver(session: fixture.hostSession, directory: macIncoming)
    var macReceived: [SyncFileReceiver.Outcome] = []
    macReceiver.onCompletion = { macReceived.append($0) }
    let resultTap = ResultTap(session: fixture.hostSession)
    let request = SyncFetchRequest(
        collection: .all,
        relativePaths: ["Album/01 Song.flac", "/etc/passwd", "../escape.flac", "escape.flac", "Album/missing.flac"]
    )
    try fixture.hostSession.sendApplicationFrame(
        type: .syncFetchRequest,
        payload: try SyncFetchCodec.encode(request)
    )
    checkEqual(resultTap.value?.completed, ["Album/01 Song.flac"], "回推完成清单")
    let reasons = Dictionary(
        uniqueKeysWithValues: (resultTap.value?.failed ?? []).map { ($0.relativePath, $0.reason) }
    )
    checkEqual(reasons["/etc/passwd"], SyncFetchFailureReason.invalidPath, "绝对路径 → invalidPath（越界拒读）")
    checkEqual(reasons["../escape.flac"], SyncFetchFailureReason.invalidPath, "`..` → invalidPath（越界拒读）")
    checkEqual(reasons["escape.flac"], SyncFetchFailureReason.outOfRoot, "软链逃逸 → outOfRoot（越界拒读）")
    checkEqual(reasons["Album/missing.flac"], SyncFetchFailureReason.notFound, "不存在 → notFound")
    let downloaded = macIncoming.appendingPathComponent("01 Song.flac")
    checkEqual(try SyncFileChecksum.sha256Hex(ofFile: downloaded), songHash, "回推内容 SHA-256 与源一致")
    checkEqual(macReceived.count, 1, "Mac 侧收到 1 个文件")

    check(!FileManager.default.fileExists(atPath: deviceRoot.appendingPathComponent("Imported/device-only.flac").path) == false, "本端文件未被应答流程改动")
    host.detach()
    _ = sink
} catch {
    check(false, "⑯ 抛错：\(error)")
}

// MARK: - ⑰ 端到端：Mac 推送 → 本端接收落库

section("⑰ 端到端：Mac 推送 → 本端接收落位 + 入库（不传播删除）")
do {
    let deviceRoot = try tempRoot("push-device")
    let keepMe = silentData(0x81, count: 2_048)
    let replacedOld = silentData(0x82, count: 2_048)
    try writeFile("Imported/device-only.flac", in: deviceRoot, data: keepMe)
    try writeFile("Album/tobe-updated.flac", in: deviceRoot, data: replacedOld)

    let macRoot = try tempRoot("push-mac")
    let newSong = silentData(0x83, count: 300_000)
    let newURL = try writeFile("Pushed/new.flac", in: macRoot, data: newSong)
    let newHash = try SyncFileChecksum.sha256Hex(ofFile: newURL)
    let updatedSong = silentData(0x84, count: 3_000)
    let updatedURL = try writeFile("Album/tobe-updated.flac", in: macRoot, data: updatedSong)
    let updatedHash = try SyncFileChecksum.sha256Hex(ofFile: updatedURL)

    let newEntry = SyncPushEntry(
        relativePath: "Pushed/new.flac", transferName: "new.flac", fileID: newHash, sha256Hex: newHash,
        size: Int64(newSong.count)
    )
    let updateEntry = SyncPushEntry(
        relativePath: "Album/tobe-updated.flac", transferName: "tobe-updated.flac", fileID: updatedHash,
        sha256Hex: updatedHash, size: Int64(updatedSong.count)
    )

    let fixture = SessionFixture.pairedHandshake()
    let sink = SinkSpy()
    let host = SyncLibraryPassiveHost(libraryRoot: deviceRoot, sink: sink, database: DatabaseManager())
    check(host.attach(to: fixture.clientSession), "被动端接线成功")

    let sender = SyncFileSender(session: fixture.hostSession)
    var sendOutcomes: [SyncFileSender.Outcome] = []
    sender.onCompletion = { sendOutcomes.append($0) }

    // 声明 → 串行推送两个文件（新歌 + 同路径更新）
    try fixture.hostSession.sendApplicationFrame(
        type: .libraryPushAnnounce,
        payload: try SyncPushCodec.encode(SyncLibraryPushAnnounce(entries: [newEntry, updateEntry]))
    )
    try sender.send(fileURL: newURL, fileID: newHash, name: newEntry.transferName)
    try sender.send(fileURL: updatedURL, fileID: updatedHash, name: updateEntry.transferName)

    let pushedLanded = deviceRoot.appendingPathComponent("Pushed/new.flac")
    check(FileManager.default.fileExists(atPath: pushedLanded.path), "推送的新歌已落位")
    checkEqual(try SyncFileChecksum.sha256Hex(ofFile: pushedLanded), newHash, "落位内容 SHA-256 一致")
    checkEqual(
        try SyncFileChecksum.sha256Hex(ofFile: deviceRoot.appendingPathComponent("Album/tobe-updated.flac")),
        updatedHash,
        "同路径文件就地替换为新内容（内容不同则更新）"
    )
    check(
        FileManager.default.fileExists(atPath: deviceRoot.appendingPathComponent("Imported/device-only.flac").path),
        "对端未声明的本端文件保留（不传播删除）"
    )
    checkEqual(
        sink.indexed.sorted(),
        [pushedLanded.path, deviceRoot.appendingPathComponent("Album/tobe-updated.flac").path].sorted(),
        "落位文件均走既有入库入口"
    )
    checkEqual(sendOutcomes.count, 2, "两次推送均完成")
    let summary = host.summary
    checkEqual(summary.landed.sorted(), ["Album/tobe-updated.flac", "Pushed/new.flac"], "账目 landed")
    checkEqual(summary.undeclaredTransfers, [], "无未声明传输")
    checkEqual(summary.failed, [], "无失败")
    checkEqual(summary.announcedEntries, 2, "本批声明条目数")
    checkEqual(summary.accountedEntries, 2, "本批已处理条目数")
    check(summary.batchCompleted, "本批已收尾")

    // 未声明的传输：不落位、不索引、临时文件清理
    let strayURL = try writeFile("Stray/orphan.flac", in: macRoot, data: silentData(0x85, count: 1_000))
    let strayHash = try SyncFileChecksum.sha256Hex(ofFile: strayURL)
    try fixture.hostSession.sendApplicationFrame(
        type: .libraryPushAnnounce,
        payload: try SyncPushCodec.encode(SyncLibraryPushAnnounce(entries: []))
    )
    try sender.send(fileURL: strayURL, fileID: strayHash, name: "orphan.flac")
    check(
        !FileManager.default.fileExists(atPath: deviceRoot.appendingPathComponent("Stray/orphan.flac").path),
        "未声明的传输不落位"
    )
    checkEqual(host.summary.undeclaredTransfers, ["orphan.flac"], "未声明传输记账")
    checkEqual(sink.indexed.count, 2, "未声明传输不进入库入口")
    let incomingLeftovers = (
        try? FileManager.default.contentsOfDirectory(
            atPath: deviceRoot.appendingPathComponent(".sync-incoming").path
        )
    ) ?? []
    checkEqual(incomingLeftovers, [], "落地目录无残渣")
    host.detach()
} catch {
    check(false, "⑰ 抛错：\(error)")
}

// MARK: - ⑱ 端到端：推送歌词（随歌安装 / 无歌丢弃）

section("⑱ 端到端：推送 aligned 歌词 → 随歌安装；本端无歌 → 丢弃不写孤儿")
do {
    let song = silentData(0x91, count: 4_096)
    let songHash = try sha256Hex(of: song)
    let deviceRoot = try tempRoot("lyrics-device")
    let deviceLyrics = AlignedLyricsStore(directory: try tempRoot("lyrics-device-store"))
    var fixtureMap = LyricsFixture()
    fixtureMap.songHashByStableId = ["device-sid": songHash]
    let deviceMapping = mapping(of: fixtureMap)

    let macRoot = try tempRoot("lyrics-mac")
    let lyricsURL = try writeFile(
        "@lyrics-src.json",
        in: macRoot,
        data: try JSONEncoder().encode(sampleLyrics("推送过来的对齐歌词"))
    )
    let lyricsFileHash = try SyncFileChecksum.sha256Hex(ofFile: lyricsURL)
    let lyricsEntry = SyncPushEntry(
        relativePath: "@lyrics/\(songHash).json",
        transferName: "\(songHash).json",
        fileID: songHash,
        sha256Hex: lyricsFileHash,
        size: 0
    )
    let orphanEntry = SyncPushEntry(
        relativePath: "@lyrics/\(String(repeating: "f", count: 64)).json",
        transferName: "\(String(repeating: "f", count: 64)).json",
        fileID: String(repeating: "f", count: 64),
        sha256Hex: lyricsFileHash,
        size: 0
    )

    let fixture = SessionFixture.pairedHandshake()
    let sink = SinkSpy()
    let host = SyncLibraryPassiveHost(
        libraryRoot: deviceRoot,
        sink: sink,
        database: DatabaseManager(),
        lyricsStore: deviceLyrics,
        lyricsMapping: deviceMapping
    )
    check(host.attach(to: fixture.clientSession), "被动端接线成功")
    let sender = SyncFileSender(session: fixture.hostSession)

    try fixture.hostSession.sendApplicationFrame(
        type: .libraryPushAnnounce,
        payload: try SyncPushCodec.encode(SyncLibraryPushAnnounce(entries: [lyricsEntry, orphanEntry]))
    )
    try sender.send(fileURL: lyricsURL, fileID: songHash, name: lyricsEntry.transferName)
    try sender.send(fileURL: lyricsURL, fileID: orphanEntry.fileID, name: orphanEntry.transferName)

    checkEqual(
        try deviceLyrics.read(forStableId: "device-sid")?.plainLyrics,
        "推送过来的对齐歌词",
        "歌词按歌曲 content_hash 映射落到本端 stableId"
    )
    checkEqual(sink.indexed, [], "歌词不走曲库入库入口")
    checkEqual(host.summary.discardedLyrics, [orphanEntry.relativePath], "本端无对应歌曲的歌词丢弃并记账")
    checkEqual(deviceLyrics.stableIds(), ["device-sid"], "不写孤儿歌词（库内只有映射到的条目）")
    checkEqual(
        (try? FileManager.default.contentsOfDirectory(
            atPath: deviceRoot.appendingPathComponent(".sync-incoming").path
        )) ?? [],
        [],
        "落地目录无残渣"
    )
    host.detach()
} catch {
    check(false, "⑱ 抛错：\(error)")
}

// MARK: - ⑲ 被动端：曲库根不存在 → 不接线

section("⑲ 被动端：曲库根不存在 → 不接线（绝不回空 manifest）")
do {
    let missingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("qqp-missing-\(UUID().uuidString)", isDirectory: true)
    let fixture = SessionFixture.pairedHandshake()
    let host = SyncLibraryPassiveHost(libraryRoot: missingRoot, sink: SinkSpy(), database: DatabaseManager())
    check(!host.attach(to: fixture.clientSession), "曲库根不存在 → 不接线")
    check(!host.isAttached, "接线态为 false")

    let macPeer = SyncManifestPeer(session: fixture.hostSession)
    var manifestResponse: SyncManifestResponse?
    var unavailable = false
    macPeer.onManifestReceived = { manifestResponse = $0 }
    macPeer.onProviderUnavailable = { unavailable = true }
    try macPeer.requestManifest()
    checkEqual(manifestResponse?.entries.count ?? -1, -1, "未接线 → 不应答 manifest（不回空表）")
    _ = unavailable
} catch {
    check(false, "⑲ 抛错：\(error)")
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
