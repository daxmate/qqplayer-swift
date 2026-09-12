//
//  DataIntegrityMigrationTests.swift
//  QQPlayerTests
//
//  审计 2026-09-12（B2 数据层完整性包）的回归用例：
//  - D1 旧库迁移完成门：两步都成功才上锁（失败 → 下次启动重试）
//  - D2 书签唯一入口：读失败 ≠ 无条目（坏 plist 不被空字典覆盖）
//  - D3 stableId 变更的引用面：书签键 + 三个歌词目录 + 封面映射一起搬
//  - D4 deleteTrack 记 outbox delete（v2 删除不传播下用于批次抑制）
//  - D5 文件移动 = stableId 由新路径重算（身份不变量）
//  - D6 引用迁移 OR IGNORE（主键冲突不再回滚整次入库事务）
//  - D7 格式取消收录：只移除曲目行，收藏/歌单/历史保留
//  - D8 搜索 LIKE 转义（专辑/歌单，含 % 与 _）
//
//  全部走 DatabaseManager.init(dbWriter:) 测试缝 + createTables()，无 UI、无模拟器交互。
//  注意：`#expect` 宏体不接受 `try`（宏展开成非 throwing 闭包）——断言一律先把
//  取值语句 try 到局部变量，再进 `#expect`。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

// MARK: - Fixture

private enum DataIntegrityFixture {
    static func makeManager() throws -> (DatabaseManager, DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        return (manager, dbQueue)
    }

    /// 临时 Documents（书签 plist / 歌词目录的文件侧迁移用）。
    static func makeTemporaryDocuments() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-data-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func insertPlaylist(db: Database, id: Int64, slug: String, title: String, folderSynced: Bool = false) throws {
        try db.execute(
            sql: """
                INSERT INTO playlist (id, slug, title, created_at, updated_at, is_folder_synced)
                VALUES (?, ?, ?, 0, 0, ?)
            """,
            arguments: [id, slug, title, folderSynced]
        )
    }

    static func outboxRows(_ db: Database) throws -> [SyncChangeLogRow] {
        try SyncChangeLogRow.order(Column("id")).fetchAll(db)
    }

    static func stableIds(_ db: Database, table: String) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT track_stable_id FROM \(table) ORDER BY track_stable_id")
    }
}

// MARK: - D1 旧库迁移完成门

struct LegacyTrackMigrationGateTests {
    @Test("D1：迁移完成门只在两步都成功时置位（任一步失败 → 下次启动重试）")
    func gateRequiresBothSteps() {
        #expect(LegacyTrackMigrationGate.shouldMarkCompleted(pathDedupSucceeded: true, stableIdMigrationSucceeded: true))
        #expect(!LegacyTrackMigrationGate.shouldMarkCompleted(pathDedupSucceeded: false, stableIdMigrationSucceeded: true))
        #expect(!LegacyTrackMigrationGate.shouldMarkCompleted(pathDedupSucceeded: true, stableIdMigrationSucceeded: false))
        #expect(!LegacyTrackMigrationGate.shouldMarkCompleted(pathDedupSucceeded: false, stableIdMigrationSucceeded: false))
    }

    @Test("D1：完成门读写往返 + 键为 v3（旧 v2 门不再被认作已完成 → 误置位的库重跑一次）")
    func gateRoundTripUsesV3Key() throws {
        #expect(LegacyTrackMigrationGate.completionKey == "database.legacyTrackMigrationsCompleted.v3")
        let suiteName = "qqplayer-tests-legacy-migration-gate-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // v2 门（历史误置位）不影响 v3 判定
        defaults.set(true, forKey: "database.legacyTrackMigrationsCompleted.v2")
        #expect(!LegacyTrackMigrationGate.isCompleted(defaults: defaults))

        LegacyTrackMigrationGate.markCompleted(defaults: defaults)
        #expect(LegacyTrackMigrationGate.isCompleted(defaults: defaults))
    }
}

// MARK: - D2 书签唯一入口（原子写 + 读失败不覆盖）

struct ExternalFileBookmarkStoreTests {
    @Test("D2：upsert 落盘并往返；remove 只删存在的键（不凭空写文件）")
    func upsertAndRemoveRoundTrip() throws {
        let documents = try DataIntegrityFixture.makeTemporaryDocuments()
        defer { try? FileManager.default.removeItem(at: documents) }
        let store = ExternalFileBookmarkStore(documentsURL: documents)
        let fileURL = documents.appendingPathComponent("ExternalFileBookmarks.plist")

        try store.upsert(Data("a".utf8), forStableId: "id-a")
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(store.loadedBookmarksOrEmpty() == ["id-a": Data("a".utf8)])

        let removedMissing = try store.remove(forStableId: "missing")
        #expect(removedMissing == false)
        let removedExisting = try store.remove(forStableId: "id-a")
        #expect(removedExisting == true)
        #expect(store.loadedBookmarksOrEmpty().isEmpty)
    }

    @Test("D2：坏 plist = unreadable（读失败 ≠ 无条目），且不会被空字典覆盖")
    func unreadableFileIsNeverOverwritten() throws {
        let documents = try DataIntegrityFixture.makeTemporaryDocuments()
        defer { try? FileManager.default.removeItem(at: documents) }
        let store = ExternalFileBookmarkStore(documentsURL: documents)
        let fileURL = documents.appendingPathComponent("ExternalFileBookmarks.plist")
        let garbage = Data("not a plist".utf8)
        try garbage.write(to: fileURL)

        guard case .unreadable = store.load() else {
            Issue.record("坏 plist 必须归为 .unreadable（清理路径要据此保守保留曲目）")
            return
        }
        // 便利读只用于展示场景：未知 → 空
        #expect(store.loadedBookmarksOrEmpty().isEmpty)

        // 写入口在读不出来时抛错，绝不覆盖（原文件保持原样）
        #expect(throws: (any Error).self) {
            try store.upsert(Data("x".utf8), forStableId: "any")
        }
        #expect(throws: (any Error).self) {
            try store.renameKeys(["any": "other"])
        }
        let after = try Data(contentsOf: fileURL)
        #expect(after == garbage)
    }

    @Test("D2：键迁移幂等 + 目标键已存在时保留目标（宁可留孤儿键也不覆盖真实书签）")
    func renameKeysIsConservativeAndIdempotent() throws {
        let documents = try DataIntegrityFixture.makeTemporaryDocuments()
        defer { try? FileManager.default.removeItem(at: documents) }
        let store = ExternalFileBookmarkStore(documentsURL: documents)

        try store.upsert(Data("old".utf8), forStableId: "old-id")
        try store.upsert(Data("kept".utf8), forStableId: "new-id")

        // 目标已存在 → 跳过（旧键保留）
        let skipped = try store.renameKeys(["old-id": "new-id"])
        #expect(skipped == 0)
        #expect(store.loadedBookmarksOrEmpty() == ["old-id": Data("old".utf8), "new-id": Data("kept".utf8)])

        // 目标不存在 → 迁移；重跑无事发生
        let renamed = try store.renameKeys(["old-id": "free-id"])
        #expect(renamed == 1)
        let renamedAgain = try store.renameKeys(["old-id": "free-id"])
        #expect(renamedAgain == 0)
        #expect(store.loadedBookmarksOrEmpty() == ["free-id": Data("old".utf8), "new-id": Data("kept".utf8)])
    }
}

// MARK: - D3 stableId 变更的引用面（文件侧）

struct TrackIdentityFileMigrationTests {
    @Test("D3：书签键 + 三个歌词目录一起跟随新 stableId（目录名取 LyricsStoreKind 单一事实源）")
    func fileReferencesFollowStableId() throws {
        let documents = try DataIntegrityFixture.makeTemporaryDocuments()
        defer { try? FileManager.default.removeItem(at: documents) }
        let store = ExternalFileBookmarkStore(documentsURL: documents)

        for kind in LyricsStoreKind.allCases {
            let directory = documents.appendingPathComponent(kind.directoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("lyrics-\(kind.rawValue)".utf8)
                .write(to: directory.appendingPathComponent("old-id.json"))
        }
        try store.upsert(Data("bookmark".utf8), forStableId: "old-id")

        let report = TrackIdentityMigration.migrateFileReferences(from: "old-id", to: "new-id", documentsURL: documents)

        #expect(report.bookmarksRenamed == 1)
        #expect(report.lyricsFilesRenamed == LyricsStoreKind.allCases.count)
        #expect(report.skipped.isEmpty)
        #expect(store.loadedBookmarksOrEmpty() == ["new-id": Data("bookmark".utf8)])
        for kind in LyricsStoreKind.allCases {
            let directory = documents.appendingPathComponent(kind.directoryName, isDirectory: true)
            let newFile = directory.appendingPathComponent("new-id.json")
            let oldFile = directory.appendingPathComponent("old-id.json")
            #expect(FileManager.default.fileExists(atPath: newFile.path))
            #expect(!FileManager.default.fileExists(atPath: oldFile.path))
        }

        // 幂等：重跑无事发生
        let second = TrackIdentityMigration.migrateFileReferences(from: "old-id", to: "new-id", documentsURL: documents)
        #expect(second.bookmarksRenamed == 0)
        #expect(second.lyricsFilesRenamed == 0)
    }

    @Test("D3：歌词目标文件已存在时不覆盖、不删源（宁可留孤儿也不丢用户歌词）")
    func lyricTargetExistingIsKept() throws {
        let documents = try DataIntegrityFixture.makeTemporaryDocuments()
        defer { try? FileManager.default.removeItem(at: documents) }
        let directory = documents.appendingPathComponent(LyricsStoreKind.manual.directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: directory.appendingPathComponent("old-id.json"))
        try Data("target".utf8).write(to: directory.appendingPathComponent("new-id.json"))

        let report = TrackIdentityMigration.migrateFileReferences(from: "old-id", to: "new-id", documentsURL: documents)

        #expect(report.lyricsFilesRenamed == 0)
        #expect(report.skipped.contains("manual:targetExists"))
        let source = try Data(contentsOf: directory.appendingPathComponent("old-id.json"))
        let target = try Data(contentsOf: directory.appendingPathComponent("new-id.json"))
        #expect(source == Data("source".utf8))
        #expect(target == Data("target".utf8))
    }

    @Test("D3：封面映射键重写是纯函数——目标已存在不覆盖、无关键不动")
    func artworkMappingRemapIsPureAndConservative() {
        let result = TrackIdentityMigration.remappedArtworkMapping(
            ["old-id": "hash-old", "new-id": "hash-new", "other": "hash-other"],
            remapping: ["old-id": "new-id"]
        )
        #expect(!result.changed)
        #expect(result.mapping == ["old-id": "hash-old", "new-id": "hash-new", "other": "hash-other"])

        let moved = TrackIdentityMigration.remappedArtworkMapping(
            ["old-id": "hash-old", "other": "hash-other"],
            remapping: ["old-id": "new-id"]
        )
        #expect(moved.changed)
        #expect(moved.mapping == ["new-id": "hash-old", "other": "hash-other"])
    }
}

// MARK: - D4 deleteTrack 记 outbox

struct DeleteTrackOutboxTests {
    @Test("D4：删除曲目时为其收藏/歌单项/播放历史记 outbox delete（抑制同键 pending upsert）")
    func deleteTrackRecordsDeleteOutbox() throws {
        let (manager, dbQueue) = try DataIntegrityFixture.makeManager()
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO track (stable_id, title, path) VALUES ('t1', 'T1', '/m/t1.flac')")
            try db.execute(sql: "INSERT INTO favorite (track_stable_id) VALUES ('t1')")
            try DataIntegrityFixture.insertPlaylist(db: db, id: 1, slug: "p1", title: "P1")
            try db.execute(sql: "INSERT INTO playlist_item (playlist_id, position, track_stable_id) VALUES (1, 1, 't1')")
            try db.execute(sql: "INSERT INTO play_history (track_stable_id, played_at, play_duration_ms) VALUES ('t1', 111, 0)")
            // folder-synced 歌单内容由本地扫描派生：不入跨端同步
            try DataIntegrityFixture.insertPlaylist(db: db, id: 2, slug: "folder", title: "F", folderSynced: true)
            try db.execute(sql: "INSERT INTO playlist_item (playlist_id, position, track_stable_id) VALUES (2, 1, 't1')")
            // 删除前本端刚加过收藏（这条 upsert 尚未发送 → 必须被删除抑制）
            try db.execute(sql: """
                INSERT INTO sync_outbox (entity, row_key, op, updated_at, payload_json)
                VALUES ('favorite', 't1', 'upsert', 1, NULL)
            """)
        }

        try manager.deleteTrack(byStableId: "t1")

        try dbQueue.read { db in
            let rows = try DataIntegrityFixture.outboxRows(db)
            let allRows = rows.map { "\($0.entity)|\($0.rowKey)|\($0.op)" }
            #expect(allRows.contains("favorite|t1|upsert"), "实际 outbox 行：\(allRows)")
            let deleteRows = rows.filter { $0.op == SyncChangeOp.delete.rawValue }
            let deleteKeys = Set(deleteRows.map { "\($0.entity)|\($0.rowKey)" })
            #expect(deleteKeys == Set([
                "favorite|t1",
                "playlist_item|p1|t1",
                "play_history|t1|111",
            ]))
            // folder-synced 歌单不产生 outbox
            #expect(!deleteRows.contains { $0.rowKey.contains("folder") })

            // 契约：v2 删除不上线，但 delete 行必须把同键 pending upsert 压掉
            // （否则对端会落地一条永远无法纠正的幽灵收藏）
            let policyRows = rows.map { SyncChangeLogPolicyRow(entity: $0.entity, rowKey: $0.rowKey, op: $0.op) }
            let transmittable = SyncChangeLogDeletionPolicy.transmittableIndexes(rows: policyRows)
            let favoriteUpsertIndex = rows.firstIndex {
                $0.entity == SyncChangeEntity.favorite.rawValue && $0.op == SyncChangeOp.upsert.rawValue
            }
            let pendingUpsertIndex = try #require(favoriteUpsertIndex)
            #expect(!transmittable.contains(pendingUpsertIndex))
        }
    }

    @Test("D4：没有引用行时 deleteTrack 不记空 delete（无行 = 本就没有）")
    func deleteTrackWithoutReferencesRecordsNothing() throws {
        let (manager, dbQueue) = try DataIntegrityFixture.makeManager()
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO track (stable_id, title, path) VALUES ('t2', 'T2', '/m/t2.flac')")
        }

        try manager.deleteTrack(byStableId: "t2")

        try dbQueue.read { db in
            let rows = try DataIntegrityFixture.outboxRows(db)
            #expect(rows.isEmpty)
        }
    }
}

// MARK: - D5 / D6 身份与引用迁移

struct TrackIdentityMigrationDatabaseTests {
    @Test("D5：文件移动 = stableId 由新路径重算（保持 SHA256(path) 不变量），引用随迁")
    func movedFileRecomputesStableId() throws {
        let (manager, dbQueue) = try DataIntegrityFixture.makeManager()
        let oldPath = "/m/old/track.flac"
        let newPath = "/m/new/track.flac"
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO track (stable_id, title, path) VALUES ('old-id', 'T', ?)",
                arguments: [oldPath]
            )
            try db.execute(sql: "INSERT INTO favorite (track_stable_id) VALUES ('old-id')")
        }

        let migrated = try manager.migrateTrackForMovedFile(oldStableId: "old-id", newPath: newPath)
        let newStableId = try #require(migrated)
        #expect(newStableId == DatabaseManager.generatePathStableId(forPath: newPath))

        try dbQueue.read { db in
            let row = try Track.filter(Column("stable_id") == newStableId).fetchOne(db)
            let fetched = try #require(row)
            #expect(fetched.path == newPath)
            // 不变量：库内 stable_id 永远等于所在路径的派生 id（此前只改 path 不改 id）
            #expect(fetched.stableId == DatabaseManager.generatePathStableId(forPath: fetched.path))
            let favorites = try DataIntegrityFixture.stableIds(db, table: "favorite")
            #expect(favorites == [newStableId])
        }

        // 幂等：旧 id 已不存在 → nil，不产生新行
        let secondRun = try manager.migrateTrackForMovedFile(oldStableId: "old-id", newPath: "/m/other.flac")
        #expect(secondRun == nil)
        let trackCount = try dbQueue.read { db in try Track.fetchCount(db) }
        #expect(trackCount == 1)
    }

    @Test("D6：同路径重复项与新 id 都有 favorite 行 → 入库不抛错（OR IGNORE + 清残留）")
    func upsertDedupWithConflictingFavoriteDoesNotThrow() throws {
        let (manager, dbQueue) = try DataIntegrityFixture.makeManager()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO track (id, stable_id, duration_ms, file_size, title, path) VALUES
                (1, 'keep-id', 1000, 100, 'X', '/m/x.flac'),
                (2, 'dup-id', 1000, 100, 'X', '/m/x.flac')
            """)
            // 裸 UPDATE 时这里会撞 favorite 主键 → 抛错 → 整次入库事务回滚（文件静默不入库）
            try db.execute(sql: "INSERT INTO favorite (track_stable_id) VALUES ('keep-id'), ('dup-id')")
            try DataIntegrityFixture.insertPlaylist(db: db, id: 1, slug: "p1", title: "P1")
            try db.execute(sql: "INSERT INTO playlist_item (playlist_id, position, track_stable_id) VALUES (1, 1, 'dup-id')")
            try db.execute(sql: "INSERT INTO play_history (track_stable_id, played_at, play_duration_ms) VALUES ('dup-id', 5, 0)")
        }

        try manager.upsertTrack(Track(stableId: "keep-id", title: "X", path: "/m/x.flac"))

        try dbQueue.read { db in
            let trackCount = try Track.fetchCount(db)
            let favorites = try DataIntegrityFixture.stableIds(db, table: "favorite")
            let playlistItems = try DataIntegrityFixture.stableIds(db, table: "playlist_item")
            // 历史跟随歌曲（P0-3），不被删除
            let history = try DataIntegrityFixture.stableIds(db, table: "play_history")
            #expect(trackCount == 1)
            #expect(favorites == ["keep-id"])
            #expect(playlistItems == ["keep-id"])
            #expect(history == ["keep-id"])
        }
    }

    @Test("D6：moveTrack 改名迁移走同一入口——四表引用齐全（含 play_history）")
    func moveTrackMigratesAllReferences() throws {
        let (manager, dbQueue) = try DataIntegrityFixture.makeManager()
        let oldPath = "/m/old/song.flac"
        let newPath = "/m/new/song.flac"
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO track (stable_id, title, path) VALUES ('old-id', 'S', ?)",
                arguments: [oldPath]
            )
            try db.execute(sql: "INSERT INTO favorite (track_stable_id) VALUES ('old-id')")
            try DataIntegrityFixture.insertPlaylist(db: db, id: 1, slug: "p1", title: "P1")
            try db.execute(sql: "INSERT INTO playlist_item (playlist_id, position, track_stable_id) VALUES (1, 1, 'old-id')")
            try db.execute(sql: "INSERT INTO play_history (track_stable_id, played_at, play_duration_ms) VALUES ('old-id', 7, 0)")
            try db.execute(sql: "INSERT INTO artist (id, name) VALUES (1, 'A')")
            try db.execute(sql: "INSERT INTO track_artist (track_stable_id, artist_id, position) VALUES ('old-id', 1, 0)")
        }

        try manager.moveTrack(from: oldPath, to: newPath)

        let expected = DatabaseManager.generatePathStableId(forPath: newPath)
        try dbQueue.read { db in
            let stableIds = try String.fetchAll(db, sql: "SELECT stable_id FROM track")
            let favorites = try DataIntegrityFixture.stableIds(db, table: "favorite")
            let playlistItems = try DataIntegrityFixture.stableIds(db, table: "playlist_item")
            let history = try DataIntegrityFixture.stableIds(db, table: "play_history")
            let artists = try DataIntegrityFixture.stableIds(db, table: "track_artist")
            #expect(stableIds == [expected])
            #expect(favorites == [expected])
            #expect(playlistItems == [expected])
            #expect(history == [expected])
            #expect(artists == [expected])
        }
    }
}

// MARK: - D7 格式取消收录

struct RemoveTrackFromLibraryTests {
    @Test("D7：只移除曲目行——收藏/歌单/播放历史保留（勾回格式重扫可恢复）")
    func keepsUserDataAndDeletesOnlyTrackRow() throws {
        let (manager, dbQueue) = try DataIntegrityFixture.makeManager()
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO track (stable_id, title, path) VALUES ('t1', 'T1', '/m/t1.flac')")
            try db.execute(sql: "INSERT INTO favorite (track_stable_id) VALUES ('t1')")
            try DataIntegrityFixture.insertPlaylist(db: db, id: 1, slug: "p1", title: "P1")
            try db.execute(sql: "INSERT INTO playlist_item (playlist_id, position, track_stable_id) VALUES (1, 1, 't1')")
            try db.execute(sql: "INSERT INTO play_history (track_stable_id, played_at, play_duration_ms) VALUES ('t1', 9, 0)")
        }

        try manager.removeTrackFromLibrary(byStableId: "t1")

        try dbQueue.read { db in
            let trackCount = try Track.fetchCount(db)
            let favorites = try DataIntegrityFixture.stableIds(db, table: "favorite")
            let playlistItems = try DataIntegrityFixture.stableIds(db, table: "playlist_item")
            let history = try DataIntegrityFixture.stableIds(db, table: "play_history")
            #expect(trackCount == 0)
            #expect(favorites == ["t1"])
            #expect(playlistItems == ["t1"])
            #expect(history == ["t1"])
        }

        // 对照：deleteTrack（文件真没了）会连引用一起清
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO track (stable_id, title, path) VALUES ('t2', 'T2', '/m/t2.flac')")
            try db.execute(sql: "INSERT INTO favorite (track_stable_id) VALUES ('t2')")
        }
        try manager.deleteTrack(byStableId: "t2")
        try dbQueue.read { db in
            let favorites = try DataIntegrityFixture.stableIds(db, table: "favorite")
            #expect(favorites == ["t1"])
        }
    }
}

// MARK: - D8 搜索 LIKE 转义

struct SearchEscapingTests {
    @Test("D8：专辑/歌单搜索转义 % 与 _（用户输入通配符不再命中整库）")
    func searchEscapesLikeWildcards() throws {
        let (manager, dbQueue) = try DataIntegrityFixture.makeManager()
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO album (id, title) VALUES
                (1, '100% Pure'), (2, 'Plain'), (3, 'a_b')
            """)
            try DataIntegrityFixture.insertPlaylist(db: db, id: 1, slug: "p1", title: "100% Pure")
            try DataIntegrityFixture.insertPlaylist(db: db, id: 2, slug: "p2", title: "Plain")
        }

        let percentAlbums = try manager.searchAlbums(query: "100%").map(\.title)
        let wildcardOnlyAlbums = try manager.searchAlbums(query: "%").map(\.title)
        let underscoreAlbums = try manager.searchAlbums(query: "a_b").map(\.title)
        let underscoreAsWildcardAlbums = try manager.searchAlbums(query: "axb").map(\.title)
        let plainAlbums = try manager.searchAlbums(query: "Plain").map(\.title)

        #expect(percentAlbums == ["100% Pure"])
        // 转义后 `%` 只是字面量：只命中标题里真含 `%` 的专辑（修前会命中整库）
        #expect(wildcardOnlyAlbums == ["100% Pure"])
        #expect(underscoreAlbums == ["a_b"])
        #expect(underscoreAsWildcardAlbums.isEmpty)
        #expect(plainAlbums == ["Plain"])

        let percentPlaylists = try manager.searchPlaylists(query: "100%").map(\.title)
        let wildcardOnlyPlaylists = try manager.searchPlaylists(query: "%").map(\.title)
        let plainPlaylists = try manager.searchPlaylists(query: "Plain").map(\.title)

        #expect(percentPlaylists == ["100% Pure"])
        #expect(wildcardOnlyPlaylists == ["100% Pure"])
        #expect(plainPlaylists == ["Plain"])
    }
}
