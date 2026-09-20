//
//  AppCoordinator+ImportExport.swift
//  QQPlayer
//
//  歌单数据层（增删改查/文件夹同步）+ 索引后置维护（数据库关系校验、
//  孤儿文件清理、缓存修剪）。
//
import Foundation

extension AppCoordinator {
    func scheduleDeferredPostIndexMaintenance() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            await self?.runPostIndexMaintenance()
        }
    }

    private func runPostIndexMaintenance() async {
        AppLog.info(.general, "🔄 AppCoordinator: Starting deferred post-index maintenance...")
        await verifyDatabaseRelationships()
        await fileCleanupManager.checkForOrphanedFiles()
        await pruneCachesForDeletedContent()
        AppLog.info(.general, "✅ AppCoordinator: Deferred post-index maintenance completed")
    }

    /// Drops cached data belonging to content that no longer exists. Deleting a
    /// track removes its database rows, but the artwork it pulled in and the
    /// artist metadata fetched for it used to live on disk forever.
    private func pruneCachesForDeletedContent() async {
        do {
            // Fetching every track is a full table read; keep it off the main
            // actor so maintenance never stutters the UI on a large library.
            let validStableIds = try await Task.detached(priority: .utility) {
                Set(try DatabaseManager.shared.getAllTracks().map(\.stableId))
            }.value

            // An empty library here almost always means the scan failed or the
            // database is unreadable, not that the user deleted everything.
            // Passing an empty set through would erase the entire artwork
            // cache, so treat it the same way the playlist cleanup does.
            guard !validStableIds.isEmpty else {
                AppLog.warn(.general, "⚠️ SAFETY: Skipping cache pruning - no tracks in database")
                return
            }

            await ArtworkManager.shared.cleanupOrphanedArtwork(validStableIds: validStableIds)
        } catch {
            AppLog.warn(.general, "⚠️ Failed to prune artwork cache: \(error)")
        }

        // Artist metadata is keyed by artist name rather than track id, so it
        // is pruned by age rather than by liveness.
        await DiscogsAPIService.shared.purgeExpiredDiskCache()
        await HybridMusicAPIService.shared.purgeExpiredDiskCache()
    }

    private func verifyDatabaseRelationships() async {
        do {
            AppLog.info(.general, "🔍 Verifying database relationships...")
            let tracks = try databaseManager.getAllTracks()
            let albums = try databaseManager.getAllAlbums()
            let artists = try databaseManager.getAllArtists()

            AppLog.info(.general, "📊 Database stats - Tracks: \(tracks.count), Albums: \(albums.count), Artists: \(artists.count)")

            let validArtistIds = Set(artists.compactMap(\.id))
            let validAlbumIds = Set(albums.compactMap(\.id))

            var tracksWithoutArtist = 0
            var tracksWithoutAlbum = 0
            var invalidArtistRefs = 0
            var invalidAlbumRefs = 0

            for track in tracks {
                // Check artist relationship
                if let artistId = track.artistId {
                    if !validArtistIds.contains(artistId) {
                        invalidArtistRefs += 1
                    }
                } else {
                    tracksWithoutArtist += 1
                }

                // Check album relationship
                if let albumId = track.albumId {
                    if !validAlbumIds.contains(albumId) {
                        invalidAlbumRefs += 1
                    }
                } else {
                    tracksWithoutAlbum += 1
                }
            }

            AppLog.info(.general, "🔍 Verification complete:"
                + "\n   - Tracks without artist: \(tracksWithoutArtist)"
                + "\n   - Tracks without album: \(tracksWithoutAlbum)"
                + "\n   - Invalid artist refs: \(invalidArtistRefs)"
                + "\n   - Invalid album refs: \(invalidAlbumRefs)")

        } catch {
            AppLog.error(.general, "❌ Failed to verify database relationships: \(error)")
        }
    }

    // MARK: - Playlist operations

    func addToPlaylist(playlistId: Int64, trackStableId: String) throws {
        try databaseManager.addToPlaylist(playlistId: playlistId, trackStableId: trackStableId)
        syncPlaylistsToCloud()
    }

    func removeFromPlaylist(playlistId: Int64, trackStableId: String) throws {
        try databaseManager.removeFromPlaylist(playlistId: playlistId, trackStableId: trackStableId)
        syncPlaylistsToCloud()
    }

    func reorderPlaylistItems(playlistId: Int64, from sourceIndex: Int, to destinationIndex: Int) throws {
        try databaseManager.reorderPlaylistItems(playlistId: playlistId, from: sourceIndex, to: destinationIndex)
        syncPlaylistsToCloud()
    }

    func createPlaylist(title: String) throws -> Playlist {
        let playlist = try databaseManager.createPlaylist(title: title)
        syncPlaylistsToCloud()
        return playlist
    }

    func createFolderPlaylist(title: String, folderPath: String) throws -> Playlist {
        let playlist = try databaseManager.createFolderPlaylist(title: title, folderPath: folderPath)
        syncPlaylistsToCloud()
        return playlist
    }

    func syncPlaylistWithFolder(playlistId: Int64, trackStableIds: [String]) throws {
        try databaseManager.syncPlaylistWithFolder(playlistId: playlistId, trackStableIds: trackStableIds)
        syncPlaylistsToCloud()
    }

    func getFolderSyncedPlaylists() throws -> [Playlist] {
        return try databaseManager.getFolderSyncedPlaylists()
    }

    func isTrackInPlaylist(playlistId: Int64, trackStableId: String) throws -> Bool {
        return try databaseManager.isTrackInPlaylist(playlistId: playlistId, trackStableId: trackStableId)
    }

    /// 删歌单：唯一入口（2026-09-17 用户拍板 A）。
    ///
    /// 与视图里原先裸调 `DatabaseManager.deletePlaylist` 的差别就一条：本入口**顺手清掉
    /// 本地镜像 JSON**（`Documents/qqplayer-playlists/playlist-<slug>.json`）——否则镜像里
    /// 留着已删歌单（幽灵文件），下次启动又被写回。
    ///
    /// **不涉及跨端删除**：删除能不能过端由 INV-13 / `SyncChangeLogDeletionPolicy`
    /// 在 changelog 层决定（delete 一律不上线、收到一律忽略），与调哪个入口无关。
    ///
    /// 幂等（同拍板）：歌单已不存在时不再抛 `playlistNotFound`，直接返回——
    /// 「已经没了」与「刚删掉」对调用方是同一种结果。
    func deletePlaylist(playlistId: Int64) throws {
        // Get playlist info before deleting from database
        let playlists = try databaseManager.getAllPlaylists()
        guard let playlist = playlists.first(where: { $0.id == playlistId }) else {
            AppLog.warn(.general, "⏭️ deletePlaylist: playlist \(playlistId) 已不存在，幂等跳过")
            return
        }

        let playlistSlug = playlist.slug

        // Delete from database
        try databaseManager.deletePlaylist(playlistId: playlistId)

        // Delete from iCloud and local storage
        try stateManager.deletePlaylist(slug: playlistSlug)

        AppLog.info(.general, "✅ Playlist '\(playlist.title)' deleted from database and cloud storage")
    }

    func renamePlaylist(playlistId: Int64, newTitle: String) throws {
        try databaseManager.renamePlaylist(playlistId: playlistId, newTitle: newTitle)
        // 镜像一致性（2026-09-17 用户拍板）：镜像 `PlaylistState` 带 `title`，
        // 改名后不同步 → 下次读镜像（小组件歌单列表 / 状态恢复）拿到的还是旧标题。
        // 与 deletePlaylist 清镜像同一族：入口负责把本地镜像跟 DB 对齐。
        syncPlaylistsToCloud()
        AppLog.info(.general, "✅ Playlist renamed to '\(newTitle)'")
    }

    /// 自定义封面：唯一入口。
    /// 刻意**不** `syncPlaylistsToCloud()`：本地镜像 `PlaylistState` 不含封面字段，
    /// 同步只会重写同一份 JSON（白写 IO）。
    func updatePlaylistCustomCover(playlistId: Int64, imagePath: String?) throws {
        try databaseManager.updatePlaylistCustomCover(playlistId: playlistId, imagePath: imagePath)
    }

    /// 清空「文件夹歌单不再重建」墓碑（重新打开自动创建时用）。纯本地表，无镜像/无同步。
    func clearDeletedFolderPlaylistTombstones() throws {
        try databaseManager.clearDeletedFolderPlaylistTombstones()
    }

    /// 曲目换路径后迁移库内引用（改名场景）。纯 DB 动作：
    /// 刷新通知由调用方按自己已有的节奏发（不在此处额外发，避免改动既有刷新时序）。
    func moveTrack(from oldPath: String, to newPath: String) throws {
        try databaseManager.moveTrack(from: oldPath, to: newPath)
    }

    func updatePlaylistAccessed(playlistId: Int64) throws {
        try databaseManager.updatePlaylistAccessed(playlistId: playlistId)
    }

    func updatePlaylistLastPlayed(playlistId: Int64) throws {
        try databaseManager.updatePlaylistLastPlayed(playlistId: playlistId)
        // Update widget to show most recently played playlists
        syncPlaylistsToCloud()
    }
}
