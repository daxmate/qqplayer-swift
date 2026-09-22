//
//  DatabaseManager+TracksMaintenance.swift
//  QQPlayer
//
//  收藏增删、曲目删除（deleteTrack）/ 仅从曲库移除（removeTrackFromLibrary）/ 文件移动后的
//  路径变更迁移（moveTrack）与外部书签清理。
//
//  2026-09-21 从 DatabaseManager+Tracks.swift 原样搬出（纯搬家，无逻辑变更）。
//
import Foundation
@preconcurrency import GRDB

extension DatabaseManager {
    // MARK: - Favorites operations

    func addToFavorites(trackStableId: String) throws {
        AppLog.info(.db, "🗃️ Database: Adding to favorites - \(trackStableId)")
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
            AppLog.info(.db, "🗃️ Database: Successfully inserted favorite")
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
        AppLog.info(.db, "🗃️ Database: Inserted \(trackStableIds.count) favorite(s) in one transaction")
    }

    func removeFromFavorites(trackStableId: String) throws {
        AppLog.info(.db, "🗃️ Database: Removing from favorites - \(trackStableId)")
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
        AppLog.info(.db, "🗃️ Database: Deleted \(deletedCount) favorite(s)")
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
        AppLog.info(.db, "🗃️ Database: Retrieved \(favorites.count) favorites")
        return favorites
    }

    func deleteTrack(byStableId stableId: String) throws {
        AppLog.info(.db, "🗃️ Database: Deleting track with stable ID - \(stableId)")
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
                AppLog.info(.db, "🗑️ Removed track from \(playlistItemsDeleted) playlist position(s)")
            }

            // Remove from favorites if it exists
            let favoritesDeleted = try Favorite.filter(Column("track_stable_id") == stableId).deleteAll(db)
            if favoritesDeleted > 0 {
                AppLog.info(.db, "🗃️ Database: Removed \(favoritesDeleted) favorite entries for track")
            }

            if playlistItemsDeleted > 0 {
                AppLog.info(.db, "🗃️ Database: Removed \(playlistItemsDeleted) playlist entries for track")
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
        AppLog.info(.db, "🗃️ Database: Deleted \(deletedCount) track(s)")

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
        AppLog.info(.db, "🗃️ Database: Removing track from library only - \(stableId)")
        defer { invalidateArtistDisplayNameCache() }
        let removedCount = try write { db in
            // 派生行（artist 关联）随行消失；重扫入库时由 setTrackArtists 重建
            try db.execute(sql: "DELETE FROM track_artist WHERE track_stable_id = ?", arguments: [stableId])
            return try Track.filter(Column("stable_id") == stableId).deleteAll(db)
        }
        AppLog.info(.db, "🗃️ Database: Removed \(removedCount) track row(s) (favorites/playlists/history kept)")

        // 清理失去曲目的专辑/歌手（不动 favorite / playlist_item / play_history）
        try cleanupOrphanedLibraryEntries()
    }

    private func removeExternalFileBookmark(for stableId: String) {
        guard let store = ExternalFileBookmarkStore.default else { return }
        do {
            if try store.remove(forStableId: stableId) {
                AppLog.info(.db, "🔖 Removed external file bookmark for stableId: \(stableId)")
            }
        } catch {
            AppLog.warn(.db, "⚠️ Failed to remove external file bookmark: \(error.localizedDescription)")
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
        // 入参可能是绝对路径（改名/搚削调用点）或存储形态；一律先归一化到存储形态。
        let normalizedOld = Self.standardizedStoredPath(LibraryRoot.storedPath(forAbsolutePath: oldPath))
        let normalizedNew = Self.standardizedStoredPath(LibraryRoot.storedPath(forAbsolutePath: newPath))
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
                AppLog.info(.db, "🗂️ moveTrack: merged \(track.stableId) into existing \(newStableId)")
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
                AppLog.info(.db, "🗂️ moveTrack: \(normalizedOld) → \(normalizedNew) (stableId \(track.stableId) → \(newStableId))")
            }
        }
        // D3：改名后文件侧引用（书签键 / 三个歌词目录 / 封面映射）一起跟随新 stableId，
        // 否则手动与被对齐的歌词在改名后静默失联（审计 🟡-1）。事务外、幂等。
        if didMigrate {
            TrackIdentityMigration.migrateFileReferences(from: track.stableId, to: newStableId)
        }
    }
}
