//
//  LibraryHiddenLayoutMigrationTests.swift
//  QQPlayerTests
//
// target: ios-only
//
//  2026-09-22「隐藏布局（v2 / v2.1）：`Documents/` 根部只留 `Music/` 可见」的回归锁。
//
//  为什么要测（每条都对应一个真实后果）：
//   · **隐藏根解析**：非曲库内容全部落 `Documents/.qqplayer/<类目>/`；散落拼接会在
//     某个调用点漏掉隐藏根 ⇒ 那个文件重新裸露在 Files/Finder 里。
//   · **`track.path` 语义不变**：仍相对 `Music` 根 —— 改坏 = 全库行解析到错误路径。
//   · **迁移器**：幂等、冲突**递归合并/改名**（绝不覆盖、绝不删除）、失败不中断且不删原件、
//     干跑只统计、完成门 —— 每一条都是「用户数据可能被搬丢」的防线。
//   · **v2.1 冲突口径**：真机 `03f867e` 失败 —— 启动期组件先建好隐藏目标目录 ⇒ 10 项全被
//     「目标已存在 ⇒ 整项跳过」留在根上。故「同名文件/同名子项 ⇒ 改名后缀搬入」
//     （`<name>.legacy-<ts>`）、「同名目录 ⇒ 逐子项递归合并」、「合并后空壳 ⇒ 改名搬进回收区」、
//     「有残留不置位完成门」各自有用例锁定。
//   · **同步协议目录**：`.sync-incoming/` 归同步链路，必须保留原位。
//   · **DB 三件套**：由 `DatabaseManager` 在打开连接前搬（移动打开中的 WAL/SHM 有风险）
//     ⇒ 迁移器必须**不碰**它们。
//   · **封面映射表**：与缓存同目录但不是缓存，改路径后仍不得被当孤儿缓存删除。
//
//  全程用临时目录 + 内存库（`LibraryRoot.documentsRootOverride` 注入），不碰真机数据、
//  不启模拟器交互；套件 `.serialized`（覆盖是进程级静态状态）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

@Suite("隐藏布局 v2：路径解析 + 根条目迁移 + 同步/DB 例外", .serialized)
struct LibraryHiddenLayoutMigrationTests {
    // MARK: - Fixture

    /// 临时 Documents 根（真实文件系统），并在用例期间把它注入 `LibraryRoot`。
    private func withDocumentsRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-hidden-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        LibraryRoot.documentsRootOverride = root
        defer {
            LibraryRoot.documentsRootOverride = nil
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
        try body(root)
    }

    private func makeManager() throws -> DatabaseManager {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        return manager
    }

    private func makeMigrator(database: DatabaseManager) -> LibraryLayoutMigrationV2Migrator {
        // UserDefaults 用独立 suite：不污染 App 的真实完成门。
        let defaults = UserDefaults(suiteName: "hidden-layout-tests-\(UUID().uuidString)") ?? .standard
        defaults.removeObject(forKey: LibraryLayoutMigrationV2Migrator.completionDefaultsKey)
        return LibraryLayoutMigrationV2Migrator(database: database, defaults: defaults)
    }

    @discardableResult
    private func writeFile(_ url: URL, bytes: Int = 8) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private let hiddenRoot = LibraryRoot.hiddenRootDirectoryName

    // MARK: - 路径解析（唯一入口）

    @Test("类目落点全部在隐藏根下；曲库根仍是 Documents/Music（唯一可见）")
    func hiddenLayoutPathsAreUnderHiddenRoot() throws {
        try withDocumentsRoot { documents in
            let music = LibraryRoot.musicRootURL()
            #expect(music == documents.appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true))

            func expectHidden(_ url: URL?, _ components: [String], isFile: Bool = false) {
                guard let url else {
                    Issue.record("路径解析失败（应可解析）")
                    return
                }
                let expected = documents
                    .appendingPathComponent(hiddenRoot, isDirectory: true)
                    .appendingPathComponent(components.joined(separator: "/"), isDirectory: !isFile)
                #expect(url.standardizedFileURL.path == expected.standardizedFileURL.path)
            }

            expectHidden(LibraryRoot.databaseDirectoryURL(), ["db"])
            expectHidden(LibraryRoot.stateDirectoryURL(), ["state"])
            expectHidden(LibraryRoot.favoritesFileURL(), ["state", "qqplayer-favorites.json"], isFile: true)
            expectHidden(LibraryRoot.playlistsDirectoryURL(), ["state", "playlists"])
            expectHidden(LibraryRoot.playerStateFileURL(), ["state", "qqplayer-player-state.json"], isFile: true)
            expectHidden(LibraryRoot.externalBookmarksFileURL(), ["state", "ExternalFileBookmarks.plist"], isFile: true)
            expectHidden(LibraryRoot.artworkDirectoryURL(), ["artwork"])
            expectHidden(LibraryRoot.artworkMappingFileURL(), ["artwork", "ArtworkMapping.plist"], isFile: true)
            expectHidden(LibraryRoot.manualLyricsDirectoryURL(), ["lyrics", "manual"])
            expectHidden(LibraryRoot.alignedLyricsDirectoryURL(), ["lyrics", "aligned"])
            expectHidden(LibraryRoot.lyricsCacheTracksDirectoryURL(), ["lyrics", "cache", "tracks"])
            expectHidden(LibraryRoot.lyricsSearchCacheDirectoryURL(), ["lyrics", "cache", "search"])
            expectHidden(LibraryRoot.logsDirectoryURL(), ["logs"])
            expectHidden(LibraryRoot.metaDirectoryURL(), ["meta"])
            expectHidden(LibraryRoot.cacheDirectoryURL(), ["cache"])
            expectHidden(LibraryRoot.namedCacheDirectoryURL("SpotifyCache"), ["cache", "SpotifyCache"])
            expectHidden(LibraryRoot.trashDirectoryURL(), ["trash"])

            // 任何落点都不得等于 Documents 根本身（那就是「裸露在外面」）。
            #expect(LibraryRoot.stateDirectoryURL() != documents)
            #expect(LibraryRoot.cacheDirectoryURL() != documents)
        }
    }

    @Test("track.path 相对语义不变：相对路径仍解到 Documents/Music 之下")
    func storedPathSemanticsUnchanged() throws {
        try withDocumentsRoot { documents in
            let stored = LibraryRoot.storedPath(forAbsolutePath: documents
                .appendingPathComponent("Music").appendingPathComponent("song.flac").path)
            #expect(stored == "song.flac")
            #expect(LibraryRoot.absoluteURL(forStoredPath: stored) == documents
                .appendingPathComponent("Music").appendingPathComponent("song.flac"))
            // 隐藏根下的文件不是曲库内文件（相对语义不被隐藏根影响）。
            #expect(LibraryRoot.isRelativeStoredPath(stored))
        }
    }

    @Test("封面映射表永不被当缓存；映射为空/读失败 ⇒ 不清理（改路径后契约仍成立）")
    func artworkMappingContractSurvivesHiddenLayout() throws {
        try withDocumentsRoot { _ in
            // 形状/命名保护：映射表名不是 `<64 位 hex>.jpg`。
            #expect(ArtworkManager.isArtworkCacheFileName(LibraryRoot.artworkMappingFileName) == false)
            #expect(ArtworkManager.deletableArtworkCacheFileNames(
                [LibraryRoot.artworkMappingFileName], usedHashes: []
            ).isEmpty)
            // fail-safe：映射为空 / 读失败 ⇒ 不清理。
            #expect(ArtworkManager.shouldPruneArtworkCache(mapping: [:], mappingUnreadable: false) == false)
            #expect(ArtworkManager.shouldPruneArtworkCache(mapping: [:], mappingUnreadable: true) == false)
        }
    }

    // MARK: - 规则分类（纯逻辑）

    @Test("分类：Music / 隐藏根 / .sync-incoming 保留原位；DB 三件套归 DB 层")
    func classificationKeepsReservedEntries() {
        #expect(LibraryLayoutMigrationV2Rules.classify(rootEntryName: "Music", isDirectory: true)
            == .keep(reason: "visibleLibraryRoot"))
        #expect(LibraryLayoutMigrationV2Rules.classify(rootEntryName: hiddenRoot, isDirectory: true)
            == .keep(reason: "hiddenRootTarget"))
        #expect(LibraryLayoutMigrationV2Rules.classify(rootEntryName: ".sync-incoming", isDirectory: true)
            == .keep(reason: "syncProtocolIncomingDirectory"))
        for name in ["MusicLibrary.sqlite", "MusicLibrary.sqlite-shm", "MusicLibrary.sqlite-wal"] {
            #expect(LibraryLayoutMigrationV2Rules.classify(rootEntryName: name, isDirectory: false)
                == .keep(reason: "handledByDatabaseRelocation"))
        }
        // 未登记条目一律保留（保守）。
        #expect(LibraryLayoutMigrationV2Rules.classify(rootEntryName: "something-unplanned", isDirectory: false)
            == .keep(reason: "unplannedFile"))
        #expect(LibraryLayoutMigrationV2Rules.classify(rootEntryName: ".weird-hidden", isDirectory: true)
            == .keep(reason: "unplannedHiddenEntry"))
    }

    // MARK: - 迁移执行器

    @Test("把根条目搬进隐藏根：目标 1:1 落地，源消失，根只剩 Music（+ 保留项）")
    func migratorMovesRootEntriesIntoHiddenRoot() throws {
        try withDocumentsRoot { documents in
            let manager = try makeManager()
            let migrator = makeMigrator(database: manager)

            try writeFile(documents.appendingPathComponent("qqplayer-favorites.json"))
            try writeFile(documents.appendingPathComponent("qqplayer-playlists/playlist-a.json"))
            try writeFile(documents.appendingPathComponent("Artwork/hash.jpg"))
            try writeFile(documents.appendingPathComponent("Artwork/ArtworkMapping.plist"))
            try writeFile(documents.appendingPathComponent("Lyrics/abc.json"))
            try writeFile(documents.appendingPathComponent("lyrics-cache/tracks/abc.json"))
            try writeFile(documents.appendingPathComponent("Lyrics2-unplanned.txt"))
            try writeFile(documents.appendingPathComponent("Logs/app.log"))
            try writeFile(documents.appendingPathComponent("meta/assets.json"))
            try writeFile(documents.appendingPathComponent("SpotifyCache/x.json"))
            try writeFile(documents.appendingPathComponent(".Trash/x.mp3"))
            try writeFile(documents.appendingPathComponent("Music/song.flac"))

            let summary = migrator.run()
            #expect(summary.failed.isEmpty)

            let expected: [(String, String)] = [
                ("qqplayer-favorites.json", "\(hiddenRoot)/state/qqplayer-favorites.json"),
                ("qqplayer-playlists/playlist-a.json", "\(hiddenRoot)/state/playlists/playlist-a.json"),
                ("Artwork/hash.jpg", "\(hiddenRoot)/artwork/hash.jpg"),
                ("Artwork/ArtworkMapping.plist", "\(hiddenRoot)/artwork/ArtworkMapping.plist"),
                ("Lyrics/abc.json", "\(hiddenRoot)/lyrics/manual/abc.json"),
                ("lyrics-cache/tracks/abc.json", "\(hiddenRoot)/lyrics/cache/tracks/abc.json"),
                ("Logs/app.log", "\(hiddenRoot)/logs/app.log"),
                ("meta/assets.json", "\(hiddenRoot)/meta/assets.json"),
                ("SpotifyCache/x.json", "\(hiddenRoot)/cache/SpotifyCache/x.json"),
                (".Trash/x.mp3", "\(hiddenRoot)/trash/x.mp3"),
            ]
            for (source, destination) in expected {
                #expect(
                    FileManager.default.fileExists(atPath: documents.appendingPathComponent(destination).path),
                    "应在隐藏根：\(destination)"
                )
                #expect(
                    !FileManager.default.fileExists(atPath: documents.appendingPathComponent(source).path),
                    "根上不应再留：\(source)"
                )
            }
            // 曲库根未动
            #expect(FileManager.default.fileExists(
                atPath: documents.appendingPathComponent("Music/song.flac").path
            ))
            // 未规划文件保留原位
            #expect(FileManager.default.fileExists(
                atPath: documents.appendingPathComponent("Lyrics2-unplanned.txt").path
            ))
        }
    }

    @Test("幂等：连跑两次结果一致，第二遍无待搬条目")
    func migratorIsIdempotent() throws {
        try withDocumentsRoot { documents in
            let manager = try makeManager()
            let defaults = UserDefaults(suiteName: "hidden-layout-idem-\(UUID().uuidString)") ?? .standard
            let migrator = LibraryLayoutMigrationV2Migrator(database: manager, defaults: defaults)

            try writeFile(documents.appendingPathComponent("qqplayer-favorites.json"))
            try writeFile(documents.appendingPathComponent("meta/assets.json"))

            let first = migrator.run()
            #expect(first.failed.isEmpty)
            #expect(first.alreadyCompleted == false)

            // 第二遍：完成门已置位 ⇒ 直接跳过。
            let second = migrator.run()
            #expect(second.alreadyCompleted)

            // 清门后重跑：源已不在 ⇒ 无待搬（结果一致，不重复搬）。
            migrator.resetCompletionGate()
            let third = migrator.run()
            #expect(third.movesCountForTest == 0)
            let hiddenFavorites = documents
                .appendingPathComponent("\(hiddenRoot)/state/qqplayer-favorites.json")
            #expect(FileManager.default.fileExists(atPath: hiddenFavorites.path))
        }
    }

    @Test("冲突不覆盖（v2.1）：同名文件 ⇒ 改名后缀搬入；旧目标内容一字节不变，根上不再留该文件")
    func conflictRenamesInsteadOfOverwriting() throws {
        try withDocumentsRoot { documents in
            let manager = try makeManager()
            let migrator = makeMigrator(database: manager)

            let source = try writeFile(
                documents.appendingPathComponent("qqplayer-favorites.json"), bytes: 4
            )
            let destination = try writeFile(
                documents.appendingPathComponent("\(hiddenRoot)/state/qqplayer-favorites.json"), bytes: 16
            )

            let summary = migrator.run()

            // 不再「整项跳过」：改名后缀搬入（旧文件仍一份不丢，只是不再顶名）。
            #expect(summary.failed.isEmpty)
            #expect(summary.renamedTotal == 1)
            #expect(!FileManager.default.fileExists(atPath: source.path), "根上不应再留同名文件")
            // 旧目标内容未被覆盖（16 字节 vs 源 4 字节）。
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            #expect((attributes[.size] as? Int) == 16)
            // 旧文件已改名搬入：目标仍在、源已不在根、内容与原源一致（4 字节）。
            let legacy = try #require(try legacySiblings(forPrefix: "qqplayer-favorites.json", in: documents))
            #expect(legacy.count == 1)
            let legacyAttributes = try FileManager.default.attributesOfItem(atPath: legacy[0].path)
            #expect((legacyAttributes[.size] as? Int) == 4)
        }
    }

    @Test("目录冲突递归合并：同名子项改名搬入、其余原样合并、空壳搬进回收区（只搬不删）")
    func directoryConflictIsMergedRecursively() throws {
        try withDocumentsRoot { documents in
            let manager = try makeManager()
            let migrator = makeMigrator(database: manager)

            // 目标目录已存在（模拟启动期 ArtworkManager 先建目录）——含同名子项。
            try writeFile(documents.appendingPathComponent("\(hiddenRoot)/artwork/keep.jpg"), bytes: 16)
            // 根上的源目录：一个同名子项 + 一个不重名子项 + 一层子目录。
            try writeFile(documents.appendingPathComponent("Artwork/keep.jpg"), bytes: 4)
            try writeFile(documents.appendingPathComponent("Artwork/other.jpg"), bytes: 8)
            try writeFile(documents.appendingPathComponent("Artwork/sub/inner.jpg"), bytes: 8)

            let summary = migrator.run()
            let artwork = documents.appendingPathComponent("\(hiddenRoot)/artwork")

            #expect(summary.failed.isEmpty)
            #expect(summary.renamedTotal == 1)
            // 不重名子项：原样合并进去。
            #expect(FileManager.default.fileExists(atPath: artwork.appendingPathComponent("other.jpg").path))
            #expect(FileManager.default.fileExists(atPath: artwork.appendingPathComponent("sub/inner.jpg").path))
            // 同名子项：旧目标内容不变（16 字节），源改名搬入（4 字节）。
            let keep = artwork.appendingPathComponent("keep.jpg")
            let keepAttributes = try FileManager.default.attributesOfItem(atPath: keep.path)
            #expect((keepAttributes[.size] as? Int) == 16)
            let legacy = try #require(try legacySiblings(forPrefix: "keep.jpg", in: documents))
            #expect(legacy.count == 1)
            let legacyAttributes = try FileManager.default.attributesOfItem(atPath: legacy[0].path)
            #expect((legacyAttributes[.size] as? Int) == 4)
            // 空壳清扫：根上 `Artwork/` 已不在（空壳改名搬进回收区，**没删**）。
            #expect(!FileManager.default.fileExists(atPath: documents.appendingPathComponent("Artwork").path))
            #expect(summary.sweptShells == ["Artwork"])
            let trash = documents.appendingPathComponent("\(hiddenRoot)/trash")
            let trashed = (try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []
            #expect(trashed.contains { $0.hasPrefix("Artwork\(LibraryLayoutMigrationV2Rules.legacySuffixPrefix)") })
        }
    }

    @Test("同名日志文件（启动期已建）⇒ 改名搬入，完成门仍能置位（根已干净）")
    func sameNamedLogFileIsRenamedAndGateSet() throws {
        try withDocumentsRoot { documents in
            let manager = try makeManager()
            let defaults = UserDefaults(suiteName: "hidden-layout-log-rename-\(UUID().uuidString)") ?? .standard
            defaults.removeObject(forKey: LibraryLayoutMigrationV2Migrator.completionDefaultsKey)
            let migrator = LibraryLayoutMigrationV2Migrator(database: manager, defaults: defaults)

            // 进程最早期就写下的日志文件：根 `app.log` 与隐藏根里的新位置同名。
            let rootLog = try writeFile(documents.appendingPathComponent("app.log"), bytes: 4)
            let hiddenLog = try writeFile(documents.appendingPathComponent("\(hiddenRoot)/logs/app.log"), bytes: 16)
            try writeFile(documents.appendingPathComponent("\(hiddenRoot)/logs/db-debug.log"), bytes: 16)
            let rootDbLog = try writeFile(documents.appendingPathComponent("db-debug.log"), bytes: 8)

            let summary = migrator.run()

            #expect(summary.failed.isEmpty)
            #expect(summary.renamedTotal == 2)
            #expect(!FileManager.default.fileExists(atPath: rootLog.path))
            #expect(!FileManager.default.fileExists(atPath: rootDbLog.path))
            let logAttributes = try FileManager.default.attributesOfItem(atPath: hiddenLog.path)
            #expect((logAttributes[.size] as? Int) == 16, "日志旧目标不被覆盖")
            #expect(try legacySiblings(forPrefix: "app.log", in: documents).count == 1)
            #expect(try legacySiblings(forPrefix: "db-debug.log", in: documents).count == 1)
            // 根已无可搬条目 ⇒ 置位（不再因冲突而永世不置位）。
            #expect(summary.residue.isEmpty)
            #expect(defaults.bool(forKey: LibraryLayoutMigrationV2Migrator.completionDefaultsKey))
        }
    }

    @Test("完成门语义（v2.1）：有残留不置位（下次启动重试）；无残留才置位")
    func completionGateRequiresNoResidue() throws {
        try withDocumentsRoot { documents in
            let manager = try makeManager()
            let defaults = UserDefaults(suiteName: "hidden-layout-residue-\(UUID().uuidString)") ?? .standard
            defaults.removeObject(forKey: LibraryLayoutMigrationV2Migrator.completionDefaultsKey)
            let migrator = LibraryLayoutMigrationV2Migrator(database: manager, defaults: defaults)

            // 让 `cache/` 的父路径是一个**文件** ⇒ 该项搬不动 ⇒ 根上留残留。
            try FileManager.default.createDirectory(
                at: documents.appendingPathComponent(hiddenRoot, isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("x".utf8).write(to: documents.appendingPathComponent("\(hiddenRoot)/cache"))
            try writeFile(documents.appendingPathComponent("SpotifyCache/x.json"))
            let movable = try writeFile(documents.appendingPathComponent("qqplayer-favorites.json"))

            let summary = migrator.run()

            #expect(summary.residue.contains("SpotifyCache"))
            #expect(!summary.didComplete)
            #expect(!defaults.bool(forKey: LibraryLayoutMigrationV2Migrator.completionDefaultsKey))
            // 能搬的仍照搬；搬不动的原件保留（只搬不删）。
            #expect(!FileManager.default.fileExists(atPath: movable.path))
            #expect(FileManager.default.fileExists(
                atPath: documents.appendingPathComponent("SpotifyCache/x.json").path
            ))
            // 未置位 ⇒ 下次启动还会再跑一轮（不是 alreadyCompleted）。
            #expect(migrator.run().alreadyCompleted == false)
        }
    }

    @Test("干跑：能看出哪些会“改名搬入”（含目录合并场景），且不碰磁盘、不置完成门")
    func dryRunShowsRenames() throws {
        try withDocumentsRoot { documents in
            let manager = try makeManager()
            let defaults = UserDefaults(suiteName: "hidden-layout-dry-rename-\(UUID().uuidString)") ?? .standard
            defaults.removeObject(forKey: LibraryLayoutMigrationV2Migrator.completionDefaultsKey)
            let migrator = LibraryLayoutMigrationV2Migrator(database: manager, defaults: defaults)

            try writeFile(documents.appendingPathComponent("\(hiddenRoot)/artwork/keep.jpg"), bytes: 16)
            let rootKeep = try writeFile(documents.appendingPathComponent("Artwork/keep.jpg"), bytes: 4)
            let rootOther = try writeFile(documents.appendingPathComponent("Artwork/other.jpg"), bytes: 8)
            let rootLog = try writeFile(documents.appendingPathComponent("app.log"), bytes: 4)

            let summary = migrator.run(dryRun: true)

            #expect(summary.isDryRun)
            #expect(summary.renamedTotal == 2, "同名子项 + 同名文件都要预报为改名搬入")
            #expect(!summary.planLine.isEmpty)
            // 干跑不碰磁盘：源全在原地、没有任何改名落点、空壳也未清扫。
            #expect(FileManager.default.fileExists(atPath: rootKeep.path))
            #expect(FileManager.default.fileExists(atPath: rootOther.path))
            #expect(FileManager.default.fileExists(atPath: rootLog.path))
            #expect(try legacySiblings(forPrefix: "keep.jpg", in: documents).isEmpty)
            #expect(FileManager.default.fileExists(atPath: documents.appendingPathComponent("Artwork").path))
            // 干跑不受完成门影响，也不置门。
            #expect(!defaults.bool(forKey: LibraryLayoutMigrationV2Migrator.completionDefaultsKey))
            #expect(migrator.run(dryRun: true).isDryRun)
        }
    }

    @Test("合并后幂等：清门重跑无待搬、不产生第二个改名副本")
    func mergeIsIdempotent() throws {
        try withDocumentsRoot { documents in
            let manager = try makeManager()
            let defaults = UserDefaults(suiteName: "hidden-layout-merge-idem-\(UUID().uuidString)") ?? .standard
            defaults.removeObject(forKey: LibraryLayoutMigrationV2Migrator.completionDefaultsKey)
            let migrator = LibraryLayoutMigrationV2Migrator(database: manager, defaults: defaults)

            try writeFile(documents.appendingPathComponent("\(hiddenRoot)/artwork/keep.jpg"), bytes: 16)
            try writeFile(documents.appendingPathComponent("Artwork/keep.jpg"), bytes: 4)

            #expect(migrator.run().failed.isEmpty)
            migrator.resetCompletionGate()
            let second = migrator.run()

            #expect(second.movesCountForTest == 0)
            #expect(second.sweptShells.isEmpty)
            #expect(second.residue.isEmpty)
            #expect(try legacySiblings(forPrefix: "keep.jpg", in: documents).count == 1)
        }
    }

    /// 隐藏根下「`<prefix>.legacy-<ts>`」形式的改名副本（断言用；只读枚举）。
    private func legacySiblings(forPrefix prefix: String, in documents: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: documents.appendingPathComponent(hiddenRoot, isDirectory: true),
            includingPropertiesForKeys: nil
        )
        var result: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            if name.hasPrefix("\(prefix)\(LibraryLayoutMigrationV2Rules.legacySuffixPrefix)") {
                result.append(url)
            }
        }
        return result
    }

    @Test("失败不中断：单项搬不动 → 该条失败，其余照搬，原件全部保留")
    func failureDoesNotStopOthersAndKeepsOriginal() throws {
        try withDocumentsRoot { documents in
            let manager = try makeManager()
            let migrator = makeMigrator(database: manager)

            // 让 `cache/` 的父路径是一个**文件** ⇒ `SpotifyCache` 的父目录建不出来（失败）。
            try FileManager.default.createDirectory(
                at: documents.appendingPathComponent(hiddenRoot, isDirectory: true),
                withIntermediateDirectories: true
            )
            try Data("x".utf8).write(to: documents.appendingPathComponent("\(hiddenRoot)/cache"))

            let cacheSource = try writeFile(documents.appendingPathComponent("SpotifyCache/x.json"))
            let stateSource = try writeFile(documents.appendingPathComponent("qqplayer-favorites.json"))

            let summary = migrator.run()

            #expect(summary.failed.contains { $0.contains("SpotifyCache") || $0.contains("cache") })
            #expect(summary.movedTotal >= 1)
            // 失败项原件保留
            #expect(FileManager.default.fileExists(atPath: cacheSource.path))
            // 其余项照搬
            #expect(!FileManager.default.fileExists(atPath: stateSource.path))
            #expect(FileManager.default.fileExists(
                atPath: documents.appendingPathComponent("\(hiddenRoot)/state/qqplayer-favorites.json").path
            ))
            // 有失败 ⇒ 完成门不置位（下次启动重试）
            let again = migrator.run()
            #expect(again.alreadyCompleted == false)
        }
    }

    @Test("干跑：只统计、不动磁盘、不置完成门")
    func dryRunOnlyCounts() throws {
        try withDocumentsRoot { documents in
            let manager = try makeManager()
            let migrator = makeMigrator(database: manager)

            let source = try writeFile(documents.appendingPathComponent("qqplayer-favorites.json"))
            let summary = migrator.run(dryRun: true)

            #expect(summary.isDryRun)
            #expect(summary.movedTotal >= 1)
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(!FileManager.default.fileExists(
                atPath: documents.appendingPathComponent("\(hiddenRoot)/state/qqplayer-favorites.json").path
            ))
            // 干跑不置门：真跑还要能干活。
            let real = migrator.run()
            #expect(real.alreadyCompleted == false)
            #expect(real.movedTotal >= 1)
        }
    }

    @Test("完成门：成功才置位；置位后直接跳过")
    func completionGateOnlyAfterSuccess() throws {
        try withDocumentsRoot { documents in
            let manager = try makeManager()
            let defaults = UserDefaults(suiteName: "hidden-layout-gate-\(UUID().uuidString)") ?? .standard
            let migrator = LibraryLayoutMigrationV2Migrator(database: manager, defaults: defaults)

            try writeFile(documents.appendingPathComponent("meta/assets.json"))
            let summary = migrator.run()
            #expect(summary.failed.isEmpty)
            #expect(defaults.bool(forKey: LibraryLayoutMigrationV2Migrator.completionDefaultsKey))

            let second = migrator.run()
            #expect(second.alreadyCompleted)
            #expect(second.movedTotal == 0)
        }
    }

    @Test("被 DB 绝对路径引用的根条目：跳过不搬（引用不悬空）+ 记入跳过")
    func referencedEntriesAreNotMoved() throws {
        try withDocumentsRoot { documents in
            let manager = try makeManager()
            let migrator = makeMigrator(database: manager)

            let referenced = try writeFile(
                documents.appendingPathComponent("qqplayer-assets/audio/clip.mp3")
            )
            // DB 行：绝对路径指向该条目。
            try manager.upsertTrack(
                Track(
                    stableId: "asset-1",
                    title: "Clip",
                    durationMs: 1000,
                    path: referenced.path,
                    fileSize: 8,
                    modificationDate: 1000
                )
            )
            try writeFile(documents.appendingPathComponent("qqplayer-favorites.json"))

            let summary = migrator.run()

            #expect(summary.skipped.contains { $0.contains("referencedByStoredPath") })
            #expect(FileManager.default.fileExists(atPath: referenced.path))
            #expect(!FileManager.default.fileExists(
                atPath: documents.appendingPathComponent("qqplayer-favorites.json").path
            ))
        }
    }
}

// MARK: - 测试用的小缝（不改生产语义）

extension LibraryLayoutMigrationV2Migrator.Summary {
    /// 本轮的搬迁件数（供「重跑无待搬」断言用；等价 `movedByDestination` 求和）。
    var movesCountForTest: Int { movedTotal }
}
