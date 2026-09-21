//
//  FileCleanupManagerTests.swift
//  QQPlayerTests
//
//  覆盖缺口审计 P2-2：`FileCleanupManager.reconcileMissingFiles` 的**选择逻辑**回归。
//
//  为什么值得测（不是形式测试）：该函数决定「库里哪些曲目行要消失」，两条路径的
//  用户数据后果完全不同——
//   · 文件真没了 → `deleteTrack`（**连收藏 / 歌单成员 / 播放历史一起清**）
//   · 文件还在、只是扩展名不在收录设置里 → `removeTrackFromLibrary`
//     （**只删 track 行，用户数据全留**）
//  `QQPlayer/Services/FileCleanupManager.swift` 的注释记录过一次真实数据损坏：
//  「此前走的是全量 deleteTrack，勾回格式后收藏与歌单成员资格永久丢失」。
//  既有测试只覆盖了数据库层（`DataIntegrityMigrationTests.swift` 的 D7），
//  没覆盖「这里怎么选」——本文件把选择逻辑钉住。
//
//  另有一条反向锁：`reconcileMissingFiles` 只处理**本次真正枚举成功的根**。
//  把「根不可用」（外置盘拔了 / 权限被拒 / 枚举失败）误当「空库」= 一次扫描抹掉
//  整个曲库的用户数据，所以空 roots 必须**一条都不删**。
//
//  依赖走构造注入（`FileCleanupManager(databaseManager:stateManager:)`，默认值仍是
//  生产单例 → 行为零变化），DB 用内存 `DatabaseQueue`，磁盘用临时目录真实文件
//  （被测代码直接调 `FileManager.default.fileExists`，不是注入闭包）。
//
//  注意：`#expect` 宏体不接受 `try`——断言一律先把取值 try 到局部变量再断言
//  （同 `DataIntegrityMigrationTests.swift` 的既有口径）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

// MARK: - Fixture

private enum CleanupFixture {
    /// `DeleteSettings` 在 `UserDefaults.standard` 里的键（与 `DeleteSettings.load()` 同源）。
    static let settingsKey = "DeleteSettings"

    /// 内存库 + `DatabaseManager`（照 `DataIntegrityMigrationTests` 的 `init(dbWriter:)` 测试缝）。
    static func makeManager() throws -> (DatabaseManager, DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        return (manager, dbQueue)
    }

    /// 临时「曲库根」目录（真实文件系统）。
    static func makeRootDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 在根目录里落一个真实文件，返回其 URL。
    @discardableResult
    static func makeFile(in root: URL, named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("qqplayer-test".utf8).write(to: url)
        return url
    }

    /// 写死本轮启用扩展名后跑 body（真实 UserDefaults，测后恢复原值，不污染其它用例）。
    ///
    /// 标 `@MainActor`（连同闭包参数）：调用方都是 `@MainActor` 套件，闭包会捕获
    /// 非 Sendable 的 `FileCleanupManager`；不标会在 Swift 6 严格并发下报
    /// 「sending value of non-Sendable type '() async -> ()' risks causing data races」。
    @MainActor
    static func withAudioExtensions(
        _ extensions: [String],
        _ body: @MainActor () async throws -> Void
    ) async throws {
        let backup = UserDefaults.standard.data(forKey: settingsKey)
        defer {
            if let backup {
                UserDefaults.standard.set(backup, forKey: settingsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: settingsKey)
            }
        }
        var settings = DeleteSettings.load()
        settings.audioExtensions = extensions
        settings.save()
        try await body()
    }

    // MARK: 数据装配

    static func insertTrack(_ db: DatabaseQueue, stableId: String, title: String, path: String) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO track (stable_id, title, path) VALUES (?, ?, ?)",
                arguments: [stableId, title, path]
            )
        }
    }

    static func insertFavorite(_ db: DatabaseQueue, stableId: String) throws {
        try db.write { db in
            try db.execute(sql: "INSERT INTO favorite (track_stable_id) VALUES (?)", arguments: [stableId])
        }
    }

    /// 歌单成员资格（建一个普通歌单 + 一条成员行；同 `DataIntegrityFixture` 口径）。
    static func insertPlaylistMembership(_ db: DatabaseQueue, stableId: String) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO playlist (id, slug, title, created_at, updated_at, is_folder_synced)
                    VALUES (1, 'p1', 'P1', 0, 0, 0)
                """
            )
            try db.execute(
                sql: "INSERT INTO playlist_item (playlist_id, position, track_stable_id) VALUES (1, 1, ?)",
                arguments: [stableId]
            )
        }
    }

    static func insertPlayHistory(_ db: DatabaseQueue, stableId: String) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO play_history (track_stable_id, played_at, play_duration_ms) VALUES (?, 7, 0)",
                arguments: [stableId]
            )
        }
    }

    // MARK: 读取

    static func trackStableIds(_ db: DatabaseQueue) throws -> [String] {
        try db.read { try String.fetchAll($0, sql: "SELECT stable_id FROM track ORDER BY stable_id") }
    }

    static func favoriteIds(_ db: DatabaseQueue) throws -> [String] {
        try db.read { try String.fetchAll($0, sql: "SELECT track_stable_id FROM favorite ORDER BY track_stable_id") }
    }

    static func playlistMemberIds(_ db: DatabaseQueue) throws -> [String] {
        try db.read {
            try String.fetchAll($0, sql: "SELECT track_stable_id FROM playlist_item ORDER BY track_stable_id")
        }
    }

    static func playHistoryIds(_ db: DatabaseQueue) throws -> [String] {
        try db.read {
            try String.fetchAll($0, sql: "SELECT track_stable_id FROM play_history ORDER BY track_stable_id")
        }
    }
}

// MARK: - 用例

@Suite("曲库调和：删哪些、留哪些", .serialized)
@MainActor
struct FileCleanupManagerTests {
    /// 反向锁：空 roots = 「本次没有任何根枚举成功」，**不是**「曲库是空的」。
    /// 库里这条曲目的文件在磁盘上确实不存在——若误当空库去比，它就会被删掉。
    @Test("空 successfullyScannedRoots → 直接返回，一条不删")
    func emptyRootsDeleteNothing() async throws {
        let (database, dbQueue) = try CleanupFixture.makeManager()
        try CleanupFixture.insertTrack(dbQueue, stableId: "gone", title: "Gone", path: "/nonexistent/qqp/gone.mp3")
        try CleanupFixture.insertFavorite(dbQueue, stableId: "gone")

        let cleanup = FileCleanupManager(databaseManager: database)
        await cleanup.reconcileMissingFiles(in: [])

        let tracks = try CleanupFixture.trackStableIds(dbQueue)
        let favorites = try CleanupFixture.favoriteIds(dbQueue)
        #expect(tracks == ["gone"], "根不可用 ≠ 空库：曲目行必须原样保留")
        #expect(favorites == ["gone"], "用户数据同样不得被动")
    }

    /// 分支 1：文件真没了 → `deleteTrack`（全量删除，引用一起清）。
    @Test("文件不存在 → deleteTrack：曲目行 + 收藏/歌单/播放历史一起清")
    func missingFileGoesThroughFullDelete() async throws {
        let (database, dbQueue) = try CleanupFixture.makeManager()
        let root = try CleanupFixture.makeRootDirectory()
        let missingPath = root.appendingPathComponent("gone.mp3").path

        try CleanupFixture.insertTrack(dbQueue, stableId: "gone", title: "Gone", path: missingPath)
        try CleanupFixture.insertFavorite(dbQueue, stableId: "gone")
        try CleanupFixture.insertPlaylistMembership(dbQueue, stableId: "gone")
        try CleanupFixture.insertPlayHistory(dbQueue, stableId: "gone")

        let cleanup = FileCleanupManager(databaseManager: database)
        await cleanup.reconcileMissingFiles(in: [root])

        let tracks = try CleanupFixture.trackStableIds(dbQueue)
        let favorites = try CleanupFixture.favoriteIds(dbQueue)
        let members = try CleanupFixture.playlistMemberIds(dbQueue)
        let history = try CleanupFixture.playHistoryIds(dbQueue)
        #expect(tracks.isEmpty, "文件真没了 → 曲目行删掉")
        #expect(favorites.isEmpty, "deleteTrack 语义 = 引用一起清")
        #expect(members.isEmpty)
        #expect(history.isEmpty)
    }

    /// 分支 2（**数据损坏回归锁**）：文件还在、只是格式被取消收录 →
    /// 只删 track 行，收藏 / 歌单成员 / 播放历史必须全部留下。
    @Test("文件在但扩展名未收录 → removeTrackFromLibrary：收藏/歌单成员/播放历史仍在")
    func formatDisabledFileKeepsUserData() async throws {
        let (database, dbQueue) = try CleanupFixture.makeManager()
        let root = try CleanupFixture.makeRootDirectory()
        let fileURL = try CleanupFixture.makeFile(in: root, named: "song.wav")

        try CleanupFixture.insertTrack(dbQueue, stableId: "wav", title: "Wav", path: fileURL.path)
        try CleanupFixture.insertFavorite(dbQueue, stableId: "wav")
        try CleanupFixture.insertPlaylistMembership(dbQueue, stableId: "wav")
        try CleanupFixture.insertPlayHistory(dbQueue, stableId: "wav")

        let cleanup = FileCleanupManager(databaseManager: database)
        try await CleanupFixture.withAudioExtensions(["mp3", "flac"]) {
            await cleanup.reconcileMissingFiles(in: [root])
        }

        let fileStillThere = FileManager.default.fileExists(atPath: fileURL.path)
        let tracks = try CleanupFixture.trackStableIds(dbQueue)
        let favorites = try CleanupFixture.favoriteIds(dbQueue)
        let members = try CleanupFixture.playlistMemberIds(dbQueue)
        let history = try CleanupFixture.playHistoryIds(dbQueue)
        #expect(fileStillThere, "格式取消收录绝不动磁盘文件")
        #expect(tracks.isEmpty, "曲目行从曲库移除（勾回格式重扫即恢复）")
        #expect(favorites == ["wav"], "收藏必须留下——此前走 deleteTrack 正是在这里永久丢失")
        #expect(members == ["wav"], "歌单成员资格必须留下（同上）")
        #expect(history == ["wav"], "播放历史必须留下")
    }

    /// 库里这条曲目所在的根**本轮没枚举成功**（不在入参 roots 里）→ 一概不碰。
    @Test("根枚举失败但库里有该根曲目 → 不删")
    func tracksInUnscannedRootAreKept() async throws {
        let (database, dbQueue) = try CleanupFixture.makeManager()
        let scannedRoot = try CleanupFixture.makeRootDirectory()
        let unscannedRoot = try CleanupFixture.makeRootDirectory()
        // 这条的文件确实不存在：唯一能救它的就是「根不在本次成功枚举列表里」
        let path = unscannedRoot.appendingPathComponent("gone.mp3").path

        try CleanupFixture.insertTrack(dbQueue, stableId: "elsewhere", title: "Elsewhere", path: path)
        try CleanupFixture.insertFavorite(dbQueue, stableId: "elsewhere")

        let cleanup = FileCleanupManager(databaseManager: database)
        await cleanup.reconcileMissingFiles(in: [scannedRoot])

        let tracks = try CleanupFixture.trackStableIds(dbQueue)
        let favorites = try CleanupFixture.favoriteIds(dbQueue)
        #expect(tracks == ["elsewhere"], "未枚举成功的根里的曲目不得被当作「已删除」")
        #expect(favorites == ["elsewhere"])
    }

    /// 混合场景：一个根 3 条 → 恰删 1（文件没了）、移除 1（格式未收录）、保留 1（正常）。
    @Test("混合：1 缺失 + 1 格式未收录 + 1 正常 → 恰删 1、移除 1、保留 1")
    func mixedRootClassifiesEachTrackExactlyOnce() async throws {
        let (database, dbQueue) = try CleanupFixture.makeManager()
        let root = try CleanupFixture.makeRootDirectory()

        let missingPath = root.appendingPathComponent("missing.mp3").path
        let disabledURL = try CleanupFixture.makeFile(in: root, named: "disabled.wav")
        let keptURL = try CleanupFixture.makeFile(in: root, named: "kept.mp3")

        try CleanupFixture.insertTrack(dbQueue, stableId: "missing", title: "Missing", path: missingPath)
        try CleanupFixture.insertTrack(dbQueue, stableId: "disabled", title: "Disabled", path: disabledURL.path)
        try CleanupFixture.insertTrack(dbQueue, stableId: "kept", title: "Kept", path: keptURL.path)
        try CleanupFixture.insertFavorite(dbQueue, stableId: "missing")
        try CleanupFixture.insertFavorite(dbQueue, stableId: "disabled")
        try CleanupFixture.insertFavorite(dbQueue, stableId: "kept")

        let cleanup = FileCleanupManager(databaseManager: database)
        try await CleanupFixture.withAudioExtensions(["mp3"]) {
            await cleanup.reconcileMissingFiles(in: [root])
        }

        let tracks = try CleanupFixture.trackStableIds(dbQueue)
        let favorites = try CleanupFixture.favoriteIds(dbQueue)
        #expect(tracks == ["kept"], "只有正常那条留在曲库：缺失全删 / 格式未收录只移库")
        #expect(favorites == ["disabled", "kept"], "缺失那条连收藏一起清；格式未收录那条的收藏必须留")
    }
}
