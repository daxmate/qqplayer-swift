//
//  DatabaseManager+PlaylistMetadata.swift
//  QQPlayer
//
//  歌单访问·播放时间戳与自定义封面更新（自 DatabaseManager+Playlists.swift 拆出）。
//  同族：DatabaseManager+Playlists.swift（歌单 CRUD）、
//        DatabaseManager+PlaylistMaintenance.swift（去重 / 孤儿清理）。
//
import Foundation
@preconcurrency import GRDB

extension DatabaseManager {
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
            // S2 M4-1：歌单封面变更 → outbox upsert（歌单结构的一部分）。
            if updated > 0,
               let playlist = try Playlist.filter(Column("id") == playlistId).fetchOne(db) {
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
                        customCoverImagePath: playlist.customCoverImagePath
                    ))
                )
            }
            return updated
        }
        AppLog.info(.db, "🎨 Database: Updated \(updatedCount) playlist(s) custom cover")
    }
}
