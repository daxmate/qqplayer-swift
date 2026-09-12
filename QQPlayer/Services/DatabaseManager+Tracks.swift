//
//  DatabaseManager+Tracks.swift
//  QQPlayer
//
//  Track CRUD/upsert/重复清理、收藏、曲目查询（byAlbum/byArtist/分页/stableIds）、
//  播放历史关联 SQL（P0-3）。
//
import Foundation
@preconcurrency import GRDB

extension DatabaseManager {
    // MARK: - Track operations

    func upsertTrack(_ track: Track) throws {
        defer { invalidateArtistDisplayNameCache() }
        var trackToSave = track

        // M3-1: 入库时算一次 content_hash（跨端歌曲身份 = 文件内容 SHA-256）。
        // 已存在（非 nil）不重算；文件缺失/读失败保持 nil，由惰性回填
        // （backfillTrackContentHashesIfNeeded）或下次入库补。哈希在写事务外
        // （audit 纪律：文件 IO 不进写事务）。
        if trackToSave.contentHash == nil {
            trackToSave.contentHash = Self.contentHashIfFilePresent(atPath: trackToSave.path)
        }
        var savedTrack: Track?
        // stableId 变更（同路径不同 id 的去重合并）记录在案：文件侧引用迁移必须
        // 在事务外做（文件 IO 不进写事务），见 TrackIdentityMigration。
        var mergedDuplicateStableIds: [String] = []

        try write { db in
            // A metadata refresh builds a new Track value with the same
            // stable ID. Reuse the existing primary key so GRDB performs an
            // UPDATE, preserving favorites, playlists and every other
            // stable-ID relationship owned by previous app versions.
            if trackToSave.id == nil,
               let existing = try Track
               .filter(Column("stable_id") == trackToSave.stableId)
               .fetchOne(db) {
                trackToSave.id = existing.id
            }

            // Safety check: Remove any duplicates with the same path but different stable_id
            // This handles edge cases where migration didn't run or failed.
            // Compare on the standardized path, matching getTrack(byPath:)'s
            // normalized fallback so iCloud container UUID changes cannot
            // hide duplicates (audit: inconsistent path spelling).
            let normalizedPath = Self.standardizedPath(trackToSave.path)
            let duplicates = try Track.filter(Column("path") == normalizedPath && Column("stable_id") != trackToSave.stableId).fetchAll(db)
            if !duplicates.isEmpty {
                print("⚠️ Found \(duplicates.count) duplicate(s) for path: \(normalizedPath)")
                for duplicate in duplicates {
                    // 引用迁移走唯一入口（D6：此前 favorite/playlist_item 是裸
                    // UPDATE，主键冲突会抛错并回滚**整次入库事务**，文件静默不入库）。
                    try TrackIdentityMigration.migrateDatabaseReferences(
                        db,
                        from: duplicate.stableId,
                        to: trackToSave.stableId
                    )
                    // Delete the duplicate
                    try Track.filter(Column("id") == duplicate.id).deleteAll(db)
                    mergedDuplicateStableIds.append(duplicate.stableId)
                    print("🗑️ Removed duplicate track with old stable_id: \(duplicate.stableId)")
                }
            }

            try trackToSave.save(db)
            savedTrack = trackToSave
        }

        // 文件侧引用（书签/三个歌词目录/封面映射）跟随新 stableId——事务外、幂等
        for duplicateStableId in mergedDuplicateStableIds {
            TrackIdentityMigration.migrateFileReferences(from: duplicateStableId, to: trackToSave.stableId)
        }

        // File-existence checks and the follow-up delete run OUTSIDE the
        // upsert write transaction: syscalls no longer pin the single GRDB
        // writer, which used to serialize all four concurrent indexers
        // (audit: file IO inside a write transaction).
        if let savedTrack {
            try cleanupStaleUnplayableDuplicates(matching: savedTrack)

            // M4-2a: 歌曲入库（带 content_hash）后重放引用它的挂起同步变更。
            // 放在写事务外（重放自走读写事务），失败不影响入库本身（下次入库/
            // 对账再试）；无挂起行时只是一次索引读，扫描入库不受影响。
            if let contentHash = savedTrack.contentHash {
                do {
                    let replayed = try SyncChangeLogReplay.replay(contentHash: contentHash, database: self)
                    if replayed > 0 {
                        print("🔁 Sync: 重放挂起变更 \(replayed) 条")
                    }
                } catch {
                    print("⚠️ Sync: 挂起变更重放失败（下次入库重试）：\(error)")
                }
            }
        }
    }

    private func normalizedDuplicateTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    private func hasReliableDuplicateMetadata(_ track: Track) -> Bool {
        guard let durationMs = track.durationMs, durationMs > 0,
              let fileSize = track.fileSize, fileSize > 0 else {
            return false
        }

        return !normalizedDuplicateTitle(track.title).isEmpty
    }

    /// Removes rows whose file no longer exists when a twin (same title,
    /// duration, size, artist) just got saved. Runs OUTSIDE the upsert write
    /// transaction in three phases so file-existence syscalls never pin the
    /// single GRDB writer (audit: file IO inside a write transaction):
    ///   1. read transaction: SQL-prefiltered candidate rows (no IO)
    ///   2. outside any transaction: file-existence + metadata checks
    ///   3. short write transaction: merge references + delete confirmed stales
    private func cleanupStaleUnplayableDuplicates(matching newTrack: Track) throws {
        guard hasReliableDuplicateMetadata(newTrack),
              FileManager.default.fileExists(atPath: newTrack.path) else {
            return
        }

        // Phase 1: Prefilter by the strict-duplicate criteria in SQL. Fetching
        // ALL tracks here made every import O(n^2) in rows AND file-exists
        // syscalls - the main cause of watchdog kills on 2000+ file imports.
        let candidates = try read { db in
            try Track
                .filter(Column("artist_id") == newTrack.artistId
                    && Column("duration_ms") == newTrack.durationMs
                    && Column("file_size") == newTrack.fileSize
                    && Column("stable_id") != newTrack.stableId)
                .fetchAll(db)
        }

        // Phase 2: file-existence + metadata checks, no database handle held.
        let staleCandidates = candidates.compactMap { stale -> (stableId: String, title: String)? in
            guard stale.stableId != newTrack.stableId,
                  !FileManager.default.fileExists(atPath: stale.path),
                  FileManager.default.fileExists(atPath: newTrack.path),
                  hasReliableDuplicateMetadata(stale),
                  hasReliableDuplicateMetadata(newTrack),
                  stale.artistId == newTrack.artistId,
                  stale.durationMs == newTrack.durationMs,
                  stale.fileSize == newTrack.fileSize else {
                return nil
            }

            let staleFilename = URL(fileURLWithPath: stale.path).lastPathComponent.lowercased()
            let keeperFilename = URL(fileURLWithPath: newTrack.path).lastPathComponent.lowercased()
            guard staleFilename == keeperFilename,
                  normalizedDuplicateTitle(stale.title) == normalizedDuplicateTitle(newTrack.title) else {
                return nil
            }
            return (stale.stableId, stale.title)
        }
        guard !staleCandidates.isEmpty else { return }

        // Phase 3: one short write transaction deletes only confirmed stales.
        var mergedStableIds: [String] = []
        try write { db in
            for stale in staleCandidates {
                try TrackIdentityMigration.migrateDatabaseReferences(db, from: stale.stableId, to: newTrack.stableId)
                try Track.filter(Column("stable_id") == stale.stableId).deleteAll(db)
                mergedStableIds.append(stale.stableId)
                print("🗑️ Removed strict stale duplicate: \(stale.title)")
            }
        }
        // 文件侧引用（书签/歌词/封面映射）跟随新 stableId——事务外、幂等
        for staleStableId in mergedStableIds {
            TrackIdentityMigration.migrateFileReferences(from: staleStableId, to: newTrack.stableId)
        }
    }

    func migrateTrackStableIdAndPath(oldStableId: String, newStableId: String, newPath: String) throws {
        var didMigrate = false
        try write { db in
            guard var oldTrack = try Track.filter(Column("stable_id") == oldStableId).fetchOne(db) else {
                return
            }

            if var existingNewTrack = try Track.filter(Column("stable_id") == newStableId).fetchOne(db) {
                existingNewTrack.path = newPath
                try existingNewTrack.update(db)
                try TrackIdentityMigration.migrateDatabaseReferences(db, from: oldStableId, to: newStableId)
                try Track.filter(Column("stable_id") == oldStableId).deleteAll(db)
                didMigrate = true
                print("🔁 Merged stale track ID \(oldStableId) into existing resolved ID \(newStableId)")
                return
            }

            oldTrack.stableId = newStableId
            oldTrack.path = newPath
            try oldTrack.update(db)
            try TrackIdentityMigration.migrateDatabaseReferences(db, from: oldStableId, to: newStableId)
            didMigrate = true
            print("🔁 Migrated track ID for moved file: \(oldStableId) -> \(newStableId)")
        }
        // D3：stableId 变更 = 六处引用一起搬（含此前完全没人迁的歌词与封面映射）
        if didMigrate {
            TrackIdentityMigration.migrateFileReferences(from: oldStableId, to: newStableId)
        }
    }

    /// 文件移动（路径变更）后的身份迁移——**唯一入口**（审计 D5）。
    ///
    /// `stable_id == SHA256(标准化 path)` 是不变量：凡路径变更，stableId 必须由新路径
    /// 重算并走同一迁移入口（否则行内身份与实际路径错位，改名迁移/去重/内容指纹对账
    /// 全基于旧 id 追踪）。调用方只管说「这行搬到哪个新路径了」。
    ///
    /// - Returns: 新 stableId；旧 id 不在库中时返回 nil（无事发生，幂等）。
    @discardableResult
    func migrateTrackForMovedFile(oldStableId: String, newPath: String) throws -> String? {
        let newStableId = Self.generatePathStableId(forPath: newPath)
        guard try getTrack(byStableId: oldStableId) != nil else { return nil }
        try migrateTrackStableIdAndPath(oldStableId: oldStableId, newStableId: newStableId, newPath: newPath)
        return newStableId
    }

    func getTrack(byPath path: String) throws -> Track? {
        let standardizedPath = Self.standardizedPath(path)
        return try read { db in
            if let exact = try Track.filter(Column("path") == path).fetchOne(db) {
                return exact
            }

            if standardizedPath != path,
               let standardized = try Track.filter(Column("path") == standardizedPath).fetchOne(db) {
                return standardized
            }

            // Preserve compatibility for older rows whose stored URL spelling
            // differs from Foundation's standardized path representation.
            let tracks = try Track.fetchAll(db)
            return tracks.first { Self.standardizedPath($0.path) == standardizedPath }
        }
    }

    func setTrackArtists(trackStableId: String, artistIds: [Int64]) throws {
        defer { invalidateArtistDisplayNameCache() }
        try write { db in
            try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [trackStableId])

            for (position, artistId) in artistIds.enumerated() {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO track_artist (track_stable_id, artist_id, position)
                        VALUES (?, ?, ?)
                    """,
                    arguments: [trackStableId, artistId, position]
                )
            }
        }
    }

    func getAllTracks() throws -> [Track] {
        return try read { db in
            return try Track.order(Column("id").desc).fetchAll(db)
        }
    }

    func getTrack(byStableId stableId: String) throws -> Track? {
        return try read { db in
            return try Track.filter(Column("stable_id") == stableId).fetchOne(db)
        }
    }

    func getTracksByStableIds(_ stableIds: [String]) throws -> [Track] {
        return try read { db in
            return try Track.filter(stableIds.contains(Column("stable_id"))).order(Column("id").desc).fetchAll(db)
        }
    }

    func getTracksByStableIdsPreservingOrder(_ stableIds: [String]) throws -> [Track] {
        guard !stableIds.isEmpty else { return [] }

        let tracks = try getTracksByStableIds(stableIds)
        let tracksByStableId = Dictionary(uniqueKeysWithValues: tracks.map { ($0.stableId, $0) })
        return stableIds.compactMap { tracksByStableId[$0] }
    }

    func getFavoriteTracks(excludingFormats: [String] = []) throws -> [Track] {
        let favoriteIds = try getFavorites()
        let orderedTracks = try getTracksByStableIdsPreservingOrder(favoriteIds)
        guard !excludingFormats.isEmpty else { return orderedTracks }

        let excludedFormats = Set(excludingFormats.map { $0.lowercased() })
        return orderedTracks.filter { track in
            let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
            return !excludedFormats.contains(ext)
        }
    }

    func getTracksPaginated(limit: Int, offset: Int, excludingFormats: [String] = []) throws -> [Track] {
        return try read { db in
            let sanitizedFormats = excludingFormats
                .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
                .filter { !$0.isEmpty }

            var sql = "SELECT * FROM track"
            if !sanitizedFormats.isEmpty {
                let formatClauses = sanitizedFormats.map { "LOWER(path) NOT LIKE '%.\($0)'" }
                sql += " WHERE " + formatClauses.joined(separator: " AND ")
            }

            sql += " ORDER BY title LIMIT \(max(limit, 0)) OFFSET \(max(offset, 0))"
            return try Track.fetchAll(db, sql: sql)
        }
    }

    func getTrackCount(excludingFormats: [String] = []) throws -> Int {
        return try read { db in
            let sanitizedFormats = excludingFormats
                .map { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
                .filter { !$0.isEmpty }

            var sql = "SELECT COUNT(*) FROM track"
            if !sanitizedFormats.isEmpty {
                let formatClauses = sanitizedFormats.map { "LOWER(path) NOT LIKE '%.\($0)'" }
                sql += " WHERE " + formatClauses.joined(separator: " AND ")
            }

            return try Int.fetchOne(db, sql: sql) ?? 0
        }
    }

    func getTracksByAlbumId(_ albumId: Int64) throws -> [Track] {
        return try read { db in
            // Fetch all tracks for this album
            let tracks = try Track
                .filter(Column("album_id") == albumId)
                .fetchAll(db)

            // Sort in Swift to ensure proper integer sorting
            let sortedTracks = tracks.sorted { track1, track2 in
                // Sort by track number only (ignore disc number)
                let trackNo1 = track1.trackNo ?? 999
                let trackNo2 = track2.trackNo ?? 999

                if trackNo1 != trackNo2 {
                    return trackNo1 < trackNo2
                }

                // Tiebreaker: sort by title
                return track1.title < track2.title
            }

            return sortedTracks
        }
    }

    func getTracksByArtistId(_ artistId: Int64) throws -> [Track] {
        return try read { db in
            return try Track.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT track.*
                    FROM track
                    LEFT JOIN track_artist ON track_artist.track_stable_id = track.stable_id
                    WHERE track.artist_id = ? OR track_artist.artist_id = ?
                    ORDER BY track.title
                """,
                arguments: [artistId, artistId]
            )
        }
    }

    /// 按多个 artist id 查曲目（去重 union），供归一后的歌手详情聚合
    /// （同名简繁两行 artist 的曲目合并显示）。
    func getTracksByArtistIds(_ ids: [Int64]) throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        let uniqueIds = Array(Set(ids))
        let placeholders = Array(repeating: "?", count: uniqueIds.count).joined(separator: ",")
        return try read { db in
            return try Track.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT track.*
                    FROM track
                    LEFT JOIN track_artist ON track_artist.track_stable_id = track.stable_id
                    WHERE track.artist_id IN (\(placeholders)) OR track_artist.artist_id IN (\(placeholders))
                    ORDER BY track.title
                """,
                arguments: StatementArguments(uniqueIds + uniqueIds)
            )
        }
    }

    // MARK: - Favorites operations

    func addToFavorites(trackStableId: String) throws {
        print("🗃️ Database: Adding to favorites - \(trackStableId)")
        try write { db in
            let favorite = Favorite(trackStableId: trackStableId)
            try favorite.insert(db)
            // S2 M4-1：收藏 upsert → outbox（同一事务，业务行与变更日志原子提交）
            try SyncChangeLogStore.record(
                db,
                entity: .favorite,
                rowKey: trackStableId,
                op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(SyncFavoriteSnapshot(trackStableId: trackStableId))
            )
            print("🗃️ Database: Successfully inserted favorite")
        }
    }

    /// Inserts many favorites in a single transaction. Restoring them one at a
    /// time meant one committed (and fsync'd) write per track, which on a cold
    /// launch with a synced library was a long stall.
    func addToFavorites(trackStableIds: [String]) throws {
        guard !trackStableIds.isEmpty else { return }
        try write { db in
            for trackStableId in trackStableIds {
                try Favorite(trackStableId: trackStableId).insert(db)
                // S2 M4-1：批量恢复也是真实收藏变更（iCloud 恢复/导入）→ 逐条 outbox
                try SyncChangeLogStore.record(
                    db,
                    entity: .favorite,
                    rowKey: trackStableId,
                    op: .upsert,
                    payloadJSON: try SyncSnapshotCodec.encode(SyncFavoriteSnapshot(trackStableId: trackStableId))
                )
            }
        }
        print("🗃️ Database: Inserted \(trackStableIds.count) favorite(s) in one transaction")
    }

    func removeFromFavorites(trackStableId: String) throws {
        print("🗃️ Database: Removing from favorites - \(trackStableId)")
        let deletedCount = try write { db in
            let count = try Favorite.filter(Column("track_stable_id") == trackStableId).deleteAll(db)
            // S2 M4-1：仅实际删除时记 outbox delete（0 行 = 本就没有，无需同步删除）
            if count > 0 {
                try SyncChangeLogStore.record(
                    db,
                    entity: .favorite,
                    rowKey: trackStableId,
                    op: .delete,
                    payloadJSON: nil
                )
            }
            return count
        }
        print("🗃️ Database: Deleted \(deletedCount) favorite(s)")
    }

    func isFavorite(trackStableId: String) throws -> Bool {
        return try read { db in
            return try Favorite.filter(Column("track_stable_id") == trackStableId).fetchOne(db) != nil
        }
    }

    func getFavorites() throws -> [String] {
        let favorites = try read { db in
            return try Favorite.fetchAll(db).map { $0.trackStableId }
        }
        // Count only - dumping every favorite ID spammed the log for large
        // libraries and leaked private track identifiers (audit)
        print("🗃️ Database: Retrieved \(favorites.count) favorites")
        return favorites
    }

    func deleteTrack(byStableId stableId: String) throws {
        print("🗃️ Database: Deleting track with stable ID - \(stableId)")
        defer { invalidateArtistDisplayNameCache() }
        let deletedCount = try write { db in
            // D4：被删的引用行要在删前取出（删完就查不到了）——它们的 key 用来
            // 记本地 outbox delete（见下方注释）。
            let playlistSlugs = try String.fetchAll(db, sql: """
            SELECT playlist.slug FROM playlist_item
            JOIN playlist ON playlist.id = playlist_item.playlist_id
            WHERE playlist_item.track_stable_id = ? AND playlist.is_folder_synced = 0
            """, arguments: [stableId])
            let playedAts = try Int64.fetchAll(
                db,
                sql: "SELECT played_at FROM play_history WHERE track_stable_id = ?",
                arguments: [stableId]
            )

            // Remove from playlist items first
            let playlistItemsDeleted = try PlaylistItem.filter(Column("track_stable_id") == stableId).deleteAll(db)
            if playlistItemsDeleted > 0 {
                print("🗑️ Removed track from \(playlistItemsDeleted) playlist position(s)")
            }

            // Remove from favorites if it exists
            let favoritesDeleted = try Favorite.filter(Column("track_stable_id") == stableId).deleteAll(db)
            if favoritesDeleted > 0 {
                print("🗃️ Database: Removed \(favoritesDeleted) favorite entries for track")
            }

            if playlistItemsDeleted > 0 {
                print("🗃️ Database: Removed \(playlistItemsDeleted) playlist entries for track")
            }

            // Remove multi-artist link rows - track_artist has no FK to track,
            // so these do NOT cascade. Leaving them kept deleted tracks'
            // artists alive forever (issue #74)
            try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [stableId])

            // Remove play history for the deleted track - play_history has no
            // FK to track, so rows for deleted tracks would otherwise pile up
            // forever and resurrect on stable-ID reuse (P0-3)
            try db.execute(sql: "DELETE FROM play_history WHERE track_stable_id = ?", arguments: [stableId])

            // D4：删除引起的引用行删除也要记本地 outbox（与 addToFavorites /
            // removeFromFavorites / removeFromPlaylist 同型）。
            // v2 语义下 delete **不上线**，它的作用是**批次抑制**：同一
            // (entity, rowKey) 在本批末尾是 delete 时，其更早的 upsert 也不再上线
            // （SyncChangeLogDeletionPolicy.transmittableIndexes）——否则本端删除前
            // 尚未发送的「加收藏 / 加歌单」upsert 会在对端落地成永远无法纠正的幽灵行。
            if favoritesDeleted > 0 {
                try SyncChangeLogStore.record(
                    db,
                    entity: .favorite,
                    rowKey: stableId,
                    op: .delete,
                    payloadJSON: nil
                )
            }
            // folder-synced 歌单内容由本地扫描派生，不入跨端同步（与写入侧一致）
            for slug in Set(playlistSlugs) {
                try SyncChangeLogStore.record(
                    db,
                    entity: .playlistItem,
                    rowKey: SyncPlaylistItemSnapshot(
                        playlistSlug: slug,
                        position: 0,
                        trackStableId: stableId
                    ).rowKey,
                    op: .delete,
                    payloadJSON: nil
                )
            }
            for playedAt in playedAts {
                try SyncChangeLogStore.record(
                    db,
                    entity: .playHistory,
                    rowKey: SyncPlayHistorySnapshot(
                        trackStableId: stableId,
                        playedAt: playedAt,
                        playDurationMs: 0
                    ).rowKey,
                    op: .delete,
                    payloadJSON: nil
                )
            }

            // Delete the track
            return try Track.filter(Column("stable_id") == stableId).deleteAll(db)
        }
        print("🗃️ Database: Deleted \(deletedCount) track(s)")

        // Clean up orphaned albums and artists after track deletion
        try cleanupOrphanedLibraryEntries()

        // Remove stored bookmark so the file won't be re-imported（经书签唯一入口）
        removeExternalFileBookmark(for: stableId)
    }

    /// 仅从曲库移除（D7）：文件保留（不动书签）、用户数据（收藏 / 歌单 / 播放历史）保留。
    ///
    /// 与 `deleteTrack` 的区别：**不删 favorite / playlist_item / play_history**，
    /// 也不清书签——用户勾回该文件格式并重扫后，同一 stableId 的 track 行重新入库，
    /// 收藏与歌单项自动重新指向它（不必重新收藏）。
    /// 使用场景 = 「文件格式取消收录」（文件没丢，只是本轮不收录）与
    /// 「仅从曲库移除（保留文件）」的取消勾选恢复语义。
    ///
    /// ⚠️ 已知边界：playlist_item 行会在下一次索引完成时被
    /// `cleanupOrphanedPlaylistItems()` 按「track 行不存在」清掉（该清理的语义 =
    /// 歌单不留孤儿条目，见 AppCoordinator+iCloud.onIndexingCompleted）。要让歌单项
    /// 也长期存活，需要「track 行保留 + 读取侧可见性过滤」的改造（产品决策），
    /// 本次不做；favorite 与 play_history 无孤儿清理，稳定保留。
    func removeTrackFromLibrary(byStableId stableId: String) throws {
        print("🗃️ Database: Removing track from library only - \(stableId)")
        defer { invalidateArtistDisplayNameCache() }
        let removedCount = try write { db in
            // 派生行（artist 关联）随行消失；重扫入库时由 setTrackArtists 重建
            try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [stableId])
            return try Track.filter(Column("stable_id") == stableId).deleteAll(db)
        }
        print("🗃️ Database: Removed \(removedCount) track row(s) (favorites/playlists/history kept)")

        // 清理失去曲目的专辑/歌手（不动 favorite / playlist_item / play_history）
        try cleanupOrphanedLibraryEntries()
    }

    private func removeExternalFileBookmark(for stableId: String) {
        guard let store = ExternalFileBookmarkStore.default else { return }
        do {
            if try store.remove(forStableId: stableId) {
                print("🔖 Removed external file bookmark for stableId: \(stableId)")
            }
        } catch {
            print("⚠️ Failed to remove external file bookmark: \(error.localizedDescription)")
        }
    }

    // MARK: - 刮削改名引用迁移（E1 标签刮削）

    /// 刮削改名后的库内引用迁移：把 track 行从旧路径迁到新路径（stable_id 重算），
    /// 收藏/歌单/歌手关联/播放历史四表引用 + 文件侧引用（书签/歌词/封面映射）
    /// 统一走 `TrackIdentityMigration`（stableId 变更的唯一入口）。
    ///
    /// - 旧路径无 track（外部文件未入库/已被删）→ 无事发生（幂等）
    /// - 新 stable_id 已被另一 track 占用（库中已有同路径曲目）→ 引用合并进已存在者后删除本行
    ///   （对齐 upsertTrack 的 duplicates 语义）
    /// - 不改文件系统、不发通知（调用方职责：TagWriterService 已完成原子改名，
    ///   UI 层负责通知刷新）
    func moveTrack(from oldPath: String, to newPath: String) throws {
        let normalizedOld = Self.standardizedPath(oldPath)
        let normalizedNew = Self.standardizedPath(newPath)
        guard normalizedOld != normalizedNew else { return }
        guard let track = try getTrack(byPath: normalizedOld) else { return }

        let newStableId = Self.generatePathStableId(forPath: normalizedNew)
        // M3-1: 改名不改内容——已有 content_hash 原样保留（内容没变）；为 nil
        // （老库行）在写事务外顺手补算（文件刚改名必存在），避免改名后因惰性回填
        // 已跑过而永久 NULL。audit 纪律：文件 IO 不进写事务。合并分支会删掉本行，
        // 该罕见路径下多算一次无害。
        let contentHashToFill: String?
        if track.contentHash == nil {
            contentHashToFill = Self.contentHashIfFilePresent(atPath: normalizedNew)
        } else {
            contentHashToFill = nil
        }
        var didMigrate = false
        try write { db in
            if let existing = try Track.filter(Column("stable_id") == newStableId).fetchOne(db),
               existing.id != track.id {
                // 目标已被库中另一曲目占用：合并引用过去，删除旧行
                try TrackIdentityMigration.migrateDatabaseReferences(db, from: track.stableId, to: newStableId)
                try Track.filter(Column("id") == track.id).deleteAll(db)
                didMigrate = true
                print("🗂️ moveTrack: merged \(track.stableId) into existing \(newStableId)")
            } else {
                var updated = track
                updated.path = normalizedNew
                updated.stableId = newStableId
                if let contentHashToFill {
                    updated.contentHash = contentHashToFill
                }
                try updated.save(db)
                try TrackIdentityMigration.migrateDatabaseReferences(db, from: track.stableId, to: newStableId)
                didMigrate = true
                print("🗂️ moveTrack: \(normalizedOld) → \(normalizedNew) (stableId \(track.stableId) → \(newStableId))")
            }
        }
        // D3：改名后文件侧引用（书签键 / 三个歌词目录 / 封面映射）一起跟随新 stableId，
        // 否则手动与被对齐的歌词在改名后静默失联（审计 🟡-1）。事务外、幂等。
        if didMigrate {
            TrackIdentityMigration.migrateFileReferences(from: track.stableId, to: newStableId)
        }
    }

    // MARK: - 批量刮削目标查询（E1 标签刮削 library 模式）

    /// 查「year 缺失 或 genre 缺失」的曲目（web 批量 library 模式：只处理
    /// year 为空或 genre 为空 的歌曲）。year 存 album 表，genre 存 track 表——
    /// 故 LEFT JOIN album 判定 album.year IS NULL OR track.genre IS NULL。
    /// 查询失败抛 GRDB 错误（调用方 runBatch 原样上抛）。
    func getTracksMissingYearOrGenre() throws -> [Track] {
        return try read { db in
            try Track.fetchAll(db, sql: """
                SELECT track.* FROM track
                LEFT JOIN album ON album.id = track.album_id
                WHERE album.year IS NULL OR track.genre IS NULL
                ORDER BY track.title
            """)
        }
    }

}
