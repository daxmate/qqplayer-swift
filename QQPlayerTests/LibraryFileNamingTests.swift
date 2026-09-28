//
//  LibraryFileNamingTests.swift
//  QQPlayerTests
//
//  曲库规范化命名纯逻辑 + 唯一改名入口（`TrackFileRenameService`）的行为测试
//  （2026-09-28「曲库命名对齐」批 A）。
//
//  覆盖：
//  - `LibraryFileNaming.canonicalFileName` 必须**复用** `TagRenameLogic.renderFileName`
//    （字形中性输入逐字节相等）/ **落库口径规范化**（繁→简，复用
//    `DisplayScriptNormalizer.canonical`）/ 空 artist+title → nil / 单侧 → 无分隔符
//  - 落库口径（简体）：繁体标签值 → 简体规范名（53 条存量的代表样例）；日文假名豁免
//  - 结构性差异仍改：磁盘名 ≠ 落库口径规范名（Meja / 王菲 / Count On Me / 米津玄師）
//  - 回归钉住：磁盘简体名 + 繁体标签 → **unchanged**（不得把简体改成繁体）
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
        // 字形中性输入（落库口径归一不改变值）→ 与 renderFileName 逐字节相等（证明复用渲染）
        let cases: [(String?, String?)] = [("A", "B"), ("周华健", "爱相随"), ("Meja", "Lemon"), ("A", nil), (nil, "B"), (nil, nil), ("", "  ")]
        for (artist, title) in cases {
            let expected = TagRenameLogic.renderFileName(
                template: TagRenameLogic.defaultTemplate,
                values: TagRenameLogic.Values(artist: artist, title: title),
                ext: ".mp3"
            )
            let actual = LibraryFileNaming.canonicalFileName(artist: artist, title: title, ext: ".mp3")
            #expect(actual == expected, "artist=\(artist ?? "nil") title=\(title ?? "nil")")
        }
        // 繁体输入：规范名 = 对**落库口径规范化后**的值的渲染，而不是原值渲染
        // （证明归一生效，且归一实现 = DisplayScriptNormalizer.canonical）
        #expect(
            LibraryFileNaming.canonicalFileName(artist: "周杰倫", title: "晴天", ext: ".mp3")
                == TagRenameLogic.renderFileName(
                    template: TagRenameLogic.defaultTemplate,
                    values: TagRenameLogic.Values(
                        artist: DisplayScriptNormalizer.canonical("周杰倫"),
                        title: DisplayScriptNormalizer.canonical("晴天")
                    ),
                    ext: ".mp3"
                )
        )
    }

    // MARK: - 落库口径（简体）归一

    @Test("落库口径：繁体标签值 → 简体规范名（53 条存量的代表样例）")
    func canonicalizesTraditionalTagValuesToSimplified() {
        // 磁盘简体 + 标签繁体（实测 53 条）：规范名必须是简体，不再把磁盘名改成繁体
        let cases: [(artist: String, title: String, expected: String)] = [
            ("五月天", "倔強", "五月天 - 倔强.mp3"),
            ("周杰倫", "晴天", "周杰伦 - 晴天.mp3"),
            ("陳奕迅", "浮誇", "陈奕迅 - 浮夸.mp3"),
            ("張學友", "一千個傷心的理由", "张学友 - 一千个伤心的理由.mp3"),
        ]
        for c in cases {
            #expect(
                LibraryFileNaming.canonicalFileName(artist: c.artist, title: c.title, ext: ".mp3") == c.expected,
                "\(c.artist) / \(c.title) 应为简体规范名"
            )
        }
        // 日文假名豁免：含假名的值不转换（日文汉字与简繁字形不同，转换会破坏原文）
        #expect(
            LibraryFileNaming.canonicalFileName(artist: "Meja", title: "いつも何度でも", ext: ".mp3")
                == "Meja - いつも何度でも.mp3"
        )
    }

    @Test("结构性差异仍改：磁盘名 ≠ 落库口径规范名（Meja / 王菲 / Count On Me / 米津玄師）")
    func structuralDifferencesStillDetected() {
        // id=12：磁盘多出来源后缀
        let mejaDisk = "Meja - いつも何度でも(\u{201C}千と千寻の神隠し\u{201D}より).mp3"
        let mejaCanonical = LibraryFileNaming.canonicalFileName(artist: "Meja", title: "いつも何度でも", ext: ".mp3")
        #expect(mejaCanonical == "Meja - いつも何度でも.mp3")
        #expect(!LibraryFileNaming.isSameName(mejaCanonical ?? "", mejaDisk))

        // id=147：磁盘用旧艺名「王菲」，标签/落库为「王靖雯」
        let wangCanonical = LibraryFileNaming.canonicalFileName(artist: "王靖雯", title: "棋子", ext: ".mp3")
        #expect(wangCanonical == "王靖雯 - 棋子.mp3")
        #expect(!LibraryFileNaming.isSameName(wangCanonical ?? "", "王菲 - 棋子.mp3"))

        // id=271：仅大小写差异（On vs on）——仍属结构性差异（大小写以标签为准；落库口径不改大小写）
        let countCanonical = LibraryFileNaming.canonicalFileName(artist: "Connie Talbot", title: "Count on Me", ext: ".mp3")
        #expect(countCanonical == "Connie Talbot - Count on Me.mp3")
        #expect(!LibraryFileNaming.isSameName(countCanonical ?? "", "Connie Talbot - Count On Me.mp3"))

        // id=156：标签为罗马化 → 规范名跟随标签（落库口径不改写非简繁差异）
        #expect(
            LibraryFileNaming.canonicalFileName(artist: "Kenshi Yonezu", title: "Lemon", ext: ".mp3")
                == "Kenshi Yonezu - Lemon.mp3"
        )
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
        // 字节层面确实不同（否则本用例无效）。注意：Swift 的 `!=` 走 Unicode 规范等价，
        // NFC/NFD 会判「相等」，必须比 UTF-8 字节（2026-09-28 批 A″ 修正：原断言
        // `composed != decomposed` 恒为 false，是批 A′ 残留的红用例）。
        #expect(Array(composed.utf8) != Array(decomposed.utf8))
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
        // NFC / NFD 各用**独立曲库**：APFS 对文件名做 Unicode 归一，同一目录下两种形态会
        // 命中同一个文件（同 normalized path ⇒ 同 stableId）。批 A′ 原写法在同一目录里插两行，
        // 稳定报 `UNIQUE constraint failed: track.stable_id`（批 A″ 修正），本用例重新拆分。
        let canonical = "Café - Song"
        let composedLibrary = try makeLibrary()
        let composedManager = try makeManager()
        let composed = try write(canonical + ".mp3", bytes: [7], in: composedLibrary)
        let composedTrack = try insertTrack(composedManager, path: composed.path)

        let first = try TrackFileRenameService.rename(
            track: composedTrack, artist: "Café", title: "Song",
            libraryRoot: composedLibrary, databaseManager: composedManager
        )
        #expect(first == .unchanged)
        #expect(FileManager.default.fileExists(atPath: composed.path))

        // NFD 形态的同名文件同样判 unchanged（防反复改名）
        let decomposedLibrary = try makeLibrary()
        let decomposedManager = try makeManager()
        let decomposedName = canonical.decomposedStringWithCanonicalMapping + ".mp3"
        let decomposed = try write(decomposedName, bytes: [8], in: decomposedLibrary)
        let decomposedTrack = try insertTrack(decomposedManager, path: decomposed.path)
        let second = try TrackFileRenameService.rename(
            track: decomposedTrack, artist: "Café", title: "Song",
            libraryRoot: decomposedLibrary, databaseManager: decomposedManager
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

    // MARK: - 批 A″ 护栏：仅大小写差异（同一文件）不得走 dedupe

    @Test("批 A″：仅大小写差异 → renamed（不是 deduped），唯一副本未被归档")
    func caseOnlyDifferenceRenamesWithoutDedupe() throws {
        let library = try makeLibrary()
        let manager = try makeManager()
        // 大小写不敏感卷（macOS 默认 APFS）上，目标名与源名命中同一个文件。
        let source = try write("Count On Me.mp3", bytes: [4, 2], in: library)
        let track = try insertTrack(manager, path: source.path)

        let outcome = try TrackFileRenameService.rename(
            track: track, artist: nil, title: "Count on Me",
            libraryRoot: library, databaseManager: manager
        )

        let target = library.appendingPathComponent("Count on Me.mp3")

        // 1. 结果 = renamed（两段式改名，大小写真的改变）
        #expect(outcome == .renamed(from: source.path, to: target.path))

        // 2. 回归钉住：绝不得走 dedupe（唯一副本不得被归档）
        if case .deduped = outcome {
            Issue.record("仅大小写差异误落 dedupe：唯一副本被归档、库行迁到不存在的目标 ⇒ 曲目悬空")
        }

        // 3. 目录里恰好一个条目，且与目标大小写一致（大小写不敏感卷上 fileExists(源)
        //    也为真，故只能用目录清单作判据——不能依赖 fileExists 否定）
        let entries = try FileManager.default.contentsOfDirectory(atPath: library.path)
        #expect(entries == ["Count on Me.mp3"])

        // 4. 字节原样（文件没被搬走/改写）
        #expect(try Data(contentsOf: target) == Data([4, 2]))

        // 5. 备份根为空（未归档任何文件；台账不是归档物）
        let backupRoot = TrackFileRenameService.backupRoot(forLibraryRoot: library)
        let archived = (try? FileManager.default.contentsOfDirectory(atPath: backupRoot.path)) ?? []
        #expect(!archived.contains { $0 != LibraryFileNaming.renameLogFileName })

        // 6. 库行已迁到新路径（旧 stableId 消失、新 stableId 在且路径为规范名）
        let newStableId = DatabaseManager.generatePathStableId(forPath: target.path)
        let migrated = try manager.getTrack(byStableId: newStableId)
        #expect(migrated != nil)
        #expect(migrated?.path == target.standardizedFileURL.path)
        #expect(try manager.getTrack(byStableId: track.stableId) == nil)
    }

    @Test("批 A″：isSameFile —— 仅大小写差异 = 同一文件；内容相同但确是两文件 ≠ 同一文件")
    func sameFileDetection() throws {
        let library = try makeLibrary()
        let fm = FileManager.default
        let a = try write("Count On Me.mp3", bytes: [1], in: library)
        let b = try write("Other.mp3", bytes: [1], in: library)
        let caseVariant = library.appendingPathComponent("Count on Me.mp3")

        // 卷是否大小写不敏感用**事实**判定（`fileExists` 能否命中大小写变体），
        // 不用 `volumeSupportsCaseSensitiveNames`：模拟器 app 容器实测该键报 false，
        // 而 `fileExists(大小写变体)` 也是 false（容器实际按大小写敏感解析，
        // 2026-09-28 批 A″ 探针实测）→ 以事实为准。
        if fm.fileExists(atPath: caseVariant.path) {
            // 大小写不敏感卷（macOS 默认 APFS / 用户机器）：仅大小写差异 = 同一文件
            #expect(TrackFileRenameService.isSameFile(a, caseVariant, fileManager: fm))
        } else {
            // 大小写敏感卷（iOS 模拟器 app 容器实测）：不存在「同一文件」这回事
            #expect(!TrackFileRenameService.isSameFile(a, caseVariant, fileManager: fm))
        }

        // 控制组：内容完全相同但为两个文件 ⇒ 不是同一文件（不误判真去重场景）
        #expect(!TrackFileRenameService.isSameFile(a, b, fileManager: fm))
        // 自身 ⇒ 同一文件
        #expect(TrackFileRenameService.isSameFile(a, a, fileManager: fm))
    }

    // MARK: - 落库口径 · 回归钉住 / 结构性差异（service 级）

    @Test("回归钉住：磁盘简体名 + 繁体标签 → unchanged（不得把简体改成繁体）")
    func traditionalTagWithSimplifiedDiskNameStaysUnchanged() throws {
        let library = try makeLibrary()
        let manager = try makeManager()
        let source = try write("五月天 - 倔强.mp3", bytes: [5, 5], in: library)
        let track = try insertTrack(manager, path: source.path)

        let outcome = try TrackFileRenameService.rename(
            track: track, artist: "五月天", title: "倔強",
            libraryRoot: library, databaseManager: manager
        )

        #expect(outcome == .unchanged)
        #expect(FileManager.default.fileExists(atPath: source.path))
        // 不得产生繁体名文件
        #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("五月天 - 倔強.mp3").path))
    }

    @Test("结构性差异仍改（service）：磁盘旧名 → 落库口径规范名（改名 + 引用迁移）")
    func structuralRenameToCanonicalName() throws {
        let library = try makeLibrary()
        let manager = try makeManager()
        let source = try write("王菲 - 棋子.mp3", bytes: [6, 6, 6], in: library)
        let track = try insertTrack(manager, path: source.path)

        let outcome = try TrackFileRenameService.rename(
            track: track, artist: "王靖雯", title: "棋子",
            libraryRoot: library, databaseManager: manager
        )

        let target = library.appendingPathComponent("王靖雯 - 棋子.mp3")
        #expect(outcome == .renamed(from: source.path, to: target.path))
        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(try Data(contentsOf: target) == Data([6, 6, 6]))
    }
}
