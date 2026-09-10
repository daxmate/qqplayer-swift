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

// MARK: - 落盘/删除 spy

private final class LyricsSinkSpy: SyncLibrarySyncSink, @unchecked Sendable {
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

        let provider: (String) -> String? = { wirePath in
            switch SyncLyricsNamespace.songContentHash(fromWirePath: wirePath) {
            case "s1": return "s1.json"
            case "escape": return "escape.json"
            case "outside": return "../\(outsideRoot.lastPathComponent)/secret.json"
            default: return nil
            }
        }

        let plan = SyncLibraryFetchResponder.makePlan(
            relativePaths: [
                "@lyrics/s1.json", "@lyrics/s1.json", "@lyrics/escape.json",
                "@lyrics/outside.json", "@lyrics/missing.json",
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
        let live = SyncLyricsContentMapping.live(database: manager)
        #expect(live.contentHashForStableId("sid-a") == "hash-a")
        #expect(live.stableIdForContentHash("hash-a") == "sid-a")
        #expect(live.contentHashForStableId("nope") == nil)
        #expect(live.stableIdForContentHash("nope") == nil)
    }

    // MARK: - Part B：端到端（内存回环）

    private struct Harness {
        let fixture: SessionFixture
        let sourceRoot: URL
        let targetRoot: URL
        let hostLyricsStore: AlignedLyricsStore
        let clientLyricsStore: AlignedLyricsStore
        let sink: LyricsSinkSpy
        let controller: SyncLibrarySyncController
        let hostManifestPeer: SyncManifestPeer
        let hostResponder: SyncLibraryFetchResponder
    }

    private func makeHarness(
        sourceFiles: [(String, Data)] = [],
        targetFiles: [(String, Data)] = [],
        protectedPaths: Set<String> = [],
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
                guard let hash = SyncLyricsNamespace.songContentHash(fromWirePath: wirePath),
                      let stableId = hostMapping.stableIdForContentHash(hash)
                else { return nil }
                return "\(stableId).json"
            }
        )

        let sink = LyricsSinkSpy()
        var configuration = SyncLibrarySyncConfiguration()
        configuration.protectedRelativePaths = protectedPaths
        let controller = SyncLibrarySyncController(
            session: fixture.clientSession,
            libraryRoot: targetRoot,
            sink: sink,
            configuration: configuration,
            database: clientManager,
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
            hostManifestPeer: hostManifestPeer,
            hostResponder: hostResponder
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
        #expect(!summary.deleted.contains("@lyrics/\(songHash).json"))

        // 规划层：即使全库镜像配置，歌词条目也永不进删除计划
        let plan = SyncLibrarySyncPlanner.plan(
            remote: SyncManifestResponse(entries: []),
            local: [
                ManifestEntry(relativePath: "@lyrics/\(songHash).json", size: 10, mtimeMs: 0, contentHash: "h", stableId: "client-sid"),
            ],
            configuration: SyncLibrarySyncConfiguration()
        )
        #expect(plan.deletes.isEmpty)
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
}
