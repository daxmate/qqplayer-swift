//
//  AppCoordinator+Siri.swift
//  QQPlayer
//
//  Siri 意图处理（iOS 专用代码路径）：播放意图 / 加入收藏·歌单意图。
//  E3（2026-09-21）自 AppCoordinator.swift 拆出——纯搬家，平台分支（#if os(iOS)）原样随搬。
//
import Foundation

#if os(iOS)
    import Intents
#endif

extension AppCoordinator {
    // MARK: - Siri Intent Handling

    #if os(iOS)
        func handleSiriPlayIntent(userActivity: NSUserActivity) async {
            guard let rawUserInfo = userActivity.userInfo else { return }

            // Convert [AnyHashable: Any] to [String: Any]
            let userInfo = rawUserInfo.compactMapKeys { $0 as? String }

            if let mediaTypeRaw = userInfo["mediaType"] as? Int,
               let mediaType = INMediaItemType(rawValue: mediaTypeRaw) {
                switch mediaType {
                case .song:
                    await handleSongPlayback(userInfo: userInfo)
                case .album, .artist:
                    // Albums and artists are no longer supported - play all music instead
                    await handleGeneralMusicPlayback(userInfo: userInfo)
                case .playlist:
                    await handlePlaylistPlayback(userInfo: userInfo)
                case .music:
                    await handleGeneralMusicPlayback(userInfo: userInfo)
                default:
                    AppLog.error(.general, "❌ Unsupported media type from Siri")
                }
            } else if let mediaIdentifiers = userInfo["mediaIdentifiers"] as? [String] {
                // Direct media identifiers provided
                await handleDirectPlayback(identifiers: mediaIdentifiers)
            }
        }

        private func handleSongPlayback(userInfo: [String: Any]) async {
            do {
                if let mediaName = userInfo["mediaName"] as? String {
                    let tracks = try databaseManager.searchTracks(query: mediaName)
                    if let firstTrack = tracks.first {
                        await playerEngine.playTrack(firstTrack, queue: tracks)
                    }
                } else {
                    // Play all songs or favorites
                    let tracks = try databaseManager.getAllTracks()
                    if let firstTrack = tracks.first {
                        await playerEngine.playTrack(firstTrack, queue: tracks)
                    }
                }
            } catch {
                AppLog.error(.general, "❌ Error playing song: \(error)")
            }
        }

        private func handlePlaylistPlayback(userInfo: [String: Any]) async {
            do {
                if let playlistName = userInfo["mediaName"] as? String {
                    let playlists = try databaseManager.searchPlaylists(query: playlistName)
                    if let firstPlaylist = playlists.first {
                        let playlistItems = try databaseManager.getPlaylistItems(playlistId: firstPlaylist.id!)
                        let trackStableIds = playlistItems.map { $0.trackStableId }
                        let tracks = try databaseManager.getTracksByStableIds(trackStableIds)
                        if let firstTrack = tracks.first {
                            await playerEngine.playTrack(firstTrack, queue: tracks)
                        }
                    }
                }
            } catch {
                AppLog.error(.general, "❌ Error playing playlist: \(error)")
            }
        }

        private func handleGeneralMusicPlayback(userInfo: [String: Any]) async {
            do {
                // Play all music - should always play all tracks, not favorites
                let tracks = try databaseManager.getAllTracks()
                AppLog.info(.general, "🎵 Playing all music: \(tracks.count) tracks, starting with most recent")

                if let firstTrack = tracks.first {
                    // Set up background session BEFORE starting playback for Siri
                    await prepareSiriAudioSession()
                    await playerEngine.playTrack(firstTrack, queue: tracks)
                }
            } catch {
                AppLog.error(.general, "❌ Error playing general music: \(error)")
            }
        }

        func prepareSiriAudioSession() async {
            // Delegate to PlayerEngine to handle background session setup for Siri
            await MainActor.run {
                PlayerEngine.shared.setupBackgroundSessionForSiri()
            }
        }

        private func handleDirectPlayback(identifiers: [String]) async {
            do {
                let tracks = try databaseManager.getTracksByStableIds(identifiers)
                if let firstTrack = tracks.first {
                    // Set up background session BEFORE starting playback for Siri
                    await prepareSiriAudioSession()
                    await playerEngine.playTrack(firstTrack, queue: tracks)
                }
            } catch {
                AppLog.error(.general, "❌ Error with direct playback: \(error)")
            }
        }

        func handleSiriPlaybackIntent(_ intent: INPlayMediaIntent, completion: @escaping (INIntentResponse) -> Void) async {
            // Extract media items from the intent
            guard let mediaItem = intent.mediaItems?.first, let identifier = mediaItem.identifier else {
                completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                return
            }

            AppLog.info(.general, "🎤 Handling Siri playback intent for: \(identifier)")

            guard identifier != "qqplayer_not_found" else {
                completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                return
            }

            do {
                if identifier.hasPrefix("search_song_") {
                    let songName = String(identifier.dropFirst(12)) // Remove "search_song_" prefix
                    AppLog.info(.general, "🎤 Searching for song: '\(songName)'")
                    let tracks = try databaseManager.searchTracks(query: songName)
                    if let firstTrack = tracks.first {
                        // Set up background session BEFORE starting playback for Siri
                        await prepareSiriAudioSession()
                        await playerEngine.playTrack(firstTrack, queue: tracks)
                        completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                    } else {
                        completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                    }
                } else if identifier.hasPrefix("search_playlist_") {
                    let playlistName = String(identifier.dropFirst(16)) // Remove "search_playlist_" prefix
                    AppLog.info(.general, "🎤 Searching for playlist: '\(playlistName)'")
                    let playlists = try databaseManager.searchPlaylists(query: playlistName)
                    if let firstPlaylist = playlists.first, let playlistId = firstPlaylist.id {
                        let playlistItems = try databaseManager.getPlaylistItems(playlistId: playlistId)
                        let trackStableIds = playlistItems.map { $0.trackStableId }
                        let tracks = try databaseManager.getTracksByStableIds(trackStableIds)
                        if let firstTrack = tracks.first {
                            // Update playlist last played time
                            try databaseManager.updatePlaylistLastPlayed(playlistId: playlistId)
                            await playerEngine.playTrack(firstTrack, queue: tracks)
                            completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                        } else {
                            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                        }
                    } else {
                        completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                    }
                } else if identifier == "my_playlist" {
                    // Play the most recently played playlist
                    let playlists = try databaseManager.getAllPlaylists()
                    if let firstPlaylist = playlists.first, let playlistId = firstPlaylist.id {
                        let playlistItems = try databaseManager.getPlaylistItems(playlistId: playlistId)
                        let trackStableIds = playlistItems.map { $0.trackStableId }
                        let tracks = try databaseManager.getTracksByStableIds(trackStableIds)
                        if let firstTrack = tracks.first {
                            await playerEngine.playTrack(firstTrack, queue: tracks)
                            completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                        } else {
                            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                        }
                    } else {
                        completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                    }
                } else if identifier.hasPrefix("playlist_") {
                    let playlistIdString = String(identifier.dropFirst(9)) // Remove "playlist_" prefix
                    AppLog.info(.general, "🎤 Playing playlist with ID: '\(playlistIdString)'")
                    if let playlistId = Int64(playlistIdString) {
                        let playlistItems = try databaseManager.getPlaylistItems(playlistId: playlistId)
                        let trackStableIds = playlistItems.map { $0.trackStableId }
                        let tracks = try databaseManager.getTracksByStableIds(trackStableIds)
                        AppLog.info(.general, "🎤 Found \(tracks.count) tracks in playlist \(playlistId)")
                        if let firstTrack = tracks.first {
                            // Update playlist last played time
                            try databaseManager.updatePlaylistLastPlayed(playlistId: playlistId)
                            await playerEngine.playTrack(firstTrack, queue: tracks)
                            completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                        } else {
                            AppLog.error(.general, "❌ No tracks found in playlist \(playlistId)")
                            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                        }
                    } else {
                        AppLog.error(.general, "❌ Invalid playlist ID: '\(playlistIdString)'")
                        completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                    }
                } else if identifier == "search_playlist_unknown" {
                    // Generic playlist request - play first playlist
                    let playlists = try databaseManager.getAllPlaylists()
                    if let firstPlaylist = playlists.first, let playlistId = firstPlaylist.id {
                        let playlistItems = try databaseManager.getPlaylistItems(playlistId: playlistId)
                        let trackStableIds = playlistItems.map { $0.trackStableId }
                        let tracks = try databaseManager.getTracksByStableIds(trackStableIds)
                        if let firstTrack = tracks.first {
                            // Update playlist last played time
                            try databaseManager.updatePlaylistLastPlayed(playlistId: playlistId)
                            await playerEngine.playTrack(firstTrack, queue: tracks)
                            completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                        } else {
                            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                        }
                    } else {
                        completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                    }
                } else if identifier.hasPrefix("search_album_") {
                    let albumName = String(identifier.dropFirst(13))
                    AppLog.info(.general, "🎤 Searching for album: '\(albumName)'")
                    let albums = try databaseManager.searchAlbums(query: albumName)
                    if let album = albums.first, let albumId = album.id {
                        let tracks = try databaseManager.getTracksByAlbumId(albumId)
                        if let firstTrack = tracks.first {
                            await prepareSiriAudioSession()
                            await playerEngine.playTrack(firstTrack, queue: tracks)
                            completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                            return
                        }
                    }
                    completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                } else if identifier.hasPrefix("search_artist_") {
                    let artistName = String(identifier.dropFirst(14))
                    AppLog.info(.general, "🎤 Searching for artist: '\(artistName)'")
                    let artists = try databaseManager.searchArtists(query: artistName)
                    if let artist = artists.first, let artistId = artist.id {
                        let tracks = try databaseManager.getTracksByArtistId(artistId)
                        if let firstTrack = tracks.first {
                            await prepareSiriAudioSession()
                            await playerEngine.playTrack(firstTrack, queue: tracks)
                            completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                            return
                        }
                    }
                    completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                } else if identifier.hasPrefix("search_any_") {
                    // iOS 27 Siri often sends untyped media requests — cascade
                    // songs → albums → artists → playlists against the main DB.
                    let name = String(identifier.dropFirst(11))
                    AppLog.info(.general, "🎤 Untyped search: '\(name)'")
                    let tracks = try databaseManager.searchTracks(query: name)
                    if let firstTrack = tracks.first {
                        await prepareSiriAudioSession()
                        await playerEngine.playTrack(firstTrack, queue: tracks)
                        completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                        return
                    }
                    if let album = try databaseManager.searchAlbums(query: name).first, let albumId = album.id {
                        let albumTracks = try databaseManager.getTracksByAlbumId(albumId)
                        if let firstTrack = albumTracks.first {
                            await prepareSiriAudioSession()
                            await playerEngine.playTrack(firstTrack, queue: albumTracks)
                            completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                            return
                        }
                    }
                    if let artist = try databaseManager.searchArtists(query: name).first, let artistId = artist.id {
                        let artistTracks = try databaseManager.getTracksByArtistId(artistId)
                        if let firstTrack = artistTracks.first {
                            await prepareSiriAudioSession()
                            await playerEngine.playTrack(firstTrack, queue: artistTracks)
                            completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                            return
                        }
                    }
                    if let playlist = try databaseManager.searchPlaylists(query: name).first, let playlistId = playlist.id {
                        let items = try databaseManager.getPlaylistItems(playlistId: playlistId)
                        let playlistTracks = try databaseManager.getTracksByStableIds(items.map { $0.trackStableId })
                        if let firstTrack = playlistTracks.first {
                            await prepareSiriAudioSession()
                            await playerEngine.playTrack(firstTrack, queue: playlistTracks)
                            completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                            return
                        }
                    }
                    AppLog.error(.general, "❌ Untyped search found nothing for '\(name)'")
                    completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                } else if identifier == "no_favorites" {
                    // User requested favorites but none exist
                    AppLog.info(.general, "🎵 No favorites found - user needs to add some favorites first")
                    completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                } else if identifier == "music_all" {
                    // Play all music
                    let tracks = try databaseManager.getAllTracks()
                    if let firstTrack = tracks.first {
                        // Set up background session BEFORE starting playback for Siri
                        await prepareSiriAudioSession()
                        await playerEngine.playTrack(firstTrack, queue: tracks)
                        completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                    } else {
                        completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                    }
                } else {
                    // Try to find by stable ID directly
                    if let track = try databaseManager.getTrack(byStableId: identifier) {
                        // Check if this track is from favorites by looking at the intent's media items
                        let favoriteIds = try databaseManager.getFavorites()

                        if favoriteIds.contains(identifier) {
                            // This is a favorite track - queue all favorites
                            AppLog.info(.general, "🎵 Playing favorite track with favorites queue")
                            let favoritesTracks = try databaseManager.getTracksByStableIds(favoriteIds)
                            await playerEngine.playTrack(track, queue: favoritesTracks)
                        } else {
                            // Regular track - queue all tracks
                            AppLog.info(.general, "🎵 Playing regular track with all tracks queue")
                            let allTracks = try databaseManager.getAllTracks()
                            // Set up background session BEFORE starting playback for Siri
                            await prepareSiriAudioSession()
                            await playerEngine.playTrack(track, queue: allTracks)
                        }
                        completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                    } else {
                        completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                    }
                }
            } catch {
                AppLog.error(.general, "❌ Error handling Siri playback: \(error)")
                completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
            }
        }

        /// "Add this song to favorites / to <playlist>" via the legacy
        /// INAddMediaIntent route the SiriIntentsExtension hands to the app.
        func handleSiriAddMediaIntent(_ intent: INAddMediaIntent, completion: @escaping (INIntentResponse) -> Void) async {
            let identifier = intent.mediaItems?.first?.identifier ?? "current_track"

            let track: Track?
            if identifier == "current_track" {
                track = playerEngine.currentTrack
            } else {
                track = try? databaseManager.getTrack(byStableId: identifier)
            }
            guard let track else {
                AppLog.error(.general, "❌ AddMedia: no track to act on")
                completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
                return
            }

            do {
                if case .playlist(let playlistName)? = intent.mediaDestination,
                   !Self.isFavoritesDestination(playlistName) {
                    let playlists = try databaseManager.searchPlaylists(query: playlistName)
                    guard let playlist = playlists.first, let playlistId = playlist.id else {
                        AppLog.error(.general, "❌ AddMedia: playlist '\(playlistName)' not found")
                        completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
                        return
                    }
                    try addToPlaylist(playlistId: playlistId, trackStableId: track.stableId)
                    AppLog.info(.general, "✅ AddMedia: added '\(track.title)' to playlist '\(playlist.title)'")
                } else {
                    // Library/favorites destination — add to favorites, idempotent.
                    if try !isFavorite(trackStableId: track.stableId) {
                        try toggleFavorite(trackStableId: track.stableId)
                    }
                    AppLog.info(.general, "✅ AddMedia: '\(track.title)' is now a favorite")
                }
                completion(INAddMediaIntentResponse(code: .success, userActivity: nil))
            } catch {
                AppLog.error(.general, "❌ AddMedia failed: \(error)")
                completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
            }
        }

    #endif

    /// Siri phrases "add this to my favorites" as a playlist destination
    /// named "my favourites" — map those names onto the favorites feature
    /// instead of looking for a playlist that doesn't exist.
    private static func isFavoritesDestination(_ name: String) -> Bool {
        let lowered = name.lowercased()
        let keywords = [
            "favorite", "favourite", "liked", "loved",
            "favori", "favoris", "préféré", "préférés", "préférées",
            "prefere", "preferes", "aimé", "aimés", "aimées", "aime",
            "coup de coeur", "coups de coeur", "coup de cœur", "coups de cœur",
        ]
        return keywords.contains { lowered.contains($0) }
    }
}
