//
//  FolderPlaylistRemovalTests.swift
//  QQPlayerTests
//
//  「子文件夹当作歌单」（folder-synced playlist）功能**彻底移除**的守护（2026-09-28）。
//
//  背景：上游继承的功能——扫描时按「音频文件的直接父目录」自动建/同步歌单
//  （`is_folder_synced` 标记 + `deleted_folder_playlist` 墓碑表 + playlist 三列
//  `folder_path / is_folder_synced / last_folder_sync`），用户已明确不再需要，
//  本批连行为、DB schema、跨端载荷、设置开关一起拔掉，并加一次性清理迁移删除两端存量。
//
//  本文件三类断言（删完之后没有现成测试替你守住，必须自己立）：
//   ① 行为/接线：扫描与共享导入管线**不再声明也不调用**任何建歌单入口
//      （仓库现成 seam = `MacIndexingGateTests` 那套「读源码 + 取函数体」，
//       本仓库没有能直跑整条扫描的注入点，故用接线形状断言，见报告「已知问题」）。
//   ② 迁移三态 + 幂等：老库（有列+存量行）→ 清理并删列；新库 / 已迁移库 → 不报错。
//   ③ 形状契约：剥注释/字符串后，`QQPlayer/**` + `Share/**` 全仓不再出现被移除的符号；
//      扫描器自带「注释/字符串不算」与「真代码必被抓到」双向自证（防断言空转）。
//
//  建库惯例同 DataIntegrityMigrationTests：`DatabaseQueue()` + `DatabaseManager(dbWriter:)`
//  + `createTables()`；无模拟器、无 UI。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

// MARK: - 读源码 / 建库基建（fail-closed：读不到 = 红，绝不静默通过）

private enum FolderPlaylistRemovalFixtures {
    /// 仓库根：本文件位于 <repo>/QQPlayerTests/ 下 → 上两级。
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 被移除符号的来源面（应用码 + 共享扩展）。
    static let scannedDirectories = ["QQPlayer", "Share"]

    static let scanningPath = "QQPlayer/Services/LibraryIndexer+Scanning.swift"
    static let sharedImportPath = "QQPlayer/Services/LibraryIndexer+SharedImport.swift"

    /// 功能移除后**不准再作为代码标识符出现**的符号（注释与字符串字面量不计）。
    static let bannedSymbols = [
        "isFolderSynced",
        "is_folder_synced",
        "folderPath",
        "folder_path",
        "lastFolderSync",
        "last_folder_sync",
        "createFolderPlaylist",
        "getFolderPlaylist",
        "getAllFolderPlaylists",
        "getFolderSyncedPlaylists",
        "syncPlaylistWithFolder",
        "processFolderPlaylists",
        "processFolderPlaylist",
        "processSharedFolderPlaylists",
        "clearDeletedFolderPlaylistTombstones",
        "autoCreateFolderPlaylists",
        "folderPlaylists",
        "deleted_folder_playlist",
    ]

    /// 每个扫描目录的文件数下限（防“目录枚举失败但返回空数组”把契约变成恒真）。
    static let minimumScannedFiles: [String: Int] = ["QQPlayer": 100, "Share": 1]

    enum FixtureError: Error, CustomStringConvertible {
        case sourceUnreadable(String)
        case functionNotFound(String)
        case scanAreaTooSmall(String, Int)

        var description: String {
            switch self {
            case .sourceUnreadable(let path): return "契约测试读不到源码（fail-closed）：\(path)"
            case .functionNotFound(let name): return "契约测试定位不到函数体（fail-closed）：\(name)"
            case .scanAreaTooSmall(let directory, let count):
                return "契约测试扫描面塌陷（fail-closed）：\(directory) 只枚举到 \(count) 个 Swift 文件"
            }
        }
    }

    static func source(at relativePath: String) throws -> String {
        let url: URL = repositoryRoot.appendingPathComponent(relativePath)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw FixtureError.sourceUnreadable(relativePath)
        }
        return text
    }

    /// 剥掉**行注释 / 块注释 / 字符串字面量内容**，只留代码结构。
    ///
    /// 为什么必须剥字符串：本次清理迁移**只能**用 SQL 与列名列表引用遗留名字
    /// （`DELETE FROM playlist WHERE is_folder_synced = 1` / `["folder_path", …]`），
    /// 那是合法且必需的；不剥的话「零残留」这条契约永远为红、只能靠白名单放水。
    /// 剥注释同 `MacIndexingGateTests`：文档注释里就写着这些名字。
    static func stripped(_ source: String) -> String {
        let characters = Array(source)
        let count = characters.count
        var out = ""
        out.reserveCapacity(count)
        var index = 0

        while index < count {
            let character = characters[index]

            // 行注释：整行丢弃（保留换行，便于 `functionBody` 定位）
            if character == "/", index + 1 < count, characters[index + 1] == "/" {
                while index < count, characters[index] != "\n" { index += 1 }
                continue
            }
            // 块注释
            if character == "/", index + 1 < count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < count, !(characters[index] == "*" && characters[index + 1] == "/") {
                    index += 1
                }
                index = min(index + 2, count)
                out.append(" ")
                continue
            }
            // 多行字符串 `"""…"""`：内容丢弃，仅留标记
            if character == "\"", index + 2 < count, characters[index + 1] == "\"", characters[index + 2] == "\"" {
                index += 3
                while index + 2 < count,
                      !(characters[index] == "\"" && characters[index + 1] == "\"" && characters[index + 2] == "\"") {
                    index += 1
                }
                index = min(index + 3, count)
                out.append("\"\"\"")
                continue
            }
            // 单行字符串：内容丢弃，仅留空引号对
            if character == "\"" {
                index += 1
                while index < count {
                    if characters[index] == "\\" { index += 2; continue }
                    if characters[index] == "\"" { index += 1; break }
                    index += 1
                }
                out.append("\"\"")
                continue
            }

            out.append(character)
            index += 1
        }
        return out
    }

    /// 取出函数体（含外层大括号）。大括号计数定位结尾（`MacIndexingGateTests` 同款）。
    /// 在**已剥离**源码上调用，避免字符串里的括号骗过计数。
    static func functionBody(named name: String, in source: String) throws -> String {
        let code = stripped(source)
        guard let declaration = code.range(of: "func \(name)("),
              let openBrace = code[declaration.lowerBound...].firstIndex(of: "{") else {
            throw FixtureError.functionNotFound(name)
        }
        var depth = 0
        var index = openBrace
        while index < code.endIndex {
            let character = code[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(code[openBrace ... index]) }
            }
            index = code.index(after: index)
        }
        throw FixtureError.functionNotFound(name)
    }

    /// 全仓（QQPlayer + Share）剥注释/字符串后的残留命中：`相对路径: 符号`。
    static func residueHits() throws -> [String] {
        var hits: [String] = []
        for directory in scannedDirectories {
            let root = repositoryRoot.appendingPathComponent(directory)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
                throw FixtureError.scanAreaTooSmall(directory, 0)
            }
            let urls = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            let floor = minimumScannedFiles[directory] ?? 1
            guard urls.count >= floor else {
                throw FixtureError.scanAreaTooSmall(directory, urls.count)
            }
            for url in urls {
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let code = stripped(raw)
                let relative = "\(directory)/\(url.lastPathComponent)"
                for symbol in bannedSymbols where code.contains(symbol) {
                    hits.append("\(relative): \(symbol)")
                }
            }
        }
        return hits.sorted()
    }
}

// MARK: - ① 行为 / 接线：扫描与共享导入不再产出歌单

@Suite("folder 歌单移除 · 扫描接线")
struct FolderPlaylistRemovalWiringTests {
    private typealias Fixtures = FolderPlaylistRemovalFixtures

    @Test("扫描器源码不再声明文件夹歌单生成函数（processFolderPlaylists / processFolderPlaylist）")
    func scannerNoLongerDeclaresFolderPlaylistBuilders() throws {
        let source = try Fixtures.source(at: Fixtures.scanningPath)
        #expect(!source.contains("processFolderPlaylists"))
        #expect(!source.contains("processFolderPlaylist("))
    }

    @Test("iOS 主扫与 macOS 主扫函数体都不再调用建歌单入口")
    func scanBodiesDoNotCreatePlaylists() throws {
        let source = try Fixtures.source(at: Fixtures.scanningPath)
        for function in ["scanLocalDocuments", "scanMusicFolder"] {
            let body = try Fixtures.functionBody(named: function, in: source)
            #expect(!body.contains("processFolderPlaylist"), "\(function) 仍在跑文件夹歌单生成")
            #expect(!body.contains("createPlaylist"), "\(function) 仍在建歌单")
            #expect(!body.contains("createFolderPlaylist"), "\(function) 仍在建文件夹歌单")
            #expect(!body.contains("syncPlaylistWithFolder"), "\(function) 仍在同步文件夹歌单")
        }
    }

    @Test("共享导入源码不再声明/调用文件夹歌单生成（processSharedFolderPlaylists）")
    func sharedImportNoLongerBuildsFolderPlaylists() throws {
        let source = try Fixtures.source(at: Fixtures.sharedImportPath)
        #expect(!source.contains("processSharedFolderPlaylists"))
        let body = try Fixtures.functionBody(named: "processSharedURLs", in: source)
        #expect(!body.contains("processSharedFolderPlaylists"))
        #expect(!body.contains("createPlaylist"))
        #expect(!body.contains("createFolderPlaylist"))
        #expect(!body.contains("syncPlaylistWithFolder"))
    }

    @Test("共享导入仍能把曲目入库（只摘掉建歌单那步，不误伤入库路径）")
    func sharedImportStillIndexesTracks() throws {
        let body = try Fixtures.functionBody(
            named: "processSharedURLs",
            in: Fixtures.source(at: Fixtures.sharedImportPath)
        )
        #expect(body.contains("processExternalFile"))
        #expect(body.contains("storeBookmarkPermanently"))
    }
}

// MARK: - ② 一次性清理迁移：三态 + 幂等

@Suite("folder 歌单移除 · 清理迁移")
struct FolderPlaylistRemovalMigrationTests {
    /// 老库：playlist 三列 + 墓碑表 + 一条 folder 歌单（含成员）+ 一条手动歌单（须保留）。
    private static func makeLegacyDatabase() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE playlist (
                    id INTEGER PRIMARY KEY,
                    slug TEXT NOT NULL UNIQUE,
                    title TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER NOT NULL,
                    last_played_at INTEGER DEFAULT 0,
                    folder_path TEXT,
                    is_folder_synced BOOLEAN DEFAULT 0,
                    last_folder_sync INTEGER,
                    custom_cover_image_path TEXT
                )
            """)
            try db.execute(sql: """
                CREATE TABLE playlist_item (
                    playlist_id INTEGER REFERENCES playlist(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    track_stable_id TEXT NOT NULL,
                    PRIMARY KEY (playlist_id, position)
                )
            """)
            try db.execute(sql: """
                CREATE TABLE deleted_folder_playlist (
                    folder_path TEXT PRIMARY KEY,
                    deleted_at INTEGER NOT NULL
                )
            """)
            try db.execute(sql: """
                INSERT INTO playlist
                    (id, slug, title, created_at, updated_at, last_played_at, folder_path, is_folder_synced, last_folder_sync)
                VALUES (1, 'folder-pl', 'Folder', 1, 1, 0, '/m/folder', 1, 1)
            """)
            try db.execute(sql: "INSERT INTO playlist_item (playlist_id, position, track_stable_id) VALUES (1, 0, 's-1')")
            try db.execute(sql: """
                INSERT INTO playlist
                    (id, slug, title, created_at, updated_at, last_played_at, folder_path, is_folder_synced, last_folder_sync)
                VALUES (2, 'manual-pl', 'Manual', 1, 1, 0, NULL, 0, NULL)
            """)
            try db.execute(sql: "INSERT INTO playlist_item (playlist_id, position, track_stable_id) VALUES (2, 0, 's-2')")
            try db.execute(sql: "INSERT INTO deleted_folder_playlist (folder_path, deleted_at) VALUES ('gone', 1)")
        }
        return queue
    }

    private static func playlistColumnNames(_ queue: DatabaseQueue) throws -> [String] {
        try queue.read { db in try db.columns(in: "playlist").map(\.name).sorted() }
    }

    private static func hasTombstoneTable(_ queue: DatabaseQueue) throws -> Bool {
        try queue.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'deleted_folder_playlist'"
            ) ?? 0
            return count > 0
        }
    }

    @Test("老库：存量 folder 歌单（含成员）被删，手动歌单与其成员原样保留")
    func legacyDatabaseIsPurged() throws {
        let queue = try Self.makeLegacyDatabase()
        try queue.write { db in try DatabaseManager.purgeLegacySubfolderDerivedPlaylists(db) }

        try queue.read { db in
            let slugs = try String.fetchAll(db, sql: "SELECT slug FROM playlist ORDER BY slug")
            #expect(slugs == ["manual-pl"])
            let itemOwners = try Int64.fetchAll(db, sql: "SELECT playlist_id FROM playlist_item ORDER BY playlist_id")
            #expect(itemOwners == [2], "folder 歌单的成员行必须一起删，手动歌单成员必须留着")
        }
    }

    @Test("老库：三列与墓碑表被移除（三列存在才删）")
    func legacySchemaIsDropped() throws {
        let queue = try Self.makeLegacyDatabase()
        try queue.write { db in try DatabaseManager.purgeLegacySubfolderDerivedPlaylists(db) }

        let columns = try Self.playlistColumnNames(queue)
        #expect(
            columns == ["created_at", "custom_cover_image_path", "id", "last_played_at", "slug", "title", "updated_at"]
        )
        let hasTombstone = try Self.hasTombstoneTable(queue)
        #expect(hasTombstone == false)
    }

    @Test("迁移幂等：老库连跑两次不报错，第二次零改动")
    func migrationIsIdempotentOnLegacyDatabase() throws {
        let queue = try Self.makeLegacyDatabase()
        try queue.write { db in try DatabaseManager.purgeLegacySubfolderDerivedPlaylists(db) }
        let columnsAfterFirst = try Self.playlistColumnNames(queue)
        let slugsAfterFirst = try queue.read { db in try String.fetchAll(db, sql: "SELECT slug FROM playlist") }

        // 第二次：无列无表 → 全部分支跳过（不抛、不改）
        try queue.write { db in try DatabaseManager.purgeLegacySubfolderDerivedPlaylists(db) }

        let columnsAfterSecond = try Self.playlistColumnNames(queue)
        let slugsAfterSecond = try queue.read { db in try String.fetchAll(db, sql: "SELECT slug FROM playlist") }
        #expect(columnsAfterSecond == columnsAfterFirst)
        #expect(slugsAfterSecond == slugsAfterFirst)
    }

    @Test("新库：createTables 建出的 schema 无三列无墓碑表，跑迁移不报错、零改动")
    func freshDatabaseIsUnaffected() throws {
        let queue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: queue)
        try manager.createTables()

        let columnsBefore = try Self.playlistColumnNames(queue)
        #expect(!columnsBefore.contains("folder_path"))
        #expect(!columnsBefore.contains("is_folder_synced"))
        #expect(!columnsBefore.contains("last_folder_sync"))
        let hasTombstone = try Self.hasTombstoneTable(queue)
        #expect(hasTombstone == false)

        try queue.write { db in try DatabaseManager.purgeLegacySubfolderDerivedPlaylists(db) }
        let columnsAfter = try Self.playlistColumnNames(queue)
        #expect(columnsAfter == columnsBefore)
    }

    @Test("新库直接跑迁移（createTables 之前）不报错：playlist 表不存在也算新库")
    func purgeOnDatabaseWithoutPlaylistTableIsSafe() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in try DatabaseManager.purgeLegacySubfolderDerivedPlaylists(db) }
        let hasPlaylistTable = try queue.read { db in
            (try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'playlist'"
            ) ?? 0) > 0
        }
        #expect(hasPlaylistTable == false)
    }
}

// MARK: - ③ 形状契约：全仓无残留符号

@Suite("folder 歌单移除 · 形状契约")
struct FolderPlaylistResidueContractTests {
    private typealias Fixtures = FolderPlaylistRemovalFixtures

    @Test("剥注释/字符串后，QQPlayer + Share 全仓不再出现被移除的符号")
    func repositoryHasNoResidue() throws {
        let hits = try Fixtures.residueHits()
        #expect(hits.isEmpty, "仍有 folder 歌单残留符号：\(hits)")
    }

    @Test("扫描器自证：注释与字符串里的符号不算（防止把注释/文字当代码）")
    func stripperIgnoresCommentsAndStrings() {
        let obfuscated = """
        // isFolderSynced folderPath
        /* createFolderPlaylist */
        let text = "is_folder_synced"
        let other = \"\"\"
        folder_path
        \"\"\"
        """
        let code = Fixtures.stripped(obfuscated)
        for symbol in ["isFolderSynced", "folderPath", "createFolderPlaylist", "is_folder_synced", "folder_path"] {
            #expect(!code.contains(symbol), "剥除失败，残留 `\(symbol)`：\(code)")
        }
    }

    @Test("扫描器自证：真代码里的符号必被抓到（防止断言空转）")
    func strippedCodeKeepsRealSymbols() {
        let real = """
        let isFolderSynced = try db.columns(in: "playlist").map(\\.name)
        func createFolderPlaylist() {}
        """
        let code = Fixtures.stripped(real)
        #expect(code.contains("isFolderSynced"))
        #expect(code.contains("createFolderPlaylist"))

        // 端到端自证：把残留喂进同一套符号清单，必须报出来
        let hits = Fixtures.bannedSymbols.filter { code.contains($0) }
        #expect(hits.contains("isFolderSynced"))
        #expect(hits.contains("createFolderPlaylist"))
    }

    @Test("扫描面地基：仓库根解析正确且扫描到足够文件（防空数组恒真）")
    func scanScopeResolves() throws {
        let marker = Fixtures.repositoryRoot.appendingPathComponent(Fixtures.scanningPath)
        #expect(FileManager.default.fileExists(atPath: marker.path), "仓库根解析错了：\(Fixtures.repositoryRoot.path)")

        let shares = Fixtures.repositoryRoot.appendingPathComponent("Share")
        let shareFiles = try FileManager.default
            .contentsOfDirectory(at: shares, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!shareFiles.isEmpty, "Share/ 目录枚举为空——扫描面塌陷")
    }
}
