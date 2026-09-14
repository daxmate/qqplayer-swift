//
//  SmartPlaylistStore.swift
//  QQPlayer
//
//  Data layer for automatic playlists (最近添加 / 最近播放 / 常听排行 / 年代).
//  Contract mirrors the desktop implementation (useSmartViews.ts):
//  - SMART_VIEW_LIMIT = 50
//  - recentPlayed dedupes by track, keeping each track's latest play
//  - topPlayed ranks by play count, ties broken by total listened duration
//  - decades buckets: 1950s (≤1959) ... 2020s (≥2020) + unknown, 9 buckets
//
//  UI-facing methods read through DatabaseManager.shared; the `from db`
//  variants are the testable cores used with an in-memory database.
//

import Foundation
@preconcurrency import GRDB

/// Automatic playlist kinds shown on the playlist page.
enum SmartPlaylistKind: String, CaseIterable, Identifiable {
    case recentAdded, recentPlayed, topPlayed, decades
    var id: String { rawValue }
}

/// Metadata for one pinned card on the playlist page. The UI derives its
/// localized title from `kind` (and `key` for decade buckets) and uses `count`
/// for the badge; `title` is a plain placeholder here.
struct SmartPlaylistCardInfo {
    let kind: SmartPlaylistKind
    let title: String
    let count: Int
}

/// One decade bucket with its track count (0-count buckets are included).
struct DecadeBucketInfo {
    let key: String
    let label: String
    let count: Int
}

enum SmartPlaylistStore {
    /// Same cap as the desktop SMART_VIEW_LIMIT.
    static let limit = 50

    // MARK: - Decade buckets (single source of truth, mirrors desktop DECADE_BUCKETS)

    /// Ordered bucket definitions. minYear/maxYear are inclusive; nil means
    /// unbounded in that direction (1950s has no lower bound within valid
    /// years, 2020s has no upper bound, unknown matches everything invalid).
    static let decadeBucketDefinitions: [(key: String, label: String, minYear: Int?, maxYear: Int?)] = [
        ("1950s", "1950s", 1000, 1959),
        ("1960s", "1960s", 1960, 1969),
        ("1970s", "1970s", 1970, 1979),
        ("1980s", "1980s", 1980, 1989),
        ("1990s", "1990s", 1990, 1999),
        ("2000s", "2000s", 2000, 2009),
        ("2010s", "2010s", 2010, 2019),
        ("2020s", "2020s", 2020, 9999),
        ("unknown", "unknown", nil, nil),
    ]

    /// Pure function: album year → decade bucket key.
    /// Follows the desktop `decadeOfYear`: non-4-digit years (<1000 or >9999)
    /// and nil map to "unknown"; 1959 → "1950s", 1960 → "1960s", 2020 → "2020s".
    static func decadeKey(ofYear year: Int?) -> String {
        guard let year else { return "unknown" }
        return decadeBucketDefinitions.first { bucket in
            guard let minYear = bucket.minYear, let maxYear = bucket.maxYear else { return false }
            return (minYear ... maxYear).contains(year)
        }?.key ?? "unknown"
    }

    // MARK: - UI-facing queries (via DatabaseManager.shared)

    /// 最近添加：modification_date 降序，nil 最后，截断 limit。
    static func recentAddedTracks() throws -> [Track] {
        try DatabaseManager.shared.read { db in
            try recentAddedTracks(from: db, limit: limit)
        }
    }

    /// 最近播放：按最新播放时间倒序，同一曲目只保留最新一条，截断 limit。
    static func recentPlayedTracks() throws -> [Track] {
        try DatabaseManager.shared.read { db in
            try recentPlayedTracks(from: db, limit: limit)
        }
    }

    /// 常听排行：按播放次数降序，并列按累计播放时长降序；只返回仍存在的曲目。
    static func topPlayedTracks() throws -> [(track: Track, playCount: Int)] {
        try DatabaseManager.shared.read { db in
            try topPlayedTracks(from: db, limit: limit)
        }
    }

    /// 年代聚合：9 个 bucket（含 0 数量）按固定顺序返回。
    static func decadeBuckets() throws -> [DecadeBucketInfo] {
        try DatabaseManager.shared.read { db in
            try decadeBuckets(from: db)
        }
    }

    /// 某 bucket 的歌曲：同年内按 year 降序，截断 limit。
    static func tracks(inDecade key: String) throws -> [Track] {
        try DatabaseManager.shared.read { db in
            try tracks(inDecade: key, from: db, limit: limit)
        }
    }

    /// 播放列表页置顶卡片的元数据（计数：recent* 为曲目数，decades 为 bucket 数）。
    /// 一次 read 事务内完成全部计数（此前 4 次独立 DB 查询，每次进页面重复执行）。
    static func cardInfos() throws -> [SmartPlaylistCardInfo] {
        try DatabaseManager.shared.read { db in
            try cardInfos(from: db)
        }
    }

    /// 可测核心：单事务内完成四个卡片计数（语义与各 from db 查询完全一致）
    static func cardInfos(from db: Database) throws -> [SmartPlaylistCardInfo] {
        [
            SmartPlaylistCardInfo(
                kind: .recentAdded,
                title: SmartPlaylistKind.recentAdded.rawValue,
                count: try recentAddedTracks(from: db, limit: limit).count
            ),
            SmartPlaylistCardInfo(
                kind: .recentPlayed,
                title: SmartPlaylistKind.recentPlayed.rawValue,
                count: try recentPlayedTracks(from: db, limit: limit).count
            ),
            SmartPlaylistCardInfo(
                kind: .topPlayed,
                title: SmartPlaylistKind.topPlayed.rawValue,
                count: try topPlayedTracks(from: db, limit: limit).count
            ),
            SmartPlaylistCardInfo(
                kind: .decades,
                title: SmartPlaylistKind.decades.rawValue,
                count: try decadeBuckets(from: db).count
            ),
        ]
    }

    /// 置顶卡片封面拼贴用的曲目：track 类歌单取前 limit 首；
    /// decades 取前 limit 个非空年代桶各 1 首（尽量覆盖不同年代封面）。
    static func coverTracks(for kind: SmartPlaylistKind, limit: Int = 4) throws -> [Track] {
        try DatabaseManager.shared.read { db in
            try coverTracks(for: kind, from: db, limit: limit)
        }
    }

    static func coverTracks(for kind: SmartPlaylistKind, from db: Database, limit: Int) throws -> [Track] {
        switch kind {
        case .recentAdded:
            return Array(try recentAddedTracks(from: db, limit: limit))
        case .recentPlayed:
            return Array(try recentPlayedTracks(from: db, limit: limit))
        case .topPlayed:
            return try topPlayedTracks(from: db, limit: limit).map(\.track)
        case .decades:
            var result: [Track] = []
            // DecadeBucketInfo.count 是 Int（非 Collection），empty_count 误报
            // swiftlint:disable:next empty_count
            let buckets = try decadeBuckets(from: db).filter { $0.count > 0 }
            for bucket in buckets.prefix(limit) {
                if let first = try tracks(inDecade: bucket.key, from: db, limit: 1).first {
                    result.append(first)
                }
            }
            return result
        }
    }

    // MARK: - Testable query cores (in-memory Database)

    static func recentAddedTracks(from db: Database, limit: Int) throws -> [Track] {
        try Track.fetchAll(db, sql: """
        SELECT * FROM track
        ORDER BY modification_date IS NULL ASC, modification_date DESC, title COLLATE NOCASE ASC
        LIMIT ?
        """, arguments: [limit])
    }

    static func recentPlayedTracks(from db: Database, limit: Int) throws -> [Track] {
        try Track.fetchAll(db, sql: """
        SELECT t.*
        FROM track t
        JOIN (
            SELECT track_stable_id, MAX(played_at) AS latest_played_at
            FROM play_history
            GROUP BY track_stable_id
        ) h ON h.track_stable_id = t.stable_id
        ORDER BY h.latest_played_at DESC, t.title COLLATE NOCASE ASC
        LIMIT ?
        """, arguments: [limit])
    }

    static func topPlayedTracks(from db: Database, limit: Int) throws -> [(track: Track, playCount: Int)] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT t.*, COUNT(h.track_stable_id) AS play_count, COALESCE(SUM(h.play_duration_ms), 0) AS total_played
        FROM track t
        JOIN play_history h ON h.track_stable_id = t.stable_id
        GROUP BY t.stable_id
        ORDER BY play_count DESC, total_played DESC, t.title COLLATE NOCASE ASC
        LIMIT ?
        """, arguments: [limit])
        return try rows.map { row in
            let track = try Track(row: row)
            let playCount: Int = row["play_count"]
            return (track, playCount)
        }
    }

    static func decadeBuckets(from db: Database) throws -> [DecadeBucketInfo] {
        // GROUP BY 下推 SQLite：不再全表拉 year 列到内存聚合（此前每次进页面
        // 都把整张 track 表的 year 拷进 Swift）；year 为空/null 的曲目归入 NULL 组，
        // 语义与内存聚合完全一致（decadeKey 映射不变）。
        let rows = try Row.fetchAll(db, sql: """
            SELECT a.year AS year, COUNT(*) AS cnt
            FROM track t
            LEFT JOIN album a ON a.id = t.album_id
            GROUP BY a.year
        """)
        var counts: [String: Int] = [:]
        for row in rows {
            let year: Int? = row["year"]
            let cnt: Int = row["cnt"]
            counts[decadeKey(ofYear: year), default: 0] += cnt
        }
        return decadeBucketDefinitions.map {
            DecadeBucketInfo(key: $0.key, label: $0.label, count: counts[$0.key, default: 0])
        }
    }

    static func tracks(inDecade key: String, from db: Database, limit: Int) throws -> [Track] {
        let clause = yearClause(for: key) ?? yearClause(for: "unknown")!
        return try Track.fetchAll(db, sql: """
        SELECT t.*
        FROM track t
        LEFT JOIN album a ON a.id = t.album_id
        WHERE \(clause)
        ORDER BY a.year DESC, t.title COLLATE NOCASE ASC
        LIMIT ?
        """, arguments: [limit])
    }

    /// SQL year predicate for a bucket key, mirroring `decadeKey` exactly so
    /// bucket membership never drifts from the pure function.
    private static func yearClause(for key: String) -> String? {
        guard let bucket = decadeBucketDefinitions.first(where: { $0.key == key }) else { return nil }
        if let minYear = bucket.minYear, let maxYear = bucket.maxYear {
            return "a.year BETWEEN \(minYear) AND \(maxYear)"
        }
        return "a.year IS NULL OR a.year < 1000 OR a.year > 9999"
    }
}

// MARK: - 置顶自动歌单卡片的网格布局（纯函数 + 单一事实源）

/// 自动歌单卡片网格的列数 / 卡宽计算。**唯一事实源**：macOS 的置顶卡片条
/// （`MacSmartPlaylistCardStrip`）与测试都读这里——此前这两个函数与阈值常量写在
/// `QQPlayer/Mac/`（iOS 单测 target 编不到），于是"4 张卡挤成一行、折不下来"这类
/// 参数问题没有任何兜底（2026-09-14 用户反馈）。
///
/// 阈值语义（macOS 歌单列宽典型 400–700pt）：
/// - `minCardWidth = 176`（与 iOS 两列卡宽同量级）→ 2 列需要可用宽 ≥ 2×176+12 = 364pt，
///   即列宽 ≥ ~396pt：**典型窗口就是 2×2 两行**；4 张一行需要可用宽 ≥ 740pt（列宽 ≥ ~772pt），
///   只有很宽的窗口才会出现。
/// - `maxCardWidth = 300`：宽列下卡不至于过大。
enum SmartPlaylistGridLayout {
    /// 卡宽下限（低于此值封面拼贴与标题不可读）。
    static let minCardWidth: CGFloat = 176
    /// 卡宽上限（宽列下单卡不过大）。
    static let maxCardWidth: CGFloat = 300
    /// 卡间距 / 条带左右内边距（列数与卡宽计算共用）。
    static let spacing: CGFloat = 12
    static let horizontalPadding: CGFloat = 16

    /// 卡片条列数：先算「卡宽不低于 minCardWidth」时能放几列，再在这个上限内挑一个
    /// 能把最后一行也填满的列数（4 张卡 → 4 或 2 列，避免 3+1 这种半空行）。
    /// availableWidth <= 0 表示本帧还没量到宽度，先按一行排，量到后立即重排。
    ///
    /// ⚠️ `minCardWidth` **只参与列数判定**，绝不能拿它当布局硬下限（`GridItem(.fixed())`
    /// 那种）：那会让内容的最小宽 = 列数 × minCardWidth，顶住一级视图的 `min: 320` 声明、
    /// 歌单列缩不下去（2026-09-14 实测）。列宽由弹性列按容器分配，单卡上限用 `maxCardWidth`。
    static func stripColumnCount(
        cardCount: Int,
        availableWidth: CGFloat,
        minCardWidth: CGFloat = minCardWidth,
        spacing: CGFloat = spacing
    ) -> Int {
        guard cardCount > 0 else { return 1 }
        guard availableWidth > 0 else { return cardCount }
        let fitting = Int((availableWidth + spacing) / (minCardWidth + spacing))
        let bounded = max(1, min(cardCount, fitting))
        guard bounded > 1 else { return 1 }
        for candidate in stride(from: bounded, through: 2, by: -1) where cardCount % candidate == 0 {
            return candidate
        }
        return bounded
    }
}
