//
//  SmartPlaylistDataTests.swift
//  QQPlayerTests
//
//  自动歌单数据层测试：
//  - decadeKey(ofYear:) 年代划分边界（照搬桌面端 decadeOfYear 语义）
//  - 四类聚合查询：recentAdded / recentPlayed / topPlayed / decades
//    用内存 GRDB 最小 schema（track/album/play_history）验证排序、去重、计数
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

struct SmartPlaylistDataTests {
    // MARK: - Fixture

    /// 最小 schema + fixture（与生产表同列名；查询核心只依赖这些列）。
    ///
    /// 专辑 year：A1=1965, A2=1975, A3=2022, A4=2005, A5=缺失, A6=1978, A7=1972
    /// 曲目 modification_date：t2(3000) > t5(2500) > t3(2000) > t7(1500) > t1(1000) > t6(500) > t8(400) > t4(nil)
    /// 播放历史：t1 两条（最新 300）、t7 两条（最新 350）、t2/t3/t6 各一条、ghost 一条（曲目已删除）
    private static func makeDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            // 与生产 createTables 同构（Track 解码需要全部非可选列）
            try db.execute(sql: """
                CREATE TABLE album (
                    id INTEGER PRIMARY KEY,
                    artist_id INTEGER,
                    title TEXT NOT NULL COLLATE NOCASE,
                    year INTEGER,
                    album_artist TEXT COLLATE NOCASE
                )
            """)
            try db.execute(sql: """
                CREATE TABLE track (
                    id INTEGER PRIMARY KEY,
                    stable_id TEXT NOT NULL UNIQUE,
                    album_id INTEGER,
                    artist_id INTEGER,
                    title TEXT NOT NULL COLLATE NOCASE,
                    track_no INTEGER,
                    disc_no INTEGER,
                    duration_ms INTEGER,
                    sample_rate INTEGER,
                    bit_depth INTEGER,
                    channels INTEGER,
                    path TEXT NOT NULL,
                    file_size INTEGER,
                    modification_date INTEGER,
                    replaygain_track_gain REAL,
                    replaygain_album_gain REAL,
                    replaygain_track_peak REAL,
                    replaygain_album_peak REAL,
                    has_embedded_art INTEGER DEFAULT 0
                )
            """)
            try db.execute(sql: """
                CREATE TABLE play_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    track_stable_id TEXT NOT NULL,
                    played_at INTEGER NOT NULL,
                    play_duration_ms INTEGER DEFAULT 0
                )
            """)

            try db.execute(sql: """
                INSERT INTO album (id, title, year) VALUES
                (1, 'A1', 1965), (2, 'A2', 1975), (3, 'A3', 2022), (4, 'A4', 2005), (5, 'A5', NULL), (6, 'A6', 1978), (7, 'A7', 1972)
            """)
            try db.execute(sql: """
                INSERT INTO track (id, stable_id, album_id, title, path, modification_date) VALUES
                (1, 't1', 1, 'T1', '/m/T1.flac', 1000),
                (2, 't2', 2, 'T2', '/m/T2.flac', 3000),
                (3, 't3', 3, 'T3', '/m/T3.flac', 2000),
                (4, 't4', NULL, 'T4', '/m/T4.flac', NULL),
                (5, 't5', 5, 'T5', '/m/T5.flac', 2500),
                (6, 't6', 4, 'T6', '/m/T6.flac', 500),
                (7, 't7', 6, 'T7', '/m/T7.flac', 1500),
                (8, 't8', 7, 'T8', '/m/T8.flac', 400)
            """)
            try db.execute(sql: """
                INSERT INTO play_history (track_stable_id, played_at, play_duration_ms) VALUES
                ('t1', 100, 10000),
                ('t1', 300, 20000),
                ('t2', 200, 5000),
                ('t3', 250, 7000),
                ('t6', 400, 0),
                ('t7', 150, 8000),
                ('t7', 350, 12000),
                ('ghost', 500, 9999)
            """)
        }
        return dbQueue
    }

    private static func stableIds(_ tracks: [Track]) -> [String] {
        tracks.map(\.stableId)
    }

    // MARK: - decadeKey 边界

    @Test("decadeKey：缺失/非 4 位/越界 → unknown")
    func decadeKeyInvalidYears() {
        #expect(SmartPlaylistStore.decadeKey(ofYear: nil) == "unknown")
        #expect(SmartPlaylistStore.decadeKey(ofYear: 0) == "unknown")
        #expect(SmartPlaylistStore.decadeKey(ofYear: 999) == "unknown")
        #expect(SmartPlaylistStore.decadeKey(ofYear: -42) == "unknown")
        #expect(SmartPlaylistStore.decadeKey(ofYear: 10000) == "unknown")
    }

    @Test("decadeKey：边界年份（1959/1960/2019/2020/9999）")
    func decadeKeyBoundaries() {
        #expect(SmartPlaylistStore.decadeKey(ofYear: 1000) == "1950s")
        #expect(SmartPlaylistStore.decadeKey(ofYear: 1959) == "1950s")
        #expect(SmartPlaylistStore.decadeKey(ofYear: 1960) == "1960s")
        #expect(SmartPlaylistStore.decadeKey(ofYear: 1979) == "1970s")
        #expect(SmartPlaylistStore.decadeKey(ofYear: 2019) == "2010s")
        #expect(SmartPlaylistStore.decadeKey(ofYear: 2020) == "2020s")
        #expect(SmartPlaylistStore.decadeKey(ofYear: 9999) == "2020s")
    }

    // MARK: - 聚合查询

    @Test("recentAdded：modification_date 降序，nil 最后，LIMIT 生效")
    func recentAddedOrdering() throws {
        let dbQueue = try Self.makeDatabase()
        try dbQueue.read { db in
            let limited = try SmartPlaylistStore.recentAddedTracks(from: db, limit: 3)
            #expect(Self.stableIds(limited) == ["t2", "t5", "t3"])

            let all = try SmartPlaylistStore.recentAddedTracks(from: db, limit: 50)
            #expect(Self.stableIds(all) == ["t2", "t5", "t3", "t7", "t1", "t6", "t8", "t4"])
        }
    }

    @Test("recentPlayed：同曲目只取最新一条，按最新播放倒序，已删曲目排除")
    func recentPlayedDedupesByLatest() throws {
        let dbQueue = try Self.makeDatabase()
        try dbQueue.read { db in
            let limited = try SmartPlaylistStore.recentPlayedTracks(from: db, limit: 3)
            #expect(Self.stableIds(limited) == ["t6", "t7", "t1"])

            let all = try SmartPlaylistStore.recentPlayedTracks(from: db, limit: 50)
            #expect(Self.stableIds(all) == ["t6", "t7", "t1", "t3", "t2"])
            #expect(!Self.stableIds(all).contains("ghost"))
        }
    }

    @Test("topPlayed：播放次数降序，并列按累计时长，附带 playCount")
    func topPlayedOrdering() throws {
        let dbQueue = try Self.makeDatabase()
        try dbQueue.read { db in
            let limited = try SmartPlaylistStore.topPlayedTracks(from: db, limit: 3)
            #expect(limited.map(\.track.stableId) == ["t1", "t7", "t3"])
            #expect(limited.map(\.playCount) == [2, 2, 1])

            let all = try SmartPlaylistStore.topPlayedTracks(from: db, limit: 50)
            #expect(all.map(\.track.stableId) == ["t1", "t7", "t3", "t2", "t6"])
            #expect(!all.contains(where: { $0.track.stableId == "ghost" }))
        }
    }

    @Test("decadeBuckets：9 个 bucket 全返回，0 数量也在，计数正确")
    func decadeBucketsCounts() throws {
        let dbQueue = try Self.makeDatabase()
        try dbQueue.read { db in
            let buckets = try SmartPlaylistStore.decadeBuckets(from: db)
            #expect(buckets.count == 9)
            #expect(buckets.map(\.key) == ["1950s", "1960s", "1970s", "1980s", "1990s", "2000s", "2010s", "2020s", "unknown"])
            #expect(buckets.map(\.count) == [0, 1, 3, 0, 0, 1, 0, 1, 2])
        }
    }

    @Test("tracks(inDecade:)：bucket 内按 year 降序，非法 key 回落 unknown")
    func tracksInDecadeOrdering() throws {
        let dbQueue = try Self.makeDatabase()
        try dbQueue.read { db in
            let seventies = try SmartPlaylistStore.tracks(inDecade: "1970s", from: db, limit: 50)
            #expect(Self.stableIds(seventies) == ["t7", "t2", "t8"])

            let unknown = try SmartPlaylistStore.tracks(inDecade: "unknown", from: db, limit: 50)
            #expect(Self.stableIds(unknown) == ["t4", "t5"])

            // 非法 bucket key → 与桌面端一致回落 unknown
            let bogus = try SmartPlaylistStore.tracks(inDecade: "bogus", from: db, limit: 50)
            #expect(Self.stableIds(bogus) == ["t4", "t5"])

            // LIMIT 生效
            let limited = try SmartPlaylistStore.tracks(inDecade: "1970s", from: db, limit: 2)
            #expect(Self.stableIds(limited) == ["t7", "t2"])
        }
    }

    @Test("cardInfos：单事务内四类计数与各查询核心一致（recent* 封顶 limit）")
    func cardInfosCounts() throws {
        let dbQueue = try Self.makeDatabase()
        try dbQueue.read { db in
            let infos = try SmartPlaylistStore.cardInfos(from: db)
            #expect(infos.count == 4)
            #expect(infos.map(\.kind.rawValue) == ["recentAdded", "recentPlayed", "topPlayed", "decades"])

            // recentAdded：8 首曲目（封顶 50）；recentPlayed/topPlayed：去重后 5 首；decades：9 桶
            #expect(infos[0].count == 8)
            #expect(infos[1].count == 5)
            #expect(infos[2].count == 5)
            #expect(infos[3].count == 9)
        }
    }

    // MARK: - 卡片封面拼贴曲目

    @Test("coverTracks：track 类歌单取前 limit 首")
    func coverTracksForTrackKinds() throws {
        let dbQueue = try Self.makeDatabase()
        try dbQueue.read { db in
            let recentAdded = try SmartPlaylistStore.coverTracks(for: .recentAdded, from: db, limit: 4)
            #expect(Self.stableIds(recentAdded) == ["t2", "t5", "t3", "t7"])

            let recentPlayed = try SmartPlaylistStore.coverTracks(for: .recentPlayed, from: db, limit: 4)
            #expect(Self.stableIds(recentPlayed) == ["t6", "t7", "t1", "t3"])

            let topPlayed = try SmartPlaylistStore.coverTracks(for: .topPlayed, from: db, limit: 4)
            #expect(Self.stableIds(topPlayed) == ["t1", "t7", "t3", "t2"])
        }
    }

    @Test("coverTracks：decades 取前 4 个非空年代桶各 1 首")
    func coverTracksForDecades() throws {
        let dbQueue = try Self.makeDatabase()
        try dbQueue.read { db in
            let decades = try SmartPlaylistStore.coverTracks(for: .decades, from: db, limit: 4)
            #expect(Self.stableIds(decades) == ["t1", "t7", "t6", "t3"])
        }
    }
    // MARK: - 置顶卡片网格布局（2026-09-14：阈值与算法上收共享层 + 补兜底）

    /// 条带内边距换算：视图传入的是「列宽」，布局算的是「列宽 − 左右内边距」。
    private static func usableWidth(columnWidth: CGFloat) -> CGFloat {
        columnWidth - SmartPlaylistGridLayout.horizontalPadding * 2
    }

    @Test("卡片网格：典型歌单列宽 → 2 列（2×2 两行），不再挤成一行 4 张")
    func cardStripUsesTwoRowsAtTypicalColumnWidth() {
        // 552pt 是 macOS 歌单列的常见宽度（用户 2026-09-14 反馈时的场景）
        let twoColumns = SmartPlaylistGridLayout.stripColumnCount(
            cardCount: 4,
            availableWidth: Self.usableWidth(columnWidth: 552)
        )
        #expect(twoColumns == 2)
    }

    @Test("卡片网格：窄列单列、很宽才一行 4 张、宽度未量到先按一行排")
    func cardStripAdaptsToAvailableWidth() {
        let narrow = SmartPlaylistGridLayout.stripColumnCount(
            cardCount: 4,
            availableWidth: Self.usableWidth(columnWidth: 360)
        )
        #expect(narrow == 1)

        let wide = SmartPlaylistGridLayout.stripColumnCount(
            cardCount: 4,
            availableWidth: Self.usableWidth(columnWidth: 860)
        )
        #expect(wide == 4)

        // 本帧还没量到宽度（0）→ 按一行排，量到后立即重排
        let unmeasured = SmartPlaylistGridLayout.stripColumnCount(cardCount: 4, availableWidth: 0)
        #expect(unmeasured == 4)

        // 没有卡片 → 1（不返回 0，避免 GridItem 空数组）
        #expect(SmartPlaylistGridLayout.stripColumnCount(cardCount: 0, availableWidth: 500) == 1)
    }

    @Test("卡片网格：绝不出现 3+1 半空行（列数必须是卡片数的约数）")
    func cardStripNeverLeavesHalfEmptyRow() {
        // 可用宽刚好只够 3 张 → 退到 2 列（4 的约数），而不是 3 列 + 1 张落单
        let threeFitting = SmartPlaylistGridLayout.stripColumnCount(cardCount: 4, availableWidth: 620)
        #expect(threeFitting == 2)

        // 六张卡（万一以后扩到 6 类）：只允许 6 / 3 / 2 / 1 列
        let sixCards = SmartPlaylistGridLayout.stripColumnCount(cardCount: 6, availableWidth: 620)
        #expect(sixCards == 3)
    }

    @Test("卡片宽度：夹在 [176, 300]，两列时均分可用宽")
    func cardStripWidthStaysWithinBounds() {
        let twoColumns = SmartPlaylistGridLayout.stripCardWidth(columns: 2, availableWidth: 520)
        #expect(twoColumns == 244)

        // 单列且很宽 → 撞上限（不至于一张卡铺满整列）
        let singleWide = SmartPlaylistGridLayout.stripCardWidth(columns: 1, availableWidth: 900)
        #expect(singleWide == SmartPlaylistGridLayout.maxCardWidth)

        // 四列窄列 → 撞下限（不再压到不可读）
        let fourNarrow = SmartPlaylistGridLayout.stripCardWidth(columns: 4, availableWidth: 700)
        #expect(fourNarrow == SmartPlaylistGridLayout.minCardWidth)

        // 宽度未量到 → 返回下限（先给个安全值，量到后重排）
        let unmeasured = SmartPlaylistGridLayout.stripCardWidth(columns: 2, availableWidth: 0)
        #expect(unmeasured == SmartPlaylistGridLayout.minCardWidth)
    }
}
