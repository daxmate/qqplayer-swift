//
//  LibraryLayoutMigrationTests.swift
//  QQPlayerTests
//
// target: ios-only
//
//  2026-09-22「Documents 文件夹化 + 曲库根 = Documents/Music + track.path 改相对」的回归。
//
//  为什么要测（每条都对应一个真实后果）：
//   · **路径形态**：`track.path` 从绝对路径改成「相对 Music 根」的相对路径后，读取必须
//     经 `LibraryRoot` 解回绝对 URL。散落的 `URL(fileURLWithPath: track.path)` 会把相对串
//     按 cwd 拼成垃圾绝对路径 → 播放「文件不存在」。
//   · **换容器**：重装后容器 UUID 变化，同一相对路径必须解析到**新**根（这是改成相对路径
//     的全部意义；退化成绝对路径 = 重装后曲库再次全悬空）。
//   · **扫描单层**：用户口径是 `Documents/Music` 单层不递归 ⇒ `Music/<子目录>/` 不收录。
//   · **一次性迁移器**：幂等、失败不删原件、冲突不覆盖、干跑只统计 —— 每一条都是
//     「用户数据可能被搬丢」的防线。
//
//  全程用临时目录 + 内存库（**按用例注入** `.documentDirectory` 指向临时根的 `FileManager`，
//  取代已删除的进程级静态 `LibraryRoot.documentsRootOverride`；见 `DocumentsRootTestSupport.swift`），
//  不碰真机数据、不启模拟器交互。
//
//  ⚠️ 与 v2（`LibraryHiddenLayoutMigrationTests.swift`）是**两个独立套件**：Swift Testing 里
//  **不同套件之间仍然并行**（`.serialized` 只约束同一套件内的用例）。两者不再共享任何可变状态 ——
//  各自的临时根经**按用例注入的 `FileManager`** 生效，跨套件并发无法互相污染
//  （2026-09-22 CI 实证：此前共享的进程级静态根被并行套件互相改写 ⇒ 双方都出现
//  「没看见自己搭的文件」的断言失败）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

@Suite("曲库布局迁移（文件夹化 v1）：路径解析 + 根条目迁移", .serialized)
struct LibraryLayoutMigrationTests {
    // MARK: - Fixture

    /// 临时 Documents 根（真实文件系统） + 指向它的注入式 `FileManager`（按用例，进程内无共享静态）。
    /// 用例把 `fileManager` 传进生产的注入缝（迁移器 / `LibraryRoot.*(fileManager:)`）。
    private func withDocumentsRoot(_ body: (URL, FileManager) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-layout-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try body(root, DocumentsRootFileManager(documentsRoot: root))
    }

    /// 内存库 + `DatabaseManager`（同 `FileCleanupManagerTests` 的测试缝）。
    private func makeManager() throws -> DatabaseManager {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        return manager
    }

    private func makeMigrator(database: DatabaseManager, fileManager: FileManager) -> LibraryLayoutMigrator {
        // UserDefaults 用独立 suite：不污染 App 的真实完成门。
        let defaults = UserDefaults(suiteName: "library-layout-tests-\(UUID().uuidString)") ?? .standard
        defaults.removeObject(forKey: LibraryLayoutMigrator.completionDefaultsKey)
        return LibraryLayoutMigrator(database: database, defaults: defaults, fileManager: fileManager)
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

    private func insertTrackRow(
        _ manager: DatabaseManager,
        stableId: String,
        path: String,
        title: String = "Song"
    ) throws {
        let track = Track(
            stableId: stableId,
            title: title,
            durationMs: 1000,
            path: path,
            fileSize: 8,
            modificationDate: 1000
        )
        try manager.upsertTrack(track)
    }

    // MARK: - 路径形态（储存/解析的唯一入口）

    @Test("曲库根下文件存相对路径，曲库外文件仍存绝对路径")
    func storesRelativeInsideMusicRootAndAbsoluteOutside() throws {
        try withDocumentsRoot { documents, fileManager in
            let insideURL = documents
                .appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
                .appendingPathComponent("song.flac")
            let outsideURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("qqplayer-outside-\(UUID().uuidString).flac")

            let insideStored = LibraryRoot.storedPath(for: insideURL, fileManager: fileManager)
            let outsideStored = LibraryRoot.storedPath(for: outsideURL, fileManager: fileManager)

            #expect(insideStored == "song.flac")
            #expect(outsideStored == outsideURL.standardizedFileURL.path)
            // 存储形态幂等：再归一化一次结果不变（所有写入点因此可以无脑调用）。
            #expect(LibraryRoot.storedPath(forAbsolutePath: insideStored, fileManager: fileManager) == insideStored)
            // 解析回绝对 URL 必须与源一致。
            #expect(LibraryRoot.absoluteURL(forStoredPath: insideStored, fileManager: fileManager).path == insideURL.standardizedFileURL.path)
            // 曲库内 / 曲库外判定。
            #expect(LibraryRoot.isExternalPath(insideStored, fileManager: fileManager) == false)
            #expect(LibraryRoot.isExternalPath(outsideStored, fileManager: fileManager))
        }
    }

    @Test("换容器：同一相对路径在不同 Documents 根下解析到各自的新根")
    func relativePathResolvesAgainstCurrentRoot() throws {
        try withDocumentsRoot { firstRoot, fileManager in
            let stored = "song.flac"
            let firstResolved = LibraryRoot.absoluteURL(forStoredPath: stored, fileManager: fileManager)
            #expect(firstResolved.path == firstRoot
                .appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
                .appendingPathComponent("song.flac").path)

            // 模拟「重装换数据容器」：换一个 Documents 根，同一相对路径必须落到新根。
            try withDocumentsRoot { secondRoot, fileManager in
                let secondResolved = LibraryRoot.absoluteURL(forStoredPath: stored, fileManager: fileManager)
                #expect(secondRoot.path != firstRoot.path)
                #expect(secondResolved.path == secondRoot
                    .appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
                    .appendingPathComponent("song.flac").path)
            }
        }
    }

    @Test("旧数据容器前缀归一化：换 UUID 的旧路径解回现容器")
    func rebasesLegacyContainerPrefix() throws {
        try withDocumentsRoot { documents, fileManager in
            let legacy = "/private/var/mobile/Containers/Data/Application/"
                + "D1917C90-5506-4FD0-ACD9-636334DA54C1/Documents/Music/song.flac"
            let stored = LibraryRoot.storedPath(forAbsolutePath: legacy, fileManager: fileManager)
            #expect(stored == "song.flac")
            #expect(LibraryRoot.absoluteURL(forStoredPath: stored, fileManager: fileManager).path
                == documents
                .appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
                .appendingPathComponent("song.flac").path)

            // 非容器绝对路径（外置盘 / iCloud）原样保留，绝不被误当沙盒内文件。
            let external = "/Volumes/Ext/Music/song.flac"
            #expect(LibraryRoot.rebasedFromLegacyContainer(external, fileManager: fileManager) == external)

            // 反例（2026-09-22 CI 修正）：只有「容器 ID 后面**紧跟** `Documents`」才算旧数据
            // 容器。临时目录与 App Group 共享容器都含 `/Containers/`，一旦被改写就会指向
            // 不存在的文件 ⇒ 全库行被误判「悬空」。两类路径必须原样返回。
            let tempLike = "/private/var/mobile/Containers/Data/Application/"
                + "342470F4-7E34-49DF-A756-DE0F76486423/tmp/staging/Documents/song.flac"
            #expect(LibraryRoot.rebasedFromLegacyContainer(tempLike, fileManager: fileManager) == tempLike)
            let appGroup = "/private/var/mobile/Containers/Shared/AppGroup/"
                + "8B1F2C34-1111-2222-3333-444455556666/Documents/song.flac"
            #expect(LibraryRoot.rebasedFromLegacyContainer(appGroup, fileManager: fileManager) == appGroup)
        }
    }

    @Test("stableId 迁移中立：旧基准根（Documents）与新基准根（Music）派生同一身份")
    func stableIdIsNeutralAcrossMusicFolderMove() throws {
        try withDocumentsRoot { documents, fileManager in
            let beforeMove = documents.appendingPathComponent("song.flac").path
            let afterMove = documents
                .appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
                .appendingPathComponent("song.flac").path
            // 改动前基准根 = Documents，改动后 = Documents/Music。
            // 同一首歌在两边派生出的身份路径**字面相同**（都是 `song.flac`）
            // ⇒ 这轮文件夹化不改身份，收藏 / 歌单 / 播放历史不会因搬家失联。
            #expect(
                DatabaseManager.identityPath(forPath: beforeMove, relativeRoot: documents)
                    == "song.flac"
            )
            #expect(
                DatabaseManager.identityPath(
                    forPath: afterMove,
                    relativeRoot: LibraryRoot.musicRootURL(fileManager: fileManager)
                ) == "song.flac"
            )
            #expect(
                DatabaseManager.generatePathStableId(forPath: beforeMove, relativeRoot: documents)
                    == DatabaseManager.generatePathStableId(
                        forPath: afterMove,
                        relativeRoot: LibraryRoot.musicRootURL(fileManager: fileManager)
                    )
            )
        }
    }

    // MARK: - 单层扫描

    @Test("扫描单层：Music 一层收录，Music 子目录不收录（递归模式仍收录）")
    func singleLevelScanExcludesSubdirectories() throws {
        try withDocumentsRoot { documents, _ in
            let musicRoot = documents.appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
            try writeFile(musicRoot.appendingPathComponent("a.flac"))
            try writeFile(musicRoot.appendingPathComponent("sub/b.flac"))

            let singleLevel = try MusicDirectoryScanner.audioFilesSync(
                in: musicRoot,
                enabledExtensions: ["flac"],
                recursive: false
            )
            let names = Set(singleLevel.map(\.lastPathComponent))
            #expect(names == ["a.flac"])

            // 递归模式（macOS 多层文件夹的既有口径）不受影响。
            let recursive = try MusicDirectoryScanner.audioFilesSync(
                in: musicRoot,
                enabledExtensions: ["flac"],
                recursive: true
            )
            #expect(Set(recursive.map(\.lastPathComponent)) == ["a.flac", "b.flac"])
        }
    }

    // MARK: - 计划（纯逻辑）

    @Test("计划：目标同名 → 跳过不搬；不同名 → 搬 + 产出 path 改写")
    func planSkipsConflictsAndRewritesMovedRows() {
        let candidates: [LibraryLayoutMigrationPlanner.Candidate] = [
            .init(sourceRelativePath: "a.flac", size: 8, category: .music),
            .init(sourceRelativePath: "b.flac", size: 8, category: .music),
        ]
        let existing: [LibraryLayoutMigrationPlanner.ExistingTarget] = [
            .init(directory: LibraryRoot.musicDirectoryName, name: "a.flac", size: 8),
        ]
        let rows: [LibraryLayoutMigrationPlanner.TrackRow] = [
            .init(stableId: "sid-a", storedPath: "/old/Documents/a.flac", legacyDocumentsRelativePath: "a.flac"),
            .init(stableId: "sid-b", storedPath: "/old/Documents/b.flac", legacyDocumentsRelativePath: "b.flac"),
            // 已是相对形态（已迁完的行）→ 不产生改写。
            .init(stableId: "sid-c", storedPath: "c.flac", legacyDocumentsRelativePath: nil),
        ]

        let plan = LibraryLayoutMigrationPlanner.makePlan(
            candidates: candidates,
            existingTargets: existing,
            trackRows: rows
        )

        #expect(plan.skips.map(\.sourceRelativePath) == ["a.flac"])
        #expect(plan.skips.first?.reason == "targetExistsSameSize")
        #expect(plan.moves.map(\.sourceRelativePath) == ["b.flac"])
        // 只有「真搬了的」行才改写 path（a.flac 被跳过 → 行不动）。
        #expect(plan.rewrites.map(\.stableId) == ["sid-b"])
        #expect(plan.rewrites.first?.newStoredPath == "b.flac")
    }

    @Test("分类：只认规划类，未规划文件（含 lyrics-cache / 其它目录）一律不动")
    func categoryOnlyCoversPlannedFiles() {
        #expect(
            LibraryLayoutMigrationRules.category(
                rootFileName: "song.flac", directoryName: nil, enabledAudioExtensions: ["flac"]
            ) == .music
        )
        #expect(
            LibraryLayoutMigrationRules.category(
                rootFileName: "app.log", directoryName: nil, enabledAudioExtensions: ["flac"]
            ) == .logs
        )
        #expect(
            LibraryLayoutMigrationRules.category(
                rootFileName: LibraryRoot.artworkMappingFileName,
                directoryName: nil,
                enabledAudioExtensions: ["flac"]
            ) == .artwork
        )
        #expect(
            LibraryLayoutMigrationRules.category(
                rootFileName: "abc.json", directoryName: "lyrics-manual", enabledAudioExtensions: ["flac"]
            ) == .lyrics
        )
        #expect(
            LibraryLayoutMigrationRules.category(
                rootFileName: "abc.json", directoryName: "lyrics-cache", enabledAudioExtensions: ["flac"]
            ) == nil
        )
        #expect(
            LibraryLayoutMigrationRules.category(
                rootFileName: "qqplayer-favorites.json", directoryName: nil, enabledAudioExtensions: ["flac"]
            ) == nil
        )
        #expect(
            LibraryLayoutMigrationRules.category(
                rootFileName: "song.flac", directoryName: nil, enabledAudioExtensions: ["mp3"]
            ) == nil
        )
    }

    // MARK: - 迁移器（端到端，临时目录 + 内存库）

    @Test("迁移：Documents 根音频搬进 Music，DB 行改写成相对路径（身份不变）")
    func migratorMovesAudioAndRewritesPath() throws {
        try withDocumentsRoot { documents, fileManager in
            let manager = try makeManager()
            let sourceURL = documents.appendingPathComponent("song.flac")
            try writeFile(sourceURL)
            // 行 id 按**改动前的基准根**（Documents）派生 —— 与改动后按 Music 根派生的
            // 结果相同（都是 `song.flac`），正所谓「搬家不换身份」；这样才落进
            // `migrateTrackForMovedFile` 的 equal-id 分支（只回写 path、不动 id）。
            let stableId = DatabaseManager.generatePathStableId(
                forPath: sourceURL.path,
                relativeRoot: documents
            )
            try insertTrackRow(manager, stableId: stableId, path: sourceURL.path)

            let summary = makeMigrator(database: manager, fileManager: fileManager).run()

            #expect(summary.didComplete)
            #expect(summary.movedByCategory[LibraryLayoutMigrationRules.Category.music.rawValue] == 1)
            #expect(summary.rewrittenPaths == 1)

            let musicRoot = documents.appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
            let destination = musicRoot.appendingPathComponent("song.flac")
            #expect(FileManager.default.fileExists(atPath: destination.path))
            #expect(FileManager.default.fileExists(atPath: sourceURL.path) == false)

            let row = try manager.getTrack(byStableId: stableId)
            #expect(row?.path == "song.flac")
            // stableId 迁移中立：搬家不换身份（否则收藏/歌单全断）。
            #expect(row?.stableId == stableId)
        }
    }

    @Test("迁移：规划目录建立 + 旧目录内容搬进对应目录（歌词/封面/日志）")
    func migratorMovesLegacyDirectoriesAndLogs() throws {
        try withDocumentsRoot { documents, fileManager in
            let manager = try makeManager()
            try writeFile(documents.appendingPathComponent("lyrics-manual/abc.json"))
            try writeFile(documents.appendingPathComponent("ArtworkCache/hash.jpg"))
            try writeFile(documents.appendingPathComponent(LibraryRoot.artworkMappingFileName))
            try writeFile(documents.appendingPathComponent("app.log"))
            try writeFile(documents.appendingPathComponent("db-debug.log"))

            let summary = makeMigrator(database: manager, fileManager: fileManager).run()
            #expect(summary.didComplete)

            let lyrics = documents.appendingPathComponent(LibraryRoot.lyricsDirectoryName, isDirectory: true)
            let artwork = documents.appendingPathComponent(LibraryRoot.artworkDirectoryName, isDirectory: true)
            let logs = documents.appendingPathComponent(LibraryRoot.logsDirectoryName, isDirectory: true)
            #expect(FileManager.default.fileExists(atPath: lyrics.appendingPathComponent("abc.json").path))
            #expect(FileManager.default.fileExists(atPath: artwork.appendingPathComponent("hash.jpg").path))
            // 封面映射表是**元数据**：不在搬迁清单里，旧位置保留作只读兜底
            // （合并与落新位置由 `ArtworkManager.loadMapping` 每次启动做）。
            // 也不能是「同名冲突跳过」——那会把「按元数据语义不搬」误读成冲突。
            #expect(FileManager.default.fileExists(
                atPath: documents.appendingPathComponent(LibraryRoot.artworkMappingFileName).path
            ))
            #expect(FileManager.default.fileExists(
                atPath: artwork.appendingPathComponent(LibraryRoot.artworkMappingFileName).path
            ) == false)
            #expect(summary.skipped.contains { $0.hasPrefix(LibraryRoot.artworkMappingFileName) } == false)
            #expect(summary.failed.isEmpty)
            #expect(FileManager.default.fileExists(atPath: logs.appendingPathComponent("app.log").path))
            #expect(FileManager.default.fileExists(atPath: logs.appendingPathComponent("db-debug.log").path))
            // 规划目录四个都在。
            for name in LibraryRoot.plannedDirectoryNames {
                #expect(FileManager.default.fileExists(
                    atPath: documents.appendingPathComponent(name, isDirectory: true).path
                ))
            }
        }
    }

    @Test("迁移幂等：清完成门后重跑结果一致、不重复搬")
    func migratorIsIdempotent() throws {
        try withDocumentsRoot { documents, fileManager in
            let manager = try makeManager()
            let sourceURL = documents.appendingPathComponent("song.flac")
            try writeFile(sourceURL)
            try insertTrackRow(manager, stableId: "sid", path: sourceURL.path)

            let migrator = makeMigrator(database: manager, fileManager: fileManager)
            let first = migrator.run()
            #expect(first.didComplete)

            // 第二次：完成门已置位 → 直接跳过（不重复搬）。
            let second = migrator.run()
            #expect(second.alreadyCompleted)
            #expect(second.movedTotal == 0)

            // 清门后重跑：逐项动作本身也幂等（源已不在旧位置 → 无待搬项、无失败）。
            migrator.resetCompletionGate()
            let third = migrator.run()
            #expect(third.movedTotal == 0)
            #expect(third.failed.isEmpty)
            #expect(third.rewrittenPaths == 0)

            let musicRoot = documents.appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
            #expect(FileManager.default.fileExists(atPath: musicRoot.appendingPathComponent("song.flac").path))
            #expect(try manager.getAllTracks().count == 1)
            #expect(try manager.getAllTracks().first?.path == "song.flac")
        }
    }

    @Test("冲突：目标同名不覆盖、原件仍在、计入跳过")
    func migratorSkipsTargetConflict() throws {
        try withDocumentsRoot { documents, fileManager in
            let manager = try makeManager()
            let sourceURL = documents.appendingPathComponent("song.flac")
            try writeFile(sourceURL, bytes: 8)
            let existingURL = documents
                .appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
                .appendingPathComponent("song.flac")
            try writeFile(existingURL, bytes: 3)
            try insertTrackRow(manager, stableId: "sid", path: sourceURL.path)

            let summary = makeMigrator(database: manager, fileManager: fileManager).run()

            #expect(summary.skipped.count == 1)
            #expect(summary.movedTotal == 0)
            // 源原件仍在（不删不覆盖），目标内容未被改写。
            #expect(FileManager.default.fileExists(atPath: sourceURL.path))
            let existingSize = try FileManager.default
                .attributesOfItem(atPath: existingURL.path)[.size] as? Int
            #expect(existingSize == 3)
        }
    }

    @Test("失败路径：单项失败不中断整体、不删原件、完成门不置位")
    func migratorKeepsGoingAfterItemFailure() throws {
        try withDocumentsRoot { documents, fileManager in
            let manager = try makeManager()
            let audioURL = documents.appendingPathComponent("song.flac")
            try writeFile(audioURL)
            // 「其它项照常成功」用**手工歌词**做样本（而不是 `app.log`）：`AppLog` 的 iOS
            // 落点也经 `LibraryRoot`（会被本用例注入的 Documents 根重定向），并行跑的
            // 其它套件随时可能在 `<根>/Logs/app.log` 落一行 ⇒ `app.log` 那一项会被判
            // 「目标已存在 → 跳过」（跳过是设计行为，不是失败）。歌词目录没有这种外部写入者。
            try writeFile(documents.appendingPathComponent("lyrics-manual/abc.json"))
            // 让曲库根**不可建**：Documents 下放一个同名**文件**（不是目录）→
            // 建 Music 目录失败 + 往 Music/ 里搬必然失败，而 Logs 那一项照常成功。
            try writeFile(documents.appendingPathComponent(LibraryRoot.musicDirectoryName))

            let migrator = makeMigrator(database: manager, fileManager: fileManager)
            let summary = migrator.run()

            #expect(summary.didComplete == false)
            #expect(summary.failed.isEmpty == false)
            // 其它项不受影响（单条失败不中断整体）。
            #expect(summary.movedByCategory[LibraryLayoutMigrationRules.Category.lyrics.rawValue] == 1)
            #expect(FileManager.default.fileExists(
                atPath: documents.appendingPathComponent(LibraryRoot.lyricsDirectoryName, isDirectory: true)
                    .appendingPathComponent("abc.json").path
            ))
            // 失败项的原件仍在原处（失败不删原件）。
            #expect(FileManager.default.fileExists(atPath: audioURL.path))

            // 完成门未置位 → 下次启动会重试（用同一 defaults 重跑，只见 not-completed）。
            let retry = migrator.run()
            #expect(retry.alreadyCompleted == false)
        }
    }

    @Test("干跑：只统计不搬（文件与 DB 都不动）")
    func dryRunOnlyReports() throws {
        try withDocumentsRoot { documents, fileManager in
            let manager = try makeManager()
            let sourceURL = documents.appendingPathComponent("song.flac")
            try writeFile(sourceURL)
            try insertTrackRow(manager, stableId: "sid", path: sourceURL.path)

            let migrator = makeMigrator(database: manager, fileManager: fileManager)
            let summary = migrator.run(dryRun: true)

            #expect(summary.isDryRun)
            #expect(summary.movedByCategory[LibraryLayoutMigrationRules.Category.music.rawValue] == 1)
            #expect(summary.rewrittenPaths == 0)
            // 文件没搬、DB 没改、规划目录也没建。
            #expect(FileManager.default.fileExists(atPath: sourceURL.path))
            #expect(try manager.getTrack(byStableId: "sid")?.path == sourceURL.path)
            let musicRoot = documents.appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
            #expect(FileManager.default.fileExists(atPath: musicRoot.path) == false)
            // 干跑不置完成门 → 之后真跑仍会执行。
            let real = migrator.run()
            #expect(real.alreadyCompleted == false)
            #expect(real.movedTotal == 1)
        }
    }

    @Test("未规划文件与 Music 历史子目录：一律不动、不递归、不搬平")
    func migratorLeavesUnplannedFilesAlone() throws {
        try withDocumentsRoot { documents, fileManager in
            let manager = try makeManager()
            try writeFile(documents.appendingPathComponent("qqplayer-favorites.json"))
            try writeFile(documents.appendingPathComponent("lyrics-cache/search/x.json"))
            try writeFile(documents.appendingPathComponent("Nested/song.flac"))
            try writeFile(
                documents
                    .appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
                    .appendingPathComponent("sub/old.flac")
            )

            let summary = makeMigrator(database: manager, fileManager: fileManager).run()

            #expect(summary.movedTotal == 0)
            #expect(FileManager.default.fileExists(atPath: documents.appendingPathComponent("qqplayer-favorites.json").path))
            #expect(FileManager.default.fileExists(atPath: documents.appendingPathComponent("lyrics-cache/search/x.json").path))
            #expect(FileManager.default.fileExists(atPath: documents.appendingPathComponent("Nested/song.flac").path))
            #expect(FileManager.default.fileExists(
                atPath: documents
                    .appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
                    .appendingPathComponent("sub/old.flac").path
            ))
        }
    }
}
