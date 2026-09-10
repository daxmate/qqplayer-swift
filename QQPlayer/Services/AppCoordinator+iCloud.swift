//
//  AppCoordinator+iCloud.swift
//  QQPlayer
//
//  iCloud 同步/状态机/文件协调：容器状态检查、收藏同步、歌单云恢复/写回、
//  索引完成后的 iCloud 收尾、widget 歌单数据刷新。
//
import Foundation
#if os(iOS)
    import UIKit
    import WidgetKit
#endif

extension AppCoordinator {
    func onIndexingCompleted() async {
        // M3-2：退役 iCloud 收藏/歌单云同步——favorites 与 playlists 的单一
        // 事实源 = DB（App Group），StateManager JSON 镜像层已退役。索引完成
        // 后只做 DB 关系维护 + widget 数据刷新。

        // Deduplicate playlist items (fixes folder-synced playlists with duplicate entries)
        do {
            try databaseManager.deduplicatePlaylistItems()
        } catch {
            print("⚠️ Failed to deduplicate playlist items: \(error)")
        }

        // Clean up orphaned playlist items
        do {
            try databaseManager.cleanupOrphanedPlaylistItems()
        } catch {
            print("⚠️ Failed to cleanup orphaned playlist items: \(error)")
        }

        // Mark initial indexing as complete
        hasCompletedInitialIndexing = true
        print("✅ Initial indexing completed - playlist sync enabled")

        // Update widget with playlists
        syncPlaylistsToCloud()

        // Run heavier maintenance after UI-critical startup work finishes
        scheduleDeferredPostIndexMaintenance()
    }

    func syncPlaylistsToCloud() {
        Task { @MainActor in
            // Prevent concurrent sync operations
            guard !isSyncingPlaylists else {
                print("⏭️ Skipping playlist sync - already in progress")
                return
            }

            // Safety: Don't sync until initial indexing is complete
            // This prevents overwriting cloud data with incomplete local data
            guard hasCompletedInitialIndexing else {
                print("⏳ Skipping playlist sync - waiting for initial indexing to complete")
                return
            }

            isSyncingPlaylists = true
            defer { isSyncingPlaylists = false }

            do {
                let playlists = try databaseManager.getAllPlaylists()

                // A library with no tracks at all is the signature of a failed
                // scan or an unreadable database - never of the user having
                // curated their way down to zero. Only in that state do we
                // refuse to overwrite the cloud copies. Computed once here
                // rather than per playlist.
                let libraryLooksUnreadable = ((try? databaseManager.getTrackCount()) ?? 0) == 0

                // Sync to iCloud
                for playlist in playlists {
                    guard let playlistId = playlist.id else { continue }

                    // Get playlist items from database
                    let dbPlaylistItems = try databaseManager.getPlaylistItems(playlistId: playlistId)

                    // Validate that tracks still exist before syncing
                    let orderedTrackIds = dbPlaylistItems.map { $0.trackStableId }
                    let existingTrackIds = Set((try? databaseManager.getTracksByStableIds(orderedTrackIds).map { $0.stableId }) ?? [])
                    let validItems = orderedTrackIds
                        .filter { existingTrackIds.contains($0) }
                        .map { ($0, Date()) }
                    let stateItems = validItems

                    // SAFETY CHECK: don't overwrite cloud data when the library
                    // itself looks unreadable, which is the corruption case this
                    // guard exists for.
                    //
                    // It used to trigger for ANY playlist that ended up empty,
                    // which also covered the perfectly ordinary case of the user
                    // deleting every track in a playlist. The cloud copy was then
                    // pinned forever, still listing the deleted tracks, and was
                    // re-mirrored into Documents/qqplayer-playlists on each launch -
                    // so the entries appeared to come back from the dead.
                    // Scoping it to "the whole library is missing" keeps the
                    // corruption protection while letting a genuinely emptied
                    // playlist clear its cloud copy.
                    if !playlist.isFolderSynced && stateItems.isEmpty && libraryLooksUnreadable {
                        if let existingCloudPlaylist = try? stateManager.loadPlaylist(slug: playlist.slug),
                           !existingCloudPlaylist.items.isEmpty {
                            print("⚠️ Skipping sync for '\(playlist.title)' - library is empty but cloud has \(existingCloudPlaylist.items.count) tracks")
                            print("🛡️ This prevents accidental data loss. The cloud version is preserved.")
                            continue
                        }
                    }

                    let playlistState = PlaylistState(
                        slug: playlist.slug,
                        title: playlist.title,
                        createdAt: Date(timeIntervalSince1970: TimeInterval(playlist.createdAt)),
                        items: stateItems
                    )
                    try stateManager.savePlaylist(playlistState)
                }
                print("✅ Playlists synced to iCloud with \(playlists.count) playlists")

                // Update widget playlist data with artwork
                await updateWidgetPlaylists(playlists: playlists)

            } catch {
                print("❌ Failed to sync playlists to iCloud: \(error)")
            }
        }
    }

    private func updateWidgetPlaylists(playlists: [Playlist]) async {
        // Widget playlist data is iOS WidgetKit-only; on macOS this is a no-op.
        #if os(iOS)
            guard let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.com.daxmate.qqplayer.ios"
            ) else {
                print("⚠️ Widget: Failed to get shared container URL")
                return
            }

            // Sort playlists by most recently played (lastPlayedAt descending)
            let sortedPlaylists = playlists.sorted { playlist1, playlist2 in
                return playlist1.lastPlayedAt > playlist2.lastPlayedAt
            }

            // Show only the top 3 most recently played playlists
            let playlistsToShow = Array(sortedPlaylists.prefix(3))
            print("📊 Widget: Showing top 3 most recently played playlists out of \(playlists.count) total")

            var widgetPlaylists: [WidgetPlaylistData] = []

            for playlist in playlistsToShow {
                guard let playlistId = playlist.id else { continue }

                do {
                    // Get playlist items IN ORDER (same as app displays)
                    let playlistItems = try databaseManager.getPlaylistItems(playlistId: playlistId)

                    let orderedTrackIds = playlistItems.map { $0.trackStableId }
                    let orderedTracks = try databaseManager.getTracksByStableIdsPreservingOrder(orderedTrackIds)

                    // Get first 4 tracks for artwork mashup (in correct playlist order)
                    let artworkTracks = Array(orderedTracks.prefix(4))
                    var artworkPaths: [String] = []

                    // Save artwork for each track
                    for (index, track) in artworkTracks.enumerated() {
                        if let artwork = await ArtworkManager.shared.getArtwork(for: track) {
                            let filename = "playlist_\(playlistId)_\(index).jpg"
                            let fileURL = containerURL.appendingPathComponent(filename)

                            // 编码 + 写盘下沉后台线程（主 actor 串行 3 歌单 × 4 曲目
                            // jpegData + write 会阻塞 UI，2026-08-29 审计 #9）
                            let hasData = await withCheckedContinuation { continuation in
                                DispatchQueue.global(qos: .utility).async {
                                    if let artworkData = artwork.jpegData(compressionQuality: 0.8) {
                                        try? artworkData.write(to: fileURL, options: .atomic)
                                        continuation.resume(returning: true)
                                    } else {
                                        continuation.resume(returning: false)
                                    }
                                }
                            }
                            if hasData {
                                artworkPaths.append(filename)
                                print("✅ Widget: Saved artwork '\(track.title)' for playlist '\(playlist.title)' tile \(index)")
                            }
                        }
                    }

                    // Get theme color from settings
                    let settings = DeleteSettings.load()
                    let colorHex = settings.backgroundColorChoice.rawValue

                    let widgetPlaylist = WidgetPlaylistData(
                        id: String(playlistId),
                        name: playlist.title,
                        trackCount: orderedTracks.count,
                        colorHex: colorHex,
                        artworkPaths: artworkPaths,
                        customCoverImagePath: playlist.customCoverImagePath
                    )
                    widgetPlaylists.append(widgetPlaylist)

                } catch {
                    print("❌ Failed to process playlist \(playlist.title): \(error)")
                }
            }

            PlaylistDataManager.shared.savePlaylists(widgetPlaylists)
            print("✅ Widget playlist data updated with \(widgetPlaylists.count) playlists")

            // Force widget to reload immediately
            WidgetCenter.shared.reloadAllTimelines()
            print("🔄 Widget timeline reload triggered")
        #endif
    }
}
