//
//  LibraryHiddenLayoutMigrationTests.swift
//  QQPlayerTests
//
// target: ios-only
//
//  2026-09-22「隐藏布局（v2）：`Documents/` 根部只留 `Music/` 可见」的回归锁。
//
//  为什么要测（每条都对应一个真实后果）：
//   · **隐藏根解析**：非曲库内容全部落 `Documents/.qqplayer/<类目>/`；散落拼接会在
//     某个调用点漏掉隐藏根 ⇒ 那个文件重新裸露在 Files/Finder 里。
//   · **`track.path` 语义不变**：仍相对 `Music` 根 —— 改坏 = 全库行解析到错误路径。
//   · **迁移器**：幂等、冲突不覆盖、失败不中断且不删原件、干跑只统计、完成门 ——
//     每一条都是「用户数据可能被搬丢」的防线。
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

    @Test("冲突不覆盖：目标已存在 → 跳过，保留原件、内容不变")
    func conflictIsSkippedNotOverwritten() throws {
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

            #expect(summary.skipped.contains { $0.contains("targetExists") })
            #expect(FileManager.default.fileExists(atPath: source.path))
            // 目标内容未被覆盖（16 字节 vs 源 4 字节）。
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            #expect((attributes[.size] as? Int) == 16)
        }
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
