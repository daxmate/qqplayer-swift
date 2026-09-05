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
        var savedTrack: Track?
        try write { db in
            var trackToSave = track

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
                    // Transfer favorites and playlist items to the new stable_id
                    try db.execute(
                        sql: "UPDATE favorite SET track_stable_id = ? WHERE track_stable_id = ?",
                        arguments: [trackToSave.stableId, duplicate.stableId]
                    )
                    try db.execute(
                        sql: "UPDATE playlist_item SET track_stable_id = ? WHERE track_stable_id = ?",
                        arguments: [trackToSave.stableId, duplicate.stableId]
                    )
                    try db.execute(
                        sql: "UPDATE OR IGNORE track_artist SET track_stable_id = ? WHERE track_stable_id = ?",
                        arguments: [trackToSave.stableId, duplicate.stableId]
                    )
                    try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [duplicate.stableId])
                    // Same path = same song: play history follows the saved row (P0-3)
                    try db.execute(
                        sql: "UPDATE play_history SET track_stable_id = ? WHERE track_stable_id = ?",
                        arguments: [trackToSave.stableId, duplicate.stableId]
                    )
                    // Delete the duplicate
                    try Track.filter(Column("id") == duplicate.id).deleteAll(db)
                    print("🗑️ Removed duplicate track with old stable_id: \(duplicate.stableId)")
                }
            }

            try trackToSave.save(db)
            savedTrack = trackToSave
        }

        // File-existence checks and the follow-up delete run OUTSIDE the
        // upsert write transaction: syscalls no longer pin the single GRDB
        // writer, which used to serialize all four concurrent indexers
        // (audit: file IO inside a write transaction).
        if let savedTrack {
            try cleanupStaleUnplayableDuplicates(matching: savedTrack)
        }
    }

    private func mergeTrackReferences(db: Database, from oldStableId: String, to newStableId: String) throws {
        try db.execute(
            sql: "UPDATE OR IGNORE favorite SET track_stable_id = ? WHERE track_stable_id = ?",
            arguments: [newStableId, oldStableId]
        )
        try db.execute(
            sql: "UPDATE OR IGNORE playlist_item SET track_stable_id = ? WHERE track_stable_id = ?",
            arguments: [newStableId, oldStableId]
        )
        try db.execute(
            sql: "UPDATE OR IGNORE track_artist SET track_stable_id = ? WHERE track_stable_id = ?",
            arguments: [newStableId, oldStableId]
        )
        try db.execute(sql: "DELETE FROM favorite WHERE track_stable_id = ?", arguments: [oldStableId])
        try db.execute(sql: "DELETE FROM playlist_item WHERE track_stable_id = ?", arguments: [oldStableId])
        try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [oldStableId])

        // play_history has no UNIQUE constraint on track_stable_id, so the
        // UPDATE migrates every row and no leftover DELETE is needed: history
        // follows the song through the merge (P0-3)
        try db.execute(
            sql: "UPDATE play_history SET track_stable_id = ? WHERE track_stable_id = ?",
            arguments: [newStableId, oldStableId]
        )
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
        try write { db in
            for stale in staleCandidates {
                try self.mergeTrackReferences(db: db, from: stale.stableId, to: newTrack.stableId)
                try Track.filter(Column("stable_id") == stale.stableId).deleteAll(db)
                print("🗑️ Removed strict stale duplicate: \(stale.title)")
            }
        }
    }

    func migrateTrackStableIdAndPath(oldStableId: String, newStableId: String, newPath: String) throws {
        try write { db in
            guard var oldTrack = try Track.filter(Column("stable_id") == oldStableId).fetchOne(db) else {
                return
            }

            if var existingNewTrack = try Track.filter(Column("stable_id") == newStableId).fetchOne(db) {
                existingNewTrack.path = newPath
                try existingNewTrack.update(db)
                try self.mergeTrackReferences(db: db, from: oldStableId, to: newStableId)
                try Track.filter(Column("stable_id") == oldStableId).deleteAll(db)
                print("🔁 Merged stale track ID \(oldStableId) into existing resolved ID \(newStableId)")
                return
            }

            oldTrack.stableId = newStableId
            oldTrack.path = newPath
            try oldTrack.update(db)
            try self.mergeTrackReferences(db: db, from: oldStableId, to: newStableId)
            print("🔁 Migrated track ID for moved file: \(oldStableId) -> \(newStableId)")
        }
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
            }
        }
        print("🗃️ Database: Inserted \(trackStableIds.count) favorite(s) in one transaction")
    }

    func removeFromFavorites(trackStableId: String) throws {
        print("🗃️ Database: Removing from favorites - \(trackStableId)")
        let deletedCount = try write { db in
            return try Favorite.filter(Column("track_stable_id") == trackStableId).deleteAll(db)
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

            // Delete the track
            return try Track.filter(Column("stable_id") == stableId).deleteAll(db)
        }
        print("🗃️ Database: Deleted \(deletedCount) track(s)")

        // Clean up orphaned albums and artists after track deletion
        try cleanupOrphanedLibraryEntries()

        // Remove stored bookmark so the file won't be re-imported
        removeExternalFileBookmark(for: stableId)
    }

    private func removeExternalFileBookmark(for stableId: String) {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        guard FileManager.default.fileExists(atPath: bookmarksURL.path) else { return }

        do {
            let data = try Data(contentsOf: bookmarksURL)
            guard var bookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] else { return }

            guard bookmarks.removeValue(forKey: stableId) != nil else { return }

            let plistData = try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .xml, options: 0)
            try plistData.write(to: bookmarksURL)
            print("🔖 Removed external file bookmark for stableId: \(stableId)")
        } catch {
            print("⚠️ Failed to remove external file bookmark: \(error.localizedDescription)")
        }
    }

    // MARK: - 刮削改名引用迁移（E1 标签刮削）

    /// 刮削改名后的库内引用迁移：把 track 行从旧路径迁到新路径（stable_id 重算），
    /// 收藏/歌单/歌手关联/播放历史四表引用跟随新 stable_id（复用 mergeTrackReferences）。
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
        try write { db in
            if let existing = try Track.filter(Column("stable_id") == newStableId).fetchOne(db),
               existing.id != track.id {
                // 目标已被库中另一曲目占用：合并引用过去，删除旧行
                try self.mergeTrackReferences(db: db, from: track.stableId, to: newStableId)
                try Track.filter(Column("id") == track.id).deleteAll(db)
                print("🗂️ moveTrack: merged \(track.stableId) into existing \(newStableId)")
            } else {
                var updated = track
                updated.path = normalizedNew
                updated.stableId = newStableId
                try updated.save(db)
                try self.mergeTrackReferences(db: db, from: track.stableId, to: newStableId)
                print("🗂️ moveTrack: \(normalizedOld) → \(normalizedNew) (stableId \(track.stableId) → \(newStableId))")
            }
        }
    }
}
