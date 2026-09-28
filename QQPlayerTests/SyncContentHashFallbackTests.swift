//
//  SyncContentHashFallbackTests.swift
//  QQPlayerTests
//
//  批 B（2026-09-28「曲库命名对齐」）：
//  ① 清单 / 对账取 `content_hash` 的**唯一兜底入口** `DatabaseManager.resolvedContentHash`
//     —— 列为空且文件本地存在 → 现场计算（复用 `contentHashIfFilePresent`）**并回填 DB**；
//  ② **形状契约**：清单 / 对账链路（本端清单采集 / 本端提供者 / 对端内容清单）不得
//     绕过兜底入口直接读裸 `content_hash` 列；
//  ③ **回归**：本地存在同内容文件但行 `content_hash` 为 NULL 时，对账必须判
//     `alreadyPresent`（upload 方向 = 对端已持有同内容）——不得产生 `toFetch` / `toPush`。
//
//  背景（缺陷形状）：2026-09-28 用户报告「同一首歌 iOS 已有（旧命名），Mac 推送时仍新建
//  了一份」⇒ iOS 出现「同曲两名」重复。取指纹的三处此前各自为政：两处原地现算（复用
//  `contentHashIfFilePresent`，**不写回** ⇒ 每轮重算），一处（对端内容清单）**直接读裸列**
//  ⇒ `content_hash` 为 NULL 的曲目永远失去内容身份键 ⇒ 同曲异名判不出「已持有」⇒ 重复推送。
//
//  口径：形状契约先剥注释与字符串字面量再匹配（同 `TrackFileRenameServiceContractTests` /
//  `SyncWiringContractTests` 既有做法；不剥的话注释里写一句就骗绿）。
//  fail-closed：扫不到文件 / 入口标记缺失 = 测试失败，绝不静默跳过。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

// MARK: - 形状契约（纯逻辑，不碰文件系统；文件系统访问只在 scan(repoRoot:)）

enum SyncContentHashFallbackContract {
    /// 兜底入口的唯一实现文件（白名单 = 只留入口本身）。
    static let entryImplementationPath = "QQPlayer/Services/DatabaseManager+ContentHash.swift"

    /// 清单 / 对账链路上取 `content_hash` 的四个文件（收口前各自为政的三个消费点 + 入口）。
    /// 写死路径是刻意的：搬走 = 契约失效，得显式改这里。
    static let scanScopePaths = [
        entryImplementationPath,
        "QQPlayer/Services/DatabaseSyncPeerLibraryFacts.swift",
        "QQPlayer/Sync/SyncLocalLibraryScanner.swift",
        "QQPlayer/Sync/SyncLocalLibraryProvider.swift",
    ]

    /// 允许出现 `.contentHash` 属性读的**接收者**（白名单只留入口本身的两处投影：
    /// 本端提供者的描述符属性赋值 / 闭包调用）。任何转义名（`track` / `row` / `t` …）
    /// 都算「直接读裸列」。
    static let allowedReceivers: Set<String> = ["self", "descriptor"]

    /// 属性读标记（带点：`track.contentHash`）。
    static let propertyMarker = ".contentHash"

    /// 兜底入口必须真的在做的三件事（缺任一 = 白名单空转）。
    static let entryMarkers = [
        "func resolvedContentHash(",
        "contentHashIfFilePresent(",
        "UPDATE track SET content_hash",
    ]

    /// 剥掉注释（行 / 块）与字符串字面量，只留代码。
    static func codeOnly(_ source: String) -> String {
        var out = ""
        var i = source.startIndex
        let end = source.endIndex
        var inString = false
        var inBlockComment = false
        var inLineComment = false
        while i < end {
            let c = source[i]
            let nextIndex = source.index(after: i)
            let next: Character = nextIndex < end ? source[nextIndex] : "\0"
            if inLineComment {
                if c == "\n" { inLineComment = false; out.append(c) }
            } else if inBlockComment {
                if c == "*", next == "/" {
                    inBlockComment = false
                    i = nextIndex
                }
            } else if inString {
                if c == "\\" {
                    i = nextIndex
                } else if c == "\"" {
                    inString = false
                }
            } else if c == "/", next == "/" {
                inLineComment = true
                i = nextIndex
            } else if c == "/", next == "*" {
                inBlockComment = true
                i = nextIndex
            } else if c == "\"" {
                inString = true
            } else {
                out.append(c)
            }
            i = source.index(after: i)
        }
        return out
    }

    /// 代码域里 `.contentHash` 属性读的**接收者**标识符（`track?.contentHash` → `track?`）。
    static func contentHashReadReceivers(inCode code: String) -> [String] {
        var receivers: [String] = []
        var searchStart = code.startIndex
        while let found = code.range(of: propertyMarker, range: searchStart ..< code.endIndex) {
            searchStart = found.upperBound
            var cursor = found.lowerBound
            var chars: [Character] = []
            while cursor > code.startIndex {
                let previous = code[code.index(before: cursor)]
                guard previous.isLetter || previous.isNumber || previous == "_" || previous == "?" else { break }
                chars.insert(previous, at: 0)
                cursor = code.index(before: cursor)
            }
            receivers.append(String(chars))
        }
        return receivers
    }

    /// 纯函数：一份源码里违禁的裸列读（空 = 该文件合规）。
    static func violations(inSource source: String, relativePath: String) -> [String] {
        guard relativePath != entryImplementationPath else { return [] }
        let code = codeOnly(source)
        return contentHashReadReceivers(inCode: code)
            .filter { !allowedReceivers.contains($0) }
            .map { "直接读裸 content_hash 列：`\($0.isEmpty ? "?." : $0 + ".")contentHash`" }
    }

    struct ScanResult {
        var scannedFiles = 0
        /// 违禁明细（`相对路径 → 标记`）
        var violations: [String] = []
        /// 入口文件是否真的实现了兜底（false = 白名单空转，必须失败）
        var entryImplementsFallback = false
    }

    /// 生产码定点扫描（文件系统访问只在这里；fail-closed 由调用方断言 `scannedFiles`）。
    static func scan(repoRoot: URL) -> ScanResult {
        var result = ScanResult()
        for relativePath in scanScopePaths {
            let url = repoRoot.appendingPathComponent(relativePath)
            guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                result.violations.append("\(relativePath)：读取失败（fail-closed，不跳过）")
                continue
            }
            result.scannedFiles += 1
            if relativePath == entryImplementationPath {
                result.entryImplementsFallback = entryMarkers.allSatisfy { source.contains($0) }
            }
            result.violations += violations(inSource: source, relativePath: relativePath)
                .map { "\(relativePath) → \($0)" }
        }
        return result
    }
}

// MARK: - 形状契约测试

struct SyncContentHashFallbackContractTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @Test("清单/对账取指纹只有一处兜底入口（白名单 = 入口实现文件；别处不得裸读 content_hash）")
    func manifestPathUsesSingleFallbackEntry() {
        let result = SyncContentHashFallbackContract.scan(repoRoot: Self.repoRoot)
        #expect(
            result.scannedFiles == SyncContentHashFallbackContract.scanScopePaths.count,
            "清单/对账链路文件没扫全 = 契约空转：扫到 \(result.scannedFiles)"
        )
        #expect(
            result.entryImplementsFallback,
            """
            白名单文件 \(SyncContentHashFallbackContract.entryImplementationPath) 里找不到兜底实现标记
            \(SyncContentHashFallbackContract.entryMarkers)——契约空转保护失效（入口被改名/搬走？）。
            """
        )
        #expect(
            result.violations.isEmpty,
            """
            清单/对账链路里出现了绕过兜底入口的裸 `content_hash` 读
            （唯一入口 = \(SyncContentHashFallbackContract.entryImplementationPath) 的
            `resolvedContentHash(forTrack:atPath:)`）：
            \(result.violations.joined(separator: "\n"))

            修法：改为 `database.resolvedContentHash(forTrack: track, atPath: <曲库路径>)`
            （列为空 → 现场计算 + 回填 DB；哈希实现只有 `contentHashIfFilePresent` 一处）。
            """
        )
    }

    @Test("合成裸读必须被抓到（契约自证有效）；注释/字符串不算")
    func syntheticBareReadIsCaught() {
        let bareRead = """
        for track in tracks {
            items.append(Item(contentHash: normalizedHash(track.contentHash)))
        }
        """
        #expect(
            SyncContentHashFallbackContract.violations(
                inSource: bareRead,
                relativePath: "QQPlayer/Services/DatabaseSyncPeerLibraryFacts.swift"
            ).count == 1,
            "裸读 track.contentHash 必须被抓到"
        )
        let optionalRead = "let hash = track?.contentHash?.isEmpty == false ? track?.contentHash : nil"
        #expect(
            SyncContentHashFallbackContract.violations(
                inSource: optionalRead,
                relativePath: "QQPlayer/Sync/SyncLocalLibraryScanner.swift"
            ).count == 2,
            "可选链裸读（track?.contentHash）必须被抓到，实际 \(SyncContentHashFallbackContract.contentHashReadReceivers(inCode: SyncContentHashFallbackContract.codeOnly(optionalRead)))"
        )

        // 收敛后的写法 + 入口自身的属性/闭包投影：不得误报
        let converged = """
        let contentHash = database.resolvedContentHash(forTrack: track, atPath: track.path)
        self.contentHash = contentHash
        self?.descriptor.contentHash(relativePath)
        """
        #expect(
            SyncContentHashFallbackContract.violations(
                inSource: converged,
                relativePath: "QQPlayer/Sync/SyncLocalLibraryProvider.swift"
            ).isEmpty,
            "兜底入口调用与描述符自身属性不得误报"
        )

        // 注释 / 字符串里的不算
        let commented = """
        // 旧写法：let hash = track.contentHash
        /* let hash = track.contentHash */
        let note = "track.contentHash"
        """
        #expect(
            SyncContentHashFallbackContract.violations(
                inSource: commented,
                relativePath: "QQPlayer/Sync/SyncLocalLibraryScanner.swift"
            ).isEmpty,
            "注释/字符串里的裸读不算（剥注释与字符串后判定）"
        )

        // 白名单文件自身必须放行
        #expect(
            SyncContentHashFallbackContract.violations(
                inSource: bareRead,
                relativePath: SyncContentHashFallbackContract.entryImplementationPath
            ).isEmpty,
            "入口实现文件里读行自身列是兜底实现的一部分，必须放行"
        )
    }
}

// MARK: - 行为：兜底入口

struct SyncContentHashFallbackBehaviorTests {
    private struct Fixture {
        let manager: DatabaseManager
        let libraryRoot: URL
    }

    private func makeFixture(_ tag: String) throws -> Fixture {
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        try manager.createTables()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqp-hash-fallback-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Fixture(manager: manager, libraryRoot: root)
    }

    /// 建行时文件**还不存在** ⇒ `upsertTrack` 的入库自动指纹取不到值 ⇒ 该行 `content_hash` 为 NULL
    /// （正是线上「惰性回填未跑到 / 云端跳过」的形态）。
    private func insertTrackWithNullHash(
        _ fixture: Fixture,
        stableId: String,
        relativePath: String
    ) throws -> Track {
        let track = Track(
            stableId: stableId,
            title: "T-\(stableId)",
            path: fixture.libraryRoot.appendingPathComponent(relativePath).path,
            contentHash: nil
        )
        try fixture.manager.upsertTrack(track)
        return track
    }

    private func storedHash(_ manager: DatabaseManager, stableId: String) throws -> String? {
        try manager.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT content_hash FROM track WHERE stable_id = ? LIMIT 1",
                arguments: [stableId]
            )
        }
    }

    @Test("兜底入口：列为空 + 文件本地存在 → 现算并回填 DB（下一轮不必重算）")
    func resolvesNullHashAndWritesBack() throws {
        let fixture = try makeFixture("writeback")
        defer { try? FileManager.default.removeItem(at: fixture.libraryRoot) }
        let track = try insertTrackWithNullHash(fixture, stableId: "s1", relativePath: "旧名.mp3")
        let fileURL = fixture.libraryRoot.appendingPathComponent("旧名.mp3")
        try Data("same-bytes".utf8).write(to: fileURL)

        #expect(try storedHash(fixture.manager, stableId: "s1") == nil, "前置：该行指纹应为 NULL")

        let expected = try SyncFileChecksum.sha256Hex(ofFile: fileURL)
        let resolved = fixture.manager.resolvedContentHash(forTrack: track, atPath: fileURL.path)
        #expect(resolved == expected, "兜底入口应现场算出与文件一致的指纹")

        let written = try #require(try storedHash(fixture.manager, stableId: "s1"))
        #expect(written == expected, "兜底入口必须把现算指纹回填 DB（避免每轮重算）")
    }

    @Test("兜底入口：列已有值直接返回（不回读文件）；无行 / 文件不存在 → nil")
    func resolvesStoredValueAndMissingCases() throws {
        let fixture = try makeFixture("stored")
        defer { try? FileManager.default.removeItem(at: fixture.libraryRoot) }
        let track = try insertTrackWithNullHash(fixture, stableId: "s2", relativePath: "x.mp3")
        try FileManager.default.createDirectory(
            at: fixture.libraryRoot.appendingPathComponent("sub"),
            withIntermediateDirectories: true
        )
        try Data("bytes".utf8).write(to: fixture.libraryRoot.appendingPathComponent("x.mp3"))
        let computed = try #require(fixture.manager.resolvedContentHash(forTrack: track, atPath: track.path))

        var stored = track
        stored.contentHash = computed
        #expect(
            fixture.manager.resolvedContentHash(forTrack: stored, atPath: "/definitely/missing.mp3") == computed,
            "列已有值必须直接返回，不因路径不可读而丢身份键"
        )

        #expect(
            fixture.manager.resolvedContentHash(forTrack: nil, atPath: "/definitely/missing.mp3") == nil,
            "无行且文件不存在 → nil（不抛、不编造）"
        )
        #expect(
            fixture.manager.resolvedContentHash(forTrack: nil, atPath: "") == nil,
            "空路径且无行 → nil"
        )
    }

    @Test("回归：对端行指纹为 NULL 但文件同内容 → 对账判 alreadyPresent（不产生 toFetch / toPush）")
    func nullPeerHashStillDeduplicatesByContent() throws {
        let fixture = try makeFixture("reconcile")
        defer { try? FileManager.default.removeItem(at: fixture.libraryRoot) }
        // iOS 侧形态：旧名文件 + 指纹 NULL
        let track = try insertTrackWithNullHash(fixture, stableId: "s3", relativePath: "爱相随-周华健.mp3")
        let legacyURL = fixture.libraryRoot.appendingPathComponent("爱相随-周华健.mp3")
        try Data("identical-audio-bytes".utf8).write(to: legacyURL)
        let hash = try SyncFileChecksum.sha256Hex(ofFile: legacyURL)

        // 对端清单（= 本端扫描采集，走兜底入口）——收口前这里会带 nil 指纹
        let remote = SyncLocalLibraryScanner.entries(
            in: fixture.libraryRoot,
            database: fixture.manager
        )
        let remoteEntry = try #require(remote.first { $0.relativePath == "爱相随-周华健.mp3" })
        #expect(remoteEntry.contentHash == hash, "对端清单必须带兜底算出的身份键")
        #expect(try storedHash(fixture.manager, stableId: track.stableId) == hash, "清单采集即回填 DB")

        // Mac 侧形态：规范名、同一内容
        let local = [
            ManifestEntry(
                relativePath: "周华健 - 爱相随.mp3",
                size: Int64("identical-audio-bytes".utf8.count),
                mtimeMs: 0,
                contentHash: hash,
                stableId: "mac-s3"
            ),
        ]

        // 拉取方向对账：远端有规范名、本端只有旧名 → 按内容身份判已持有
        let reconciliation = SyncManifestReconciler.reconcile(remote: local, local: remote)
        #expect(reconciliation.toFetch.isEmpty, "同内容异路径不得判 toFetch（否则会重复落盘）")
        #expect(reconciliation.alreadyPresent.map(\.relativePath) == ["周华健 - 爱相随.mp3"])

        // 推送方向对账（Mac 推送）同样按内容身份跳过
        let pushPlan = SyncLibraryPushPlanner.plan(local: local, remote: remote)
        #expect(pushPlan.toPush.isEmpty, "对端已持有同内容 → 不得再推（重复推送的根因）")
        #expect(pushPlan.alreadyPresent.map(\.relativePath) == ["周华健 - 爱相随.mp3"])
    }

    @Test("回归：对端内容清单（帧 16）必须带兜底算出的身份键（收口前这里是裸读列）")
    func peerLibraryCatalogCarriesComputedHash() throws {
        let fixture = try makeFixture("catalog")
        defer { try? FileManager.default.removeItem(at: fixture.libraryRoot) }
        _ = try insertTrackWithNullHash(fixture, stableId: "s4", relativePath: "开不了口-周杰伦.mp3")
        let fileURL = fixture.libraryRoot.appendingPathComponent("开不了口-周杰伦.mp3")
        try Data("catalog-bytes".utf8).write(to: fileURL)
        let hash = try SyncFileChecksum.sha256Hex(ofFile: fileURL)

        let facts = DatabaseSyncPeerLibraryFacts(
            database: fixture.manager,
            libraryRoot: fixture.libraryRoot
        )
        let catalog = facts.catalog()
        let item = try #require(catalog.tracks.first { $0.relativePath == "开不了口-周杰伦.mp3" })
        #expect(
            item.contentHash == hash,
            "对端内容清单的曲目必须带兜底算出的身份键（否则「从设备浏览/选择」判不出同曲）"
        )
        #expect(try storedHash(fixture.manager, stableId: "s4") == hash, "取清单即回填 DB")
    }
}
