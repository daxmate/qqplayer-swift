//
//  DatabaseManager+Playlists.swift
//  QQPlayer
//
//  歌单 CRUD/文件夹同步/清理（N+1 LEFT JOIN 修复查询）、手动歌单去重/孤儿清理。
//
import Foundation
@preconcurrency import GRDB

extension DatabaseManager {
    func deduplicatePlaylistItems() throws {
        print("🔍 Checking for duplicate playlist items...")

        let removedCount = try write { db in
            let playlists = try Playlist.fetchAll(db)
            var totalRemoved = 0

            for playlist in playlists {
                guard let playlistId = playlist.id else { continue }

                // Fetch every item of this playlist together with its track
                // path in ONE LEFT JOIN query instead of one Track lookup per
                // item (audit: N+1 queries on manual playlist cleanup).
                let rows = try Row.fetchAll(db, sql: """
                SELECT pi.position, pi.track_stable_id, t.path
                FROM playlist_item pi
                LEFT JOIN track t ON t.stable_id = pi.track_stable_id
                WHERE pi.playlist_id = ?
                ORDER BY pi.position
                """, arguments: [playlistId])

                // Group by track path (need to join with track table)
                var seenPaths: Set<String> = [] // paths we've already seen
                var itemsToRemove: [PlaylistItem] = []

                for row in rows {
                    let position: Int = row["position"]
                    let trackStableId: String = row["track_stable_id"]
                    let path: String? = row["path"]

                    // A nil path means the track row is gone; the item is kept
                    // (orphan cleanup handles it) and cannot be a duplicate.
                    guard let path else { continue }

                    if seenPaths.contains(path) {
                        // Duplicate found - mark for removal
                        itemsToRemove.append(PlaylistItem(playlistId: playlistId, position: position, trackStableId: trackStableId))
                        print("⚠️ Playlist '\(playlist.title)': Found duplicate for path '\(path)' at position \(position)")
                    } else {
                        // First occurrence - keep it
                        seenPaths.insert(path)
                    }
                }

                // Remove duplicates
                for item in itemsToRemove {
                    try PlaylistItem
                        .filter(Column("playlist_id") == playlistId && Column("position") == item.position)
                        .deleteAll(db)
                    totalRemoved += 1
                }

                if !itemsToRemove.isEmpty {
                    print("✅ Removed \(itemsToRemove.count) duplicate items from playlist '\(playlist.title)'")

                    // Reorder remaining items to fill gaps
                    let remainingItems = try PlaylistItem
                        .filter(Column("playlist_id") == playlistId)
                        .order(Column("position"))
                        .fetchAll(db)

                    for (index, item) in remainingItems.enumerated() {
                        try db.execute(
                            sql: "UPDATE playlist_item SET position = ? WHERE playlist_id = ? AND track_stable_id = ? AND position = ?",
                            arguments: [index, playlistId, item.trackStableId, item.position]
                        )
                    }
                }
            }

            return totalRemoved
        }

        if removedCount > 0 {
            print("✅ Removed \(removedCount) duplicate playlist items across all playlists")
        } else {
            print("✅ No duplicate playlist items found")
        }
    }

    func cleanupOrphanedPlaylistItems() throws {
        print("🧹 Cleaning up orphaned playlist items...")

        // SAFETY CHECK: Verify database is healthy before cleanup
        let trackCount = try read { db in
            try Track.fetchCount(db)
        }

        if trackCount == 0 {
            print("⚠️ SAFETY: Skipping playlist cleanup - no tracks in database (possible database error)")
            print("⚠️ This prevents accidental deletion of all playlist items")
            return
        }

        // One DELETE removes every item whose track is gone, replacing the
        // per-item existence query (audit: N+1). The trackCount==0 safety
        // gate above still protects against an unreadable/empty library.
        let deletedCount = try write { db in
            try db.execute(sql: """
            DELETE FROM playlist_item
            WHERE track_stable_id NOT IN (SELECT stable_id FROM track)
            """)
            return db.changesCount
        }

        if deletedCount > 0 {
            print("✅ Cleaned up \(deletedCount) orphaned playlist items")
        } else {
            print("✅ No orphaned playlist items found")
        }
    }

    // MARK: - Playlist operations

    func createPlaylist(title: String) throws -> Playlist {
        return try write { db in
            let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
            let now = Int64(Date().timeIntervalSince1970)
            let playlist = Playlist(
                id: nil,
                slug: slug,
                title: title,
                createdAt: now,
                updatedAt: now,
                lastPlayedAt: 0,
                folderPath: nil,
                isFolderSynced: false,
                lastFolderSync: nil
            )
            let inserted = try playlist.insertAndFetch(db)!
            // S2 M4-1：手动歌单新建 → outbox upsert（同一事务）。folder-synced 歌单
            // 由本地扫描器派生（folder_path 是设备本地路径），不参与跨端 LWW。
            let snapshot = SyncPlaylistSnapshot(
                slug: inserted.slug,
                title: inserted.title,
                createdAt: inserted.createdAt,
                updatedAt: inserted.updatedAt,
                lastPlayedAt: inserted.lastPlayedAt,
                folderPath: inserted.folderPath,
                isFolderSynced: inserted.isFolderSynced,
                lastFolderSync: inserted.lastFolderSync,
                customCoverImagePath: inserted.customCoverImagePath
            )
            try SyncChangeLogStore.record(
                db,
                entity: .playlist,
                rowKey: snapshot.rowKey,
                op: .upsert,
                payloadJSON: try SyncSnapshotCodec.encode(snapshot)
            )
            return inserted
        }
    }

    func createFolderPlaylist(title: String, folderPath: String) throws -> Playlist {
        return try write { db in
            // Normalize folder path by using just the folder name for comparison
            // This avoids issues with changing container UUIDs
            let folderName = URL(fileURLWithPath: folderPath).lastPathComponent

            // Check if this folder was previously deleted by the user
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM deleted_folder_playlist WHERE folder_path = ?",
                arguments: [folderName]
            ) ?? 0

            if count > 0 {
                print("⛔ Folder playlist '\(folderName)' was previously deleted by user, skipping recreation")
                throw DatabaseError.folderPlaylistDeleted
            }

            let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
            let now = Int64(Date().timeIntervalSince1970)

            // Check if a folder-synced playlist already exists for this path
            if let existingPlaylist = try Playlist.filter(Column("folder_path") == folderPath).fetchOne(db) {
                print("📁 Folder playlist already exists: \(existingPlaylist.title)")
                return existingPlaylist
            }

            // CRITICAL: Check if a manual playlist with the same title/slug already exists
            // This prevents data loss by not overwriting user-created playlists
            if let existingManualPlaylist = try Playlist.filter(Column("slug") == slug).fetchOne(db) {
                if !existingManualPlaylist.isFolderSynced {
                    print("⚠️ Manual playlist '\(title)' already exists - converting to folder-synced playlist")
                    // Update the existing playlist to be folder-synced
                    var updatedPlaylist = existingManualPlaylist
                    updatedPlaylist.folderPath = folderPath
                    updatedPlaylist.isFolderSynced = true
                    updatedPlaylist.lastFolderSync = now
                    updatedPlaylist.updatedAt = now
                    try updatedPlaylist.update(db)
                    print("✅ Converted manual playlist '\(title)' to folder-synced")
                    return updatedPlaylist
                } else {
                    // Another folder playlist with same name but different path
                    print("⚠️ Folder playlist '\(title)' already exists with different path")
                    return existingManualPlaylist
                }
            }

            let playlist = Playlist(
                id: nil,
                slug: slug,
                title: title,
                createdAt: now,
                updatedAt: now,
                lastPlayedAt: 0,
                folderPath: folderPath,
                isFolderSynced: true,
                lastFolderSync: now
            )
            print("📁 Creating folder-synced playlist: \(title) -> \(folderPath)")
            return try playlist.insertAndFetch(db)!
        }
    }

    enum DatabaseError: Error {
        case folderPlaylistDeleted
    }

    func getAllPlaylists() throws -> [Playlist] {
        return try read { db in
            return try Playlist.order(Column("last_played_at").desc, Column("updated_at").desc).fetchAll(db)
        }
    }

    func searchPlaylists(query: String, limit: Int = 15) throws -> [Playlist] {
        return try read { db in
            let pattern = "%\(query)%"
            return try Playlist
                .filter(Column("title").like(pattern))
                .order(Column("title"))
                .limit(limit)
                .fetchAll(db)
        }
    }

    func getFolderPlaylist(forPath folderPath: String) throws -> Playlist? {
        return try read { db in
            return try Playlist.filter(Column("folder_path") == folderPath && Column("is_folder_synced") == true).fetchOne(db)
        }
    }

    func addToPlaylist(playlistId: Int64, trackStableId: String) throws {
        print("🎵 Adding track \(trackStableId) to playlist \(playlistId)")
        try write { db in
            // Check if track is already in playlist
            let existingItem = try PlaylistItem
                .filter(Column("playlist_id") == playlistId && Column("track_stable_id") == trackStableId)
                .fetchOne(db)

            if existingItem != nil {
                print("⚠️ Track already in playlist")
                return
            }

            // Get the next position in the playlist
            let maxPosition = try PlaylistItem
                .filter(Column("playlist_id") == playlistId)
                .select(max(Column("position")))
                .asRequest(of: Int.self)
                .fetchOne(db) ?? 0

            let playlistItem = PlaylistItem(playlistId: playlistId, position: maxPosition + 1, trackStableId: trackStableId)
            print("🎵 Creating playlist item with position \(maxPosition + 1)")
            try playlistItem.insert(db)
            // S2 M4-1：手动歌单项新增 → outbox upsert（同一事务）。folder-synced
            // 歌单内容由本地扫描派生，不入跨端同步。
            if let playlist = try Playlist.filter(Column("id") == playlistId).fetchOne(db),
               !playlist.isFolderSynced {
                try SyncChangeLogStore.record(
                    db,
                    entity: .playlistItem,
                    rowKey: SyncPlaylistItemSnapshot(
                        playlistSlug: playlist.slug,
                        position: playlistItem.position,
                        trackStableId: playlistItem.trackStableId
                    ).rowKey,
                    op: .upsert,
                    payloadJSON: try SyncSnapshotCodec.encode(SyncPlaylistItemSnapshot(
                        playlistSlug: playlist.slug,
                        position: playlistItem.position,
                        trackStableId: playlistItem.trackStableId
                    ))
                )
            }
            print("✅ Successfully added track to playlist")
        }
    }

    func removeFromPlaylist(playlistId: Int64, trackStableId: String) throws {
        try write { db in
            let deleted = try PlaylistItem
                .filter(Column("playlist_id") == playlistId && Column("track_stable_id") == trackStableId)
                .deleteAll(db)
            // S2 M4-1：手动歌单项删除 → outbox delete（行键稳定 = slug|track）。
            if deleted > 0,
               let playlist = try Playlist.filter(Column("id") == playlistId).fetchOne(db),
               !playlist.isFolderSynced {
                try SyncChangeLogStore.record(
                    db,
                    entity: .playlistItem,
                    rowKey: SyncPlaylistItemSnapshot(
                        playlistSlug: playlist.slug,
                        position: 0,
                        trackStableId: trackStableId
                    ).rowKey,
                    op: .delete,
                    payloadJSON: nil
                )
            }
        }
    }

    func reorderPlaylistItems(playlistId: Int64, from sourceIndex: Int, to destinationIndex: Int) throws {
        print("🔄 Database: Reordering playlist items from \(sourceIndex) to \(destinationIndex)")
        try write { db in
            // Get all playlist items ordered by position
            let items = try PlaylistItem
                .filter(Column("playlist_id") == playlistId)
                .order(Column("position"))
                .fetchAll(db)

            guard sourceIndex >= 0 && sourceIndex < items.count &&
                destinationIndex >= 0 && destinationIndex < items.count else {
                print("❌ Invalid indices for reordering")
                return
            }

            // Remove the item from the source position
            var mutableItems = items
            let movedItem = mutableItems.remove(at: sourceIndex)

            // Insert at the destination position
            mutableItems.insert(movedItem, at: destinationIndex)

            // Two-phase update to avoid UNIQUE constraint violations:
            // Phase 1: Shift all positions by +10000 (temporary offset)
            print("🔄 Phase 1: Shifting positions to avoid conflicts")
            for (index, item) in mutableItems.enumerated() {
                _ = try PlaylistItem
                    .filter(Column("playlist_id") == playlistId &&
                        Column("track_stable_id") == item.trackStableId)
                    .updateAll(db, Column("position").set(to: index + 10000))
            }

            // Phase 2: Set final positions
            print("🔄 Phase 2: Setting final positions")
            for (index, item) in mutableItems.enumerated() {
                _ = try PlaylistItem
                    .filter(Column("playlist_id") == playlistId &&
                        Column("track_stable_id") == item.trackStableId)
                    .updateAll(db, Column("position").set(to: index))
            }

            // S2 M4-1：手动歌单重排 → 全量 upsert（同一事务；位置是载荷字段，行键
            // slug|track 稳定，同键多版本由 LWW updated_at 收敛）。folder-synced 跳过。
            if let playlist = try Playlist.filter(Column("id") == playlistId).fetchOne(db),
               !playlist.isFolderSynced {
                let finalItems = try PlaylistItem
                    .filter(Column("playlist_id") == playlistId)
                    .order(Column("position"))
                    .fetchAll(db)
                for item in finalItems {
                    let snapshot = SyncPlaylistItemSnapshot(
                        playlistSlug: playlist.slug,
                        position: item.position,
                        trackStableId: item.trackStableId
                    )
                    try SyncChangeLogStore.record(
                        db,
                        entity: .playlistItem,
                        rowKey: snapshot.rowKey,
                        op: .upsert,
                        payloadJSON: try SyncSnapshotCodec.encode(snapshot)
                    )
                }
            }

            print("✅ Successfully reordered playlist items")
        }
    }

    func getPlaylistItems(playlistId: Int64) throws -> [PlaylistItem] {
        return try read { db in
            return try PlaylistItem
                .filter(Column("playlist_id") == playlistId)
                .order(Column("position"))
                .fetchAll(db)
        }
    }

    func isTrackInPlaylist(playlistId: Int64, trackStableId: String) throws -> Bool {
        return try read { db in
            return try PlaylistItem
                .filter(Column("playlist_id") == playlistId && Column("track_stable_id") == trackStableId)
                .fetchOne(db) != nil
        }
    }

    func deletePlaylist(playlistId: Int64) throws {
        print("🗑️ Database: Deleting playlist with ID - \(playlistId)")
        let deletedCount = try write { db in
            // 先取歌单（记录 delete 行键用；folder-synced 歌单不入同步，但删除时
            // 若曾是手动歌单转 folder（历史遗留）也不补记——v1 只同步手动歌单生命周期）
            let playlist = try Playlist.filter(Column("id") == playlistId).fetchOne(db)
            if let playlist, !playlist.isFolderSynced {
                try SyncChangeLogStore.record(
                    db,
                    entity: .playlist,
                    rowKey: playlist.slug,
                    op: .delete,
                    payloadJSON: try SyncSnapshotCodec.encode(SyncPlaylistSnapshot(
                        slug: playlist.slug,
                        title: playlist.title,
                        createdAt: playlist.createdAt,
                        updatedAt: playlist.updatedAt,
                        lastPlayedAt: playlist.lastPlayedAt,
                        folderPath: playlist.folderPath,
                        isFolderSynced: playlist.isFolderSynced,
                        lastFolderSync: playlist.lastFolderSync,
                        customCoverImagePath: playlist.customCoverImagePath
                    ))
                )
            }

            // Check if this is a folder-synced playlist
            if let playlist,
               let folderPath = playlist.folderPath,
               playlist.isFolderSynced {
                // Normalize to just the folder name to avoid container UUID issues
                let folderName = URL(fileURLWithPath: folderPath).lastPathComponent

                // Add to deleted folder playlists table to prevent recreation
                let now = Int64(Date().timeIntervalSince1970)
                try db.execute(
                    sql: "INSERT OR REPLACE INTO deleted_folder_playlist (folder_path, deleted_at) VALUES (?, ?)",
                    arguments: [folderName, now]
                )
                print("📝 Marked folder playlist '\(folderName)' as deleted to prevent recreation")
            }

            return try Playlist.filter(Column("id") == playlistId).deleteAll(db)
        }
        print("🗑️ Database: Deleted \(deletedCount) playlist(s)")
    }

    func getAllFolderPlaylists() throws -> [Playlist] {
        return try read { db in
            try Playlist.filter(Column("is_folder_synced") == true).fetchAll(db)
        }
    }

    /// Clears the "don't recreate" tombstones so folder playlists come back
    /// on the next scan when the user re-enables auto-creation
    func clearDeletedFolderPlaylistTombstones() throws {
        try write { db in
            try db.execute(sql: "DELETE FROM deleted_folder_playlist")
        }
    }

    func renamePlaylist(playlistId: Int64, newTitle: String) throws {
        print("✏️ Database: Renaming playlist \(playlistId) to '\(newTitle)'")
        let now = Int64(Date().timeIntervalSince1970)
        let updatedCount = try write { db in
            let updated = try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db,
                           Column("title").set(to: newTitle),
                           Column("updated_at").set(to: now)
                )
            // S2 M4-1：手动歌单改名 → outbox upsert（slug 不变 = 行键稳定）。
            // folder-synced 歌单（本地扫描器派生）不入同步。
            if updated > 0,
               let playlist = try Playlist.filter(Column("id") == playlistId).fetchOne(db),
               !playlist.isFolderSynced {
                try SyncChangeLogStore.record(
                    db,
                    entity: .playlist,
                    rowKey: playlist.slug,
                    op: .upsert,
                    payloadJSON: try SyncSnapshotCodec.encode(SyncPlaylistSnapshot(
                        slug: playlist.slug,
                        title: playlist.title,
                        createdAt: playlist.createdAt,
                        updatedAt: playlist.updatedAt,
                        lastPlayedAt: playlist.lastPlayedAt,
                        folderPath: playlist.folderPath,
                        isFolderSynced: playlist.isFolderSynced,
                        lastFolderSync: playlist.lastFolderSync,
                        customCoverImagePath: playlist.customCoverImagePath
                    ))
                )
            }
            return updated
        }
        print("✏️ Database: Updated \(updatedCount) playlist(s)")
    }

    func syncPlaylistWithFolder(playlistId: Int64, trackStableIds: [String]) throws {
        print("🔄 Syncing playlist \(playlistId) with folder tracks (additive-only sync)")

        try write { db in
            // Get current playlist items
            let currentItems = try PlaylistItem.filter(Column("playlist_id") == playlistId).fetchAll(db)
            let currentTrackIds = Set(currentItems.map { $0.trackStableId })
            let newTrackIds = Set(trackStableIds)

            // Only add tracks that are in the folder but not in the playlist
            // This preserves user additions and doesn't remove files (files deleted from
            // library will be cleaned up automatically by database constraints)
            let tracksToAdd = newTrackIds.subtracting(currentTrackIds)

            print("🔄 Folder sync: Adding \(tracksToAdd.count) new tracks from folder")

            // Add new tracks from folder
            let maxPositionQuery = try PlaylistItem
                .filter(Column("playlist_id") == playlistId)
                .select(max(Column("position")))
                .asRequest(of: Int?.self)
                .fetchOne(db)

            let maxPosition: Int
            if let position = maxPositionQuery, let unwrappedPosition = position {
                maxPosition = unwrappedPosition
            } else {
                maxPosition = -1
            }

            var position = maxPosition + 1
            for trackId in tracksToAdd {
                let item = PlaylistItem(playlistId: playlistId, position: position, trackStableId: trackId)
                try item.insert(db)
                position += 1
            }

            // Update last folder sync timestamp
            let now = Int64(Date().timeIntervalSince1970)
            _ = try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db, Column("last_folder_sync").set(to: now))
        }
    }

    func getFolderSyncedPlaylists() throws -> [Playlist] {
        return try read { db in
            return try Playlist.filter(Column("is_folder_synced") == true).fetchAll(db)
        }
    }

    func updatePlaylistAccessed(playlistId: Int64) throws {
        print("⏰ Database: Updating playlist \(playlistId) last accessed time")
        let now = Int64(Date().timeIntervalSince1970)
        let updatedCount = try write { db in
            return try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db, Column("updated_at").set(to: now))
        }
        print("⏰ Database: Updated \(updatedCount) playlist(s)")
    }

    func updatePlaylistLastPlayed(playlistId: Int64) throws {
        print("🎵 Database: Updating playlist \(playlistId) last played time")
        let now = Int64(Date().timeIntervalSince1970)
        let updatedCount = try write { db in
            return try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db, Column("last_played_at").set(to: now))
        }
        print("🎵 Database: Updated \(updatedCount) playlist(s) last played time")
    }

    func updatePlaylistCustomCover(playlistId: Int64, imagePath: String?) throws {
        print("🎨 Database: Updating playlist \(playlistId) custom cover to '\(imagePath ?? "nil")'")
        let now = Int64(Date().timeIntervalSince1970)
        let updatedCount = try write { db in
            let updated = try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db,
                           Column("custom_cover_image_path").set(to: imagePath),
                           Column("updated_at").set(to: now)
                )
            // S2 M4-1：手动歌单封面变更 → outbox upsert（歌单结构的一部分）。
            if updated > 0,
               let playlist = try Playlist.filter(Column("id") == playlistId).fetchOne(db),
               !playlist.isFolderSynced {
                try SyncChangeLogStore.record(
                    db,
                    entity: .playlist,
                    rowKey: playlist.slug,
                    op: .upsert,
                    payloadJSON: try SyncSnapshotCodec.encode(SyncPlaylistSnapshot(
                        slug: playlist.slug,
                        title: playlist.title,
                        createdAt: playlist.createdAt,
                        updatedAt: playlist.updatedAt,
                        lastPlayedAt: playlist.lastPlayedAt,
                        folderPath: playlist.folderPath,
                        isFolderSynced: playlist.isFolderSynced,
                        lastFolderSync: playlist.lastFolderSync,
                        customCoverImagePath: playlist.customCoverImagePath
                    ))
                )
            }
            return updated
        }
        print("🎨 Database: Updated \(updatedCount) playlist(s) custom cover")
    }
}
