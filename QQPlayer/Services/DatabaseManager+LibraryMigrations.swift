//
//  DatabaseManager+LibraryMigrations.swift
//  QQPlayer
//
//  存量修复迁移：库内归名（migrateCanonicalizeScriptForms）、合唱歌手拆分
//  （migrateSplitCombinedArtistNames）、分裂专辑合并（migrateMergeSplitAlbums）、
//  孤儿行清理（cleanupOrphanedLibraryEntries）。
//
//  2026-09-21 从 DatabaseManager+Library.swift 原样搬出（纯搬家，无逻辑变更）。
//
import Foundation
@preconcurrency import GRDB

extension DatabaseManager {

    /// 存量归名（库内简繁归一的第一步，必须在 #16 / #81 之前跑）：
    /// `artist.name` / `album.title` / `album.album_artist` / `track.title`
    /// 全部写成**规范形**（简体，与 UI 语言设置解耦，2026-09-18 用户拍板
    /// 「落库全部是简体中文」），随后按归一名合并同形歌手行。
    ///
    /// 顺序不能反：先归名、后合并。名字没归一时分组的 key 是原文，
    /// 「周傳雄 / 周传雄」永远进不了同一组。
    ///
    /// 为什么歌手合并写在这里而不是复用 #16：`migrateSplitCombinedArtistNames` 只按
    /// `;` / `\\` 拆**合唱歌手名**，不管简繁分裂；而简繁分裂出来的两行是**同一个歌手**
    /// （名字即身份），合并安全。
    ///
    /// 专辑同形合并**不在这里重写一遍**：名字归到规范形后，既有的
    /// `migrateMergeSplitAlbums()`（issue #81）分组键 `albumMatchKey`
    /// 立刻能看见简繁分裂的同名专辑，由它按「共享歌手 + 年份不冲突」护栏合并
    /// —— 一处语义一处实现（同形 ≠ 同一专辑：`丝路` 同时是梁静茹 2005 与齐秦 1996
    /// 两张不同专辑，标题相同也必须留两行）。
    ///
    /// 保留行规则：**曲目多者优先，并列取 id 小者**；保留行的名字 = 规范形（第 1 步已写）。
    /// 引用面（全仓引用 artist.id 的只有这 4 处，全部重挂后才删除行）：
    /// `track.artist_id` / `track_artist.artist_id` / `album.artist_id` /
    /// `album_artist_link.artist_id`。其中 `album.artist_id` 是 `ON DELETE CASCADE`，
    /// **必须在删行前重挂**，否则整张专辑会跟着被删掉。
    ///
    /// 不动的数据：英文/日文名（映射表不覆盖即原样返回）、
    /// 用户文件标签、同步载荷（同步集合不含 artist/album/track 文本）。
    ///
    /// ⚠️ **不可逆的数据改写**：名字被规范形覆盖后，原字形无法从库内恢复。
    /// 跑之前请备份 DB（迁移只改库，不动用户文件）：
    ///   `cp ~/Library/Containers/<bundle-id>/Data/Documents/qqplayer.db{,.bak}`
    /// 或直接拷一份 App 容器目录。
    ///
    /// 幂等：第二次运行没有可改的名字、也没有同形组 → 无事发生（有测试锁定）。
    func migrateCanonicalizeScriptForms() throws {
        defer { invalidateArtistDisplayNameCache() }
        try write { db in
            // 1) 全库归名：库内形态一律写成规范形
            var renamedArtists = 0
            for artist in try Artist.fetchAll(db) {
                guard let id = artist.id else { continue }
                let canonical = DisplayScriptNormalizer.canonical(artist.name)
                guard canonical != artist.name else { continue }
                try db.execute(sql: "UPDATE artist SET name = ? WHERE id = ?", arguments: [canonical, id])
                renamedArtists += 1
            }

            var renamedAlbums = 0
            for album in try Album.fetchAll(db) {
                guard let id = album.id else { continue }
                let canonicalTitle = DisplayScriptNormalizer.canonical(album.title)
                let canonicalAlbumArtist = album.albumArtist.map(DisplayScriptNormalizer.canonical)
                guard canonicalTitle != album.title || canonicalAlbumArtist != album.albumArtist else { continue }
                try db.execute(
                    sql: "UPDATE album SET title = ?, album_artist = ? WHERE id = ?",
                    arguments: [canonicalTitle, canonicalAlbumArtist, id]
                )
                renamedAlbums += 1
            }

            // track 是最大的表：只要 id/title，不物化整个模型
            var renamedTracks = 0
            for row in try Row.fetchAll(db, sql: "SELECT id, title FROM track") {
                let id: Int64 = row["id"]
                let title: String = row["title"]
                let canonical = DisplayScriptNormalizer.canonical(title)
                guard canonical != title else { continue }
                try db.execute(sql: "UPDATE track SET title = ? WHERE id = ?", arguments: [canonical, id])
                renamedTracks += 1
            }

            // 2) 同形歌手行合并（第 1 步后 key = 规范形；名字相同 = 同一歌手）
            var groups: [String: [Artist]] = [:]
            for artist in try Artist.fetchAll(db) {
                groups[artist.name, default: []].append(artist)
            }

            var mergedGroups = 0
            for (name, group) in groups where group.count > 1 {
                let ranked: [(artist: Artist, trackCount: Int)] = try group.compactMap { artist in
                    guard let id = artist.id else { return nil }
                    // 曲目数 = 主歌手引用 ∪ 多歌手链接引用（去重，同一首只算一次）
                    let count = try Int.fetchOne(db, sql: """
                        SELECT COUNT(*) FROM (
                            SELECT stable_id AS stable_id FROM track WHERE artist_id = ?
                            UNION
                            SELECT track_stable_id FROM track_artist WHERE artist_id = ?
                        )
                    """, arguments: [id, id]) ?? 0
                    return (artist, count)
                }.sorted {
                    if $0.trackCount != $1.trackCount { return $0.trackCount > $1.trackCount }
                    return ($0.artist.id ?? 0) < ($1.artist.id ?? 0)
                }

                guard let keeper = ranked.first, let keeperId = keeper.artist.id else { continue }
                for entry in ranked.dropFirst() {
                    guard let loserId = entry.artist.id, loserId != keeperId else { continue }

                    try db.execute(
                        sql: "UPDATE track SET artist_id = ? WHERE artist_id = ?",
                        arguments: [keeperId, loserId]
                    )
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO track_artist (track_stable_id, artist_id, position)
                        SELECT track_stable_id, ?, position FROM track_artist WHERE artist_id = ?
                    """, arguments: [keeperId, loserId])
                    try db.execute(sql: "DELETE FROM track_artist WHERE artist_id = ?", arguments: [loserId])

                    // 删行前先重挂：album.artist_id 是 ON DELETE CASCADE
                    try db.execute(
                        sql: "UPDATE album SET artist_id = ? WHERE artist_id = ?",
                        arguments: [keeperId, loserId]
                    )
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO album_artist_link (album_id, artist_id, position)
                        SELECT album_id, ?, position FROM album_artist_link WHERE artist_id = ?
                    """, arguments: [keeperId, loserId])
                    try db.execute(sql: "DELETE FROM album_artist_link WHERE artist_id = ?", arguments: [loserId])

                    try db.execute(sql: "DELETE FROM artist WHERE id = ?", arguments: [loserId])
                }
                mergedGroups += 1
                if AppLog.isEnabled(.debug, .db) { AppLog.debug(.db, "🈶 Canonicalized artist group '\(name)': merged \(group.count) rows into id \(keeperId)") }
            }

            if renamedArtists + renamedAlbums + renamedTracks > 0 || mergedGroups > 0 {
                AppLog.info(.db, "🈶 Script canonicalization: artists renamed \(renamedArtists), albums \(renamedAlbums), tracks \(renamedTracks), merged artist groups \(mergedGroups)")
            }
        }
    }

    /// Repairs libraries indexed before multi-artist splitting: artist rows
    /// like "A; B" or "A\\B" are split into individual artists and every
    /// reference re-linked (issue #16). Idempotent - split rows are deleted,
    /// so later launches find nothing to do.
    func migrateSplitCombinedArtistNames() throws {
        defer { invalidateArtistDisplayNameCache() }
        try write { db in
            let combinedArtists = try Artist.fetchAll(db).filter {
                $0.name.contains(";") || $0.name.contains("\\\\")
            }

            for combinedArtist in combinedArtists {
                guard let combinedId = combinedArtist.id else { continue }

                // Same separators as LibraryIndexer.parseArtistNames
                var parts = [combinedArtist.name]
                for delimiter in [";", "\\\\", "\u{0}"] {
                    parts = parts.flatMap { $0.components(separatedBy: delimiter) }
                }
                var seen = Set<String>()
                let names: [String] = parts.compactMap {
                    // 拆出来的每一段也走规范形：否则 "周杰倫; 周杰伦" 会拆出两个名字、
                    // 建出两行（本迁移之后紧跟的存量归名不会再跑，等于漏网）
                    let trimmed = DisplayScriptNormalizer.canonical($0.trimmingCharacters(in: .whitespacesAndNewlines))
                    let key = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                    guard !trimmed.isEmpty, !seen.contains(key) else { return nil }
                    seen.insert(key)
                    return trimmed
                }
                // 拆完后只剩一个名字的情况也要处理：归名会把 "周杰倫; 周杰伦"
                // 写成 "周杰伦; 周杰伦"，去重后 names == ["周杰伦"] ——
                // 这行不是合唱、就是同一个歌手的重复写法，应当并到同名行
                // （否则库里永远留着一行带分号的 "周杰伦; 周杰伦"）。
                // 下面的重挂逻辑对单元素数组同样成立。
                guard names.count > 1 || names.first != combinedArtist.name else { continue }

                var artistIds: [Int64] = []
                for name in names {
                    if let existing = try Artist.filter(Column("name") == name).fetchOne(db),
                       let id = existing.id {
                        artistIds.append(id)
                    } else if let inserted = try Artist(name: name).insertAndFetch(db),
                              let id = inserted.id {
                        artistIds.append(id)
                    }
                }
                guard let primaryId = artistIds.first else { continue }

                // Re-link track_artist rows to the individual artists
                let trackRows = try Row.fetchAll(
                    db,
                    sql: "SELECT track_stable_id, position FROM track_artist WHERE artist_id = ?",
                    arguments: [combinedId]
                )
                for row in trackRows {
                    let stableId: String = row["track_stable_id"]
                    let basePosition: Int = row["position"]
                    for (index, artistId) in artistIds.enumerated() {
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO track_artist (track_stable_id, artist_id, position) VALUES (?, ?, ?)",
                            arguments: [stableId, artistId, basePosition * 100 + index]
                        )
                    }
                }
                try db.execute(sql: "DELETE FROM track_artist WHERE artist_id = ?", arguments: [combinedId])

                // Re-link album_artist_link rows
                let albumRows = try Row.fetchAll(
                    db,
                    sql: "SELECT album_id, position FROM album_artist_link WHERE artist_id = ?",
                    arguments: [combinedId]
                )
                for row in albumRows {
                    let albumId: Int64 = row["album_id"]
                    let basePosition: Int = row["position"]
                    for (index, artistId) in artistIds.enumerated() {
                        try db.execute(
                            sql: "INSERT OR IGNORE INTO album_artist_link (album_id, artist_id, position) VALUES (?, ?, ?)",
                            arguments: [albumId, artistId, basePosition * 100 + index]
                        )
                    }
                }
                try db.execute(sql: "DELETE FROM album_artist_link WHERE artist_id = ?", arguments: [combinedId])

                // Repoint primary references BEFORE deleting the combined row:
                // album.artist_id cascades on artist deletion, so a stale
                // reference would take whole albums down with it
                try db.execute(sql: "UPDATE track SET artist_id = ? WHERE artist_id = ?", arguments: [primaryId, combinedId])
                try db.execute(sql: "UPDATE album SET artist_id = ? WHERE artist_id = ?", arguments: [primaryId, combinedId])

                try db.execute(sql: "DELETE FROM artist WHERE id = ?", arguments: [combinedId])
                if AppLog.isEnabled(.debug, .db) { AppLog.debug(.db, "🎤 Split combined artist '\(combinedArtist.name)' into: \(names.joined(separator: ", "))") }
            }
        }
    }

    /// Merges albums that were split because their tracks' artist strings
    /// differed (featured guests - issue #81): same normalized title, at
    /// least one shared artist, and no conflicting year. Keeps the entry
    /// with the most tracks. Idempotent - merged duplicates are deleted.
    func migrateMergeSplitAlbums() throws {
        try write { db in
            let albums = try Album.fetchAll(db)
            var groups: [String: [Album]] = [:]
            for album in albums {
                groups[self.albumMatchKey(album.title).lowercased(), default: []].append(album)
            }

            for (_, group) in groups where group.count > 1 {
                // An album's full artist set: primary artist, linked album
                // artists, and every artist credited on its tracks
                func artistSet(for albumId: Int64, primary: Int64?) throws -> Set<Int64> {
                    var ids = Set(try Int64.fetchAll(db, sql: """
                        SELECT artist_id FROM album_artist_link WHERE album_id = ?
                        UNION SELECT artist_id FROM track WHERE album_id = ? AND artist_id IS NOT NULL
                        UNION SELECT ta.artist_id FROM track_artist ta
                              JOIN track t ON t.stable_id = ta.track_stable_id
                              WHERE t.album_id = ?
                    """, arguments: [albumId, albumId, albumId]))
                    if let primary { ids.insert(primary) }
                    return ids
                }

                let ranked: [(album: Album, trackCount: Int)] = try group.compactMap { album in
                    guard let id = album.id else { return nil }
                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track WHERE album_id = ?", arguments: [id]) ?? 0
                    return (album, count)
                }.sorted { $0.trackCount > $1.trackCount }

                guard let keeper = ranked.first, let keeperId = keeper.album.id else { continue }
                var keeperArtists = try artistSet(for: keeperId, primary: keeper.album.artistId)

                for entry in ranked.dropFirst() {
                    guard let dupId = entry.album.id else { continue }
                    let dupArtists = try artistSet(for: dupId, primary: entry.album.artistId)
                    // Only merge albums that share an artist - same-titled
                    // albums by unrelated artists are legitimately separate
                    guard !keeperArtists.isDisjoint(with: dupArtists) else { continue }
                    if let keeperYear = keeper.album.year, let dupYear = entry.album.year,
                       keeperYear != dupYear { continue }

                    try db.execute(sql: "UPDATE track SET album_id = ? WHERE album_id = ?", arguments: [keeperId, dupId])
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO album_artist_link (album_id, artist_id, position)
                        SELECT ?, artist_id, position + 1000 FROM album_artist_link WHERE album_id = ?
                    """, arguments: [keeperId, dupId])
                    try db.execute(sql: "DELETE FROM album WHERE id = ?", arguments: [dupId])
                    keeperArtists.formUnion(dupArtists)
                    if AppLog.isEnabled(.debug, .db) { AppLog.debug(.db, "💿 Merged split album '\(entry.album.title)' into '\(keeper.album.title)'") }
                }
            }
        }
    }

    /// Purges stale link rows, empty albums, and artists nothing references.
    /// Runs after every track deletion and once at startup, so libraries
    /// damaged by the old deleteTrack (which leaked track_artist rows and
    /// kept empty artists alive - issue #74) heal on next launch.
    func cleanupOrphanedLibraryEntries() throws {
        try write { db in
            // Link rows for tracks that no longer exist - track_artist has no
            // FK to track, so these never cascade and must be purged manually
            try db.execute(sql: """
                DELETE FROM track_artist
                WHERE track_stable_id NOT IN (SELECT stable_id FROM track)
            """)

            // Delete albums that have no tracks referencing them
            try db.execute(sql: """
                DELETE FROM album
                WHERE id NOT IN (
                    SELECT DISTINCT album_id
                    FROM track
                    WHERE album_id IS NOT NULL
                )
            """)

            // Link rows for albums that no longer exist - the FK cascade
            // covers this when foreign keys are on, but don't rely on it
            // (older app versions may have written without the pragma)
            try db.execute(sql: """
                DELETE FROM album_artist_link
                WHERE album_id NOT IN (SELECT id FROM album)
            """)

            // Delete artists that have no tracks referencing them
            try db.execute(sql: """
                DELETE FROM artist
                WHERE id NOT IN (
                    SELECT DISTINCT artist_id
                    FROM track
                    WHERE artist_id IS NOT NULL
                    UNION
                    SELECT DISTINCT artist_id
                    FROM track_artist
                    UNION
                    SELECT DISTINCT artist_id
                    FROM album_artist_link
                )
            """)
        }
    }
}
