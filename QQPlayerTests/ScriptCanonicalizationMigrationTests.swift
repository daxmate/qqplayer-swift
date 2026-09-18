//
//  ScriptCanonicalizationMigrationTests.swift
//  QQPlayerTests
//
//  库内简繁归一（2026-09-18 用户拍板「落库全部是简体中文」）的回归用例：
//  - C1 规范形 = 显示层 toSimplified（唯一实现，不是第二份）
//  - C2 入库归口：upsertArtist / upsertAlbum(title + album_artist) / upsertTrack 落库即规范形
//  - C3 存量迁移：全库归名 → 同形歌手行合并 → 四个引用面全部重挂、零悬空
//  - C4 保留行规则：曲目多者优先，并列取 id 小者
//  - C5 幂等：第二次运行零改动
//  - C6 顺序依赖：归名后 #81 的分组键才能看见简繁分裂的同名专辑
//  - C7 #16 拆出的片段也走规范形（"周杰倫; 周杰伦" 只建一行）
//  - C8 孤儿行归既有 #74 清理（不在此迁移里造第二套）
//  全部走 DatabaseManager(dbWriter:) 测试缝 + createTables()，无 UI、无模拟器交互。
//  注意：`#expect` 宏体不接受 `try`——先 try 到局部变量再断言。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

// MARK: - Fixture

private enum CanonFixture {
    static func makeManager() throws -> (DatabaseManager, DatabaseQueue) {
        let dbQueue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: dbQueue)
        try manager.createTables()
        return (manager, dbQueue)
    }

    static func insertArtist(_ db: Database, id: Int64, name: String) throws {
        try db.execute(sql: "INSERT INTO artist (id, name) VALUES (?, ?)", arguments: [id, name])
    }

    static func insertAlbum(
        _ db: Database,
        id: Int64,
        artistId: Int64?,
        title: String,
        year: Int? = nil,
        albumArtist: String? = nil
    ) throws {
        try db.execute(
            sql: "INSERT INTO album (id, artist_id, title, year, album_artist) VALUES (?, ?, ?, ?, ?)",
            arguments: [id, artistId, title, year, albumArtist]
        )
    }

    static func insertTrack(
        _ db: Database,
        stableId: String,
        title: String,
        artistId: Int64?,
        albumId: Int64?
    ) throws {
        try db.execute(
            sql: "INSERT INTO track (stable_id, title, path, artist_id, album_id) VALUES (?, ?, ?, ?, ?)",
            arguments: [stableId, title, "/m/\(stableId).flac", artistId, albumId]
        )
    }

    static func linkTrackArtist(_ db: Database, stableId: String, artistId: Int64, position: Int) throws {
        try db.execute(
            sql: "INSERT INTO track_artist (track_stable_id, artist_id, position) VALUES (?, ?, ?)",
            arguments: [stableId, artistId, position]
        )
    }

    static func linkAlbumArtist(_ db: Database, albumId: Int64, artistId: Int64, position: Int) throws {
        try db.execute(
            sql: "INSERT INTO album_artist_link (album_id, artist_id, position) VALUES (?, ?, ?)",
            arguments: [albumId, artistId, position]
        )
    }

    /// 快照：全库行内容（用于幂等断言）。表名固定，避免动态 SQL 带来的不确定性。
    static func snapshot(_ db: Database) throws -> String {
        var parts: [String] = []
        parts += try String.fetchAll(db, sql: "SELECT id || '|' || name || '|' || IFNULL(name,'') FROM artist ORDER BY id")
        parts += try String.fetchAll(db, sql: """
            SELECT id || '|' || IFNULL(artist_id, -1) || '|' || title || '|' || IFNULL(year, -1) || '|' || IFNULL(album_artist, '')
            FROM album ORDER BY id
        """)
        parts += try String.fetchAll(db, sql: """
            SELECT stable_id || '|' || IFNULL(artist_id, -1) || '|' || IFNULL(album_id, -1) || '|' || title || '|' || path
            FROM track ORDER BY stable_id
        """)
        parts += try String.fetchAll(db, sql: """
            SELECT track_stable_id || '|' || artist_id || '|' || position FROM track_artist
            ORDER BY track_stable_id, artist_id
        """)
        parts += try String.fetchAll(db, sql: """
            SELECT album_id || '|' || artist_id || '|' || position FROM album_artist_link
            ORDER BY album_id, artist_id
        """)
        return parts.joined(separator: "\n")
    }

    /// 悬空引用：四个引用面里指向不存在行的条数（合并/删除后必须为 0）。
    static func danglingReferenceCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            SELECT
                (SELECT COUNT(*) FROM track WHERE artist_id IS NOT NULL
                    AND artist_id NOT IN (SELECT id FROM artist))
              + (SELECT COUNT(*) FROM track WHERE album_id IS NOT NULL
                    AND album_id NOT IN (SELECT id FROM album))
              + (SELECT COUNT(*) FROM track_artist WHERE artist_id NOT IN (SELECT id FROM artist))
              + (SELECT COUNT(*) FROM album_artist_link WHERE artist_id NOT IN (SELECT id FROM artist))
              + (SELECT COUNT(*) FROM album_artist_link WHERE album_id NOT IN (SELECT id FROM album))
              + (SELECT COUNT(*) FROM album WHERE artist_id IS NOT NULL
                    AND artist_id NOT IN (SELECT id FROM artist))
        """) ?? -1
    }
}

// MARK: - C1 规范形唯一入口

struct ScriptCanonicalizationContractTests {
    @Test("canonical 就是显示层 toSimplified（同一实现，不是第二份映射）")
    func canonicalEqualsDisplayToSimplified() {
        let samples = [
            "周杰倫", "絲路", "愛在西元前", "周杰倫 & 費玉清",
            "Adele", "Hello, World!", "宇多田ヒカル", "Beautiful World", "",
        ]
        for sample in samples {
            #expect(DisplayScriptNormalizer.canonical(sample) == DisplayScriptNormalizer.display(sample, direction: .toSimplified))
        }
    }

    @Test("canonical：英文/日文名原样返回，不被误伤")
    func canonicalLeavesLatinAndKanaAlone() {
        #expect(DisplayScriptNormalizer.canonical("Adele") == "Adele")
        #expect(DisplayScriptNormalizer.canonical("宇多田ヒカル") == "宇多田ヒカル")
        #expect(DisplayScriptNormalizer.canonical("Beautiful World") == "Beautiful World")
    }

    @Test("canonical：与显示方向解耦，UI 语言不影响库内规范形")
    func canonicalIsDirectionIndependent() {
        // 无论 preferredLocalizations 给出什么方向，库内规范形恒为简体。
        #expect(DisplayScriptNormalizer.canonical("周杰倫") == "周杰伦")
        #expect(DisplayScriptNormalizer.direction(for: ["zh-Hant"]) == .toTraditional)
        // 解耦的本质：canonical 恒简体（单参、与方向无关），display 才随方向变。
        #expect(DisplayScriptNormalizer.display("周杰伦", direction: .toSimplified) == "周杰伦")
        #expect(DisplayScriptNormalizer.display("周杰伦", direction: .toTraditional)
            != DisplayScriptNormalizer.display("周杰伦", direction: .toSimplified))
        // ⚠️ 已知局限（不属本契约）：`杰→傑` 是一字多繁（人名「周杰倫」vs 用词「傑出」），
        // 字符级映射无法两全 → toTraditional 会把「周杰伦」渲染成「周傑倫」。
        // 这是映射表层面既有的歧义，需另行决策（本测试不锁定它的具体结果）。
    }
}

// MARK: - C2 入库归口

struct ScriptCanonicalizationUpsertTests {
    @Test("upsertArtist：简繁两种写法命同一行，落库为规范形")
    func upsertArtistReusesCanonicalRow() throws {
        let (manager, dbQueue) = try CanonFixture.makeManager()
        let first = try manager.upsertArtist(name: "周杰倫")
        let second = try manager.upsertArtist(name: "周杰伦")

        #expect(first.id == second.id)
        #expect(second.name == "周杰伦")
        try dbQueue.read { db in
            let rows = try Artist.fetchAll(db)
            #expect(rows.count == 1)
            #expect(rows.first?.name == "周杰伦")
        }
    }

    @Test("upsertAlbum：简繁同形命同一行，title 与 album_artist 都落规范形")
    func upsertAlbumReusesCanonicalRow() throws {
        let (manager, dbQueue) = try CanonFixture.makeManager()
        let artist = try manager.upsertArtist(name: "梁静茹")
        let traditional = try manager.upsertAlbum(title: "絲路", artistId: artist.id, year: 2005, albumArtist: "梁靜茹")
        let simplified = try manager.upsertAlbum(title: "丝路", artistId: artist.id, year: 2005, albumArtist: "梁静茹")

        #expect(traditional.id == simplified.id)
        #expect(simplified.title == "丝路")
        #expect(simplified.albumArtist == "梁静茹")
        try dbQueue.read { db in
            let rows = try Album.fetchAll(db)
            #expect(rows.count == 1)
        }
    }

    @Test("upsertTrack：曲名落库即规范形")
    func upsertTrackStoresCanonicalTitle() throws {
        let (manager, _) = try CanonFixture.makeManager()
        try manager.upsertTrack(Track(stableId: "s1", title: "愛在西元前", path: "/m/s1.flac"))

        let stored = try manager.getTrack(byStableId: "s1")
        #expect(stored?.title == "爱在西元前")
    }
}

// MARK: - C3 / C4 / C5 / C8 存量迁移

struct ScriptCanonicalizationMigrationTests {
    /// 播种：两组同形歌手（一组曲目数并列、一组曲目数不同）+ 简繁同名专辑 + 孤儿行。
    private func seed(_ db: Database) throws {
        // 组 A：周杰倫(id1) / 周杰伦(id2)，各 1 首 → 并列，保留 id 小者 = 1
        try CanonFixture.insertArtist(db, id: 1, name: "周杰倫")
        try CanonFixture.insertArtist(db, id: 2, name: "周杰伦")
        // 组 B：费玉清(id3) 挂 1 首 < 費玉清(id4) 挂 2 首 → 保留曲目多者 = 4
        try CanonFixture.insertArtist(db, id: 3, name: "费玉清")
        try CanonFixture.insertArtist(db, id: 4, name: "費玉清")
        // 孤儿行：无曲目、无链接 → 由既有 #74 清理负责
        try CanonFixture.insertArtist(db, id: 5, name: "黎沸揮")

        // 专辑：简繁同名、同歌手、年份一致 → 归名后应被 #81 合并（C6）
        try CanonFixture.insertAlbum(db, id: 10, artistId: 1, title: "依然範特西", year: 2006, albumArtist: "周杰倫")
        try CanonFixture.insertAlbum(db, id: 11, artistId: 2, title: "依然范特西", year: 2006, albumArtist: "周杰伦")
        // 另一张专辑，验证 album.artist_id 重挂（不悬空、不被级联删）
        try CanonFixture.insertAlbum(db, id: 12, artistId: 4, title: "一剪梅", year: 1983, albumArtist: "費玉清")

        try CanonFixture.insertTrack(db, stableId: "t1", title: "千裏之外", artistId: 1, albumId: 10)
        try CanonFixture.insertTrack(db, stableId: "t2", title: "聽媽媽的話", artistId: 2, albumId: 11)
        try CanonFixture.insertTrack(db, stableId: "t3", title: "一剪梅", artistId: 4, albumId: 12)
        try CanonFixture.insertTrack(db, stableId: "t4", title: "千裏之外（合唱版）", artistId: 4, albumId: 12)

        try CanonFixture.linkTrackArtist(db, stableId: "t1", artistId: 1, position: 0)
        try CanonFixture.linkTrackArtist(db, stableId: "t2", artistId: 2, position: 0)
        try CanonFixture.linkTrackArtist(db, stableId: "t3", artistId: 3, position: 0)
        try CanonFixture.linkTrackArtist(db, stableId: "t4", artistId: 4, position: 0)

        try CanonFixture.linkAlbumArtist(db, albumId: 10, artistId: 1, position: 0)
        try CanonFixture.linkAlbumArtist(db, albumId: 11, artistId: 2, position: 0)
        try CanonFixture.linkAlbumArtist(db, albumId: 12, artistId: 4, position: 0)
    }

    @Test("存量迁移：归名 + 合并 + 四个引用面零悬空 + 曲目守恒")
    func migrationMergesAndRelinks() throws {
        let (manager, dbQueue) = try CanonFixture.makeManager()
        try dbQueue.write { db in try seed(db) }
        let tracksBefore = try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") }

        try manager.migrateCanonicalizeScriptForms()

        try dbQueue.read { db in
            // 组 A（并列 → 取 id 小者 1）、组 B（1 首 vs 2 首 → 取曲目多者 4）。
            // id=5 是「无曲目、无链接」的孤儿行：本迁移只负责**归名**（黎沸揮 → 黎沸挥）
            // 与**合并同形行**；删除空行是既有 #74 的职责（seed 注释同此口径），故它仍在。
            let artists = try Artist.order(Column("id")).fetchAll(db)
            #expect(artists.map(\.id) == [1, 4, 5])
            #expect(artists.map(\.name) == ["周杰伦", "费玉清", "黎沸挥"])

            // 曲名归名
            let titles = try String.fetchAll(db, sql: "SELECT title FROM track ORDER BY stable_id")
            #expect(titles == ["千里之外", "听妈妈的话", "一剪梅", "千里之外（合唱版）"])
            let canonCheck1 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track")
            #expect(canonCheck1 == tracksBefore)

            // 引用重挂：所有指向 loser（2 / 3）的引用都不存在
            let canonCheck2 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE artist_id IN (2, 3)")
            #expect(canonCheck2 == 0)
            let canonCheck3 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_artist WHERE artist_id IN (2, 3)")
            #expect(canonCheck3 == 0)
            let canonCheck4 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album_artist_link WHERE artist_id IN (2, 3)")
            #expect(canonCheck4 == 0)
            let canonCheck5 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album WHERE artist_id IN (2, 3)")
            #expect(canonCheck5 == 0)
            // album.artist_id 重挂后专辑没被级联删掉（删行前重挂）
            let canonCheck6 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album")
            #expect(canonCheck6 == 3)
            let canonCheck7 = try Int.fetchAll(db, sql: "SELECT DISTINCT artist_id FROM album ORDER BY artist_id").map(String.init)
            #expect(canonCheck7 == ["1", "4"])
            // 专辑文本也归名
            let albumTitles = try String.fetchAll(db, sql: "SELECT DISTINCT title FROM album ORDER BY title")
            #expect(albumTitles == ["一剪梅", "依然范特西"])

            let canonCheck8 = try CanonFixture.danglingReferenceCount(db)
            #expect(canonCheck8 == 0)
        }
    }

    @Test("保留行规则：曲目多者优先，并列才取 id 小者")
    func migrationKeepsRowWithMostTracks() throws {
        let (manager, dbQueue) = try CanonFixture.makeManager()
        try dbQueue.write { db in
            try CanonFixture.insertArtist(db, id: 7, name: "王菲")
            try CanonFixture.insertArtist(db, id: 8, name: "王菲") // 同形（此处无需繁体，规则与字形无关）
            try CanonFixture.insertTrack(db, stableId: "a1", title: "棋子", artistId: 7, albumId: nil)
            try CanonFixture.insertTrack(db, stableId: "a2", title: "红豆", artistId: 8, albumId: nil)
            try CanonFixture.insertTrack(db, stableId: "a3", title: "暧昧", artistId: 8, albumId: nil)
        }

        try manager.migrateCanonicalizeScriptForms()

        try dbQueue.read { db in
            let canonCheck9 = try Int.fetchAll(db, sql: "SELECT id FROM artist ORDER BY id")
            #expect(canonCheck9 == [8])
            let canonCheck10 = try Int.fetchAll(db, sql: "SELECT artist_id FROM track ORDER BY stable_id")
            #expect(canonCheck10 == [8, 8, 8])
            let canonCheck11 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track")
            #expect(canonCheck11 == 3)
            let canonCheck12 = try CanonFixture.danglingReferenceCount(db)
            #expect(canonCheck12 == 0)
        }
    }

    @Test("幂等：第二次运行零改动")
    func migrationIsIdempotent() throws {
        let (manager, dbQueue) = try CanonFixture.makeManager()
        try dbQueue.write { db in try seed(db) }

        try manager.migrateCanonicalizeScriptForms()
        let afterFirst = try dbQueue.read { db in try CanonFixture.snapshot(db) }
        try manager.migrateCanonicalizeScriptForms()
        let afterSecond = try dbQueue.read { db in try CanonFixture.snapshot(db) }

        #expect(afterFirst == afterSecond)
    }

    @Test("归名后 #81 的分组键才看得见简繁同名专辑（顺序依赖锁）")
    func mergeSplitAlbumsSeesCanonicalizedTitles() throws {
        let (manager, dbQueue) = try CanonFixture.makeManager()
        try dbQueue.write { db in try seed(db) }

        try manager.migrateCanonicalizeScriptForms()
        // 迁移本身不合并专辑（同形 ≠ 同一专辑），交给既有 #81
        let afterCanonical = try dbQueue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album") }
        #expect(afterCanonical == 3)

        try manager.migrateMergeSplitAlbums()

        try dbQueue.read { db in
            // 「依然範特西 / 依然范特西」同歌手同年份 → 合成一张
            let canonCheck13 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album")
            #expect(canonCheck13 == 2)
            let canonCheck14 = try String.fetchAll(db, sql: "SELECT DISTINCT title FROM album ORDER BY title")
            #expect(canonCheck14 == ["一剪梅", "依然范特西"])
            let canonCheck15 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track")
            #expect(canonCheck15 == 4)
            let canonCheck16 = try CanonFixture.danglingReferenceCount(db)
            #expect(canonCheck16 == 0)
        }
    }

    @Test("#16 拆出的每个片段也走规范形：'周杰倫; 周杰伦' 只建一行")
    func splitCombinedArtistCanonicalizesParts() throws {
        let (manager, dbQueue) = try CanonFixture.makeManager()
        try dbQueue.write { db in
            try CanonFixture.insertArtist(db, id: 1, name: "周杰倫; 周杰伦")
            try CanonFixture.insertTrack(db, stableId: "c1", title: "千里之外", artistId: 1, albumId: nil)
            try CanonFixture.linkTrackArtist(db, stableId: "c1", artistId: 1, position: 0)
        }

        // 顺序与启动链一致：先存量归名，再 #16 拆分
        try manager.migrateCanonicalizeScriptForms()
        try manager.migrateSplitCombinedArtistNames()

        try dbQueue.read { db in
            let names = try String.fetchAll(db, sql: "SELECT name FROM artist ORDER BY id")
            #expect(names == ["周杰伦"])
            // 分号行必须被并掉并重挂引用（不能留一行 "周杰伦; 周杰伦"）
            let canonCheck17 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artist WHERE name LIKE '%;%'")
            #expect(canonCheck17 == 0)
            let canonCheck18 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE artist_id IS NULL")
            #expect(canonCheck18 == 0)
            let canonCheck19 = try CanonFixture.danglingReferenceCount(db)
            #expect(canonCheck19 == 0)
        }
    }

    @Test("#16：简繁混写拆出的片段合并进已存在的同名行（不新建第二行）")
    func splitCombinedArtistMergesIntoExistingRow() throws {
        let (manager, dbQueue) = try CanonFixture.makeManager()
        try dbQueue.write { db in
            try CanonFixture.insertArtist(db, id: 1, name: "周杰倫; 費玉清")
            try CanonFixture.insertArtist(db, id: 2, name: "费玉清")
            try CanonFixture.insertTrack(db, stableId: "c2", title: "千里之外", artistId: 1, albumId: nil)
            try CanonFixture.linkTrackArtist(db, stableId: "c2", artistId: 1, position: 0)
        }

        try manager.migrateCanonicalizeScriptForms()
        try manager.migrateSplitCombinedArtistNames()

        try dbQueue.read { db in
            let names = try String.fetchAll(db, sql: "SELECT name FROM artist ORDER BY name")
            #expect(names == ["周杰伦", "费玉清"])
            let canonCheck20 = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_artist")
            #expect(canonCheck20 == 2)
            let canonCheck21 = try CanonFixture.danglingReferenceCount(db)
            #expect(canonCheck21 == 0)
        }
    }

    @Test("孤儿行由既有 #74 清理负责，本迁移不越界删除")
    func orphanCleanupStaysWithIssue74() throws {
        let (manager, dbQueue) = try CanonFixture.makeManager()
        try dbQueue.write { db in try seed(db) }

        try manager.migrateCanonicalizeScriptForms()
        // 本迁移只归名/合并，不动孤儿行
        let orphansAfterMigration = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artist WHERE id = 5")
        }
        #expect(orphansAfterMigration == 1)

        try manager.cleanupOrphanedLibraryEntries()
        let orphansAfterCleanup = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM artist WHERE id = 5")
        }
        #expect(orphansAfterCleanup == 0)
        let canonCheck22 = try dbQueue.read { db in try CanonFixture.danglingReferenceCount(db) }
        #expect(canonCheck22 == 0)
    }
}
