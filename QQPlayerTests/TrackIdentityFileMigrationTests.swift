//
//  TrackIdentityFileMigrationTests.swift
//  QQPlayerTests
//
//  stableId 文件侧迁移（`TrackIdentityMigration.migrateFileReferences`，按设计在**事务外**调用）
//  的**报告语义**回归。
//
//  为什么单开一个文件：`DataIntegrityMigrationTests.swift` 里已有套件只锁了**一条正确分支**
//  （歌词目标已存在 → 不覆盖、不删源）；覆盖缺口审计 P1-3 点名的其余面全裸奔——报告各计数、
//  `skipped` 的三种取值、失败路径（不抛 + 已成功项保留）、幂等、库根外文件不误伤。
//  这正是"迁移散落六处、各迁一部分"那类事故的形状：**计数错了没人发现**，静默漏迁
//  一路滑到用户丢歌词（QQPlay…tion.swift 头部记的真实事故）。
//
//  套件名与既有同名结构体错开（Swift 同模块内不能重名）：既有那个（`DataIntegrityMigrationTests.swift`
//  的 `TrackIdentityFileMigrationTests`）按审计条目 D1–D8 组织，留在原文件不动；本文件的套件叫
//  `TrackIdentityFileMigrationReportTests`，只管文件侧整体报告语义。
//
//  **与既有 D3 的去重（移植时逐条对表，避免第二份实现）**：
//   · D3「书签键 + 三个歌词目录一起跟随新 stableId」已覆盖：笔数 / 落盘文件改名与旧文件消失 /
//     书签 plist 内容。→ 本文件对应用例**只保留它没锁的边际**：`artworkKeysRenamed` 计数，
//     以及「搬过去的内容确实是各自那一份」（D3 只查存在性，不查内容）。
//   · D3「歌词目标文件已存在时不覆盖、不删源」已覆盖：`skipped.contains`、源/目标字节不变。
//     → 本文件对应用例**改为只断言报告计数语义**（`skipped` 全等恰一条、各计数为 0、无事不写 plist）。
//   · D3「封面映射键纯函数」已覆盖 `remappedArtworkMapping` → 本文件不重复测纯函数，
//     只锁 `artworkKeysRenamed` 是**计划数**（= 有效映射条数）这一既有口径。
//
//  全部用临时目录搭真实文件树直测：入口非 throwing、`documentsURL` 可注入，不需要
//  真实库 / GRDB / UI。
//
//  注意：`#expect` 宏体不接受 `try`（宏展开成非 throwing 闭包）→ 断言一律先把取值
//  try 到局部变量，或走非 throwing 的本地 helper。
//
//  本文件从 a0e5faf（分支 test/coverage-gaps-p1）适配到 main @ 50f8a9b：
//  `TrackIdentityMigration.migrateFileReferences(from:to:documentsURL:)` /
//  `(remapping:documentsURL:)`、`TrackIdentityFileMigrationReport`、
//  `ExternalFileBookmarkStore(documentsURL:)` + `upsert(_:forStableId:)` /
//  `loadedBookmarksOrEmpty()` / `fileURL`、`LyricsStoreKind.directoryName/allCases`
//  逐个核对一致（skipped 字符串格式 `manual:targetExists` / `manual:renameFailed` /
//  `bookmarks:readFailed` 亦一致）。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - Fixture（临时"库根" + 真实文件树）

private enum FileMigrationFixture {
    static let oldId = "old-id"
    static let newId = "new-id"

    /// 临时库根（代替 Documents）。每次调用独立 → 测试可并行、互不干扰。
    static func makeLibraryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-track-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func lyricsURL(libraryRoot: URL, kind: LyricsStoreKind, stableId: String) -> URL {
        libraryRoot
            .appendingPathComponent(kind.directoryName, isDirectory: true)
            .appendingPathComponent("\(stableId).json")
    }

    /// 落一份歌词文件。目录名取 `LyricsStoreKind` 单一事实源（network 是嵌套路径 lyrics-cache/tracks，
    /// 靠 intermediate 建目录）——测试不写死目录名，生产改了目录名这里跟着走。
    static func writeLyrics(libraryRoot: URL, kind: LyricsStoreKind, stableId: String) throws {
        let url = lyricsURL(libraryRoot: libraryRoot, kind: kind, stableId: stableId)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents(for: stableId, kind: kind).utf8).write(to: url)
    }

    /// 内容带 stableId + kind：断言能同时看出"搬没搬"和"搬的是哪一份"。
    static func contents(for stableId: String, kind: LyricsStoreKind) -> String {
        "\(stableId)-\(kind.rawValue)"
    }

    static func data(at url: URL) -> Data? {
        try? Data(contentsOf: url)
    }

    static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// MARK: - 文件侧迁移：报告语义

@Suite("stableId 文件侧迁移：报告计数 / skipped / 失败路径 / 幂等")
struct TrackIdentityFileMigrationReportTests {
    @Test("五处目标全成功：报告计数逐一相等（书签 1 / 歌词 3 / 封面 1）、skipped 为空、搬的是各自那一份")
    func allFiveTargetsSucceedWithExactCounts() throws {
        let libraryRoot = try FileMigrationFixture.makeLibraryRoot()
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let store = ExternalFileBookmarkStore(documentsURL: libraryRoot)
        try store.upsert(Data("bookmark".utf8), forStableId: FileMigrationFixture.oldId)
        for kind in LyricsStoreKind.allCases {
            try FileMigrationFixture.writeLyrics(
                libraryRoot: libraryRoot,
                kind: kind,
                stableId: FileMigrationFixture.oldId
            )
        }

        let report = TrackIdentityMigration.migrateFileReferences(
            from: FileMigrationFixture.oldId,
            to: FileMigrationFixture.newId,
            documentsURL: libraryRoot
        )

        // 计数必须逐一相等（不是"调用后没抛异常"）：漏迁一整个目录 = lyricsFilesRenamed 少 1；
        // 封面项是**计划数**（有效映射条数），漏给映射 = artworkKeysRenamed 少 1。
        #expect(report.bookmarksRenamed == 1)
        #expect(report.lyricsFilesRenamed == LyricsStoreKind.allCases.count)
        #expect(report.artworkKeysRenamed == 1)
        #expect(report.skipped.isEmpty)

        // D3 只查了「新 id 文件在、旧 id 文件没了」；这里补它没锁的边际：**内容跟着各自的源走**，
        // 三个目录之间不会串号（串号 = 用户听到别人的歌词，且计数仍然是 3 看不出来）。
        for kind in LyricsStoreKind.allCases {
            let moved = FileMigrationFixture.lyricsURL(
                libraryRoot: libraryRoot,
                kind: kind,
                stableId: FileMigrationFixture.newId
            )
            let expected = FileMigrationFixture.contents(for: FileMigrationFixture.oldId, kind: kind)
            let actual = FileMigrationFixture.data(at: moved)
            #expect(actual == Data(expected.utf8), "\(kind.rawValue)：搬过去的必须是本目录那一份")
        }
    }

    @Test("源在 + 目标在：报告计数语义——恰一条 skipped、各计数为 0、无事不写书签 plist")
    func existingTargetIsSkippedAndSourceIsKept() throws {
        let libraryRoot = try FileMigrationFixture.makeLibraryRoot()
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let store = ExternalFileBookmarkStore(documentsURL: libraryRoot)
        try FileMigrationFixture.writeLyrics(libraryRoot: libraryRoot, kind: .manual, stableId: FileMigrationFixture.oldId)

        let report = TrackIdentityMigration.migrateFileReferences(
            from: FileMigrationFixture.oldId,
            to: FileMigrationFixture.newId,
            documentsURL: libraryRoot
        )

        #expect(report.lyricsFilesRenamed == 0)
        // 恰一条：按"项"记，不按 kind 重复；字符串用全等锁住既有格式
        // （D3 用的是 `.contains`，锁不住"多记了几条"）。
        #expect(report.skipped == ["manual:targetExists"])
        #expect(report.bookmarksRenamed == 0)
        // 无事可迁时不写 plist（没有可迁移的键 → 不该留下空文件）。
        #expect(!FileMigrationFixture.exists(store.fileURL))
    }

    @Test("歌词目录不可写：不抛错、已成功项保留、失败项进 skipped（renameFailed），失败项源文件不丢")
    func unwritableLyricsDirectoryFailsWithoutRollingBackSuccesses() throws {
        let libraryRoot = try FileMigrationFixture.makeLibraryRoot()
        let manualDirectory = libraryRoot.appendingPathComponent(
            LyricsStoreKind.manual.directoryName,
            isDirectory: true
        )
        defer {
            // 先恢复写权限再删：否则临时目录连清理都清不掉
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: manualDirectory.path
            )
            try? FileManager.default.removeItem(at: libraryRoot)
        }

        let store = ExternalFileBookmarkStore(documentsURL: libraryRoot)
        try store.upsert(Data("bookmark".utf8), forStableId: FileMigrationFixture.oldId)
        try FileMigrationFixture.writeLyrics(libraryRoot: libraryRoot, kind: .aligned, stableId: FileMigrationFixture.oldId)
        try FileMigrationFixture.writeLyrics(libraryRoot: libraryRoot, kind: .manual, stableId: FileMigrationFixture.oldId)
        // network 目录根本不建 → 源不存在：既不算成功也不算失败
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: manualDirectory.path
        )

        let report = TrackIdentityMigration.migrateFileReferences(
            from: FileMigrationFixture.oldId,
            to: FileMigrationFixture.newId,
            documentsURL: libraryRoot
        )

        #expect(report.skipped == ["manual:renameFailed"])
        #expect(report.lyricsFilesRenamed == 1)   // aligned 那份留住了，没被回滚
        #expect(report.bookmarksRenamed == 1)     // 书签不受歌词目录故障牵连

        let alignedExpected = FileMigrationFixture.contents(for: FileMigrationFixture.oldId, kind: .aligned)
        let alignedMoved = FileMigrationFixture.lyricsURL(
            libraryRoot: libraryRoot,
            kind: .aligned,
            stableId: FileMigrationFixture.newId
        )
        let alignedSource = FileMigrationFixture.lyricsURL(
            libraryRoot: libraryRoot,
            kind: .aligned,
            stableId: FileMigrationFixture.oldId
        )
        let alignedActual = FileMigrationFixture.data(at: alignedMoved)
        #expect(alignedActual == Data(alignedExpected.utf8))
        #expect(!FileMigrationFixture.exists(alignedSource))

        // 失败项：源文件仍在（用户歌词没被"改名失败"带走）
        let manualSource = FileMigrationFixture.lyricsURL(
            libraryRoot: libraryRoot,
            kind: .manual,
            stableId: FileMigrationFixture.oldId
        )
        let manualActual = FileMigrationFixture.data(at: manualSource)
        let manualExpected = FileMigrationFixture.contents(for: FileMigrationFixture.oldId, kind: .manual)
        #expect(manualActual == Data(manualExpected.utf8))
        let bookmarks = store.loadedBookmarksOrEmpty()
        #expect(bookmarks[FileMigrationFixture.newId] == Data("bookmark".utf8))
    }

    @Test("书签 plist 读不出来：记 readFailed、不计成功、坏 plist 原样保留、且不阻断歌词迁移")
    func corruptBookmarkPlistIsReportedAndDoesNotBlockLyrics() throws {
        let libraryRoot = try FileMigrationFixture.makeLibraryRoot()
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let store = ExternalFileBookmarkStore(documentsURL: libraryRoot)
        let garbage = Data("this is not a plist".utf8)
        try garbage.write(to: store.fileURL)
        for kind in LyricsStoreKind.allCases {
            try FileMigrationFixture.writeLyrics(
                libraryRoot: libraryRoot,
                kind: kind,
                stableId: FileMigrationFixture.oldId
            )
        }

        let report = TrackIdentityMigration.migrateFileReferences(
            from: FileMigrationFixture.oldId,
            to: FileMigrationFixture.newId,
            documentsURL: libraryRoot
        )

        #expect(report.bookmarksRenamed == 0)
        #expect(report.skipped == ["bookmarks:readFailed"])
        // 关键：书签分支的异常不能吞掉后面的歌词迁移（这里若为 0 就说明失败把后续项短路了）
        #expect(report.lyricsFilesRenamed == LyricsStoreKind.allCases.count)
        // 读失败不写：坏 plist 保留原字节，不用空字典抹掉还能救的书签
        #expect(FileMigrationFixture.data(at: store.fileURL) == garbage)
    }

    @Test("重跑幂等：第二次文件与书签计数归零、skipped 仍为空")
    func rerunIsIdempotentForFilesAndBookmarks() throws {
        let libraryRoot = try FileMigrationFixture.makeLibraryRoot()
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let store = ExternalFileBookmarkStore(documentsURL: libraryRoot)
        try store.upsert(Data("bookmark".utf8), forStableId: FileMigrationFixture.oldId)
        for kind in LyricsStoreKind.allCases {
            try FileMigrationFixture.writeLyrics(
                libraryRoot: libraryRoot,
                kind: kind,
                stableId: FileMigrationFixture.oldId
            )
        }

        let first = TrackIdentityMigration.migrateFileReferences(
            from: FileMigrationFixture.oldId,
            to: FileMigrationFixture.newId,
            documentsURL: libraryRoot
        )
        #expect(first.bookmarksRenamed == 1)
        #expect(first.lyricsFilesRenamed == LyricsStoreKind.allCases.count)
        #expect(first.skipped.isEmpty)

        let second = TrackIdentityMigration.migrateFileReferences(
            from: FileMigrationFixture.oldId,
            to: FileMigrationFixture.newId,
            documentsURL: libraryRoot
        )
        #expect(second.bookmarksRenamed == 0)
        #expect(second.lyricsFilesRenamed == 0)
        #expect(second.skipped.isEmpty)   // 重跑不产生 false positive 的 skip
        // ⚠️ 封面项例外：`artworkKeysRenamed` 是**计划数**（= 有效映射条数），不是实际改名数
        //    （TrackIdentityMigration.swift:190 直接赋 artworkRemapping.count；真正落盘由
        //    ArtworkManager 在 MainActor 上异步做）。所以重跑它仍是 1 —— 这里锁的是既有口径，
        //    不是"幂等"；口径若改成实际数，这条会红，改动用例的人应当先看清这个区别。
        #expect(second.artworkKeysRenamed == 1)

        // 落盘幂等：第二次之后文件仍是新 id 的那份（没有被二次改名/清掉）
        for kind in LyricsStoreKind.allCases {
            let moved = FileMigrationFixture.lyricsURL(
                libraryRoot: libraryRoot,
                kind: kind,
                stableId: FileMigrationFixture.newId
            )
            let expected = FileMigrationFixture.contents(for: FileMigrationFixture.oldId, kind: kind)
            let actual = FileMigrationFixture.data(at: moved)
            #expect(actual == Data(expected.utf8))
        }
    }

    @Test("库根外 / 非歌词目录里的同名文件：不改名、也不计失败")
    func filesOutsideLyricsStoreRootsAreUntouched() throws {
        let libraryRoot = try FileMigrationFixture.makeLibraryRoot()
        let outsideRoot = try FileMigrationFixture.makeLibraryRoot()
        defer {
            try? FileManager.default.removeItem(at: libraryRoot)
            try? FileManager.default.removeItem(at: outsideRoot)
        }

        // (a) 库根之外的同名文件（外部位置）
        let outsideFile = outsideRoot.appendingPathComponent("\(FileMigrationFixture.oldId).json")
        try Data("outside-root".utf8).write(to: outsideFile)

        // (b) 库根内、但不在 LyricsStoreKind 三个目录里的同名文件
        let strayDirectory = libraryRoot.appendingPathComponent("lyrics-legacy", isDirectory: true)
        try FileMigrationFixture.makeDirectory(strayDirectory)
        let strayInDirectory = strayDirectory.appendingPathComponent("\(FileMigrationFixture.oldId).json")
        try Data("stray-directory".utf8).write(to: strayInDirectory)

        // (c) 库根根目录下散落的同名文件
        let strayAtRoot = libraryRoot.appendingPathComponent("\(FileMigrationFixture.oldId).json")
        try Data("stray-root".utf8).write(to: strayAtRoot)

        // 只有 aligned 是"真"歌词文件 → 只该它动
        try FileMigrationFixture.writeLyrics(libraryRoot: libraryRoot, kind: .aligned, stableId: FileMigrationFixture.oldId)

        let report = TrackIdentityMigration.migrateFileReferences(
            from: FileMigrationFixture.oldId,
            to: FileMigrationFixture.newId,
            documentsURL: libraryRoot
        )

        #expect(report.lyricsFilesRenamed == 1)
        #expect(report.skipped.isEmpty)   // 不在迁移面上的文件既不该动，也不该被算作失败
        #expect(FileMigrationFixture.data(at: outsideFile) == Data("outside-root".utf8))
        #expect(FileMigrationFixture.data(at: strayInDirectory) == Data("stray-directory".utf8))
        #expect(FileMigrationFixture.data(at: strayAtRoot) == Data("stray-root".utf8))
        #expect(!FileMigrationFixture.exists(outsideRoot.appendingPathComponent("\(FileMigrationFixture.newId).json")))
    }

    @Test("批量映射：每一对都算数，恒等对（old == new）整对跳过且不产生 skip 噪音")
    func batchRemappingCountsEveryPairAndIgnoresIdentityPairs() throws {
        let libraryRoot = try FileMigrationFixture.makeLibraryRoot()
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let store = ExternalFileBookmarkStore(documentsURL: libraryRoot)
        try store.upsert(Data("bookmark-a1".utf8), forStableId: "a1")
        try store.upsert(Data("bookmark-a2".utf8), forStableId: "a2")
        for kind in LyricsStoreKind.allCases {
            try FileMigrationFixture.writeLyrics(libraryRoot: libraryRoot, kind: kind, stableId: "a1")
            try FileMigrationFixture.writeLyrics(libraryRoot: libraryRoot, kind: kind, stableId: "a2")
            try FileMigrationFixture.writeLyrics(libraryRoot: libraryRoot, kind: kind, stableId: "same-id")
        }

        let report = TrackIdentityMigration.migrateFileReferences(
            remapping: ["a1": "b1", "a2": "b2", "same-id": "same-id"],
            documentsURL: libraryRoot
        )

        #expect(report.bookmarksRenamed == 2)
        #expect(report.lyricsFilesRenamed == 2 * LyricsStoreKind.allCases.count)
        #expect(report.artworkKeysRenamed == 2)   // 恒等对不计入（覆盖缺口审计里"计数要逐对相等"）
        #expect(report.skipped.isEmpty)

        // 两对各自搬对：内容跟着各自的源走，没串号
        for kind in LyricsStoreKind.allCases {
            for (sourceId, destinationId) in [("a1", "b1"), ("a2", "b2")] {
                let moved = FileMigrationFixture.lyricsURL(
                    libraryRoot: libraryRoot,
                    kind: kind,
                    stableId: destinationId
                )
                let expected = FileMigrationFixture.contents(for: sourceId, kind: kind)
                let actual = FileMigrationFixture.data(at: moved)
                #expect(actual == Data(expected.utf8))
            }
        }
        // 恒等对的文件原地不动、也没被当成"目标已存在"跳过
        let identityFile = FileMigrationFixture.lyricsURL(
            libraryRoot: libraryRoot,
            kind: .manual,
            stableId: "same-id"
        )
        #expect(FileMigrationFixture.data(at: identityFile) == Data("same-id-manual".utf8))
    }

    @Test("无事可做：空映射 / 恒等映射 / 源不存在 → 全零、skipped 空、不建目录、不写 plist")
    func noOpRemappingsLeaveFileSystemUntouched() throws {
        let libraryRoot = try FileMigrationFixture.makeLibraryRoot()
        defer { try? FileManager.default.removeItem(at: libraryRoot) }

        let store = ExternalFileBookmarkStore(documentsURL: libraryRoot)

        // (a) 空映射：早退，报告就是初始值
        let empty = TrackIdentityMigration.migrateFileReferences(remapping: [:], documentsURL: libraryRoot)
        #expect(empty.bookmarksRenamed == 0)
        #expect(empty.lyricsFilesRenamed == 0)
        #expect(empty.artworkKeysRenamed == 0)
        #expect(empty.skipped.isEmpty)

        // (b) 恒等映射：三个分支都按 `where oldStableId != newStableId` 过滤 → 不动文件、不记 skip
        try FileMigrationFixture.writeLyrics(libraryRoot: libraryRoot, kind: .manual, stableId: "same-id")
        let identity = TrackIdentityMigration.migrateFileReferences(
            remapping: ["same-id": "same-id"],
            documentsURL: libraryRoot
        )
        #expect(identity.lyricsFilesRenamed == 0)
        #expect(identity.artworkKeysRenamed == 0)
        #expect(identity.skipped.isEmpty)
        let identityFile = FileMigrationFixture.lyricsURL(
            libraryRoot: libraryRoot,
            kind: .manual,
            stableId: "same-id"
        )
        #expect(FileMigrationFixture.data(at: identityFile) == Data("same-id-manual".utf8))

        // (c) 源文件根本不存在（歌词目录没建）：无事发生，也不算失败
        let missingSource = TrackIdentityMigration.migrateFileReferences(
            from: "ghost-id",
            to: FileMigrationFixture.newId,
            documentsURL: libraryRoot
        )
        #expect(missingSource.bookmarksRenamed == 0)
        #expect(missingSource.lyricsFilesRenamed == 0)
        #expect(missingSource.skipped.isEmpty)
        // ⚠️ 反直觉但真实：封面项与磁盘无关（= 有效映射条数，TrackIdentityMigration.swift:190），
        //    所以这里没有封面文件也照样计 1。
        #expect(missingSource.artworkKeysRenamed == 1)
        #expect(!FileMigrationFixture.exists(store.fileURL))
        // 不替不存在的歌词目录建空壳（只有 (b) 建的 manual 存在）
        for kind in LyricsStoreKind.allCases where kind != .manual {
            let directory = libraryRoot.appendingPathComponent(kind.directoryName, isDirectory: true)
            #expect(!FileMigrationFixture.exists(directory))
        }
    }
}
