//
//  ReinstallLibraryPurgeTests.swift
//  QQPlayerTests
//
// target: ios-only
//
//  「重装（数据容器 UUID 变化）后曲库被清空」的**端到端回归**。
//
//  真机事故（2026-09-23 00:43Z 一次启动）：App Group 容器里的 `qqplayer.db`
//  track 225 → 0、play_history 882 → 2、favorite 1 → 0、playlist_item 443 → 0。
//  根因形态有两条，都在本文件里钉死：
//   ①（已修，`6dcab50`）`migrateTrackStableIdAndPath` 在 `oldStableId == newStableId`
//      时先 update 再 deleteAll —— 删掉的就是刚更新过的那唯一一行；
//   ②（本文件新增的洞）后置维护的 `FileCleanupManager.checkForOrphanedFiles` 把
//      「**入库 path** 解出来不存在」的**曲库内**行直接 `deleteTrack`（连收藏 / 歌单成员 /
//      播放历史一起清）。它**没有扫描上下文**却每次启动都跑：后置维护挂在
//      `onIndexingCompleted`（`AppCoordinator+iCloud.swift`）上，后者由
//      `isIndexingPublisher` 的 sink 触发，而 `CurrentValueSubject` **订阅即送当前值
//      false** ⇒ 「⏭️ Recent app launch - skipping automatic scan」那种**跳过主扫**的
//      启动，15s 后照样清库；此时没有任何自愈跑过 ⇒ 悬空行被当成「文件没了」。
//
//  口径（本文件的判据）：
//   · 曲库内行删不删，只由 `reconcileMissingFiles` 判（要求「本轮枚举过它的根」+
//     「主扫之后」——那时主扫已按 stableId 修好悬空 path，剩下的「不存在」才是真删除）；
//   · **曲库外（书签类）文件**的后置清扫语义不变（真不可达仍清）；
//   · 修 path 走唯一入口链（`LibraryIndexer` 判定 → `migrateTrackForMovedFile` →
//     `migrateTrackStableIdAndPath`），本文件不新开平行入口。
//
//  测试缝：内存库（`DatabaseManager(dbWriter:)` + `createTables()`）+ 注入 Documents 根
//  （`DocumentsRootFileManager`，见 `DocumentsRootTestSupport.swift`）⇒ 不写真机容器、
//  不启模拟器交互、无音频解析（被判定为 `.resyncPathOnly` 的行在扫描里直接 return）。
//
//  注意：`#expect` 宏体不接受 `try`——断言一律先把取值 try 到局部变量再断言。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

// MARK: - Fixture

private enum ReinstallFixture {
    /// 旧数据容器前缀（真机取证里的形态 `…/Containers/Data/Application/<UUID>/Documents/…`）。
    static let oldContainerPrefix =
        "/private/var/mobile/Containers/Data/Application/1CA0DAEB-1111-2222-3333-444455556666"

    /// 「重装后 path 悬空」的两种入库形态：
    /// · `canonical`：`<旧容器>/Documents/Music/song.mp3`（当前曲库布局，`LibraryRoot`
    ///   的旧容器归一化**能**映射到现容器 ⇒ 只要现容器里真有这个文件就不算悬空）；
    /// · `legacy`：`<旧容器>/Documents/song.mp3`（曲库文件夹化之前的 Documents 根形态，
    ///   归一化后落在现容器 `Documents/song.mp3` ⇒ 指不到已搬进 `Music/` 的文件 = 真悬空）。
    static func stalePath(_ form: StalePathForm, fileName: String) -> String {
        switch form {
        case .canonical: return "\(oldContainerPrefix)/Documents/Music/\(fileName)"
        case .legacy: return "\(oldContainerPrefix)/Documents/\(fileName)"
        }
    }

    enum StalePathForm { case canonical, legacy }

    /// 内存库 + `DatabaseManager`（照 `DocumentsDerivedPathGuardTests` 的同一测试缝）。
    static func makeManager() throws -> DatabaseManager {
        let queue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: queue)
        try manager.createTables()
        return manager
    }

    /// 临时 Documents 根 + 指向它的注入 FM（每用例独立，结束即删）。
    /// 标 `@MainActor`（连同闭包参数）：调用方都是 `@MainActor` 套件，闭包会捕获
    /// 非 Sendable 的 `FileCleanupManager`（同 `FileCleanupManagerTests.withAudioExtensions` 口径）。
    @MainActor
    static func withDocumentsRoot(
        _ body: @MainActor (URL, DocumentsRootFileManager) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-reinstall-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try await body(root, DocumentsRootFileManager(documentsRoot: root))
    }

    /// 在（注入根的）曲库目录里落一个真实文件，返回其 URL。
    @discardableResult
    static func makeTrackFile(
        documents: URL,
        named name: String,
        insideMusicDirectory: Bool = true
    ) throws -> URL {
        let directory = insideMusicDirectory
            ? documents.appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
            : documents
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x41, count: 16).write(to: url)
        return url
    }

    // MARK: 曲库外（书签类）三件套

    /// 临时「曲库外」目录（书签 plist + 被改名文件都在这，每用例独立，结束即删）。
    @MainActor
    static func withExternalDirectory(
        _ body: @MainActor (URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-external-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    /// 在曲库外目录里落一个真实文件（内容非空——可访问性探测会真的读 1KB）。
    @discardableResult
    static func makeExternalFile(in directory: URL, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(repeating: 0x51, count: 64).write(to: url)
        return url
    }

    /// 书签 plist 的唯一入口实例，落点 = 给定临时目录（不碰真机 `.qqplayer/state`）。
    static func makeBookmarkStore(in directory: URL) -> ExternalFileBookmarkStore {
        ExternalFileBookmarkStore(directory: directory)
    }

    /// 把「解析得到 `url`」的书签写进 store（键 = stableId）。
    static func writeBookmark(
        for url: URL,
        stableId: String,
        store: ExternalFileBookmarkStore
    ) throws {
        let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try store.save([stableId: data])
    }

    // MARK: 行写入（raw SQL：不改 path / 不触发 upsert 的指纹与去重逻辑）

    static func insertTrack(
        _ manager: DatabaseManager,
        stableId: String,
        title: String,
        path: String,
        fileSize: Int64? = nil,
        modificationDate: Int64? = nil
    ) throws {
        try manager.write { db in
            try db.execute(
                sql: """
                    INSERT INTO track (stable_id, title, path, file_size, modification_date)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [stableId, title, path, fileSize, modificationDate]
            )
        }
    }

    static func insertFavorite(_ manager: DatabaseManager, stableId: String) throws {
        try manager.write { db in
            try db.execute(sql: "INSERT INTO favorite (track_stable_id) VALUES (?)", arguments: [stableId])
        }
    }

    /// 歌单成员资格（普通歌单一条成员行；同 `FileCleanupManagerTests` 口径）。
    /// 幂等：多条曲目共用同一个普通歌单（`id = 1`），同一用例连插多条时不得撞
    /// `playlist.id` / `playlist.slug` 的唯一约束（`INSERT OR IGNORE`）；成员行的
    /// 位置按歌单内当前最大位置 +1 递增，避免撞 `playlist_item` 的
    /// `(playlist_id, position)` 主键。单次调用仍是 position = 1，与原夹具一致。
    static func insertPlaylistMembership(_ manager: DatabaseManager, stableId: String) throws {
        try manager.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO playlist (id, slug, title, created_at, updated_at, is_folder_synced)
                VALUES (1, 'p1', 'P1', 0, 0, 0)
            """)
            try db.execute(
                sql: """
                    INSERT INTO playlist_item (playlist_id, position, track_stable_id)
                    VALUES (1, (SELECT COALESCE(MAX(position), 0) + 1 FROM playlist_item WHERE playlist_id = 1), ?)
                """,
                arguments: [stableId]
            )
        }
    }

    static func insertPlayHistory(_ manager: DatabaseManager, stableId: String) throws {
        try manager.write { db in
            try db.execute(
                sql: "INSERT INTO play_history (track_stable_id, played_at, play_duration_ms) VALUES (?, 7, 0)",
                arguments: [stableId]
            )
        }
    }

    /// 造一条「曲目行 + 收藏 + 歌单成员 + 播放历史」完备的曲目（真机事故里一起被清的那四张表）。
    static func insertCompleteTrack(
        _ manager: DatabaseManager,
        stableId: String,
        title: String,
        path: String,
        fileSize: Int64? = nil,
        modificationDate: Int64? = nil
    ) throws {
        try insertTrack(
            manager,
            stableId: stableId,
            title: title,
            path: path,
            fileSize: fileSize,
            modificationDate: modificationDate
        )
        try insertFavorite(manager, stableId: stableId)
        try insertPlaylistMembership(manager, stableId: stableId)
        try insertPlayHistory(manager, stableId: stableId)
    }

    // MARK: 读取

    static func trackIds(_ manager: DatabaseManager) throws -> [String] {
        try manager.write { db in
            try String.fetchAll(db, sql: "SELECT stable_id FROM track ORDER BY stable_id")
        }
    }

    static func favoriteIds(_ manager: DatabaseManager) throws -> [String] {
        try manager.write { db in
            try String.fetchAll(db, sql: "SELECT track_stable_id FROM favorite ORDER BY track_stable_id")
        }
    }

    static func playlistMemberIds(_ manager: DatabaseManager) throws -> [String] {
        try manager.write { db in
            try String.fetchAll(db, sql: "SELECT track_stable_id FROM playlist_item ORDER BY track_stable_id")
        }
    }

    static func playHistoryIds(_ manager: DatabaseManager) throws -> [String] {
        try manager.write { db in
            try String.fetchAll(db, sql: "SELECT track_stable_id FROM play_history ORDER BY track_stable_id")
        }
    }
}

// MARK: - Task A-1/A-2：重装后路径自愈（修 path，不删行）

@Suite("重装后悬空 path：修 path 不删行", .serialized)
@MainActor
struct ReinstallStalePathSelfHealTests {
    /// 旧容器 `Documents/Music/…` 形态：`LibraryRoot` 的旧容器归一化**能把 path 接回现容器**，
    /// 现容器里那个文件在 ⇒ 判定 `current`（无需改写 path，更不得删行）。
    @Test("A-1：旧容器 Documents/Music 形态 + 文件在曲库根下 ⇒ 判定 current，行原样保留")
    func canonicalStaleContainerPathCountsAsLive() async throws {
        try await ReinstallFixture.withDocumentsRoot { documents, fileManager in
            let manager = try ReinstallFixture.makeManager()
            let indexer = LibraryIndexer(databaseManager: manager)
            let file = try ReinstallFixture.makeTrackFile(documents: documents, named: "song.mp3")
            let fingerprint = try indexer.fileFingerprint(for: file)

            let stableId = DatabaseManager.generatePathStableId(forPath: file.path, fileManager: fileManager)
            try ReinstallFixture.insertTrack(
                manager,
                stableId: stableId,
                title: "Song",
                path: ReinstallFixture.stalePath(.canonical, fileName: "song.mp3"),
                fileSize: fingerprint.fileSize,
                modificationDate: fingerprint.modificationDate
            )

            let row = try manager.getTrack(byStableId: stableId)
            let existingRow = try #require(row)
            let decision = indexer.metadataRefreshDecision(
                existingRow,
                fingerprint: fingerprint,
                currentPath: file.path,
                fileManager: fileManager
            )
            #expect(decision == .current, "旧容器 Documents/Music 形态能被归一化接回现容器 ⇒ 不是悬空")
            let stale = indexer.staleStoredPath(existingRow, currentPath: file.path, fileManager: fileManager)
            #expect(stale == nil)

            // 行的 path 经唯一入口解析回**真实存在**的文件（旧容器前缀被归一化到注入根）。
            let resolved = LibraryRoot.absolutePath(forStoredPath: existingRow.path, fileManager: fileManager)
            #expect(resolved == file.standardizedFileURL.path)
            #expect(fileManager.fileExists(atPath: resolved))
            // 没有任何写动作 ⇒ 行还在。
            let ids = try ReinstallFixture.trackIds(manager)
            #expect(ids == [stableId])
        }
    }

    /// 旧容器 `Documents/…` 形态（曲库文件夹化之前的入库形态）：归一化后落在现容器
    /// `Documents/song.mp3`，而文件已搬进 `Music/` ⇒ 真悬空 ⇒ 判定 `resyncPathOnly`，
    /// 由 `migrateTrackForMovedFile` 按 stableId 只回写 path（行保留、stableId 不变）。
    @Test("A-2：旧容器 Documents 根形态 ⇒ 判定 resyncPathOnly 并按 stableId 修 path（不删行）")
    func legacyDocumentsRootStalePathIsRepairedByStableId() async throws {
        try await ReinstallFixture.withDocumentsRoot { documents, fileManager in
            let manager = try ReinstallFixture.makeManager()
            let indexer = LibraryIndexer(databaseManager: manager)
            let file = try ReinstallFixture.makeTrackFile(documents: documents, named: "song.mp3")
            let fingerprint = try indexer.fileFingerprint(for: file)

            // stableId = 现容器下的身份（容器 UUID 变化不改它——这正是自愈能成立的前提）。
            let stableId = DatabaseManager.generatePathStableId(forPath: file.path, fileManager: fileManager)
            try ReinstallFixture.insertTrack(
                manager,
                stableId: stableId,
                title: "Song",
                path: ReinstallFixture.stalePath(.legacy, fileName: "song.mp3"),
                fileSize: fingerprint.fileSize,
                modificationDate: fingerprint.modificationDate
            )

            let row = try manager.getTrack(byStableId: stableId)
            let existingRow = try #require(row)
            let needsRefresh = indexer.needsMetadataRefresh(
                existingRow,
                fingerprint: fingerprint,
                currentPath: file.path
            )
            #expect(needsRefresh, "路径维度必须让它进扫描处理（否则重装后永远不自愈）")
            let decision = indexer.metadataRefreshDecision(
                existingRow,
                fingerprint: fingerprint,
                currentPath: file.path,
                fileManager: fileManager
            )
            #expect(decision == .resyncPathOnly, "指纹未变 + path 悬空 ⇒ 只回写 path，不重解析")

            // 扫描的修复动作（`LibraryIndexer+Parsing.processLocalFile` 的 .resyncPathOnly 分支同形）。
            let resolutionsBefore = fileManager.documentDirectoryResolutionCount
            let returned = try manager.migrateTrackForMovedFile(
                oldStableId: stableId,
                newPath: file.path,
                fileManager: fileManager
            )
            #expect(returned == stableId, "iOS 身份不变：stableId 必须逐字不变（只改 path）")
            #expect(
                fileManager.documentDirectoryResolutionCount > resolutionsBefore,
                "身份/路径派生链内部绕回 .default（注入 FM 未生效）"
            )

            let repaired = try manager.getTrack(byStableId: stableId)
            let repairedRow = try #require(repaired)
            #expect(repairedRow.path == "song.mp3", "path 改写成相对曲库根（注入根内闭合）")
            #expect(repairedRow.stableId == stableId)
            #expect(repairedRow.title == "Song", "其余元数据不得被动")
            let ids = try ReinstallFixture.trackIds(manager)
            #expect(ids == [stableId], "修 path 不是删行：行数必须还是 1")
            #expect(fileManager.fileExists(atPath: LibraryRoot.absolutePath(
                forStoredPath: repairedRow.path,
                fileManager: fileManager
            )))
        }
    }

    /// 端到端（生产 FM 形态）：主扫处理一个 path 悬空的入库行 ⇒ 行保留且 path 解析到真实文件。
    /// 走的是 `LibraryIndexer.indexFile` 真实入口（不是判定函数），落库用内存库。
    @Test("A-3：主扫入口 indexFile 对悬空行只修 path、不删行（端到端）")
    func scanSelfHealsWithoutDeleting() async throws {
        let manager = try ReinstallFixture.makeManager()
        let indexer = LibraryIndexer(databaseManager: manager)
        // 真实文件放在系统临时目录（不属于真机 Documents ⇒ 生产 FM 下它按绝对路径入库，确定可断言）。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-reinstall-scan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("song.mp3")
        try Data(repeating: 0x42, count: 16).write(to: file)

        let fingerprint = try indexer.fileFingerprint(for: file)
        let stableId = DatabaseManager.generatePathStableId(forPath: file.path)
        try ReinstallFixture.insertTrack(
            manager,
            stableId: stableId,
            title: "Song",
            path: ReinstallFixture.stalePath(.canonical, fileName: "song.mp3"),
            fileSize: fingerprint.fileSize,
            modificationDate: fingerprint.modificationDate
        )
        try ReinstallFixture.insertFavorite(manager, stableId: stableId)

        await indexer.indexFile(file)

        let row = try manager.getTrack(byStableId: stableId)
        let scannedRow = try #require(row, "主扫不得删行")
        #expect(scannedRow.stableId == stableId)
        let resolved = LibraryRoot.absolutePath(forStoredPath: scannedRow.path)
        let resolvedExists = FileManager.default.fileExists(atPath: resolved)
        #expect(resolvedExists, "修完的 path 必须解析到真实文件：\(scannedRow.path)")
        let idsAfterScan = try ReinstallFixture.trackIds(manager)
        let favoritesAfterScan = try ReinstallFixture.favoriteIds(manager)
        #expect(idsAfterScan == [stableId])
        #expect(favoritesAfterScan == [stableId])
    }
}

// MARK: - Task A-2 后半：后置清扫（无扫描上下文）不得删库

@Suite("后置孤儿清扫：曲库内行不得被判删除", .serialized)
@MainActor
struct PostIndexSweepMustNotPurgeLibraryTests {
    /// **本次修复的回归锁**（修复前必红）：后置维护的孤儿清扫没有扫描上下文，
    /// 曲库内行「入库 path 解出来不存在」**不等于**「文件没了」——
    /// 重装换容器（或旧形态 path 尚未自愈）时它只是还没被主扫修正。
    /// ⇒ 该入口必须保留行（删除授权在 `reconcileMissingFiles`）。
    @Test("B-1：跳过主扫的启动里，后置清扫不得删任何曲库内行（含引用四表）")
    func postIndexSweepKeepsAllInternalRows() async throws {
        try await ReinstallFixture.withDocumentsRoot { documents, fileManager in
            let manager = try ReinstallFixture.makeManager()
            let cleanup = FileCleanupManager(databaseManager: manager)

            // ① 旧容器 Documents 根形态（归一化指不到文件）+ 文件在曲库根下 ⇒ 悬空，但文件没丢。
            let liveFile = try ReinstallFixture.makeTrackFile(documents: documents, named: "live.mp3")
            try ReinstallFixture.insertCompleteTrack(
                manager,
                stableId: "stale-forms",
                title: "Stale Forms",
                path: ReinstallFixture.stalePath(.legacy, fileName: "live.mp3")
            )
            // ② 当前布局的相对路径行 + 文件在曲库根下 ⇒ 正常行。
            try ReinstallFixture.insertCompleteTrack(
                manager,
                stableId: "relative-live",
                title: "Relative Live",
                path: "relative.mp3"
            )
            _ = try ReinstallFixture.makeTrackFile(documents: documents, named: "relative.mp3")
            // ③ 相对路径行但文件确实不在磁盘（无扫描上下文时**不得**据此删）。
            try ReinstallFixture.insertCompleteTrack(
                manager,
                stableId: "relative-gone",
                title: "Relative Gone",
                path: "gone.mp3"
            )

            await cleanup.checkForOrphanedFiles(fileManager: fileManager)

            let ids = try ReinstallFixture.trackIds(manager)
            #expect(
                ids == ["relative-gone", "relative-live", "stale-forms"],
                "没有扫描上下文 ⇒ 一条曲库内行都不许删（悬空 path 等主扫自愈，真删由 reconcileMissingFiles 判）"
            )
            let favorites = try ReinstallFixture.favoriteIds(manager)
            let members = try ReinstallFixture.playlistMemberIds(manager)
            let history = try ReinstallFixture.playHistoryIds(manager)
            #expect(favorites == ["relative-gone", "relative-live", "stale-forms"], "收藏不得被清")
            #expect(members == ["relative-gone", "relative-live", "stale-forms"], "歌单成员不得被清")
            #expect(history == ["relative-gone", "relative-live", "stale-forms"], "播放历史不得被清")
            #expect(fileManager.fileExists(atPath: liveFile.path), "清扫从不碰磁盘文件")
        }
    }

    /// 对照（语义未变）：曲库外（书签类）文件真不可达 ⇒ 仍按既有语义清理。
    /// 这条**必须**保持删除——否则 macOS（曲库 = `~/Music/QQPlayer`，判定为曲库外）会失去清理能力。
    @Test("B-2：曲库外文件不可达仍清（既有语义不变，含 macOS 曲库路径形态）")
    func postIndexSweepStillCleansUnreachableExternalFiles() async throws {
        try await ReinstallFixture.withDocumentsRoot { _, fileManager in
            let manager = try ReinstallFixture.makeManager()
            let cleanup = FileCleanupManager(databaseManager: manager)
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("qqplayer-outside-\(UUID().uuidString).mp3")
                .path
            try ReinstallFixture.insertCompleteTrack(
                manager,
                stableId: "external-gone",
                title: "External Gone",
                path: outside
            )
            #expect(!fileManager.fileExists(atPath: outside), "前提：曲库外文件确实不存在")

            await cleanup.checkForOrphanedFiles(fileManager: fileManager)

            let ids = try ReinstallFixture.trackIds(manager)
            let favorites = try ReinstallFixture.favoriteIds(manager)
            #expect(ids.isEmpty, "曲库外不可达文件仍按既有语义清理")
            #expect(favorites.isEmpty, "deleteTrack 语义 = 引用一起清")
        }
    }

    /// 口径定稿（`docs/library-storage-contract.md` §3.6）：曲库外文件**改名后**原 path 不可达，
    /// 但书签能解析到新位置且探测可访问 ⇒ **行保留**；且存储 path **保持旧值、不写回**
    /// （本入口无扫描上下文，不做自愈；path 修写的唯一入口链是 `migrateTrackForMovedFile`）。
    @Test("B-3：曲库外文件改名后书签解析到新位置且可访问 ⇒ 行保留、存储 path 逐字不变")
    func externalFileRenamedKeepsRowAndStoredPath() async throws {
        try await ReinstallFixture.withDocumentsRoot { _, fileManager in
            try await ReinstallFixture.withExternalDirectory { externalDirectory in
                let manager = try ReinstallFixture.makeManager()
                let store = ReinstallFixture.makeBookmarkStore(in: externalDirectory)
                // 改名后的**新位置**：真实文件 + 指向它的书签（书签只记录新位置）。
                let newLocation = try ReinstallFixture.makeExternalFile(
                    in: externalDirectory,
                    named: "renamed.mp3"
                )
                try ReinstallFixture.writeBookmark(
                    for: newLocation,
                    stableId: "external-renamed",
                    store: store
                )
                // 入库 path = **旧位置**（改名前的绝对路径），磁盘上已不存在。
                let oldLocation = externalDirectory.appendingPathComponent("original.mp3").path
                try ReinstallFixture.insertCompleteTrack(
                    manager,
                    stableId: "external-renamed",
                    title: "Renamed",
                    path: oldLocation
                )
                let oldLocationMissing = !fileManager.fileExists(atPath: oldLocation)
                let pointsElsewhere = newLocation.path != oldLocation
                #expect(oldLocationMissing, "前提：旧位置确实不存在（否则走的是原 path 可访问分支，测不到书签链）")
                #expect(pointsElsewhere, "前提：书签指向的确实是另一个位置")

                let cleanup = FileCleanupManager(databaseManager: manager, bookmarkStore: store)
                await cleanup.checkForOrphanedFiles(fileManager: fileManager)

                let ids = try ReinstallFixture.trackIds(manager)
                let favorites = try ReinstallFixture.favoriteIds(manager)
                #expect(ids == ["external-renamed"], "书签解析到新位置且可访问 ⇒ 不得删行")
                #expect(favorites == ["external-renamed"], "保留行的收藏不得被清")

                let row = try manager.getTrack(byStableId: "external-renamed")
                let storedRow = try #require(row, "行必须还在")
                #expect(storedRow.path == oldLocation, "存储 path 必须逐字保持旧值：改名不自愈写回")
            }
        }
    }

    /// 口径定稿（`docs/library-storage-contract.md` §3.6）：书签 plist **读不出来**（unreadable）
    /// 是「未知」而不是「没有书签」⇒ 清理路径必须保守保留（D2 原则，同 `BookmarkResolution.unknown`）。
    @Test("B-4：书签读不出来（unreadable）⇒ 曲库外行保守保留（D2）")
    func externalFileWithUnreadableBookmarkKeepsRow() async throws {
        try await ReinstallFixture.withDocumentsRoot { _, fileManager in
            try await ReinstallFixture.withExternalDirectory { externalDirectory in
                let manager = try ReinstallFixture.makeManager()
                let store = ReinstallFixture.makeBookmarkStore(in: externalDirectory)
                // 非原子写被截断的形态：plist 在磁盘上、但解析不出来。
                try Data("bookmarks:truncated".utf8).write(to: store.fileURL)
                let outcome = store.load()
                let isUnreadable: Bool
                switch outcome {
                case .unreadable: isUnreadable = true
                case .loaded: isUnreadable = false
                }
                #expect(isUnreadable, "前提：书签必须处于 unreadable 形态")

                let missing = externalDirectory.appendingPathComponent("gone.mp3").path
                try ReinstallFixture.insertCompleteTrack(
                    manager,
                    stableId: "external-unreadable",
                    title: "Unreadable",
                    path: missing
                )
                #expect(!fileManager.fileExists(atPath: missing), "前提：曲库外文件确实不存在")

                let cleanup = FileCleanupManager(databaseManager: manager, bookmarkStore: store)
                await cleanup.checkForOrphanedFiles(fileManager: fileManager)

                let ids = try ReinstallFixture.trackIds(manager)
                let favorites = try ReinstallFixture.favoriteIds(manager)
                #expect(ids == ["external-unreadable"], "书签读不出来 = 未知 ⇒ 保守保留")
                #expect(favorites == ["external-unreadable"], "保留行的收藏不得被清")
            }
        }
    }
}

// MARK: - 扫描尾部调和：唯一的「文件真没了 → 删行」授权点

@Suite("扫描尾部调和：只删「本轮枚举过的根」里真的没了的行", .serialized)
@MainActor
struct ScanReconciliationAuthorityTests {
    /// 调和只处理「解析出的绝对 URL 落在本轮成功枚举的根内」的行；根外的悬空行一律不碰。
    @Test("C-1：只删已枚举根内真的没了的行；根外/其它根的悬空行原样保留")
    func reconcileDeletesOnlyInsideSuccessfullyScannedRoots() async throws {
        try await ReinstallFixture.withDocumentsRoot { documents, fileManager in
            let manager = try ReinstallFixture.makeManager()
            let cleanup = FileCleanupManager(databaseManager: manager)
            let musicRoot = documents.appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
            _ = try ReinstallFixture.makeTrackFile(documents: documents, named: "kept.mp3")
            _ = try ReinstallFixture.makeTrackFile(documents: documents, named: "other-root.mp3")

            try ReinstallFixture.insertCompleteTrack(
                manager, stableId: "kept", title: "Kept", path: "kept.mp3"
            )
            try ReinstallFixture.insertCompleteTrack(
                manager, stableId: "deleted", title: "Deleted", path: "gone.mp3"
            )
            // 旧容器 Documents 根形态：归一化后落在现容器 `Documents/gone.mp3`（曲库根**之外**）。
            try ReinstallFixture.insertCompleteTrack(
                manager,
                stableId: "legacy-stale",
                title: "Legacy Stale",
                path: ReinstallFixture.stalePath(.legacy, fileName: "gone.mp3")
            )
            // 另一个根（本轮没成功枚举）里的行。
            try ReinstallFixture.insertCompleteTrack(
                manager,
                stableId: "unscanned-root",
                title: "Unscanned Root",
                path: documents.appendingPathComponent("gone.mp3").path
            )

            await cleanup.reconcileMissingFiles(in: [musicRoot], fileManager: fileManager)

            let ids = try ReinstallFixture.trackIds(manager)
            #expect(
                ids == ["kept", "legacy-stale", "unscanned-root"],
                "只有根内真的没了的 deleted 被删；根外/未枚举根/旧形态悬空行必须保留"
            )
            let favorites = try ReinstallFixture.favoriteIds(manager)
            #expect(!favorites.contains("deleted"), "真删除走 deleteTrack（引用一起清）")
            #expect(favorites.contains("legacy-stale"), "被保留行的用户数据不得被动")
        }
    }

    /// 判定顺序（本包的核心结论之一）：**先自愈、后判定**。
    /// 修复后的行（path 已相对化）落在扫描根内 —— 文件在就留、文件真没了才删。
    @Test("C-2：主扫自愈之后才判「文件不存在」（修好的行按现 path 判去留）")
    func reconcileJudgesAfterSelfHeal() async throws {
        try await ReinstallFixture.withDocumentsRoot { documents, fileManager in
            let manager = try ReinstallFixture.makeManager()
            let cleanup = FileCleanupManager(databaseManager: manager)
            let musicRoot = documents.appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
            let file = try ReinstallFixture.makeTrackFile(documents: documents, named: "song.mp3")
            let stableId = DatabaseManager.generatePathStableId(forPath: file.path, fileManager: fileManager)
            try ReinstallFixture.insertCompleteTrack(
                manager,
                stableId: stableId,
                title: "Song",
                path: ReinstallFixture.stalePath(.legacy, fileName: "song.mp3")
            )

            // ① 主扫的修复动作（同 `processLocalFile` 的 .resyncPathOnly 分支）。
            let returned = try manager.migrateTrackForMovedFile(
                oldStableId: stableId,
                newPath: file.path,
                fileManager: fileManager
            )
            #expect(returned == stableId)

            // ② 扫描尾部调和：文件在 ⇒ 保留。
            await cleanup.reconcileMissingFiles(in: [musicRoot], fileManager: fileManager)
            let afterScan = try ReinstallFixture.trackIds(manager)
            let favoritesAfterScan = try ReinstallFixture.favoriteIds(manager)
            #expect(afterScan == [stableId], "自愈后的行落在扫描根内且文件存在 ⇒ 必须保留")
            #expect(favoritesAfterScan == [stableId])

            // ③ 文件真被删掉后再扫一轮 ⇒ 这次才删（删除授权点仍然有效）。
            try FileManager.default.removeItem(at: file)
            await cleanup.reconcileMissingFiles(in: [musicRoot], fileManager: fileManager)
            let afterDelete = try ReinstallFixture.trackIds(manager)
            let favoritesAfterDelete = try ReinstallFixture.favoriteIds(manager)
            #expect(afterDelete.isEmpty, "文件真没了 ⇒ 调和删行（能力未被本包削弱）")
            #expect(favoritesAfterDelete.isEmpty, "deleteTrack 语义 = 引用一起清")
        }
    }

    /// 空 `roots` = 「本轮没有任何根枚举成功」，**不是**「曲库是空的」（重装场景下尤其危险：
    /// 整库 path 悬空 + 根不可用 ⇒ 一次误判即抹掉全库用户数据）。
    @Test("C-3：roots 为空 → 早退，一条不删（重装悬空行同样受保护）")
    func reconcileWithEmptyRootsDeletesNothing() async throws {
        try await ReinstallFixture.withDocumentsRoot { documents, fileManager in
            let manager = try ReinstallFixture.makeManager()
            let cleanup = FileCleanupManager(databaseManager: manager)
            _ = try ReinstallFixture.makeTrackFile(documents: documents, named: "live.mp3")
            try ReinstallFixture.insertCompleteTrack(
                manager,
                stableId: "stale-forms",
                title: "Stale Forms",
                path: ReinstallFixture.stalePath(.legacy, fileName: "live.mp3")
            )
            try ReinstallFixture.insertCompleteTrack(
                manager, stableId: "relative-gone", title: "Relative Gone", path: "gone.mp3"
            )

            await cleanup.reconcileMissingFiles(in: [], fileManager: fileManager)

            let ids = try ReinstallFixture.trackIds(manager)
            #expect(ids == ["relative-gone", "stale-forms"], "根不可用 ≠ 空库：一条都不许删")
            let favorites = try ReinstallFixture.favoriteIds(manager)
            #expect(favorites == ["relative-gone", "stale-forms"])
        }
    }
}
