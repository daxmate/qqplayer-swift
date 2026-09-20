//
//  AlignedLyricsSyncTests.swift
//  QQPlayerTests
//
//  S2 M4-2b aligned 歌词随歌同步（§6.3 B 方案）：
//  - Part A：aligned 歌词库单一入口（写/读/删/枚举/接收侧安装）+ 类型标记
//    （只有 aligned 参与同步；manual/network 存储与语义不变）
//  - Part B：wire 命名空间 `@lyrics/{歌曲 content_hash}.json`、manifest 纳入、
//    多根应答（越界/软链逃逸仍被拒）、接收侧 content_hash 映射落盘（无歌则丢弃）；
//    **歌词只补不删**（§6 语义修订 2026-09-10：删除不跨端传播）
//
//  fixture：临时目录库 + DatabaseManager(dbWriter:) 内存库 + SyncPeerSessionTestSupport 双 ready 回环。
//  （生产 sink 的 DB 副作用走单例，此处不触；由 scripts/run-local-sync-tests.sh 的 ⑭ 覆盖）
//

import Foundation
import GRDB

import Testing

@testable import QQPlayer

/// 测试曲库根（身份入口的必传输入；本文件不建真实曲库文件，故只用于构造）。
private let testLibraryRoot = URL(fileURLWithPath: "/library")

// MARK: - 落盘 spy

private final class LyricsSinkSpy: SyncLibrarySyncSink, @unchecked Sendable {
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

@MainActor
struct AlignedLyricsSyncTests {
    // MARK: - 夹具

    private func tempRoot(_ tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-m42b-\(tag)-\(UUID().uuidString)", isDirectory: true)
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

    private func sampleLyrics(_ text: String) -> Lyrics {
        Lyrics(
            plainLyrics: text,
            syncedLyrics: [LyricsLine(timestamp: 1.0, text: text)],
            isInstrumental: false,
            source: .lrclib
        )
    }

    /// 歌曲内容指纹（= 文件 SHA-256，与 Track.content_hash 同口径）。
    private func contentHash(of data: Data) throws -> String {
        let url = try tempRoot("hash").appendingPathComponent("song.flac")
        try data.write(to: url)
        return try SyncFileChecksum.sha256Hex(ofFile: url)
    }

    private func mapping(_ table: [String: String]) -> SyncLyricsContentMapping {
        SyncLyricsContentMapping(
            contentHashForStableId: { table[$0] },
            stableIdForContentHash: { hash in table.first { $0.value == hash }?.key }
        )
    }

    // MARK: - Part A：aligned 歌词库

    @Test("aligned 歌词库：写 / 读 / 删 / 枚举 + 幂等")
    func storeRoundTrip() throws {
        let store = AlignedLyricsStore(directory: try tempRoot("store"))
        try store.write(sampleLyrics("第一行"), forStableId: "s1")
        try store.write(sampleLyrics("第二行"), forStableId: "s2")

        #expect(try store.read(forStableId: "s1")?.plainLyrics == "第一行")
        #expect(try store.read(forStableId: "s1")?.source == .lrclib)
        #expect(store.stableIds() == ["s1", "s2"])
        #expect(store.entries().count == 2)
        #expect(store.contains(forStableId: "s1"))
        #expect(try store.read(forStableId: "missing") == nil)

        try store.delete(forStableId: "s1")
        #expect(!store.contains(forStableId: "s1"))
        try store.delete(forStableId: "s1") // 幂等
        #expect(store.stableIds() == ["s2"])
    }

    @Test("aligned 歌词库：非法 stableId 拒绝（防路径穿越）")
    func storeRejectsInvalidStableId() throws {
        let store = AlignedLyricsStore(directory: try tempRoot("store-invalid"))
        for bad in ["", ".", "..", "a/b", "..\\escape"] {
            #expect(!AlignedLyricsStore.isValidStableId(bad), "stableId 应非法：\(bad)")
            #expect(throws: AlignedLyricsStore.StoreError.self) {
                try store.write(sampleLyrics("x"), forStableId: bad)
            }
        }
        #expect(store.stableIds().isEmpty)
    }

    @Test("aligned 歌词库：install 校验可解码 + 移动落位（不留临时文件）")
    func storeInstallValidatesAndMoves() throws {
        let store = AlignedLyricsStore(directory: try tempRoot("store-install"))
        let incoming = try tempRoot("incoming")

        let good = incoming.appendingPathComponent("good.json")
        try JSONEncoder().encode(sampleLyrics("收到的")).write(to: good)
        try store.install(receivedFileAt: good, forStableId: "s9")
        #expect(try store.read(forStableId: "s9")?.plainLyrics == "收到的")
        #expect(!FileManager.default.fileExists(atPath: good.path))

        let bad = incoming.appendingPathComponent("bad.json")
        try Data("not json".utf8).write(to: bad)
        #expect(throws: AlignedLyricsStore.StoreError.self) {
            try store.install(receivedFileAt: bad, forStableId: "s10")
        }
        #expect(!store.contains(forStableId: "s10"))
    }

    @Test("类型标记：只有 aligned 参与同步，三类目录命名空间互不重叠")
    func onlyAlignedSynchronizes() {
        #expect(LyricsStoreKind.aligned.synchronizesWithLibrary)
        #expect(!LyricsStoreKind.manual.synchronizesWithLibrary)
        #expect(!LyricsStoreKind.network.synchronizesWithLibrary)
        #expect(LyricsStoreKind.synchronizedKinds == [.aligned])
        #expect(Set(LyricsStoreKind.allCases.map(\.directoryName)).count == 3)
    }

    // MARK: - Part B：命名空间 / manifest

    @Test("歌词命名空间：歌曲 content_hash ↔ wire 路径，形态非法一律拒")
    func namespaceRoundTrip() {
        #expect(SyncLyricsNamespace.wirePath(songContentHash: "abc123") == "@lyrics/abc123.json")
        #expect(SyncLyricsNamespace.songContentHash(fromWirePath: "@lyrics/abc123.json") == "abc123")
        #expect(SyncLyricsNamespace.isLyricsPath("./@lyrics/abc123.json"))
        #expect(!SyncLyricsNamespace.isLyricsPath("Album/01.flac"))
        for bad in ["@lyrics/../x.json", "@lyrics/a/b.json", "@lyrics/.json", "@lyrics/x.flac", "@lyrics/"] {
            #expect(SyncLyricsNamespace.songContentHash(fromWirePath: bad) == nil, "应拒绝：\(bad)")
        }
    }

    @Test("manifest：歌词条目以歌曲 content_hash 为键，指纹缺失/集合外不出现")
    func manifestKeyedBySongContentHash() throws {
        let store = AlignedLyricsStore(directory: try tempRoot("manifest"))
        try store.write(sampleLyrics("有指纹"), forStableId: "s1")
        try store.write(sampleLyrics("无指纹"), forStableId: "s2")
        let map = mapping(["s1": "hash-1"])

        let entries = SyncAlignedLyricsManifest.entries(store: store, mapping: map)
        #expect(entries.count == 1)
        #expect(entries.first?.relativePath == "@lyrics/hash-1.json")
        #expect(entries.first?.stableId == "s1")
        #expect(entries.first?.contentHash?.isEmpty == false)

        #expect(
            SyncAlignedLyricsManifest.entries(store: store, mapping: map, collection: .tracks(["s1"]))
                .map(\.relativePath) == ["@lyrics/hash-1.json"]
        )
        #expect(SyncAlignedLyricsManifest.entries(store: store, mapping: map, collection: .tracks(["x"])).isEmpty)
        #expect(SyncAlignedLyricsManifest.entries(store: store, mapping: .unresolved).isEmpty)
    }

    @Test("多根应答：歌词只从歌词根取，越界/软链逃逸/嵌套路径仍被拒")
    func makePlanServesLyricsFromLyricsRootOnly() throws {
        let lyricsRoot = try tempRoot("plan-lyrics")
        let outsideRoot = try tempRoot("plan-outside")
        let outsideFile = try writeFile("secret.json", in: outsideRoot, data: Data("{}".utf8))
        try Data("{}".utf8).write(to: lyricsRoot.appendingPathComponent("s1.json"))
        try FileManager.default.createSymbolicLink(
            at: lyricsRoot.appendingPathComponent("escape.json"),
            withDestinationURL: outsideFile
        )
        let roots = SyncFetchRoots(libraryRoot: try tempRoot("plan-lib"), lyricsRoot: lyricsRoot)

        let provider: @Sendable (String) -> String? = { wirePath in
            switch SyncLyricsNamespace.songContentHash(fromWirePath: wirePath) {
            case "s1": return "s1.json"
            case "escape": return "escape.json"
            case "outside": return "../\(outsideRoot.lastPathComponent)/secret.json"
            case "absolute": return outsideFile.path
            default: return nil
            }
        }

        let plan = SyncLibraryFetchResponder.makePlan(
            relativePaths: [
                "@lyrics/s1.json", "@lyrics/s1.json", "@lyrics/escape.json",
                "@lyrics/outside.json", "@lyrics/absolute.json", "@lyrics/missing.json",
                "@lyrics/../etc/passwd", "@lyrics/a/b.json",
            ],
            roots: roots,
            lyricsFileNameProvider: provider
        )
        #expect(plan.files.map(\.relativePath) == ["@lyrics/s1.json"])
        #expect(plan.files.map(\.url) == [lyricsRoot.appendingPathComponent("s1.json")])
        let reasons = Dictionary(plan.failures.map { ($0.relativePath, $0.reason) }, uniquingKeysWith: { first, _ in first })
        #expect(reasons["@lyrics/escape.json"] == SyncFetchFailureReason.outOfRoot)
        #expect(reasons["@lyrics/outside.json"] == SyncFetchFailureReason.notFound)
        // 注入映射给出绝对路径 → 拒（只接受单段文件名，绝不用它拼出根外路径）
        #expect(reasons["@lyrics/absolute.json"] == SyncFetchFailureReason.notFound)
        #expect(reasons["@lyrics/missing.json"] == SyncFetchFailureReason.notFound)
        #expect(reasons["@lyrics/../etc/passwd"] == SyncFetchFailureReason.invalidPath)
        #expect(reasons["@lyrics/a/b.json"] == SyncFetchFailureReason.invalidPath)

        let noLyrics = SyncLibraryFetchResponder.makePlan(
            relativePaths: ["@lyrics/s1.json"],
            roots: .libraryOnly(roots.libraryRoot),
            lyricsFileNameProvider: provider
        )
        #expect(noLyrics.failures.map(\.reason) == [SyncFetchFailureReason.notFound])
        #expect(noLyrics.files.isEmpty)
        // 未接线歌词根时不得落回曲库根：曲库根内不会冒出歌词命名空间副本
        #expect(!FileManager.default.fileExists(atPath: roots.libraryRoot.appendingPathComponent("@lyrics/s1.json").path))
    }

    @Test("生产映射：复用 M4-2a SyncContentHashResolver（双向 + 无此歌 = nil）")
    func liveMappingUsesContentHashResolver() throws {
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        try manager.createTables()
        try manager.write { db in
            try db.execute(
                sql: "INSERT INTO track (stable_id, title, path, content_hash) VALUES (?, ?, ?, ?)",
                arguments: ["sid-a", "T", "/m/a.flac", "hash-a"]
            )
        }
        let live = SyncLyricsContentMapping.live(database: manager, libraryRoot: testLibraryRoot)
        #expect(live.contentHashForStableId("sid-a") == "hash-a")
        #expect(live.stableIdForContentHash("hash-a") == "sid-a")
        #expect(live.contentHashForStableId("nope") == nil)
        #expect(live.stableIdForContentHash("nope") == nil)
    }

    // MARK: - Part B：端到端（内存回环）

    private struct Harness {
        let fixture: SessionFixture
        /// 设备侧曲库（内容源）
        let sourceRoot: URL
        /// Mac 侧曲库（落位目标）
        let targetRoot: URL
        let hostLyricsStore: AlignedLyricsStore
        let clientLyricsStore: AlignedLyricsStore
        let sink: LyricsSinkSpy
        /// Mac 侧拉取控制器（R1b-2：发起方恒为 Mac）
        let controller: SyncLibraryPullController
        /// 设备侧被动端（应答 manifest / 按路径回推）
        let deviceHost: SyncLibraryPassiveHost
    }

    private func makeHarness(
        sourceFiles: [(String, Data)] = [],
        targetFiles: [(String, Data)] = [],
        hostMapping: SyncLyricsContentMapping = .unresolved,
        clientMapping: SyncLyricsContentMapping = .unresolved,
        hostLyrics: [(String, Lyrics)] = [],
        clientLyrics: [(String, Lyrics)] = []
    ) throws -> Harness {
        let fixture = SessionFixture.pairedHandshake()
        let sourceRoot = try tempRoot("e2e-src")
        let targetRoot = try tempRoot("e2e-dst")
        for (path, data) in sourceFiles { try writeFile(path, in: sourceRoot, data: data) }
        for (path, data) in targetFiles { try writeFile(path, in: targetRoot, data: data) }

        let hostLyricsStore = AlignedLyricsStore(directory: try tempRoot("e2e-host-lyrics"))
        let clientLyricsStore = AlignedLyricsStore(directory: try tempRoot("e2e-client-lyrics"))
        for (stableId, lyrics) in hostLyrics { try hostLyricsStore.write(lyrics, forStableId: stableId) }
        for (stableId, lyrics) in clientLyrics { try clientLyricsStore.write(lyrics, forStableId: stableId) }

        let hostManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try hostManager.createTables()
        let clientManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try clientManager.createTables()

        // 设备侧装配（iOS 单一被动入口：应答 manifest + 按路径回推）
        let deviceHost = SyncLibraryPassiveHost(
            libraryRoot: sourceRoot,
            sink: LyricsSinkSpy(),
            database: hostManager,
            lyricsStore: hostLyricsStore,
            lyricsMapping: hostMapping
        )
        _ = deviceHost.attach(to: fixture.clientSession)

        // Mac 侧装配（发起方）：拉取控制器 + 曲库描述符（含 aligned 歌词命名空间）
        let sink = LyricsSinkSpy()
        let descriptor = SyncLocalLibraryDescriptor(
            libraryRoot: targetRoot,
            rootName: "测试 Mac 曲库",
            lyricsRoot: clientLyricsStore.directory,
            sourceFiles: {
                SyncLocalLibraryScanner.sourceFiles(in: targetRoot, database: clientManager)
            },
            lyricsEntries: {
                SyncAlignedLyricsManifest.entries(store: clientLyricsStore, mapping: clientMapping)
            },
            contentHash: { relativePath in
                DatabaseManager.contentHashIfFilePresent(
                    atPath: targetRoot.appendingPathComponent(relativePath).path
                )
            },
            lyricsFileName: { wirePath in
                guard let hash = SyncLyricsNamespace.songContentHash(fromWirePath: wirePath),
                      let stableId = clientMapping.stableIdForContentHash(hash)
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
            hostLyricsStore: hostLyricsStore,
            clientLyricsStore: clientLyricsStore,
            sink: sink,
            controller: controller,
            deviceHost: deviceHost
        )
    }

    @Test("端到端：aligned 歌词随歌同步 → 按 content_hash 映射落本端 stableId")
    func lyricsFollowSong() throws {
        let song = Data(repeating: 0x61, count: 4_096)
        let songHash = try contentHash(of: song)
        let harness = try makeHarness(
            sourceFiles: [("Album/01 Song.flac", song)],
            hostMapping: mapping(["host-sid": songHash]),
            clientMapping: mapping(["client-sid": songHash]),
            hostLyrics: [("host-sid", sampleLyrics("随歌同步"))]
        )

        #expect(try harness.clientLyricsStore.read(forStableId: "client-sid")?.plainLyrics == "随歌同步")
        #expect(!harness.clientLyricsStore.contains(forStableId: "host-sid"))
        // 歌词不落曲库根、不进曲库入库入口
        #expect(harness.sink.indexed.count == 1)
        #expect(!FileManager.default.fileExists(atPath: harness.targetRoot.appendingPathComponent("@lyrics/\(songHash).json").path))
        guard case let .done(summary) = harness.controller.state else {
            Issue.record("期望 done，实际 \(harness.controller.state)")
            return
        }
        #expect(summary.completed.contains("@lyrics/\(songHash).json"))
        #expect(summary.orphanLyricsSkipped.isEmpty)
        let incoming = harness.targetRoot.appendingPathComponent(".sync-incoming")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: incoming.path)) ?? []).isEmpty)
    }

    @Test("端到端：本端无对应歌曲 → 歌词丢弃不落库（不写孤儿，无残渣）")
    func orphanLyricsDiscarded() throws {
        let song = Data(repeating: 0x62, count: 4_096)
        let songHash = try contentHash(of: song)
        let harness = try makeHarness(
            hostMapping: mapping(["host-sid": songHash]),
            clientMapping: .unresolved,
            hostLyrics: [("host-sid", sampleLyrics("孤立歌词"))]
        )

        #expect(harness.clientLyricsStore.stableIds().isEmpty)
        guard case let .done(summary) = harness.controller.state else {
            Issue.record("期望 done，实际 \(harness.controller.state)")
            return
        }
        #expect(summary.orphanLyricsSkipped == ["@lyrics/\(songHash).json"])
        let incoming = harness.targetRoot.appendingPathComponent(".sync-incoming")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: incoming.path)) ?? []).isEmpty)
    }

    @Test("端到端：远端歌删除 → 本端 aligned 歌词保留（删除不传播）")
    func remoteDeletedSongKeepsLyrics() throws {
        let song = Data(repeating: 0x63, count: 4_096)
        let songHash = try contentHash(of: song)
        let harness = try makeHarness(
            targetFiles: [("Album/gone.flac", song)],
            clientMapping: mapping(["client-sid": songHash]),
            clientLyrics: [("client-sid", sampleLyrics("要保留的"))]
        )

        // 对端已无这首歌（也没了它的歌词）→ 本端歌词原样保留（删除不传播）
        #expect(harness.clientLyricsStore.stableIds() == ["client-sid"])
        #expect(try harness.clientLyricsStore.read(forStableId: "client-sid")?.plainLyrics == "要保留的")
        guard case let .done(summary) = harness.controller.state else {
            Issue.record("期望 done，实际 \(harness.controller.state)")
            return
        }
        // v2 §12b-7：删除不跨端传播——summary 里没有删除通道，对端缺的歌词恒为零动作。
        #expect(summary.requested.isEmpty && summary.completed.isEmpty)

        // 规划层：即使全库镜像配置，歌词条目也永不进删除计划
        let plan = SyncLibraryPullPlanner.plan(
            remote: SyncManifestResponse(entries: []),
            local: [
                ManifestEntry(relativePath: "@lyrics/\(songHash).json", size: 10, mtimeMs: 0, contentHash: "h", stableId: "client-sid"),
            ],
            selection: .all
        )
        #expect(plan.relativePaths.isEmpty)
        #expect(plan.unchanged.isEmpty)
    }

    @Test("端到端：歌词同步不影响 manual 与 network 存储")
    func manualAndNetworkUntouched() throws {
        let documents = try tempRoot("documents")
        let manualDir = documents.appendingPathComponent("lyrics-manual")
        let networkDir = documents.appendingPathComponent("lyrics-cache/tracks")
        for dir in [manualDir, networkDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let manualFile = manualDir.appendingPathComponent("s1.json")
        let networkFile = networkDir.appendingPathComponent("s1.json")
        try Data("manual".utf8).write(to: manualFile)
        try Data("network".utf8).write(to: networkFile)

        let song = Data(repeating: 0x64, count: 4_096)
        let songHash = try contentHash(of: song)
        _ = try makeHarness(
            sourceFiles: [("Album/01.flac", song)],
            hostMapping: mapping(["client-sid": songHash]),
            clientMapping: mapping(["client-sid": songHash]),
            hostLyrics: [("client-sid", sampleLyrics("随歌同步的"))]
        )

        // 同步只动 aligned 库目录；manual / network 字节不变、无新增文件
        #expect(try String(contentsOf: manualFile, encoding: .utf8) == "manual")
        #expect(try String(contentsOf: networkFile, encoding: .utf8) == "network")
        #expect(
            (try FileManager.default.contentsOfDirectory(atPath: manualDir.path)).sorted() == ["s1.json"]
        )
        #expect(
            (try FileManager.default.contentsOfDirectory(atPath: networkDir.path)).sorted() == ["s1.json"]
        )
    }

    // MARK: - F2 补发通道（2026-09-16）

    private func lyricEntry(_ songHash: String, contentHash: String? = "lyric-bytes") -> ManifestEntry {
        ManifestEntry(
            relativePath: "@lyrics/\(songHash).json",
            size: 12,
            mtimeMs: 0,
            contentHash: contentHash,
            stableId: "sid"
        )
    }

    private func audioEntry(_ relativePath: String, contentHash: String) -> ManifestEntry {
        ManifestEntry(
            relativePath: relativePath,
            size: 4_096,
            mtimeMs: 0,
            contentHash: contentHash,
            stableId: "sid"
        )
    }

    @Test("F2 补发计划：只补不覆盖 —— 同路径两侧都有就谁都不动（内容不同也不动）")
    func resendPlanOnlyFills() {
        let plan = SyncLyricsResendPlanner.plan(
            localLyrics: [lyricEntry("h1", contentHash: "本端版本")],
            remoteEntries: [
                audioEntry("Album/A.flac", contentHash: "h1"),
                lyricEntry("h1", contentHash: "对端版本"),
            ]
        )
        #expect(plan.isIdle, "两侧都有 = 谁都不动（F2 只补不覆盖）")
        #expect(plan.present == ["@lyrics/h1.json"])
    }

    @Test("F2 补发计划：歌不在对端不推；对端有本端没有的歌词不回流（单向）")
    func resendPlanGatesOnSongPresence() {
        let local = [lyricEntry("hA"), lyricEntry("hB")]
        // 对端只有 B 这首歌（音频条目的 contentHash = 歌曲指纹），并带一条本端没有的歌词 hC
        let remote = [audioEntry("Album/B.flac", contentHash: "hB"), lyricEntry("hC")]

        let plan = SyncLyricsResendPlanner.plan(localLyrics: local, remoteEntries: remote)
        // hA：对端没有这首歌 → 不推（推过去只会被丢弃，把「歌词丢弃」计数变成噪音）
        #expect(plan.toPush.map(\.relativePath) == ["@lyrics/hB.json"])
        // hC：本端没有 → 不回流（对齐歌词单向：桌面 → 移动，反方向是显式「从设备取回」）
        #expect(plan.present.isEmpty)
        #expect(plan.pendingCount == 1)
    }

    @Test("F2 补发计划：非歌词命名空间条目一律进不了补发计划")
    func resendPlanLyricsNamespaceOnly() {
        let plan = SyncLyricsResendPlanner.plan(
            localLyrics: [audioEntry("Album/A.flac", contentHash: "h1"), lyricEntry("h1")],
            remoteEntries: [audioEntry("Album/A.flac", contentHash: "h1")]
        )
        #expect(plan.toPush.map(\.relativePath) == ["@lyrics/h1.json"])
        #expect(SyncLyricsResendPlanner.lyricsEntries(plan.toPush).count == plan.toPush.count)
    }

    @Test("F2 补发状态机 + 自动轮判定：合法迁移 / 终态不再迁 / 一次连接一次")
    func resendStateMachineAndAutoRunDecision() {
        #expect(SyncLyricsResendStateMachine.canTransition(from: .idle, to: .planning))
        #expect(SyncLyricsResendStateMachine.canTransition(from: .planning, to: .pushing))
        #expect(SyncLyricsResendStateMachine.canTransition(from: .planning, to: .done(SyncLyricsResendSummary())))
        #expect(SyncLyricsResendStateMachine.canTransition(from: .pushing, to: .done(SyncLyricsResendSummary())))
        #expect(!SyncLyricsResendStateMachine.canTransition(from: .idle, to: .pushing))
        #expect(
            !SyncLyricsResendStateMachine.canTransition(
                from: .done(SyncLyricsResendSummary()),
                to: .planning
            ),
            "终态不可再迁（幂等重跑不重开）"
        )

        #expect(SyncLyricsResendAutoRunDecision.shouldStart(
            isConnected: true, hasSession: true, didAutoRunForCurrentConnection: false
        ))
        #expect(!SyncLyricsResendAutoRunDecision.shouldStart(
            isConnected: true, hasSession: true, didAutoRunForCurrentConnection: true
        ))
        #expect(!SyncLyricsResendAutoRunDecision.shouldStart(
            isConnected: false, hasSession: true, didAutoRunForCurrentConnection: false
        ))
    }

    @Test("F2 接收侧只补不覆盖：本端已有 → 保留本端、不覆盖、临时文件清干净")
    func receiverKeepsLocalLyrics() throws {
        let store = AlignedLyricsStore(directory: try tempRoot("only-fill"))
        let songHash = "h-only-fill"
        try store.write(sampleLyrics("本端对齐结果"), forStableId: "sid-1")
        let receiver = SyncLyricsReceiver(
            lyricsStore: store,
            lyricsMapping: mapping(["sid-1": songHash])
        )
        let incomingDir = try tempRoot("only-fill-incoming")
        let incomingFile = incomingDir.appendingPathComponent("incoming.json")
        try JSONEncoder().encode(sampleLyrics("对端发来的结果")).write(to: incomingFile)

        let outcome = receiver.receive(tempURL: incomingFile, wirePath: "@lyrics/\(songHash).json")
        #expect(outcome == .keptLocal("@lyrics/\(songHash).json"))
        #expect(try store.read(forStableId: "sid-1")?.plainLyrics == "本端对齐结果")
        #expect(!FileManager.default.fileExists(atPath: incomingFile.path), "保留本端时不留临时文件")

        // 对照组：本端（映射表）没有这首歌 → 先暂存，收尾时仍映射不到才丢弃
        let otherHash = "h-only-fill-new"
        let second = incomingDir.appendingPathComponent("incoming2.json")
        try JSONEncoder().encode(sampleLyrics("新来的结果")).write(to: second)
        let buffered = receiver.receive(
            tempURL: second,
            wirePath: "@lyrics/\(otherHash).json"
        )
        #expect(buffered == .pending("@lyrics/\(otherHash).json"), "本端无对应歌曲 → 暂存待收尾重试")
        #expect(receiver.flushPending() == [.discarded("@lyrics/\(otherHash).json")], "收尾仍映射不到 → 丢弃")
        #expect(!FileManager.default.fileExists(atPath: second.path), "丢弃时不留临时文件")
    }

    @Test("F2 披露投影：只出计数 > 0 的行，顺序 = 丢弃 → 待补 → 保留本端")
    func lyricsDisclosureRows() {
        #expect(
            SyncEntityOutcomeDisclosure
                .lyricsRows(discarded: 0, pendingResend: 0, keptLocal: 0)
                .isEmpty,
            "全 0 = 空表（不做恒零噪音表）"
        )
        let rows = SyncEntityOutcomeDisclosure.lyricsRows(discarded: 2, pendingResend: 1, keptLocal: 3)
        #expect(rows.map(\.labelKey) == [
            SyncEntityOutcomeDisclosure.lyricsDiscardedLabelKey,
            SyncEntityOutcomeDisclosure.lyricsPendingResendLabelKey,
            SyncEntityOutcomeDisclosure.lyricsKeptLocalLabelKey,
        ])
        #expect(rows.map(\.count) == [2, 1, 3])
        #expect(rows.map(\.isGap) == [true, true, false], "保留本端是正常计数行，不是缺口")
        #expect(rows[0].hintKey == SyncEntityOutcomeDisclosure.lyricsDiscardedHintKey)
        #expect(rows[2].hintKey == nil)
    }

    @Test("F2 端到端：补发轮把对端缺的对齐歌词推过去（帧 10/11/14/4-6）")
    func lyricsResendRoundPushesMissingLyrics() throws {
        let songA = Data(repeating: 0x71, count: 4_096)
        let songB = Data(repeating: 0x72, count: 4_096)
        let hashA = try contentHash(of: songA)
        let hashB = try contentHash(of: songB)

        let fixture = SessionFixture.pairedHandshake()
        // 设备侧：A、B 两首歌都在；只有 B 的对齐歌词（本端缺 A 的歌词 → 等补发轮推）
        let deviceRoot = try tempRoot("resend-device")
        for (path, data) in [("Album/A.flac", songA), ("Album/B.flac", songB)] {
            try writeFile(path, in: deviceRoot, data: data)
        }
        let deviceLyrics = AlignedLyricsStore(directory: try tempRoot("resend-device-lyrics"))
        try deviceLyrics.write(sampleLyrics("设备侧对齐"), forStableId: "dev-sid-b")
        let deviceManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try deviceManager.createTables()
        let deviceHost = SyncLibraryPassiveHost(
            libraryRoot: deviceRoot,
            sink: LyricsSinkSpy(),
            database: deviceManager,
            lyricsStore: deviceLyrics,
            lyricsMapping: mapping(["dev-sid-a": hashA, "dev-sid-b": hashB])
        )
        _ = deviceHost.attach(to: fixture.clientSession)

        // Mac 侧：有 A 的歌词（该推）、有 C 的歌词（**对端没有 C 这首歌** → 不推）；
        // 本端没有 B 的歌词，对端有 → 单向：**不回流**
        let songC = Data(repeating: 0x74, count: 4_096)
        let hashC = try contentHash(of: songC)
        let macRoot = try tempRoot("resend-mac")
        let macLyrics = AlignedLyricsStore(directory: try tempRoot("resend-mac-lyrics"))
        try macLyrics.write(sampleLyrics("Mac 侧 A"), forStableId: "mac-sid-a")
        try macLyrics.write(sampleLyrics("Mac 侧 C"), forStableId: "mac-sid-c")
        let macManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try macManager.createTables()
        let macMapping = mapping(["mac-sid-a": hashA, "mac-sid-c": hashC])
        let descriptor = SyncLocalLibraryDescriptor(
            libraryRoot: macRoot,
            rootName: "测试 Mac 曲库",
            lyricsRoot: macLyrics.directory,
            sourceFiles: {
                SyncLocalLibraryScanner.sourceFiles(in: macRoot, database: macManager)
            },
            lyricsEntries: {
                SyncAlignedLyricsManifest.entries(store: macLyrics, mapping: macMapping)
            },
            contentHash: { _ in nil },
            lyricsFileName: { wirePath in
                guard let songHash = SyncLyricsNamespace.songContentHash(fromWirePath: wirePath),
                      let stableId = macMapping.stableIdForContentHash(songHash)
                else { return nil }
                return "\(stableId).json"
            }
        )
        let controller = SyncLyricsResendController(session: fixture.hostSession, descriptor: descriptor)
        try controller.start()

        guard case let .done(summary) = controller.state else {
            Issue.record("期望 done，实际 \(controller.state)")
            return
        }
        #expect(summary.plannedPush == ["@lyrics/\(hashA).json"], "只把「对端有歌、且缺这条歌词」的列入计划")
        #expect(summary.pushed == ["@lyrics/\(hashA).json"], "对端确认送达")
        #expect(summary.pendingResend.isEmpty)
        #expect(try deviceLyrics.read(forStableId: "dev-sid-a")?.plainLyrics == "Mac 侧 A")
        // 对端没有 C 这首歌 → 不推（补发轮不抢跑；歌到位由下一次整轮同步负责）
        #expect(!summary.plannedPush.contains("@lyrics/\(hashC).json"))
        #expect(!deviceLyrics.contains(forStableId: "dev-sid-c"))
        // 单向：设备侧的 B 歌词不回流本端
        #expect(try macLyrics.read(forStableId: "mac-sid-b") == nil)
        #expect(deviceLyrics.stableIds().sorted() == ["dev-sid-a", "dev-sid-b"])
        // 歌词不落曲库根
        #expect(!FileManager.default.fileExists(atPath: macRoot.appendingPathComponent("@lyrics/\(hashA).json").path))
    }

    @Test("F2 端到端：两侧都有 → 谁都不动（只补不覆盖，不覆盖对端已有结果）")
    func lyricsResendRoundKeepsBothSides() throws {
        let song = Data(repeating: 0x73, count: 4_096)
        let hash = try contentHash(of: song)

        let fixture = SessionFixture.pairedHandshake()
        let deviceRoot = try tempRoot("keep-device")
        try writeFile("Album/A.flac", in: deviceRoot, data: song)
        let deviceLyrics = AlignedLyricsStore(directory: try tempRoot("keep-device-lyrics"))
        try deviceLyrics.write(sampleLyrics("设备侧版本"), forStableId: "dev-sid")
        let deviceManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try deviceManager.createTables()
        let deviceHost = SyncLibraryPassiveHost(
            libraryRoot: deviceRoot,
            sink: LyricsSinkSpy(),
            database: deviceManager,
            lyricsStore: deviceLyrics,
            lyricsMapping: mapping(["dev-sid": hash])
        )
        _ = deviceHost.attach(to: fixture.clientSession)

        let macRoot = try tempRoot("keep-mac")
        let macLyrics = AlignedLyricsStore(directory: try tempRoot("keep-mac-lyrics"))
        try macLyrics.write(sampleLyrics("Mac 侧版本"), forStableId: "mac-sid")
        let macManager = DatabaseManager(dbWriter: try DatabaseQueue())
        try macManager.createTables()
        let macMapping = mapping(["mac-sid": hash])
        let descriptor = SyncLocalLibraryDescriptor(
            libraryRoot: macRoot,
            rootName: "测试 Mac 曲库",
            lyricsRoot: macLyrics.directory,
            sourceFiles: {
                SyncLocalLibraryScanner.sourceFiles(in: macRoot, database: macManager)
            },
            lyricsEntries: {
                SyncAlignedLyricsManifest.entries(store: macLyrics, mapping: macMapping)
            },
            contentHash: { _ in nil },
            lyricsFileName: { wirePath in
                guard let songHash = SyncLyricsNamespace.songContentHash(fromWirePath: wirePath),
                      let stableId = macMapping.stableIdForContentHash(songHash)
                else { return nil }
                return "\(stableId).json"
            }
        )
        let controller = SyncLyricsResendController(session: fixture.hostSession, descriptor: descriptor)
        try controller.start()

        guard case let .done(summary) = controller.state else {
            Issue.record("期望 done，实际 \(controller.state)")
            return
        }
        #expect(summary.pendingResend.isEmpty)
        #expect(summary.didNothing, "两侧都有 = 零动作（只补不覆盖）")
        #expect(summary.presentCount == 1)
        // 两侧各自版本原样保留，谁也没被覆盖
        #expect(try macLyrics.read(forStableId: "mac-sid")?.plainLyrics == "Mac 侧版本")
        #expect(try deviceLyrics.read(forStableId: "dev-sid")?.plainLyrics == "设备侧版本")
    }
}
