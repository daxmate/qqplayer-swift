//
//  DatabaseManager+PlaylistMaintenance.swift
//  QQPlayer
//
//  歌单维护：手动歌单去重 / 孤儿条目清理（自 DatabaseManager+Playlists.swift 拆出）。
//  同族：DatabaseManager+Playlists.swift（歌单 CRUD）、
//        DatabaseManager+PlaylistFolderSync.swift（文件夹歌单同步 / 时间戳 / 自定义封面）。
//
import Foundation
@preconcurrency import GRDB

extension DatabaseManager {
    func deduplicatePlaylistItems() throws {
        AppLog.info(.db, "🔍 Checking for duplicate playlist items...")

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
                        AppLog.warn(.db, "⚠️ Playlist '\(playlist.title)': Found duplicate for path '\(path)' at position \(position)")
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
                    AppLog.info(.db, "✅ Removed \(itemsToRemove.count) duplicate items from playlist '\(playlist.title)'")

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
            AppLog.info(.db, "✅ Removed \(removedCount) duplicate playlist items across all playlists")
        } else {
            AppLog.info(.db, "✅ No duplicate playlist items found")
        }
    }

    func cleanupOrphanedPlaylistItems() throws {
        AppLog.info(.db, "🧹 Cleaning up orphaned playlist items...")

        // SAFETY CHECK: Verify database is healthy before cleanup
        let trackCount = try read { db in
            try Track.fetchCount(db)
        }

        if trackCount == 0 {
            AppLog.warn(.db, "⚠️ SAFETY: Skipping playlist cleanup - no tracks in database (possible database error)")
            AppLog.warn(.db, "⚠️ This prevents accidental deletion of all playlist items")
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
            AppLog.info(.db, "✅ Cleaned up \(deletedCount) orphaned playlist items")
        } else {
            AppLog.info(.db, "✅ No orphaned playlist items found")
        }
    }
}
