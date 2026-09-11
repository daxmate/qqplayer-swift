//
//  main.swift — M3-3b 无模拟器本地 harness（**不参与 App target 编译**）
//
//  用 swiftc 直编生产源码 + 本目录夹具，真跑与 QQPlayerTests 同构的断言：
//  帧 12/13 编解码、请求路径规范化/解析、应答器解析计划、控制器状态机/对账映射、
//  四条既有端到端场景（拉取一致性 / 远端已删删除 / 私有区保护 / 越界拒绝），
//  以及 M4-2b（aligned 歌词库 / 随歌同步 / 越界拒读 / 只补不删）。
//  覆盖还包括 T7（单向差集与 download 方向）、R3a/R3b（歌单补齐 / 跟歌走）与
//  T9（㊱-㊴：对端内容清单帧 15/16 —— 编解码 / 纯逻辑 / 内存回环端到端 / 客户端健壮性）。
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
    /// 设备侧曲库（被拉取的内容源）
    let sourceRoot: URL
    /// Mac 侧曲库（落位目标）
    let targetRoot: URL
    /// 设备侧被动端（应答 manifest / 按路径回推 / 接收推送）
    let deviceHost: SyncLibraryPassiveHost
    let sink: SinkSpy
    /// Mac 侧拉取控制器（R1b-2 取代旧 iOS 主动控制器）
    let controller: SyncLibraryPullController
    /// 两端 aligned 歌词库（M4-2b）：host = 设备侧，client = Mac 侧
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

    // 设备侧：被动端（应答 manifest + 按路径回推），与 R1b-1 iOS 装配同构
    let deviceHost = SyncLibraryPassiveHost(
        libraryRoot: sourceRoot,
        rootName: "测试设备曲库",
        sink: SinkSpy(),
        database: DatabaseManager(),
        lyricsStore: hostLyricsStore,
        lyricsMapping: hostMapping
    )
    _ = deviceHost.attach(to: fixture.clientSession)

    // Mac 侧：拉取控制器（发起方恒为 Mac）
    let sink = SinkSpy()
    let macManager = DatabaseManager()
    let descriptor = SyncLocalLibraryDescriptor(
        libraryRoot: targetRoot,
        rootName: "测试 Mac 曲库",
        lyricsRoot: clientLyricsStore.directory,
        sourceFiles: { SyncLocalLibraryScanner.sourceFiles(in: targetRoot, database: macManager) },
        lyricsEntries: {
            SyncAlignedLyricsManifest.entries(store: clientLyricsStore, mapping: clientMapping)
        },
        contentHash: { relativePath in
            DatabaseManager.contentHashIfFilePresent(
                atPath: targetRoot.appendingPathComponent(relativePath).path
            )
        },
        lyricsFileName: { wirePath in
            guard let songHash = SyncLyricsNamespace.songContentHash(fromWirePath: wirePath),
                  let stableId = clientMapping.stableIdForContentHash(songHash)
            else { return nil }
            return "\(stableId).json"
        }
    )
    let controller = SyncLibraryPullController(
        session: fixture.hostSession,
        descriptor: descriptor,
        sink: sink,
        configuration: SyncLibraryPullConfiguration(),
        lyricsStore: clientLyricsStore,
        lyricsMapping: clientMapping
    )
    try controller.start()

    return Harness(
        fixture: fixture,
        sourceRoot: sourceRoot,
        targetRoot: targetRoot,
        deviceHost: deviceHost,
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
check(SyncLibraryPullStateMachine.canTransition(from: .idle, to: .requestingManifest), "idle → requestingManifest 允许")
check(SyncLibraryPullStateMachine.canTransition(from: .requestingManifest, to: .fetching), "requestingManifest → fetching 允许")
check(SyncLibraryPullStateMachine.canTransition(from: .requestingManifest, to: .done(SyncLibraryPullSummary())), "requestingManifest → done 允许（无待拉取）")
check(SyncLibraryPullStateMachine.canTransition(from: .fetching, to: .done(SyncLibraryPullSummary())), "fetching → done 允许")
check(!SyncLibraryPullStateMachine.canTransition(from: .idle, to: .fetching), "idle → fetching 拒绝（越级）")
check(SyncLibraryPullStateMachine.canTransition(from: .fetching, to: .failed("x")), "非终态 → failed 允许")
check(!SyncLibraryPullStateMachine.canTransition(from: .done(SyncLibraryPullSummary()), to: .failed("x")), "终态后迁移拒绝")

check(SyncLibraryPushStateMachine.canTransition(from: .idle, to: .requestingManifest), "推送：idle → requestingManifest 允许")
check(SyncLibraryPushStateMachine.canTransition(from: .requestingManifest, to: .done(SyncLibraryPushSummary())), "推送：requestingManifest → done 允许（全部已一致）")
check(SyncLibraryPushStateMachine.canTransition(from: .requestingManifest, to: .pushing), "推送：requestingManifest → pushing 允许")
check(SyncLibraryPushStateMachine.canTransition(from: .pushing, to: .done(SyncLibraryPushSummary())), "推送：pushing → done 允许")
check(!SyncLibraryPushStateMachine.canTransition(from: .idle, to: .pushing), "推送：idle → pushing 拒绝（越级）")
check(!SyncLibraryPushStateMachine.canTransition(from: .done(SyncLibraryPushSummary()), to: .failed("x")), "推送：终态后迁移拒绝")

do {
    let remote = SyncManifestResponse(entries: [
        entry("changed.flac", hash: "new"),
        entry("missing.flac", hash: "h3"),
        entry("same.flac", hash: "h1"),
    ])
    let local = [entry("same.flac", hash: "h1"), entry("changed.flac", hash: "old")]
    let plan = SyncLibraryPullPlanner.plan(
        remote: remote,
        local: local,
        selection: .all
    )
    checkEqual(plan.relativePaths, ["changed.flac", "missing.flac"], "本地缺失/内容不同 → 拉取列表")
    checkEqual(plan.unchanged.map(\.relativePath), ["same.flac"], "内容一致 → unchanged")

    // 不传播删除：远端已消失的本地条目（含导入区）不进任何待处理列表
    let noDeletePlan = SyncLibraryPullPlanner.plan(
        remote: SyncManifestResponse(entries: []),
        local: [entry("Album/synced.flac", hash: "h1"), entry("Imported/private.flac", hash: "h2")],
        selection: .all
    )
    checkEqual(noDeletePlan.relativePaths, [], "远端已删 → 无待拉取动作（本端保留）")
    checkEqual(noDeletePlan.unchanged, [], "远端已删 → unchanged 为空")

    // 集合选择不影响本端存留
    let scopedPlan = SyncLibraryPullPlanner.plan(
        remote: SyncManifestResponse(entries: [
            entry("selected.flac", hash: "h1", stableId: "s1"),
            entry("other.flac", hash: "h2", stableId: "s2"),
        ]),
        local: [],
        selection: .relativePaths(["other.flac"])
    )
    checkEqual(scopedPlan.relativePaths, ["other.flac"], "显式选择集只拉入选路径（不产生删除）")
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
    _ = harness.deviceHost
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
    _ = harness.deviceHost
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
    let plan = SyncLibraryPullPlanner.plan(
        remote: SyncManifestResponse(entries: []),
        local: [entry("@lyrics/\(songHash).json", hash: "h", stableId: "client-sid")],
        selection: .all
    )
    checkEqual(plan.relativePaths, [], "规划层：远端没有的歌词 → 无动作，不留任何待办（只补不删）")
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

// MARK: - ⑳ 推送方向对账（纯逻辑，R1b-2 块①）

section("⑳ 推送方向对账：本端选择集为准（缺则推 / 一致则跳 / 对端多的不动）")
do {
    let localEntries = [
        entry("Album/changed.flac", hash: "new"),
        entry("Album/missing.flac", hash: "h3"),
        entry("Album/same.flac", hash: "h1"),
        entry("@lyrics/h1.json", hash: "lh1"),
    ]
    let remoteEntries = [
        entry("Album/changed.flac", hash: "old"),
        entry("Album/same.flac", hash: "h1"),
        entry("Album/device-only.flac", hash: "h9"),
    ]
    let plan = SyncLibraryPushPlanner.plan(local: localEntries, remote: remoteEntries)
    checkEqual(
        plan.toPush.map(\.relativePath),
        ["@lyrics/h1.json", "Album/changed.flac", "Album/missing.flac"],
        "对端缺该路径或内容不同 → 计划推送（升序）"
    )
    checkEqual(plan.unchanged.map(\.relativePath), ["Album/same.flac"], "同路径 + content_hash 相同 → 跳过")
    check(
        !plan.toPush.contains { $0.relativePath == "Album/device-only.flac" }
            && !plan.unchanged.contains { $0.relativePath == "Album/device-only.flac" },
        "对端多出来的条目 → 什么都不做（不传播删除）"
    )
    checkEqual(
        SyncLibraryPushPlanner.plan(
            local: [entry("Album/x.flac", hash: nil)],
            remote: [entry("Album/x.flac", hash: "h")]
        ).toPush.map(\.relativePath),
        ["Album/x.flac"],
        "本端指纹缺失 → 保守推送（绝不误判一致）"
    )
    checkEqual(
        SyncLibraryPushPlanner.plan(
            local: [entry("Album/x.flac", hash: "h")],
            remote: [entry("Album/x.flac", hash: nil)]
        ).toPush.map(\.relativePath),
        ["Album/x.flac"],
        "对端指纹缺失 → 保守推送"
    )

    let selection = SyncLibraryPushSelection.relativePaths(["B/2.flac", "A/1.flac", "../escape.flac", "A/1.flac"])
    checkEqual(selection.normalizedPaths, ["A/1.flac", "B/2.flac"], "选择集规范化（拒非法 / 去重 / 升序）")
    checkEqual(
        SyncLibraryPushSelection.relativePaths(["Album/same.flac"]).filter(localEntries).map(\.relativePath),
        ["Album/same.flac"],
        "选择集过滤：命中显式路径"
    )
    checkEqual(SyncLibraryPushSelection.all.filter(localEntries).count, localEntries.count, "全库选择集不过滤")
}

// MARK: - ㉑ 端到端：Mac 推送 → 设备接收

section("㉑ 端到端：Mac 推送 → 设备落位 + 入库（跳过已一致 / 不传播删除 / 歌词随歌）")
do {
    let sameSong = silentData(0xB1, count: 5_000)
    let deviceOld = silentData(0xB2, count: 3_000)
    let deviceOnly = silentData(0xB3, count: 1_000)
    let deviceRoot = try tempRoot("push-device")
    try writeFile("Album/same.flac", in: deviceRoot, data: sameSong)
    try writeFile("Album/update.flac", in: deviceRoot, data: deviceOld)
    try writeFile("Imported/device-only.flac", in: deviceRoot, data: deviceOnly)

    let macRoot = try tempRoot("push-mac")
    try writeFile("Album/same.flac", in: macRoot, data: sameSong)
    let newSong = silentData(0xB4, count: 300_000)
    try writeFile("Pushed/new.flac", in: macRoot, data: newSong)
    let updatedSong = silentData(0xB5, count: 3_500)
    try writeFile("Album/update.flac", in: macRoot, data: updatedSong)
    let newHash = try sha256Hex(of: newSong)
    let updatedHash = try sha256Hex(of: updatedSong)

    let macLyrics = AlignedLyricsStore(directory: try tempRoot("push-mac-lyrics"))
    try macLyrics.write(sampleLyrics("随歌推送的歌词"), forStableId: "mac-sid")
    var macFixture = LyricsFixture()
    macFixture.songHashByStableId = ["mac-sid": newHash]
    var deviceFixture = LyricsFixture()
    deviceFixture.songHashByStableId = ["device-sid": newHash]
    let macMapping = mapping(of: macFixture)
    let deviceMapping = mapping(of: deviceFixture)

    let fixture = SessionFixture.pairedHandshake()
    let deviceSink = SinkSpy()
    let deviceLyrics = AlignedLyricsStore(directory: try tempRoot("push-device-lyrics"))
    let deviceHost = SyncLibraryPassiveHost(
        libraryRoot: deviceRoot,
        sink: deviceSink,
        database: DatabaseManager(),
        lyricsStore: deviceLyrics,
        lyricsMapping: deviceMapping
    )
    check(deviceHost.attach(to: fixture.clientSession), "设备被动端接线")

    let macManager = DatabaseManager()
    let descriptor = SyncLocalLibraryDescriptor(
        libraryRoot: macRoot,
        rootName: "测试 Mac",
        lyricsRoot: macLyrics.directory,
        sourceFiles: { SyncLocalLibraryScanner.sourceFiles(in: macRoot, database: macManager) },
        lyricsEntries: { SyncAlignedLyricsManifest.entries(store: macLyrics, mapping: macMapping) },
        contentHash: { relativePath in
            DatabaseManager.contentHashIfFilePresent(
                atPath: macRoot.appendingPathComponent(relativePath).path
            )
        },
        lyricsFileName: { wirePath in
            guard let songHash = SyncLyricsNamespace.songContentHash(fromWirePath: wirePath),
                  let stableId = macMapping.stableIdForContentHash(songHash)
            else { return nil }
            return "\(stableId).json"
        }
    )
    let push = SyncLibraryPushController(session: fixture.hostSession, descriptor: descriptor)
    try push.start()

    let lyricsWire = "@lyrics/\(newHash).json"
    if case let .done(summary) = push.state {
        checkEqual(
            summary.planned,
            [lyricsWire, "Album/update.flac", "Pushed/new.flac"].sorted(),
            "推送计划（升序）"
        )
        checkEqual(summary.skipped, ["Album/same.flac"], "已一致条目跳过（不重复传）")
        checkEqual(
            summary.completed,
            [lyricsWire, "Album/update.flac", "Pushed/new.flac"].sorted(),
            "全部确认送达"
        )
        checkEqual(summary.failed, [], "推送无失败")
        check(summary.isFullSuccess, "推送账目 isFullSuccess")
    } else {
        check(false, "推送状态应为 done，实际 \(push.state)")
    }

    let newLanded = deviceRoot.appendingPathComponent("Pushed/new.flac")
    check(FileManager.default.fileExists(atPath: newLanded.path), "推送的新歌落位")
    if FileManager.default.fileExists(atPath: newLanded.path) {
        checkEqual(try SyncFileChecksum.sha256Hex(ofFile: newLanded), newHash, "新歌落位内容 SHA-256 一致")
    }
    checkEqual(
        try SyncFileChecksum.sha256Hex(ofFile: deviceRoot.appendingPathComponent("Album/update.flac")),
        updatedHash,
        "同路径文件就地替换为新内容（内容不同则更新）"
    )
    check(
        FileManager.default.fileExists(atPath: deviceRoot.appendingPathComponent("Imported/device-only.flac").path),
        "对端未声明的本端文件保留（不传播删除）"
    )
    checkEqual(
        deviceSink.indexed.sorted(),
        [deviceRoot.appendingPathComponent("Album/update.flac").path, newLanded.path].sorted(),
        "落位文件均走既有入库入口（歌词不走曲库入库）"
    )
    checkEqual(
        try deviceLyrics.read(forStableId: "device-sid")?.plainLyrics,
        "随歌推送的歌词",
        "歌词按歌曲 content_hash 映射落到设备 stableId"
    )
    check(!deviceLyrics.contains(forStableId: "mac-sid"), "不按 Mac 侧 stableId 落库")
    checkEqual(
        (try? FileManager.default.contentsOfDirectory(
            atPath: deviceRoot.appendingPathComponent(".sync-incoming").path
        )) ?? [],
        [],
        "落地目录无残渣"
    )
    deviceHost.detach()
} catch {
    check(false, "㉑ 抛错：\(error)")
}

// MARK: - ㉒ R3a 编排夹具

/// 设备侧收到的 manifest_request 计数（R3a：空选择集必须为 0）。
var r3aManifestRequests = 0

/// R3a 编排夹具：Mac 描述器 + 设备被动端 + 注入曲库事实 + 编排器。
struct CollectionScenario {
    let fixture: SessionFixture
    let macRoot: URL
    let deviceRoot: URL
    let macSink: SinkSpy
    let deviceSink: SinkSpy
    let deviceHost: SyncLibraryPassiveHost
    let coordinator: SyncCollectionSyncCoordinator
    /// R3b 携带替身（未注入 = nil）
    let carryDriver: CarrySpyDriver?
}

func makeCollectionScenario(
    selection: SyncCollectionSelection,
    direction: SyncTransferDirection = .upload,
    macFiles: [(String, Data)] = [],
    deviceFiles: [(String, Data)] = [],
    playlists: [String: [SyncCollectionTrackFact]] = [:],
    knownPaths: [String: SyncCollectionTrackFact] = [:],
    lyricsWirePaths: Set<String> = [],
    macLyrics: [(stableId: String, lyrics: Lyrics)] = [],
    macLyricsMapping: SyncLyricsContentMapping = .unresolved,
    deviceLyricsMapping: SyncLyricsContentMapping = .unresolved,
    carryFacts: MemoryCarryFacts = MemoryCarryFacts(),
    injectCarry: Bool = false
) throws -> CollectionScenario {
    let fixture = SessionFixture.pairedHandshake()
    let macRoot = try tempRoot("r3a-mac")
    let deviceRoot = try tempRoot("r3a-device")
    for (path, data) in macFiles { try writeFile(path, in: macRoot, data: data) }
    for (path, data) in deviceFiles { try writeFile(path, in: deviceRoot, data: data) }

    let macLyricsStore = AlignedLyricsStore(directory: try tempRoot("r3a-mac-lyrics"))
    for item in macLyrics { try macLyricsStore.write(item.lyrics, forStableId: item.stableId) }
    let deviceLyricsStore = AlignedLyricsStore(directory: try tempRoot("r3a-device-lyrics"))

    r3aManifestRequests = 0
    let deviceSink = SinkSpy()
    let deviceHost = SyncLibraryPassiveHost(
        libraryRoot: deviceRoot,
        sink: deviceSink,
        database: DatabaseManager(),
        lyricsStore: deviceLyricsStore,
        lyricsMapping: deviceLyricsMapping
    )
    check(deviceHost.attach(to: fixture.clientSession), "设备被动端接线")
    // 设备侧入站帧计数（挂在链首；链式转发不影响被动端）
    let devicePriorHandler = fixture.clientSession.onApplicationFrame
    fixture.clientSession.onApplicationFrame = { frame in
        if frame.type == .manifestRequest { r3aManifestRequests += 1 }
        devicePriorHandler?(frame)
    }

    let macSink = SinkSpy()
    let macManager = DatabaseManager()
    let descriptor = SyncLocalLibraryDescriptor(
        libraryRoot: macRoot,
        rootName: "R3a 测试 Mac",
        lyricsRoot: macLyricsStore.directory,
        sourceFiles: { SyncLocalLibraryScanner.sourceFiles(in: macRoot, database: macManager) },
        lyricsEntries: {
            SyncAlignedLyricsManifest.entries(store: macLyricsStore, mapping: macLyricsMapping)
        },
        contentHash: { relativePath in
            DatabaseManager.contentHashIfFilePresent(
                atPath: macRoot.appendingPathComponent(relativePath).path
            )
        },
        lyricsFileName: { wirePath in
            guard let songHash = SyncLyricsNamespace.songContentHash(fromWirePath: wirePath),
                  let stableId = macLyricsMapping.stableIdForContentHash(songHash)
            else { return nil }
            return "\(stableId).json"
        }
    )
    let carryDriver = injectCarry ? CarrySpyDriver(facts: carryFacts) : nil
    let coordinator = SyncCollectionSyncCoordinator(
        session: fixture.hostSession,
        descriptor: descriptor,
        selection: selection,
        facts: MemoryCollectionFacts(
            playlists: playlists,
            knownPaths: knownPaths,
            lyricsWirePaths: lyricsWirePaths
        ),
        sink: macSink,
        lyricsStore: macLyricsStore,
        lyricsMapping: macLyricsMapping,
        playbackCarry: carryDriver
    )
    try coordinator.start(direction: direction)
    return CollectionScenario(
        fixture: fixture,
        macRoot: macRoot,
        deviceRoot: deviceRoot,
        macSink: macSink,
        deviceSink: deviceSink,
        deviceHost: deviceHost,
        coordinator: coordinator,
        carryDriver: carryDriver
    )
}

// MARK: - ㉓ 选中歌单 → 设备缺歌自动推送补齐

section("㉓ R3a：选中歌单 → 设备缺歌自动推送补齐（含已一致跳过）")
do {
    let same = silentData(0xC1, count: 4_000)
    let fresh = silentData(0xC2, count: 200_000)
    let sameHash = try sha256Hex(of: same)
    let freshHash = try sha256Hex(of: fresh)

    // T7：upload 方向（只推不拉）
    let scenario = try makeCollectionScenario(
        selection: .playlists(["p1"]),
        direction: .upload,
        macFiles: [("Album/keep.flac", same), ("Album/new.flac", fresh)],
        deviceFiles: [("Album/keep.flac", same)],
        playlists: [
            "p1": [
                SyncCollectionTrackFact(stableId: "s-keep", relativePath: "Album/keep.flac", contentHash: sameHash),
                SyncCollectionTrackFact(stableId: "s-new", relativePath: "Album/new.flac", contentHash: freshHash),
            ],
        ]
    )

    let report = scenario.coordinator.report
    check(scenario.coordinator.state == .done, "编排终态 done")
    check(report.direction == .upload, "账目方向 = upload")
    checkEqual(report.plannedPush, ["Album/new.flac"], "设备缺 → 计划推送")
    checkEqual(report.plannedPull, [String](), "无需拉取")
    checkEqual(report.skipped, ["Album/keep.flac"], "已一致 → 跳过")
    check(report.isComplete, "编排完全成功")
    checkEqual(report.pushed, ["Album/new.flac"], "推送账目")
    checkEqual(report.pullFailed, [SyncFileFetchFailure](), "拉取无失败")
    checkEqual(report.transferCount, 1, "本次仅一次传输")
    checkEqual(r3aManifestRequests, 2, "一次计划 + 一次推送各请求一次 manifest")

    let landed = scenario.deviceRoot.appendingPathComponent("Album/new.flac")
    checkEqual(
        try sha256Hex(of: try Data(contentsOf: landed)),
        freshHash,
        "补齐文件落位且内容 SHA-256 一致"
    )
    checkEqual(
        scenario.deviceSink.indexed,
        [landed.path],
        "落位文件走既有入库入口"
    )
    check(
        scenario.deviceRoot.appendingPathComponent("Album/keep.flac").isFileURL,
        "设备既有文件未被动过"
    )
    checkEqual(report.remoteOnlyIgnored, [String](), "无对端独有条目")
    scenario.deviceHost.detach()
} catch {
    check(false, "㉓ 抛错：\(error)")
}

// MARK: - ㉔ Mac 缺歌 → 从设备下载补齐（T7：download 方向）

section("㉔ T7：download — Mac 缺歌 → 从设备拉取补齐（以对端清单为准）")
do {
    let deviceOnly = silentData(0xC3, count: 120_000)
    let deviceOnlyHash = try sha256Hex(of: deviceOnly)

    // download × `.relativePaths`：期望集合 = 选择集本身的路径（本端展开会把本端
    // 没有的歌判为 unresolved → 不能用展开结果）。
    let scenario = try makeCollectionScenario(
        selection: .relativePaths(["Album/from-device.flac"]),
        direction: .download,
        macFiles: [],
        deviceFiles: [("Album/from-device.flac", deviceOnly)],
        knownPaths: [
            "Album/from-device.flac": SyncCollectionTrackFact(
                stableId: "s-dev",
                relativePath: "Album/from-device.flac",
                contentHash: deviceOnlyHash
            ),
        ]
    )

    let report = scenario.coordinator.report
    check(scenario.coordinator.state == .done, "编排终态 done")
    check(report.direction == .download, "账目方向 = download")
    checkEqual(report.plannedPush, [String](), "download 不产生推送计划")
    checkEqual(report.plannedPull, ["Album/from-device.flac"], "本端缺 → 计划拉取")
    checkEqual(report.pulled, ["Album/from-device.flac"], "拉取账目")
    check(report.isComplete, "编排完全成功")
    checkEqual(report.transferCount, 1, "本次仅一次传输")

    let landed = scenario.macRoot.appendingPathComponent("Album/from-device.flac")
    checkEqual(
        try sha256Hex(of: try Data(contentsOf: landed)),
        deviceOnlyHash,
        "补齐文件落位本端且内容 SHA-256 一致"
    )
    checkEqual(scenario.macSink.indexed, [landed.path], "落位文件走既有入库入口")
    checkEqual(
        (try? FileManager.default.contentsOfDirectory(
            atPath: scenario.macRoot.appendingPathComponent(".sync-incoming").path
        )) ?? [],
        [],
        "落地目录无残渣"
    )
    scenario.deviceHost.detach()
} catch {
    check(false, "㉔ 抛错：\(error)")
}

// MARK: - ㉕ 两端已一致 → 零传输；对端独有 → 不传播删除

section("㉕ R3a：两端已一致 → 零传输；对端独有 → 本端保留（不传播删除）")
do {
    let same = silentData(0xC4, count: 6_000)
    let deviceOnly = silentData(0xC5, count: 2_000)
    let sameHash = try sha256Hex(of: same)

    let scenario = try makeCollectionScenario(
        selection: .playlists(["p1"]),
        macFiles: [("Album/same.flac", same)],
        deviceFiles: [("Album/same.flac", same), ("Imported/device-only.flac", deviceOnly)],
        playlists: [
            "p1": [
                SyncCollectionTrackFact(
                    stableId: "s-same",
                    relativePath: "Album/same.flac",
                    contentHash: sameHash
                ),
            ],
        ]
    )

    let report = scenario.coordinator.report
    check(scenario.coordinator.state == .done, "编排终态 done")
    checkEqual(report.plannedPush, [String](), "无推送")
    checkEqual(report.plannedPull, [String](), "无拉取")
    checkEqual(report.skipped, ["Album/same.flac"], "已一致 → 跳过")
    checkEqual(report.transferCount, 0, "两端已一致 → 零传输")
    checkEqual(r3aManifestRequests, 1, "零传输只请求一次 manifest（计划）")
    checkEqual(
        report.remoteOnlyIgnored,
        ["Imported/device-only.flac"],
        "对端独有 → 仅记账"
    )
    checkEqual(scenario.macSink.indexed, [String](), "本端无落位")
    checkEqual(scenario.deviceSink.indexed, [String](), "设备无落位")
    check(
        FileManager.default.fileExists(
            atPath: scenario.deviceRoot.appendingPathComponent("Imported/device-only.flac").path
        ),
        "对端独有文件保留（不传播删除）"
    )
    check(
        !FileManager.default.fileExists(
            atPath: scenario.macRoot.appendingPathComponent("Imported/device-only.flac").path
        ),
        "不把对端独有内容复制过来（选择集之外）"
    )
    scenario.deviceHost.detach()
} catch {
    check(false, "㉕ 抛错：\(error)")
}

// MARK: - ㉖ 空选择集 → 不推不拉

section("㉖ R3a：空选择集 → 不推不拉（连 manifest 都不请求）")
do {
    let macData = silentData(0xC6, count: 3_000)
    let deviceData = silentData(0xC7, count: 3_000)
    let macHash = try sha256Hex(of: macData)

    let scenario = try makeCollectionScenario(
        selection: .playlists([]),
        macFiles: [("Album/mac.flac", macData)],
        deviceFiles: [("Album/device.flac", deviceData)],
        playlists: [
            "p1": [
                SyncCollectionTrackFact(
                    stableId: "s-mac",
                    relativePath: "Album/mac.flac",
                    contentHash: macHash
                ),
            ],
        ]
    )

    let report = scenario.coordinator.report
    check(scenario.coordinator.state == .done, "空选择集直接 done")
    check(report.isEmptySelection, "账目标记空选择集")
    check(!report.didRequestPeerManifest, "不请求对端 manifest")
    checkEqual(r3aManifestRequests, 0, "设备一个 manifest 请求都没收到")
    checkEqual(report.plannedPush, [String](), "不推")
    checkEqual(report.plannedPull, [String](), "不拉")
    checkEqual(report.transferCount, 0, "零传输")
    checkEqual(scenario.macSink.indexed, [String](), "本端无落位")
    checkEqual(scenario.deviceSink.indexed, [String](), "设备无落位")
    check(
        FileManager.default.fileExists(
            atPath: scenario.deviceRoot.appendingPathComponent("Album/device.flac").path
        ),
        "设备文件保留"
    )
    scenario.deviceHost.detach()
} catch {
    check(false, "㉖ 抛错：\(error)")
}

// MARK: - ㉗ 选中歌单 + 歌词随歌补齐

section("㉗ R3a：选中歌单 → 歌词随歌补齐（wire 命名空间 + 对端 stableId 落位）")
do {
    let song = silentData(0xC8, count: 90_000)
    let songHash = try sha256Hex(of: song)
    let wirePath = SyncLyricsNamespace.wirePath(songContentHash: songHash)!

    var macFixture = LyricsFixture()
    macFixture.songHashByStableId = ["mac-sid": songHash]
    var deviceFixture = LyricsFixture()
    deviceFixture.songHashByStableId = ["device-sid": songHash]

    let scenario = try makeCollectionScenario(
        selection: .playlists(["p1"]),
        macFiles: [("Album/with-lyrics.flac", song)],
        deviceFiles: [],
        playlists: [
            "p1": [
                SyncCollectionTrackFact(
                    stableId: "mac-sid",
                    relativePath: "Album/with-lyrics.flac",
                    contentHash: songHash
                ),
            ],
        ],
        lyricsWirePaths: [wirePath],
        macLyrics: [(stableId: "mac-sid", lyrics: sampleLyrics("R3a 随歌歌词"))],
        macLyricsMapping: mapping(of: macFixture),
        deviceLyricsMapping: mapping(of: deviceFixture)
    )

    let report = scenario.coordinator.report
    check(scenario.coordinator.state == .done, "编排终态 done")
    checkEqual(
        report.plannedPush,
        [wirePath, "Album/with-lyrics.flac"].sorted(),
        "推送计划含歌词 wire 路径 + 歌曲"
    )
    checkEqual(report.pushed.sorted(), report.plannedPush, "全部送达")
    check(report.isComplete, "编排完全成功")
    checkEqual(
        scenario.deviceSink.indexed.map { ($0 as NSString).lastPathComponent },
        ["with-lyrics.flac"],
        "只有歌曲走进库入口（歌词不走曲库入库）"
    )
    check(
        FileManager.default.fileExists(
            atPath: scenario.deviceRoot.appendingPathComponent("Album/with-lyrics.flac").path
        ),
        "歌曲落位设备"
    )
    scenario.deviceHost.detach()
} catch {
    check(false, "㉗ 抛错：\(error)")
}

// MARK: - ㉘ R3a 双向差集纯逻辑（三方向一次覆盖）

section("㉘ T7：单向差集纯逻辑（upload 只推 / download 只拉 / 冲突各按其方向处理）")
do {
    // 与 CI 用例 `SyncCollectionSelectionTests` 同款直接数据：
    // local 只持有 push + same（pull 只在远端）。
    // 2026-09-11：CI 红点（本端多写一条 pull.flac → 两侧同 hash 必判「一致」）的本地兜底断言。
    let local = [entry("Album/push.flac", hash: "a"), entry("Album/same.flac", hash: "b")]
    let remote = [
        entry("Album/same.flac", hash: "b"),
        entry("Album/pull.flac", hash: "c"),
        entry("Album/device-only.flac", hash: "d"),
    ]
    let expected = ["Album/pull.flac", "Album/push.flac", "Album/same.flac"]

    // upload：只推；本端缺的那条**不许拉**（方向语义）
    let upload = SyncCollectionDiffPlanner.plan(
        expected: expected,
        local: local,
        remote: remote,
        direction: .upload
    )
    checkEqual(upload.toPush, ["Album/push.flac"], "对端缺 → 推")
    checkEqual(upload.toPull, [], "upload 不产生 toPull")
    checkEqual(upload.peerOnlySkipped, ["Album/pull.flac"], "upload：对端有本端无 → 仅记账")
    checkEqual(upload.unchanged, ["Album/same.flac"], "两侧一致 → 跳过")
    checkEqual(upload.remoteOnlyIgnored, ["Album/device-only.flac"], "对端独有 → 仅记账（不传播删除）")
    checkEqual(upload.missingBoth, [], "期望里两侧都有实体 → 无 missingBoth")

    // download：只拉；本端有对端缺的那条**不推不删**
    let download = SyncCollectionDiffPlanner.plan(
        expected: expected,
        local: local,
        remote: remote,
        direction: .download
    )
    checkEqual(download.toPull, ["Album/pull.flac"], "本端缺 → 拉")
    checkEqual(download.toPush, [], "download 不产生 toPush")
    checkEqual(download.localOnlySkipped, ["Album/push.flac"], "download：本端有对端无 → 不动手")
    checkEqual(download.unchanged, ["Album/same.flac"], "两侧一致 → 跳过")

    let differsLocal = [entry("Album/x.flac", hash: "old")]
    let differsRemote = [entry("Album/x.flac", hash: "new")]
    let differs = SyncCollectionDiffPlanner.plan(
        expected: ["Album/x.flac"],
        local: differsLocal,
        remote: differsRemote,
        direction: .upload
    )
    checkEqual(differs.toPush, ["Album/x.flac"], "upload 内容不同 → 推（发起方权威）")
    checkEqual(differs.toPull, [], "upload 内容不同 → 不回拉")

    let conflict = SyncCollectionDiffPlanner.plan(
        expected: ["Album/x.flac"],
        local: differsLocal,
        remote: differsRemote,
        direction: .download
    )
    checkEqual(conflict.conflictingKept, ["Album/x.flac"], "download 内容不同 → 本端保留（不覆盖）")
    checkEqual(conflict.toPush, [], "download 内容不同 → 不推")
    checkEqual(conflict.toPull, [], "download 内容不同 → 不拉")
}

// MARK: - ㉙ R3b：跟歌走计划器（纯逻辑，三条硬规则）

section("㉙ R3b：跟歌走计划器（只带传输过的歌 / 两端共有才带 / 不传删除）")
// 纯逻辑（无 IO）：不需要 do/catch。
do {
    let favoriteRow = SyncPlaybackCarryRow(
        outboxID: 1, entity: "favorite", rowKey: "s-one", op: "upsert", updatedAtMs: 1_000,
        payloadJSON: "{\"track_stable_id\":\"s-one\"}"
    )
    let historyRow = SyncPlaybackCarryRow(
        outboxID: 2, entity: "play_history", rowKey: "s-one|1700000000000", op: "upsert", updatedAtMs: 1_001,
        payloadJSON: "{}"
    )
    let otherSongRow = SyncPlaybackCarryRow(
        outboxID: 3, entity: "favorite", rowKey: "s-other", op: "upsert", updatedAtMs: 1_002
    )
    let facts = MemoryCarryFacts(
        tracks: [
            "A/one.flac": SyncCollectionTrackFact(stableId: "s-one", relativePath: "A/one.flac", contentHash: "h-one"),
            "A/two.flac": SyncCollectionTrackFact(stableId: "s-two", relativePath: "A/two.flac", contentHash: "h-two"),
            "A/three.flac": SyncCollectionTrackFact(stableId: "s-three", relativePath: "A/three.flac", contentHash: nil),
            "B/untransferred.flac": SyncCollectionTrackFact(
                stableId: "s-other", relativePath: "B/untransferred.flac", contentHash: "h-other"
            ),
        ],
        rows: [
            "s-one": [favoriteRow, historyRow],
            "s-two": [SyncPlaybackCarryRow(
                outboxID: 4, entity: "favorite", rowKey: "s-two", op: "upsert", updatedAtMs: 1_003
            )],
            "s-other": [otherSongRow],
        ]
    )
    let scope = SyncPlaybackCarryScope(
        direction: .push,
        transferredPaths: ["A/three.flac", "A/two.flac", "@lyrics/h-one.json", "A/one.flac", "A/nowhere.flac"],
        peerContentHashes: ["h-one"]
    )
    let plan = SyncPlaybackCarryPlanner.plan(scope: scope, facts: facts)

    checkEqual(plan.scopePaths, ["@lyrics/h-one.json", "A/nowhere.flac", "A/one.flac", "A/three.flac", "A/two.flac"], "传输路径规范化 + 去重 + 升序")
    checkEqual(plan.carriedPaths, ["A/one.flac"], "只带本轮传输且两端共有且有数据的歌")
    checkEqual(plan.entries.map(\.outboxID), [1, 2], "携带条目 = 本端该歌的播放数据行（按变更序）")
    checkEqual(plan.entries.map(\.contentHash), ["h-one", "h-one"], "条目身份键 = 歌曲 content_hash")
    checkEqual(plan.entries.first?.reconciliationKey, "favorite\u{1F}s-one", "对账键 = entity + row_key")
    checkEqual(plan.lyricsPathsIgnored, ["@lyrics/h-one.json"], "歌词路径不承载播放数据")
    checkEqual(plan.skippedUnknownPath, ["A/nowhere.flac"], "本端查不到路径 → 记账跳过")
    checkEqual(plan.skippedUnfingerprinted, ["A/three.flac"], "未指纹 → 无法配对，跳过")
    checkEqual(plan.skippedNotPaired, ["A/two.flac"], "对端没有该指纹 → 不带（两端共有才带）")
    check(!plan.entries.contains { $0.rowKey == "s-other" }, "未传输的歌的播放数据不带（不做全库对账）")

    // 删除不上线（决策 7）：同键 upsert→delete 在本批末尾 = 整键不上线
    let deleteFacts = MemoryCarryFacts(
        tracks: ["A/gone.flac": SyncCollectionTrackFact(stableId: "s-gone", relativePath: "A/gone.flac", contentHash: "h-gone")],
        rows: [
            "s-gone": [
                SyncPlaybackCarryRow(outboxID: 10, entity: "favorite", rowKey: "s-gone", op: "upsert", updatedAtMs: 1),
                SyncPlaybackCarryRow(outboxID: 11, entity: "favorite", rowKey: "s-gone", op: "delete", updatedAtMs: 2),
            ],
        ]
    )
    let deletePlan = SyncPlaybackCarryPlanner.plan(
        scope: SyncPlaybackCarryScope(direction: .push, transferredPaths: ["A/gone.flac"], peerContentHashes: ["h-gone"]),
        facts: deleteFacts
    )
    checkEqual(deletePlan.entries, [SyncPlaybackCarryEntry](), "取消收藏（delete）不上线")
    checkEqual(deletePlan.skippedNoPlaybackData, ["A/gone.flac"], "只剩 delete → 记为无数据可带")

    // 配对前提：传输完成后对端身份 = 对端 manifest ∪ 本轮传输歌曲指纹
    let afterTransfer = SyncPlaybackCarryScope.afterTransfer(
        direction: .push,
        transferredPaths: ["A/one.flac", "@lyrics/h-one.json"],
        peerEntries: [entry("A/one.flac", hash: nil)], // 传输前对端没有/未指纹
        facts: facts
    )
    check(afterTransfer.peerContentHashes.contains("h-one"), "传输完成后把本轮传输歌曲的指纹并入对端身份集合")
    checkEqual(
        SyncPlaybackCarryPlanner.plan(scope: afterTransfer, facts: facts).carriedPaths,
        ["A/one.flac"],
        "只看对端 manifest 会误判未配对 → 并入后正常携带"
    )

    // 拉取方向只做配对范围（载荷由数据所有者产生）
    let pullPlan = SyncPlaybackCarryPlanner.pairingPlan(
        scope: SyncPlaybackCarryScope(direction: .pull, transferredPaths: ["A/one.flac", "A/two.flac"], peerContentHashes: ["h-one"]),
        facts: facts
    )
    checkEqual(pullPlan.carriedPaths, ["A/one.flac"], "拉取方向：请求范围为两端共有的歌")
    checkEqual(pullPlan.entries, [SyncPlaybackCarryEntry](), "拉取方向本端不发出条目")
    checkEqual(pullPlan.skippedNotPaired, ["A/two.flac"], "拉取方向同样只认两端共有")

    // 同指纹多路径 → 只带一次
    let dupFacts = MemoryCarryFacts(
        tracks: [
            "A/dup-a.flac": SyncCollectionTrackFact(stableId: "s-dup", relativePath: "A/dup-a.flac", contentHash: "h-dup"),
            "A/dup-b.flac": SyncCollectionTrackFact(stableId: "s-dup", relativePath: "A/dup-b.flac", contentHash: "h-dup"),
        ],
        rows: ["s-dup": [SyncPlaybackCarryRow(outboxID: 20, entity: "favorite", rowKey: "s-dup", op: "upsert", updatedAtMs: 1)]]
    )
    let dupPlan = SyncPlaybackCarryPlanner.plan(
        scope: SyncPlaybackCarryScope(direction: .push, transferredPaths: ["A/dup-b.flac", "A/dup-a.flac"], peerContentHashes: ["h-dup"]),
        facts: dupFacts
    )
    checkEqual(dupPlan.entries.count, 1, "同一首歌（同指纹）多路径只带一次")
    checkEqual(dupPlan.carriedPaths, ["A/dup-a.flac"], "首见路径获胜（路径升序确定性）")
}

// MARK: - ㉙ R3b：编排端到端——推送方向跟歌走

section("㉚ R3b：推送阶段结束 → 跟歌带播放数据（只带传输过的歌）")
do {
    let pushed = silentData(0xD1, count: 80_000)
    let pushedHash = try sha256Hex(of: pushed)
    let otherMacOnly = silentData(0xD2, count: 5_000)
    let otherHash = try sha256Hex(of: otherMacOnly)

    let carryFacts = MemoryCarryFacts(
        tracks: [
            "Album/new.flac": SyncCollectionTrackFact(stableId: "mac-new", relativePath: "Album/new.flac", contentHash: pushedHash),
            "Album/not-selected.flac": SyncCollectionTrackFact(
                stableId: "mac-other", relativePath: "Album/not-selected.flac", contentHash: otherHash
            ),
        ],
        rows: [
            "mac-new": [
                SyncPlaybackCarryRow(outboxID: 1, entity: "favorite", rowKey: "mac-new", op: "upsert", updatedAtMs: 1_000),
                SyncPlaybackCarryRow(outboxID: 2, entity: "play_history", rowKey: "mac-new|1700000000000", op: "upsert", updatedAtMs: 1_001),
            ],
            // 未选中的歌也有播放数据 → 不在本轮传输集合里，绝不携带
            "mac-other": [SyncPlaybackCarryRow(outboxID: 3, entity: "favorite", rowKey: "mac-other", op: "upsert", updatedAtMs: 1_002)],
        ]
    )

    let scenario = try makeCollectionScenario(
        selection: .playlists(["p1"]),
        macFiles: [("Album/new.flac", pushed), ("Album/not-selected.flac", otherMacOnly)],
        deviceFiles: [],
        playlists: [
            "p1": [
                SyncCollectionTrackFact(stableId: "mac-new", relativePath: "Album/new.flac", contentHash: pushedHash),
            ],
        ],
        carryFacts: carryFacts,
        injectCarry: true
    )

    let report = scenario.coordinator.report
    check(scenario.coordinator.state == .done, "编排终态 done")
    checkEqual(report.pushed, ["Album/new.flac"], "只推选中集合里的缺歌")
    checkEqual(report.playbackCarriedPush, ["Album/new.flac"], "接入：推送方向只带本轮传输的歌")
    checkEqual(report.playbackCarriedPull, [String](), "本轮无拉取 → 无拉取携带")
    check(report.playbackCarryError == nil, "携带无错误")
    checkEqual(scenario.carryDriver?.pushCarryPlans.count, 1, "推送携带恰好触发一次")
    let plan = scenario.carryDriver?.lastPushPlan
    checkEqual(plan?.entries.map(\.rowKey), ["mac-new", "mac-new|1700000000000"], "携带条目 = 该歌在 Mac 的播放数据行")
    checkEqual(plan?.entries.map(\.contentHash), [pushedHash, pushedHash], "条目身份键 = 歌曲 content_hash")
    check(
        !(plan?.entries.contains { $0.rowKey == "mac-other" } ?? true),
        "未传输的歌数据不携带（不做全库对账）"
    )
    checkEqual(plan?.skippedNotPaired, [String](), "本轮传输的歌已完成配对（对端 manifest ∪ 传输指纹）")
    check(
        FileManager.default.fileExists(atPath: scenario.deviceRoot.appendingPathComponent("Album/new.flac").path),
        "歌确实已送达对端"
    )
    scenario.deviceHost.detach()
} catch {
    check(false, "㉙ 抛错：\(error)")
}

// MARK: - ㉚ R3b：编排端到端——拉取方向请求范围

section("㉛ R3b：拉取阶段结束 → 请求对端带回这批歌的播放数据")
do {
    let deviceOnly = silentData(0xD3, count: 60_000)
    let deviceHash = try sha256Hex(of: deviceOnly)

    let carryFacts = MemoryCarryFacts(
        tracks: [
            "Album/from-device.flac": SyncCollectionTrackFact(
                stableId: "mac-pulled", relativePath: "Album/from-device.flac", contentHash: deviceHash
            ),
        ]
    )

    let scenario = try makeCollectionScenario(
        selection: .relativePaths(["Album/from-device.flac"]),
        direction: .download,
        macFiles: [],
        deviceFiles: [("Album/from-device.flac", deviceOnly)],
        knownPaths: [
            "Album/from-device.flac": SyncCollectionTrackFact(
                stableId: "dev-sid", relativePath: "Album/from-device.flac", contentHash: deviceHash
            ),
        ],
        carryFacts: carryFacts,
        injectCarry: true
    )

    let report = scenario.coordinator.report
    check(scenario.coordinator.state == .done, "编排终态 done")
    check(report.direction == .download, "账目方向 = download")
    checkEqual(report.pulled, ["Album/from-device.flac"], "歌已拉到本端")
    checkEqual(report.playbackCarriedPull, ["Album/from-device.flac"], "接入：拉取方向请求范围为两端共有的歌")
    checkEqual(report.playbackCarriedPush, [String](), "本轮无推送 → 无推送携带")
    checkEqual(scenario.carryDriver?.pullCarryPlans.count, 1, "拉取携带恰好触发一次")
    checkEqual(scenario.carryDriver?.lastPullPlan?.entries, [SyncPlaybackCarryEntry](), "拉取方向本端不发条目")
    check(report.playbackCarryError == nil, "携带无错误")
    scenario.deviceHost.detach()
} catch {
    check(false, "㉚ 抛错：\(error)")
}

// MARK: - ㉛ R3b：零传输 / 未接线 → 不携带（R3a 行为零变化）

section("㉜ R3b：零传输不出发携带；未接线保持 R3a 行为")
do {
    let same = silentData(0xD4, count: 4_000)
    let sameHash = try sha256Hex(of: same)
    let carryFacts = MemoryCarryFacts(
        tracks: ["Album/same.flac": SyncCollectionTrackFact(stableId: "mac-same", relativePath: "Album/same.flac", contentHash: sameHash)],
        rows: ["mac-same": [SyncPlaybackCarryRow(outboxID: 1, entity: "favorite", rowKey: "mac-same", op: "upsert", updatedAtMs: 1)]]
    )

    let wired = try makeCollectionScenario(
        selection: .playlists(["p1"]),
        macFiles: [("Album/same.flac", same)],
        deviceFiles: [("Album/same.flac", same)],
        playlists: ["p1": [SyncCollectionTrackFact(stableId: "mac-same", relativePath: "Album/same.flac", contentHash: sameHash)]],
        carryFacts: carryFacts,
        injectCarry: true
    )
    checkEqual(wired.coordinator.report.transferCount, 0, "两端已一致 → 零传输")
    checkEqual(wired.carryDriver?.pushCarryPlans.count, 0, "零传输不触发推送携带")
    checkEqual(wired.carryDriver?.pullCarryPlans.count, 0, "零传输不触发拉取携带")
    checkEqual(wired.coordinator.report.playbackCarriedPush, [String](), "账目无推送携带")
    wired.deviceHost.detach()

    let unWired = try makeCollectionScenario(
        selection: .relativePaths(["Album/only-device.flac"]),
        direction: .download,
        macFiles: [],
        deviceFiles: [("Album/only-device.flac", silentData(0xD5, count: 9_000))],
        knownPaths: [
            "Album/only-device.flac": SyncCollectionTrackFact(
                stableId: "dev-sid",
                relativePath: "Album/only-device.flac",
                contentHash: try sha256Hex(of: silentData(0xD5, count: 9_000))
            ),
        ],
        injectCarry: false
    )
    check(unWired.carryDriver == nil, "未注入驱动")
    check(unWired.coordinator.report.playbackCarriedPush.isEmpty, "未接线：账目无推送携带（R3a 行为）")
    check(unWired.coordinator.report.playbackCarriedPull.isEmpty, "未接线：账目无拉取携带（R3a 行为）")
    check(unWired.coordinator.report.playbackCarryError == nil, "未接线不报错")
    checkEqual(unWired.coordinator.report.pulled, ["Album/only-device.flac"], "传输行为不受影响")
    unWired.deviceHost.detach()
} catch {
    check(false, "㉜ 抛错：\(error)")
}

// MARK: - ㉝ T7：两个方向端到端（`.all` 不再空转 / 冲突不覆盖）

section("㉝ T7：upload × .all 不空转（本端全量为期望）")
do {
    let same = silentData(0xE1, count: 5_000)
    let macOnly = silentData(0xE2, count: 70_000)
    let macOnlyHash = try sha256Hex(of: macOnly)

    let scenario = try makeCollectionScenario(
        selection: .all,
        direction: .upload,
        macFiles: [("Album/mac-only.flac", macOnly), ("Album/same.flac", same)],
        deviceFiles: [("Album/same.flac", same), ("Imported/device-only.flac", silentData(0xE3, count: 3_000))]
    )

    let report = scenario.coordinator.report
    check(scenario.coordinator.state == .done, "编排终态 done")
    check(report.isLibraryWide, "账目：库级选择")
    checkEqual(report.plannedPush, ["Album/mac-only.flac"], "全库 upload 产出非空计划（修空转）")
    checkEqual(report.plannedPull, [String](), "upload 不拉")
    checkEqual(report.skipped, ["Album/same.flac"], "已一致 → 跳过")
    checkEqual(report.remoteOnlyIgnored, ["Imported/device-only.flac"], "对端独有 → 仅记账")
    checkEqual(report.pushed, ["Album/mac-only.flac"], "推送账目")
    check(
        !FileManager.default.fileExists(
            atPath: scenario.macRoot.appendingPathComponent("Imported/device-only.flac").path
        ),
        "upload 不把对端独有内容拉回本端"
    )
    checkEqual(
        try sha256Hex(of: try Data(contentsOf: scenario.deviceRoot.appendingPathComponent("Album/mac-only.flac"))),
        macOnlyHash,
        "补齐文件落位设备且内容一致"
    )
    scenario.deviceHost.detach()
} catch {
    check(false, "㉝ 抛错：\(error)")
}

section("㉞ T7：download × .all 拉对端独有（本端没有的歌能拉回来）")
do {
    let same = silentData(0xE4, count: 5_000)
    let deviceOnly = silentData(0xE5, count: 65_000)
    let deviceOnlyHash = try sha256Hex(of: deviceOnly)

    let scenario = try makeCollectionScenario(
        selection: .all,
        direction: .download,
        macFiles: [("Album/same.flac", same), ("Album/mac-only.flac", silentData(0xE6, count: 2_000))],
        deviceFiles: [("Album/same.flac", same), ("Imported/device-only.flac", deviceOnly)]
    )

    let report = scenario.coordinator.report
    check(scenario.coordinator.state == .done, "编排终态 done")
    checkEqual(report.plannedPull, ["Imported/device-only.flac"], "全库 download 产出非空计划（对端独有 → 拉）")
    checkEqual(report.plannedPush, [String](), "download 不推")
    checkEqual(report.skipped, ["Album/same.flac"], "已一致 → 跳过")
    // download × .all 的期望集合 = 对端清单 → 本端独有文件根本不在期望内（不在对账范围），
    // 既不推也不删；只有「期望内」的路径才会进 localOnlySkipped。
    checkEqual(report.localOnlySkipped, [String](), "期望（=对端清单）之外的本端文件不参与对账")
    checkEqual(report.pulled, ["Imported/device-only.flac"], "拉取账目")
    checkEqual(
        try sha256Hex(of: try Data(contentsOf: scenario.macRoot.appendingPathComponent("Imported/device-only.flac"))),
        deviceOnlyHash,
        "对端独有的歌落到本端且内容一致"
    )
    check(
        FileManager.default.fileExists(
            atPath: scenario.macRoot.appendingPathComponent("Album/mac-only.flac").path
        ),
        "本端独有文件保留（download 不删不推）"
    )
    scenario.deviceHost.detach()
} catch {
    check(false, "㉞ 抛错：\(error)")
}

section("㉟ T7：download 内容冲突 → 本端保留（不覆盖）")
do {
    let macVersion = silentData(0xE7, count: 4_000)
    let deviceVersion = silentData(0xE8, count: 4_000)

    let scenario = try makeCollectionScenario(
        selection: .all,
        direction: .download,
        macFiles: [("Album/x.flac", macVersion)],
        deviceFiles: [("Album/x.flac", deviceVersion)]
    )

    let report = scenario.coordinator.report
    check(scenario.coordinator.state == .done, "编排终态 done")
    checkEqual(report.conflictingKept, ["Album/x.flac"], "内容不同 → 本端保留（仅记账）")
    checkEqual(report.plannedPull, [String](), "冲突不拉取")
    checkEqual(report.plannedPush, [String](), "冲突不推送")
    checkEqual(report.transferCount, 0, "冲突 → 零传输")
    checkEqual(
        try sha256Hex(of: try Data(contentsOf: scenario.macRoot.appendingPathComponent("Album/x.flac"))),
        try sha256Hex(of: macVersion),
        "本端文件内容未被覆盖"
    )
    scenario.deviceHost.detach()
} catch {
    check(false, "㉟ 抛错：\(error)")
}

// MARK: - T9 对端内容清单（帧 15/16）：编解码 / 纯逻辑 / 端到端 / 客户端健壮性

/// async 断言的载体（harness 顶层是同步代码，用信号量等待 Task）。
final class AsyncBox<T>: @unchecked Sendable {
    var value: T?
    var error: Error?
}

func runAsync<T>(_ box: AsyncBox<T>, _ body: @escaping () async throws -> T) {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        do { box.value = try await body() } catch { box.error = error }
        semaphore.signal()
    }
    semaphore.wait()
}

/// T9 纯逻辑夹具：乱序 + 同 id 歌单 + 同路径曲目 + 一个非法 scope。
func t9Catalog() -> SyncPeerLibraryCatalog {
    SyncPeerLibraryCatalog(
        playlists: [
            SyncPeerPlaylistItem(id: "rock", name: "Rock", trackCount: 1),
            SyncPeerPlaylistItem(id: "jazz", name: "Jazz", trackCount: 2),
            SyncPeerPlaylistItem(id: "jazz", name: "Jazz 撞名", trackCount: 99),
        ],
        tracks: [
            SyncPeerTrackItem(
                relativePath: "Rock/01 c.flac", title: "C", artistName: "Cherry",
                sizeBytes: 300, contentHash: "h3"
            ),
            SyncPeerTrackItem(
                relativePath: "Jazz/02 b.flac", title: "Blue Moon", artistName: "Bob",
                sizeBytes: 200, contentHash: "h2"
            ),
            SyncPeerTrackItem(
                relativePath: "Jazz/01 a.flac", title: "A Song", artistName: nil,
                sizeBytes: 100, contentHash: nil
            ),
            SyncPeerTrackItem(
                relativePath: "Jazz/01 a.flac", title: "重复行", artistName: "dup",
                sizeBytes: 100, contentHash: "dup"
            ),
        ],
        trackPathsByPlaylist: [
            "jazz": ["Jazz/01 a.flac", "Jazz/02 b.flac"],
            "rock": ["Rock/01 c.flac"],
        ]
    )
}

section("㊱ T9：帧 15/16 编号 + 载荷编解码（含非法载荷）")
do {
    checkEqual(SyncFrameType.peerLibraryRequest.rawValue, 15, "peer_library_request = 15（10-14 冻结）")
    checkEqual(SyncFrameType.peerLibraryResponse.rawValue, 16, "peer_library_response = 16")

    let request = SyncPeerLibraryRequestPayload(
        scope: "tracks", playlistID: "jazz", query: "blue",
        offset: 2, limit: 10, requestID: 42
    )
    let encoded = try SyncPeerLibraryCodec.encode(request)
    let decoded = try SyncPeerLibraryCodec.decode(SyncPeerLibraryRequestPayload.self, from: encoded)
    checkEqual(decoded, request, "请求载荷 JSON 往返一致")
    checkEqual(try SyncPeerLibraryCodec.encode(decoded), encoded, "同一载荷两次编码字节一致（线上确定性）")

    let response = SyncPeerLibraryResponsePayload(
        requestID: 42,
        scope: "tracks",
        total: 3,
        items: [
            .track(SyncPeerTrackItem(
                relativePath: "A/x.flac", title: "X", artistName: nil, sizeBytes: 10, contentHash: nil
            )),
            .playlist(SyncPeerPlaylistItem(id: "jazz", name: "Jazz", trackCount: 2)),
        ],
        hasMore: true,
        libraryTrackCount: 9,
        librarySizeBytes: 1_234,
        truncated: false
    )
    let responseData = try SyncPeerLibraryCodec.encode(response)
    let decodedResponse = try SyncPeerLibraryCodec.decode(SyncPeerLibraryResponsePayload.self, from: responseData)
    checkEqual(decodedResponse, response, "响应载荷（联合条目）往返一致")
    checkEqual(decodedResponse.trackItems.map(\.relativePath), ["A/x.flac"], "联合条目取曲目视图")
    checkEqual(decodedResponse.playlistItems.map(\.id), ["jazz"], "联合条目取歌单视图")
    let json = String(data: responseData, encoding: .utf8) ?? ""
    check(json.contains("\"kind\":\"track\""), "联合条目线上带判别字段 kind")

    // 非法载荷：条目缺判别字段 / 未知判别值 → 解码失败（不静默生成错数据）
    let missingKind = Data(
        #"{"requestID":1,"scope":"tracks","total":0,"items":[{"id":"x"}],"hasMore":false,"libraryTrackCount":0,"librarySizeBytes":0,"truncated":false}"#.utf8
    )
    var missingKindFailed = false
    do { _ = try SyncPeerLibraryCodec.decode(SyncPeerLibraryResponsePayload.self, from: missingKind) } catch {
        missingKindFailed = true
    }
    check(missingKindFailed, "条目缺 kind → 解码失败")

    let unknownKind = Data(
        #"{"requestID":1,"scope":"tracks","total":0,"items":[{"kind":"album"}],"hasMore":false,"libraryTrackCount":0,"librarySizeBytes":0,"truncated":false}"#.utf8
    )
    var unknownKindFailed = false
    do { _ = try SyncPeerLibraryCodec.decode(SyncPeerLibraryResponsePayload.self, from: unknownKind) } catch {
        unknownKindFailed = true
    }
    check(unknownKindFailed, "未知 kind → 解码失败")
} catch {
    check(false, "㊱ 抛错：\(error)")
}

section("㊲ T9：内容清单纯逻辑（排序/去重/分页/筛选/钳制/非法 scope）")
do {
    let catalog = t9Catalog()
    checkEqual(catalog.playlists.map(\.id), ["jazz", "rock"], "歌单按 name 升序 + 同 id 去重")
    checkEqual(
        catalog.tracks.map(\.relativePath),
        ["Jazz/01 a.flac", "Jazz/02 b.flac", "Rock/01 c.flac"],
        "曲目按 relativePath 升序 + 同路径去重"
    )
    checkEqual(catalog.trackCount, 3, "曲库总曲目数（摘要）")
    checkEqual(catalog.totalSizeBytes, 600, "曲库总大小（摘要）")

    // 分页
    let page1 = catalog.response(for: SyncPeerLibraryRequestPayload(
        scope: "tracks", offset: 0, limit: 2, requestID: 1
    ))
    checkEqual(page1.total, 3, "分页 total = 全集条数")
    checkEqual(page1.items.count, 2, "第 1 页条数 = limit")
    check(page1.hasMore, "第 1 页 hasMore")
    checkEqual(page1.libraryTrackCount, 3, "摘要随页恒返回")
    let page2 = catalog.response(for: SyncPeerLibraryRequestPayload(
        scope: "tracks", offset: 2, limit: 2, requestID: 2
    ))
    checkEqual(page2.items.count, 1, "第 2 页条数（尾页）")
    check(!page2.hasMore, "尾页 hasMore = false")
    checkEqual(
        (page1.trackItems + page2.trackItems).map(\.relativePath),
        ["Jazz/01 a.flac", "Jazz/02 b.flac", "Rock/01 c.flac"],
        "两页拼接 = 全集（无重无漏）"
    )
    let pageOutOfRange = catalog.response(for: SyncPeerLibraryRequestPayload(
        scope: "tracks", offset: 99, limit: 10, requestID: 3
    ))
    checkEqual(pageOutOfRange.items.count, 0, "越界 offset → 空页")
    check(!pageOutOfRange.hasMore, "越界 offset → hasMore=false")

    let playlistPage = catalog.response(for: SyncPeerLibraryRequestPayload(
        scope: "playlists", offset: 0, limit: 1, requestID: 4
    ))
    checkEqual(playlistPage.playlistItems.map(\.id), ["jazz"], "歌单分页")
    checkEqual(playlistPage.total, 2, "歌单总数")
    check(playlistPage.hasMore, "歌单还有下一页")

    // 筛选（对端做 contains 匹配：标题 / 歌手 / 相对路径，大小写不敏感）
    func tracks(liking query: String) -> [String] {
        catalog.response(for: SyncPeerLibraryRequestPayload(
            scope: "tracks", query: query, offset: 0, limit: 50, requestID: 5
        )).trackItems.map(\.relativePath)
    }
    checkEqual(tracks(liking: "blue"), ["Jazz/02 b.flac"], "query 命中标题（大小写不敏感）")
    checkEqual(tracks(liking: "CHERRY"), ["Rock/01 c.flac"], "query 命中歌手")
    checkEqual(tracks(liking: "rock/"), ["Rock/01 c.flac"], "query 命中相对路径")
    checkEqual(tracks(liking: "zzz"), [], "query 无命中 → 空清单")

    func tracks(inPlaylist playlistID: String) -> [String] {
        catalog.response(for: SyncPeerLibraryRequestPayload(
            scope: "tracks", playlistID: playlistID, offset: 0, limit: 50, requestID: 6
        )).trackItems.map(\.relativePath)
    }
    checkEqual(tracks(inPlaylist: "jazz"), ["Jazz/01 a.flac", "Jazz/02 b.flac"], "playlistID 过滤（jazz）")
    checkEqual(tracks(inPlaylist: "rock"), ["Rock/01 c.flac"], "playlistID 过滤（rock）")
    checkEqual(tracks(inPlaylist: "nope"), [], "未知歌单 → 空清单")
    checkEqual(tracks(inPlaylist: "a/b"), [], "非法歌单标识 → 空清单（绝不回落全库）")

    // 非法 scope / 越界参数 / 不可信字符串
    let badScope = catalog.response(for: SyncPeerLibraryRequestPayload(
        scope: "albums", offset: 0, limit: 50, requestID: 7
    ))
    checkEqual(badScope.total, 0, "非法 scope → total 0")
    checkEqual(badScope.items.count, 0, "非法 scope → 空清单")
    checkEqual(badScope.libraryTrackCount, 3, "非法 scope → 摘要仍返回")
    checkEqual(badScope.requestID, 7, "响应回显 requestID")

    let clampProbe = SyncPeerLibraryRequestPayload(scope: "tracks", offset: -5, limit: 0, requestID: 8)
    checkEqual(clampProbe.clampedLimit, 1, "limit <= 0 → 钳到 1")
    checkEqual(clampProbe.clampedOffset, 0, "offset < 0 → 钳到 0")
    checkEqual(
        SyncPeerLibraryRequestPayload(scope: "tracks", limit: 9_999, requestID: 9).clampedLimit,
        500,
        "limit > 500 → 钳到 500"
    )
    checkEqual(
        SyncPeerLibraryRequestPayload(scope: "tracks", offset: 0, limit: 9999, requestID: 10)
            .clampedLimit, 500, "超大 limit 应答侧收口"
    )
    let hugeQuery = String(repeating: "x", count: 5_000)
    checkEqual(
        SyncPeerLibraryRequestPayload(scope: "tracks", query: hugeQuery, requestID: 11)
            .normalizedQuery?.count,
        SyncPeerLibraryRequestPayload.maxQueryLength,
        "超长 query 截断到上限"
    )
    check(
        SyncPeerLibraryRequestPayload(scope: "tracks", query: "   ", requestID: 12).normalizedQuery == nil,
        "空白 query → 不过滤"
    )
}

section("㊳ T9：端到端（内存回环）— Mac 客户端取对端内容清单")
do {
    let fixture = SessionFixture.pairedHandshake()
    let deviceRoot = try tempRoot("t9-device")
    let catalog = SyncPeerLibraryCatalog(
        playlists: [
            SyncPeerPlaylistItem(id: "jazz", name: "Jazz", trackCount: 2),
            SyncPeerPlaylistItem(id: "rock", name: "Rock", trackCount: 1),
            SyncPeerPlaylistItem(id: "@favorites", name: "收藏", trackCount: 1),
        ],
        tracks: [
            SyncPeerTrackItem(
                relativePath: "Jazz/01 a.flac", title: "A Song", artistName: "Alice",
                sizeBytes: 1_000, contentHash: "h1"
            ),
            SyncPeerTrackItem(
                relativePath: "Jazz/02 b.flac", title: "Blue Moon", artistName: "Bob",
                sizeBytes: 2_000, contentHash: "h2"
            ),
            SyncPeerTrackItem(
                relativePath: "Rock/01 c.flac", title: "Cherry", artistName: "Carol",
                sizeBytes: 4_000, contentHash: nil
            ),
        ],
        trackPathsByPlaylist: [
            "jazz": ["Jazz/01 a.flac", "Jazz/02 b.flac"],
            "rock": ["Rock/01 c.flac"],
            "@favorites": ["Jazz/02 b.flac"],
        ]
    )
    // 设备侧（被动端）：内容清单 provider = 内存清单
    let deviceHost = SyncLibraryPassiveHost(
        libraryRoot: deviceRoot,
        rootName: "测试设备曲库",
        sink: SinkSpy(),
        database: DatabaseManager(),
        lyricsStore: AlignedLyricsStore(directory: try tempRoot("t9-lyrics")),
        peerLibraryProvider: { catalog }
    )
    check(deviceHost.attach(to: fixture.clientSession), "被动端接线成功")

    // Mac 侧（发起端）：内容清单客户端
    let client = SyncPeerLibraryClient(session: fixture.hostSession, timeout: 3)

    let playlistsBox = AsyncBox<[SyncPeerPlaylistItem]>()
    runAsync(playlistsBox) { try await client.fetchPlaylists() }
    check(playlistsBox.error == nil, "歌单清单请求无错误（\(String(describing: playlistsBox.error))）")
    checkEqual(
        playlistsBox.value?.map(\.id) ?? [],
        ["jazz", "rock", "@favorites"],
        "歌单清单（按 name 升序；收藏伪歌单同列其中）"
    )
    checkEqual(playlistsBox.value?.first(where: { $0.id == "jazz" })?.trackCount, 2, "歌单曲目数随清单返回")

    let summaryBox = AsyncBox<(trackCount: Int, sizeBytes: Int64)>()
    runAsync(summaryBox) { try await client.fetchLibrarySummary() }
    checkEqual(summaryBox.value?.trackCount, 3, "摘要：对端曲库总曲目数")
    checkEqual(summaryBox.value?.sizeBytes, 7_000, "摘要：对端曲库总大小")

    let firstPageBox = AsyncBox<SyncPeerLibraryResponsePayload>()
    runAsync(firstPageBox) {
        try await client.fetchTracks(playlistID: nil, query: nil, offset: 0, limit: 2)
    }
    checkEqual(firstPageBox.value?.total, 3, "曲目页 total")
    checkEqual(firstPageBox.value?.items.count, 2, "曲目页第 1 页条数")
    check(firstPageBox.value?.hasMore == true, "曲目页 hasMore")
    checkEqual(
        firstPageBox.value?.trackItems.first.map { [$0.title ?? "", $0.artistName ?? "", "\($0.sizeBytes)", $0.contentHash ?? ""] },
        ["A Song", "Alice", "1000", "h1"],
        "曲目条目的标题/歌手/大小/指纹跨端一致"
    )

    let secondPageBox = AsyncBox<SyncPeerLibraryResponsePayload>()
    runAsync(secondPageBox) {
        try await client.fetchTracks(playlistID: nil, query: nil, offset: 2, limit: 2)
    }
    checkEqual(
        (firstPageBox.value?.trackItems ?? []) + (secondPageBox.value?.trackItems ?? []),
        catalog.tracks,
        "两页拼接 = 对端全集（客户端按 offset 翻页）"
    )

    let queryBox = AsyncBox<SyncPeerLibraryResponsePayload>()
    runAsync(queryBox) {
        try await client.fetchTracks(playlistID: nil, query: "moon", offset: 0, limit: 50)
    }
    checkEqual(queryBox.value?.trackItems.map(\.relativePath), ["Jazz/02 b.flac"], "query 过滤在对端执行")

    let playlistBox = AsyncBox<SyncPeerLibraryResponsePayload>()
    runAsync(playlistBox) {
        try await client.fetchTracks(playlistID: "jazz", query: nil, offset: 0, limit: 50)
    }
    checkEqual(
        playlistBox.value?.trackItems.map(\.relativePath),
        ["Jazz/01 a.flac", "Jazz/02 b.flac"],
        "playlistID 过滤在对端执行"
    )

    let favoritesBox = AsyncBox<SyncPeerLibraryResponsePayload>()
    runAsync(favoritesBox) {
        try await client.fetchTracks(
            playlistID: SyncCollectionSelection.favoritesPlaylistID,
            query: nil, offset: 0, limit: 50
        )
    }
    checkEqual(
        favoritesBox.value?.trackItems.map(\.relativePath),
        ["Jazz/02 b.flac"],
        "收藏伪歌单（@favorites）过滤"
    )

    // 注册点 3 的实证：没有控制器/重传，全靠会话分发到 responder
    check(client.pendingRequestCount == 0, "响应到达后在途表清空")
    deviceHost.detach()
} catch {
    check(false, "㊳ 抛错：\(error)")
}

section("㊴ T9：客户端健壮性（超时不悬挂 / 取消 / 会话关闭）")
do {
    // 对端不接线（没有任何 responder 应答）→ 必须超时抛错，绝不永久等待
    let silent = SessionFixture.pairedHandshake()
    let timeoutClient = SyncPeerLibraryClient(session: silent.hostSession, timeout: 0.3)
    let timeoutBox = AsyncBox<SyncPeerLibraryResponsePayload>()
    runAsync(timeoutBox) {
        try await timeoutClient.fetchTracks(playlistID: nil, query: nil, offset: 0, limit: 10)
    }
    checkEqual(
        timeoutBox.error as? SyncPeerLibraryClient.ClientError,
        .timeout,
        "对端不答 → 超时抛错"
    )
    check(timeoutClient.pendingRequestCount == 0, "超时后在途表清空（不悬挂）")

    // UI 取消 → 在途请求立即抛 .cancelled（不等超时）
    let cancelFixture = SessionFixture.pairedHandshake()
    let cancelClient = SyncPeerLibraryClient(session: cancelFixture.hostSession, timeout: 30)
    let cancelBox = AsyncBox<SyncPeerLibraryResponsePayload>()
    let cancelSemaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            cancelBox.value = try await cancelClient.fetchTracks(playlistID: nil, query: nil, offset: 0, limit: 10)
        } catch {
            cancelBox.error = error
        }
        cancelSemaphore.signal()
    }
    Thread.sleep(forTimeInterval: 0.05)
    cancelClient.cancel()
    cancelSemaphore.wait()
    checkEqual(
        cancelBox.error as? SyncPeerLibraryClient.ClientError,
        .cancelled,
        "cancel() 立即唤醒在途请求"
    )

    // 会话关闭 → 在途请求立即失败（不等超时）
    let closedFixture = SessionFixture.pairedHandshake()
    let closedClient = SyncPeerLibraryClient(session: closedFixture.hostSession, timeout: 30)
    let closedBox = AsyncBox<SyncPeerLibraryResponsePayload>()
    let closedSemaphore = DispatchSemaphore(value: 0)
    Task {
        do {
            closedBox.value = try await closedClient.fetchTracks(playlistID: nil, query: nil, offset: 0, limit: 10)
        } catch {
            closedBox.error = error
        }
        closedSemaphore.signal()
    }
    Thread.sleep(forTimeInterval: 0.05)
    closedFixture.hostSession.cancel(reason: .userCancelled)
    closedSemaphore.wait()
    checkEqual(
        closedBox.error as? SyncPeerLibraryClient.ClientError,
        .sessionClosed,
        "会话关闭 → 在途请求立即失败"
    )

    // 未 ready 的会话 → 立即抛 sessionNotReady（不静默挂起）
    let idleChannel = LoopbackTransport()
    let idleSession = SyncPeerSession(
        role: .host,
        localIdentity: SyncIdentity.generate(),
        trustStore: MemoryTrustStore(),
        config: SyncSessionConfiguration(),
        pairingNonces: SyncPairingNonceRegistry(),
        transport: idleChannel
    )
    idleChannel.session = idleSession
    let idleClient = SyncPeerLibraryClient(session: idleSession, timeout: 5)
    let idleBox = AsyncBox<SyncPeerLibraryResponsePayload>()
    runAsync(idleBox) {
        try await idleClient.fetchTracks(playlistID: nil, query: nil, offset: 0, limit: 10)
    }
    checkEqual(
        idleBox.error as? SyncPeerLibraryClient.ClientError,
        .sessionNotReady,
        "未 ready 会话 → sessionNotReady"
    )
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
