//
//  LibraryFileNamingTests.swift
//  QQPlayerTests
//
//  曲库规范化命名纯逻辑 + 唯一改名入口（`TrackFileRenameService`）的行为测试
//  （2026-09-28「曲库命名对齐」批 A）。
//
//  覆盖：
//  - `LibraryFileNaming.canonicalFileName` 必须**复用** `TagRenameLogic.renderFileName`
//    （逐字节相等）/ 空 artist+title → nil / 单侧 → 无分隔符
//  - `isSameName` NFC/NFD 等价（防反复改名）
//  - 改名三分支：目标不存在 → renamed / 同内容 → deduped / 内容不同 → skippedTargetConflict
//  - 幂等：已是规范名 → unchanged；再跑一遍仍 unchanged
//  - 备份根与台账路径约定（`<libraryRoot>/../.qqplayer-rename-backup/rename-log.tsv`）
//
//  fixtures：临时目录曲库 + `DatabaseManager(dbWriter: DatabaseQueue())` 内存库（同既有模式）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

struct LibraryFileNamingTests {
    // MARK: - fixtures

    private func makeLibrary() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryFileNamingTests-\(UUID().uuidString)")
            .appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func write(_ name: String, bytes: [UInt8], in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    private func makeManager() throws -> DatabaseManager {
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        try manager.createTables()
        return manager
    }

    @discardableResult
    private func insertTrack(
        _ manager: DatabaseManager,
        path: String,
        title: String = "t",
        contentHash: String? = nil
    ) throws -> Track {
        var track = Track(
            stableId: DatabaseManager.generatePathStableId(forPath: path),
            title: title,
            path: path
        )
        track.contentHash = contentHash
        try manager.write { db in try track.insert(db) }
        return track
    }

    // MARK: - 纯逻辑：渲染复用 / 空值 / 归一

    @Test("canonicalFileName 必须复用 TagRenameLogic.renderFileName（唯一渲染实现）")
    func canonicalFileNameReusesTagRenameLogic() {
        let cases: [(String?, String?)] = [("A", "B"), ("周华健", "爱相随"), ("A", nil), (nil, "B"), (nil, nil), ("", "  ")]
        for (artist, title) in cases {
            let expected = TagRenameLogic.renderFileName(
                template: TagRenameLogic.defaultTemplate,
                values: TagRenameLogic.Values(artist: artist, title: title),
                ext: ".mp3"
            )
            let actual = LibraryFileNaming.canonicalFileName(artist: artist, title: title, ext: ".mp3")
            #expect(actual == expected, "artist=\(artist ?? "nil") title=\(title ?? "nil")")
        }
    }

    @Test("artist 与 title 都空 → nil（不该改名）")
    func emptyValuesReturnNil() {
        #expect(LibraryFileNaming.canonicalFileName(artist: nil, title: nil, ext: ".mp3") == nil)
        #expect(LibraryFileNaming.canonicalFileName(artist: "", title: "   ", ext: ".mp3") == nil)
        #expect(LibraryFileNaming.canonicalFileName(artist: "", title: "", ext: ".flac") == nil)
    }

    @Test("单侧有值 → 无分隔符（TagRenameLogic 默认模板分支）")
    func singleSidedValues() {
        #expect(LibraryFileNaming.canonicalFileName(artist: "A", title: nil, ext: ".mp3") == "A.mp3")
        #expect(LibraryFileNaming.canonicalFileName(artist: nil, title: "B", ext: ".mp3") == "B.mp3")
    }

    @Test("isSameName：NFC/NFD 等价视为同名；大小写不同不算同名")
    func unicodeNormalizedComparison() {
        let composed = "Café - Song"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        #expect(composed != decomposed) // 字节层面确实不同（否则本用例无效）
        #expect(LibraryFileNaming.isSameName(composed, decomposed))

        #expect(LibraryFileNaming.isSameName("周华健 - 爱相随", "周华健 - 爱相随"))
        #expect(!LibraryFileNaming.isSameName("Count On Me", "Count on Me"))
        #expect(LibraryFileNaming.isSameBaseName("X.mp3", "X.MP3"))
        #expect(!LibraryFileNaming.isSameBaseName("X.mp3", "Y.mp3"))
    }

    // MARK: - 备份/台账路径约定

    @Test("备份根 = <libraryRoot>/../.qqplayer-rename-backup；台账 = 备份根/rename-log.tsv")
    func backupAndLogPaths() throws {
        let library = try makeLibrary()
        let expectedBackup = library.deletingLastPathComponent()
            .appendingPathComponent(LibraryFileNaming.renameBackupDirectoryName, isDirectory: true)
        #expect(TrackFileRenameService.backupRoot(forLibraryRoot: library) == expectedBackup)
        #expect(
            TrackFileRenameService.renameLogURL(forLibraryRoot: library)
                == expectedBackup.appendingPathComponent(LibraryFileNaming.renameLogFileName)
        )
        #expect(LibraryFileNaming.isRenameBackupPathComponent(".qqplayer-rename-backup"))
        #expect(LibraryFileNaming.isRenameBackupPathComponent("foo-rename-backup"))
        #expect(!LibraryFileNaming.isRenameBackupPathComponent("Music"))
        #expect(LibraryFileNaming.isInsideRenameBackup(expectedBackup.appendingPathComponent("a/b.mp3")))
        #expect(!LibraryFileNaming.isInsideRenameBackup(library.appendingPathComponent("b.mp3")))
    }

    // MARK: - 服务三分支

    @Test("分支 renamed：目标不存在 → 纯 moveItem + 引用迁移（stableId 重算）")
    func branchRenamed() throws {
        let library = try makeLibrary()
        let manager = try makeManager()
        let source = try write("爱相随-周华健.mp3", bytes: [1, 2, 3, 4], in: library)
        let track = try insertTrack(manager, path: source.path)

        let outcome = try TrackFileRenameService.rename(
            track: track,
            artist: "周华健",
            title: "爱相随",
            libraryRoot: library,
            databaseManager: manager
        )

        let target = library.appendingPathComponent("周华健 - 爱相随.mp3")
        #expect(outcome == .renamed(from: source.path, to: target.path))
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))

        let migrated = try manager.getTrack(byStableId: DatabaseManager.generatePathStableId(forPath: target.path))
        #expect(migrated != nil)
        #expect(migrated?.path == target.standardizedFileURL.path)
        // 音频字节零改动
        #expect(try Data(contentsOf: target) == Data([1, 2, 3, 4]))
        // 台账落盘
        let log = try String(contentsOf: TrackFileRenameService.renameLogURL(forLibraryRoot: library), encoding: .utf8)
        #expect(log.contains("renamed"))
        #expect(log.contains("周华健 - 爱相随.mp3"))
    }

    @Test("分支 deduped：目标存在且内容一致 → 源文件归档备份 + 引用并入目标 + 删源行")
    func branchDeduped() throws {
        let library = try makeLibrary()
        let manager = try makeManager()
        let bytes: [UInt8] = [9, 9, 9]
        let source = try write("Count On Me-Connie Talbot.mp3", bytes: bytes, in: library)
        let target = try write("Connie Talbot - Count on Me.mp3", bytes: bytes, in: library)
        let sourceTrack = try insertTrack(manager, path: source.path)
        let targetTrack = try insertTrack(manager, path: target.path)
        // 源行的收藏引用：去重后应并入目标 stableId
        try manager.write { db in
            try db.execute(
                sql: "INSERT INTO favorite (track_stable_id) VALUES (?)",
                arguments: [sourceTrack.stableId]
            )
        }

        let outcome = try TrackFileRenameService.rename(
            track: sourceTrack,
            artist: "Connie Talbot",
            title: "Count on Me",
            libraryRoot: library,
            databaseManager: manager
        )

        guard case .deduped(let removedPath, let backupPath) = outcome else {
            Issue.record("期望 deduped，实际 \(outcome)")
            return
        }
        #expect(removedPath == source.path)
        // 源文件已离开曲库、进入备份根
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: backupPath))
        #expect(LibraryFileNaming.isInsideRenameBackup(URL(fileURLWithPath: backupPath)))
        #expect(try Data(contentsOf: URL(fileURLWithPath: backupPath)) == Data(bytes))
        // 目标文件原样保留
        #expect(FileManager.default.fileExists(atPath: target.path))
        // 源行已删、目标行在、收藏引用并入目标 stableId
        #expect(try manager.getTrack(byStableId: sourceTrack.stableId) == nil)
        #expect(try manager.getTrack(byStableId: targetTrack.stableId) != nil)
        #expect(try manager.getFavorites() == [targetTrack.stableId])
        // 台账记录 deduped
        let log = try String(contentsOf: TrackFileRenameService.renameLogURL(forLibraryRoot: library), encoding: .utf8)
        #expect(log.contains("deduped"))
    }

    @Test("分支 skippedTargetConflict：目标存在但内容不同 → 不改、不覆盖、不加 (2)")
    func branchSkippedTargetConflict() throws {
        let library = try makeLibrary()
        let manager = try makeManager()
        let source = try write("爱相随-周华健.mp3", bytes: [1, 1, 1], in: library)
        let target = try write("周华健 - 爱相随.mp3", bytes: [2, 2, 2], in: library)
        let track = try insertTrack(manager, path: source.path)

        let outcome = try TrackFileRenameService.rename(
            track: track,
            artist: "周华健",
            title: "爱相随",
            libraryRoot: library,
            databaseManager: manager
        )

        #expect(outcome == .skippedTargetConflict(existingPath: target.path))
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: target) == Data([2, 2, 2])) // 未被覆盖
        // 无 `(2)` 变体产生
        let entries = try FileManager.default.contentsOfDirectory(atPath: library.path)
        #expect(!entries.contains { $0.contains("(2)") })
        #expect(entries.count == 2)
    }

    @Test("幂等：已是规范名 → unchanged；NFC/NFD 形态也不改名")
    func idempotent() throws {
        let library = try makeLibrary()
        let manager = try makeManager()
        let canonical = "Café - Song"
        let composed = try write(canonical + ".mp3", bytes: [7], in: library)
        let track = try insertTrack(manager, path: composed.path)

        let first = try TrackFileRenameService.rename(
            track: track, artist: "Café", title: "Song",
            libraryRoot: library, databaseManager: manager
        )
        #expect(first == .unchanged)

        // NFD 形态的同名文件同样判 unchanged（防反复改名）
        let decomposedName = canonical.decomposedStringWithCanonicalMapping + ".mp3"
        let decomposed = try write(decomposedName, bytes: [8], in: library)
        let track2 = try insertTrack(manager, path: decomposed.path)
        let second = try TrackFileRenameService.rename(
            track: track2, artist: "Café", title: "Song",
            libraryRoot: library, databaseManager: manager
        )
        #expect(second == .unchanged)
        #expect(FileManager.default.fileExists(atPath: decomposed.path))
    }

    @Test("notRenameable：artist/title 都空 → 不改名")
    func notRenameable() throws {
        let library = try makeLibrary()
        let manager = try makeManager()
        let source = try write("track01.mp3", bytes: [3], in: library)
        let track = try insertTrack(manager, path: source.path)

        let outcome = try TrackFileRenameService.rename(
            track: track, artist: nil, title: nil,
            libraryRoot: library, databaseManager: manager
        )
        #expect(outcome == .notRenameable(reason: "emptyArtistAndTitle"))
        #expect(FileManager.default.fileExists(atPath: source.path))
    }
}
