//
//  DatabaseManager+Playlists.swift
//  QQPlayer
//
//  歌单 CRUD（N+1 LEFT JOIN 修复查询）：创建 / 查询 / 条目增删重排 / 重命名 / 删除。
//  同族：DatabaseManager+PlaylistMaintenance.swift（去重 / 孤儿清理）、
//        DatabaseManager+PlaylistFolderSync.swift（文件夹同步 / 时间戳 / 自定义封面）。
//
import Foundation
@preconcurrency import GRDB

extension DatabaseManager {
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
                AppLog.warn(.db, "⛔ Folder playlist '\(folderName)' was previously deleted by user, skipping recreation")
                throw DatabaseError.folderPlaylistDeleted
            }

            let slug = title.lowercased().replacingOccurrences(of: " ", with: "-")
            let now = Int64(Date().timeIntervalSince1970)

            // Check if a folder-synced playlist already exists for this path
            if let existingPlaylist = try Playlist.filter(Column("folder_path") == folderPath).fetchOne(db) {
                AppLog.info(.db, "📁 Folder playlist already exists: \(existingPlaylist.title)")
                return existingPlaylist
            }

            // CRITICAL: Check if a manual playlist with the same title/slug already exists
            // This prevents data loss by not overwriting user-created playlists
            if let existingManualPlaylist = try Playlist.filter(Column("slug") == slug).fetchOne(db) {
                if !existingManualPlaylist.isFolderSynced {
                    AppLog.warn(.db, "⚠️ Manual playlist '\(title)' already exists - converting to folder-synced playlist")
                    // Update the existing playlist to be folder-synced
                    var updatedPlaylist = existingManualPlaylist
                    updatedPlaylist.folderPath = folderPath
                    updatedPlaylist.isFolderSynced = true
                    updatedPlaylist.lastFolderSync = now
                    updatedPlaylist.updatedAt = now
                    try updatedPlaylist.update(db)
                    AppLog.info(.db, "✅ Converted manual playlist '\(title)' to folder-synced")
                    return updatedPlaylist
                } else {
                    // Another folder playlist with same name but different path
                    AppLog.warn(.db, "⚠️ Folder playlist '\(title)' already exists with different path")
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
            AppLog.info(.db, "📁 Creating folder-synced playlist: \(title) -> \(folderPath)")
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
            // D8：与其他搜索共用同一转义入口
            let pattern = self.likePattern(for: query)
            return try Playlist
                .filter(Column("title").like(pattern, escape: "\\"))
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
        AppLog.info(.db, "🎵 Adding track \(trackStableId) to playlist \(playlistId)")
        try write { db in
            // Check if track is already in playlist
            let existingItem = try PlaylistItem
                .filter(Column("playlist_id") == playlistId && Column("track_stable_id") == trackStableId)
                .fetchOne(db)

            if existingItem != nil {
                AppLog.warn(.db, "⚠️ Track already in playlist")
                return
            }

            // Get the next position in the playlist
            let maxPosition = try PlaylistItem
                .filter(Column("playlist_id") == playlistId)
                .select(max(Column("position")))
                .asRequest(of: Int.self)
                .fetchOne(db) ?? 0

            let playlistItem = PlaylistItem(playlistId: playlistId, position: maxPosition + 1, trackStableId: trackStableId)
            AppLog.info(.db, "🎵 Creating playlist item with position \(maxPosition + 1)")
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
            AppLog.info(.db, "✅ Successfully added track to playlist")
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
        AppLog.info(.db, "🔄 Database: Reordering playlist items from \(sourceIndex) to \(destinationIndex)")
        try write { db in
            // Get all playlist items ordered by position
            let items = try PlaylistItem
                .filter(Column("playlist_id") == playlistId)
                .order(Column("position"))
                .fetchAll(db)

            guard sourceIndex >= 0 && sourceIndex < items.count &&
                destinationIndex >= 0 && destinationIndex < items.count else {
                AppLog.error(.db, "❌ Invalid indices for reordering")
                return
            }

            // Remove the item from the source position
            var mutableItems = items
            let movedItem = mutableItems.remove(at: sourceIndex)

            // Insert at the destination position
            mutableItems.insert(movedItem, at: destinationIndex)

            // Two-phase update to avoid UNIQUE constraint violations.
            // 按**旧 position** 定位行（playlist_item 主键 = (playlist_id, position)）；
            // 此前按 track_stable_id 匹配：同一曲目在歌单里出现两次时两行会被写成
            // 同一 position → 撞主键 → 整个重排事务回滚（审计 🔵-7）。
            // 阶段 1 的目标位置带 +10000 偏移，与阶段 2 的目标集不相交，两阶段
            // 内部目标位置各自唯一 ⇒ 不会互相撞键。
            AppLog.info(.db, "🔄 Phase 1: Shifting positions to avoid conflicts")
            for (index, item) in mutableItems.enumerated() {
                _ = try PlaylistItem
                    .filter(Column("playlist_id") == playlistId &&
                        Column("position") == item.position)
                    .updateAll(db, Column("position").set(to: index + 10000))
            }

            // Phase 2: Set final positions
            AppLog.info(.db, "🔄 Phase 2: Setting final positions")
            // 阶段 2 只按「阶段 1 写入的临时 position」定位行，不读 item → 用 indices
            for index in mutableItems.indices {
                _ = try PlaylistItem
                    .filter(Column("playlist_id") == playlistId &&
                        Column("position") == index + 10000)
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

            AppLog.info(.db, "✅ Successfully reordered playlist items")
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
        AppLog.info(.db, "🗑️ Database: Deleting playlist with ID - \(playlistId)")
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
                AppLog.info(.db, "📝 Marked folder playlist '\(folderName)' as deleted to prevent recreation")
            }

            return try Playlist.filter(Column("id") == playlistId).deleteAll(db)
        }
        AppLog.info(.db, "🗑️ Database: Deleted \(deletedCount) playlist(s)")
    }

    func renamePlaylist(playlistId: Int64, newTitle: String) throws {
        AppLog.info(.db, "✏️ Database: Renaming playlist \(playlistId) to '\(newTitle)'")
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
        AppLog.info(.db, "✏️ Database: Updated \(updatedCount) playlist(s)")
    }
}
