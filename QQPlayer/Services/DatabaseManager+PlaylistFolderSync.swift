//
//  DatabaseManager+PlaylistFolderSync.swift
//  QQPlayer
//
//  文件夹歌单（folder-synced playlist）查询 / 墓碑清理 / 与磁盘文件夹增量同步，
//  以及歌单访问·播放时间戳与自定义封面更新（自 DatabaseManager+Playlists.swift 拆出）。
//  同族：DatabaseManager+Playlists.swift（歌单 CRUD）、
//        DatabaseManager+PlaylistMaintenance.swift（手动歌单去重 / 孤儿清理）。
//
import Foundation
@preconcurrency import GRDB

extension DatabaseManager {
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

    func syncPlaylistWithFolder(playlistId: Int64, trackStableIds: [String]) throws {
        AppLog.info(.db, "🔄 Syncing playlist \(playlistId) with folder tracks (additive-only sync)")

        try write { db in
            // Get current playlist items
            let currentItems = try PlaylistItem.filter(Column("playlist_id") == playlistId).fetchAll(db)
            let currentTrackIds = Set(currentItems.map { $0.trackStableId })
            let newTrackIds = Set(trackStableIds)

            // Only add tracks that are in the folder but not in the playlist
            // This preserves user additions and doesn't remove files (files deleted from
            // library will be cleaned up automatically by database constraints)
            let tracksToAdd = newTrackIds.subtracting(currentTrackIds)

            AppLog.info(.db, "🔄 Folder sync: Adding \(tracksToAdd.count) new tracks from folder")

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
        AppLog.info(.db, "⏰ Database: Updating playlist \(playlistId) last accessed time")
        let now = Int64(Date().timeIntervalSince1970)
        let updatedCount = try write { db in
            return try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db, Column("updated_at").set(to: now))
        }
        AppLog.info(.db, "⏰ Database: Updated \(updatedCount) playlist(s)")
    }

    func updatePlaylistLastPlayed(playlistId: Int64) throws {
        AppLog.info(.db, "🎵 Database: Updating playlist \(playlistId) last played time")
        let now = Int64(Date().timeIntervalSince1970)
        let updatedCount = try write { db in
            return try Playlist
                .filter(Column("id") == playlistId)
                .updateAll(db, Column("last_played_at").set(to: now))
        }
        AppLog.info(.db, "🎵 Database: Updated \(updatedCount) playlist(s) last played time")
    }

    func updatePlaylistCustomCover(playlistId: Int64, imagePath: String?) throws {
        AppLog.info(.db, "🎨 Database: Updating playlist \(playlistId) custom cover to '\(imagePath ?? "nil")'")
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
        AppLog.info(.db, "🎨 Database: Updated \(updatedCount) playlist(s) custom cover")
    }
}
