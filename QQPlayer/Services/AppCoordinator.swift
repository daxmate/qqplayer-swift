//
//  AppCoordinator.swift
//  QQPlayer
//
//  Main app coordinator that manages all services
//
//  核心：状态属性/初始化流程/公开业务 API/播放入口/Siri 意图处理。
//  拆分见 AppCoordinator+iCloud/ImportExport/Models.swift。
//

import Combine
import Foundation
#if os(iOS)
    import Intents
#endif

@MainActor
class AppCoordinator: ObservableObject {
    static let shared = AppCoordinator()

    @Published var isInitialized = false

    let databaseManager = DatabaseManager.shared
    let stateManager = StateManager.shared
    let libraryIndexer = LibraryIndexer.shared
    let playerEngine = PlayerEngine.shared
    let fileCleanupManager = FileCleanupManager.shared

    private var cancellables = Set<AnyCancellable>()

    private init() {
        setupBindings()
    }

    func initialize() async {
        print("🚀 AppCoordinator.initialize() started")

        // Cosmos → QQPlayer rebrand: rename legacy data paths once so
        // playlists/favorites/player-state created by older installs stay
        // readable and don't linger under the old names in the Files app.
        await Task.detached(priority: .userInitiated) {
            StateManager.shared.migrateLegacyPaths()
        }.value

        // M3-2：一次性 iCloud → 沙盒存量迁移（幂等可断点；无 iCloud 数据时自动跳过）。
        // 必须在首次扫描前跑完，确保 LibraryIndexer 主扫只面对沙盒 Documents。
        #if os(iOS)
            _ = await SandboxMusicMigrator.shared.runIfNeeded()
        #endif

        // Check if we should auto-scan based on last scan date
        var settings = DeleteSettings.load()
        print("📅 Current lastLibraryScanDate: \(settings.lastLibraryScanDate?.description ?? "nil")")
        let shouldAutoScan = shouldPerformAutoScan(lastScanDate: settings.lastLibraryScanDate)

        if shouldAutoScan {
            print("🔄 App launched after long time - starting automatic library scan")
        } else {
            print("⏭️ Recent app launch - skipping automatic scan (use manual sync button)")
        }

        // M3-2：退役 iCloud 状态机后本地沙盒是唯一数据源，不再区分 online/offline
        // 分支——统一走本地主扫（FileManager 扫沙盒 Documents）。
        if shouldAutoScan {
            await startLibraryIndexing()
            settings.lastLibraryScanDate = Date()
            settings.save()
        }
        print("App initialized with local sandbox music library")

        // Restore UI state only to show user what was playing without interrupting other apps
        Task {
            await playerEngine.restoreUIStateOnly()
        }

        isInitialized = true
    }

    private func shouldPerformAutoScan(lastScanDate: Date?) -> Bool {
        // If never scanned before, definitely scan
        guard let lastScanDate = lastScanDate else {
            print("🆕 Never scanned before - will perform scan")
            return true
        }

        // Check if it's been more than 1 hour since last scan
        // This prevents scanning when app was just backgrounded/resumed
        let hoursSinceLastScan = Date().timeIntervalSince(lastScanDate) / 3600
        let shouldScan = hoursSinceLastScan >= 1.0

        if shouldScan {
            print("⏰ Last scan was \(String(format: "%.1f", hoursSinceLastScan)) hours ago - will scan")
        } else {
            print("⏰ Last scan was \(String(format: "%.1f", hoursSinceLastScan)) hours ago - skipping")
        }

        return shouldScan
    }

    private func startLibraryIndexing() async {
        libraryIndexer.start()
    }

    private func setupBindings() {
        libraryIndexer.$isIndexing
            .sink { [weak self] isIndexing in
                if !isIndexing {
                    Task { @MainActor in
                        await self?.onIndexingCompleted()
                    }
                }
            }
            .store(in: &cancellables)

        // Listen for background color changes to update widget theme
        NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))
            .sink { [weak self] _ in
                Task { @MainActor in
                    print("🎨 Background color changed - updating widget theme")
                    // Update playlist widget colors
                    self?.syncPlaylistsToCloud()
                    // Update now playing widget color
                    self?.playerEngine.updateWidgetData()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    func getAllTracks() throws -> [Track] {
        return try databaseManager.getAllTracks()
    }

    func manualSync() async {
        print("🔄 Manual sync triggered - attempting library indexing")

        // Check if we're already indexing
        if libraryIndexer.isIndexing {
            print("⚠️ Library indexing already in progress - skipping manual sync")
            return
        }

        // For manual sync, always attempt to re-index to catch new files
        print("📋 Performing manual sync - user requested fresh library scan")
        await startLibraryIndexing()
    }

    func getAllAlbums() throws -> [Album] {
        return try databaseManager.getAllAlbums()
    }

    func toggleFavorite(trackStableId: String) throws {
        print("🔄 Toggle favorite for track: \(trackStableId)")

        let wasLiked = try databaseManager.isFavorite(trackStableId: trackStableId)
        print("📊 Track was liked before toggle: \(wasLiked)")

        if wasLiked {
            try databaseManager.removeFromFavorites(trackStableId: trackStableId)
            print("❌ Removed from favorites: \(trackStableId)")
        } else {
            try databaseManager.addToFavorites(trackStableId: trackStableId)
            print("❤️ Added to favorites: \(trackStableId)")
        }

        // Notify observers that favorites changed
        NotificationCenter.default.post(name: NSNotification.Name("FavoritesChanged"), object: nil)

        // Verify the database operation worked
        let isNowLiked = try databaseManager.isFavorite(trackStableId: trackStableId)
        print("📊 Track is now liked after toggle: \(isNowLiked)")

        // Get current favorites count from database
        let currentFavorites = try databaseManager.getFavorites()
        print("📊 Total favorites in database after toggle: \(currentFavorites.count)")

        // Always save favorites (both locally and to iCloud if available)
        Task {
            do {
                let favorites = try databaseManager.getFavorites()
                print("📊 Favorites to save: \(favorites.count) - \(favorites)")
                try stateManager.saveFavorites(favorites)
                print("💾 Favorites saved: \(favorites.count) total")

                // Verify save worked by loading back
                let loadedFavorites = try stateManager.loadFavorites()
                print("📊 Loaded favorites after save: \(loadedFavorites.count) - \(loadedFavorites)")
            } catch {
                print("❌ Failed to save favorites: \(error)")
            }
        }
    }

    func isFavorite(trackStableId: String) throws -> Bool {
        return try databaseManager.isFavorite(trackStableId: trackStableId)
    }

    func getFavorites() throws -> [String] {
        return try databaseManager.getFavorites()
    }

    var isSyncingPlaylists = false
    var hasCompletedInitialIndexing = false

    func playTrack(_ track: Track, queue: [Track] = []) async {
        await playerEngine.playTrack(track, queue: queue)
    }

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
                    print("❌ Unsupported media type from Siri")
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
                print("❌ Error playing song: \(error)")
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
                print("❌ Error playing playlist: \(error)")
            }
        }

        private func handleGeneralMusicPlayback(userInfo: [String: Any]) async {
            do {
                // Play all music - should always play all tracks, not favorites
                let tracks = try databaseManager.getAllTracks()
                print("🎵 Playing all music: \(tracks.count) tracks, starting with most recent")

                if let firstTrack = tracks.first {
                    // Set up background session BEFORE starting playback for Siri
                    await prepareSiriAudioSession()
                    await playerEngine.playTrack(firstTrack, queue: tracks)
                }
            } catch {
                print("❌ Error playing general music: \(error)")
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
                print("❌ Error with direct playback: \(error)")
            }
        }

        func handleSiriPlaybackIntent(_ intent: INPlayMediaIntent, completion: @escaping (INIntentResponse) -> Void) async {
            // Extract media items from the intent
            guard let mediaItem = intent.mediaItems?.first, let identifier = mediaItem.identifier else {
                completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                return
            }

            print("🎤 Handling Siri playback intent for: \(identifier)")

            guard identifier != "qqplayer_not_found" else {
                completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                return
            }

            do {
                if identifier.hasPrefix("search_song_") {
                    let songName = String(identifier.dropFirst(12)) // Remove "search_song_" prefix
                    print("🎤 Searching for song: '\(songName)'")
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
                    print("🎤 Searching for playlist: '\(playlistName)'")
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
                    print("🎤 Playing playlist with ID: '\(playlistIdString)'")
                    if let playlistId = Int64(playlistIdString) {
                        let playlistItems = try databaseManager.getPlaylistItems(playlistId: playlistId)
                        let trackStableIds = playlistItems.map { $0.trackStableId }
                        let tracks = try databaseManager.getTracksByStableIds(trackStableIds)
                        print("🎤 Found \(tracks.count) tracks in playlist \(playlistId)")
                        if let firstTrack = tracks.first {
                            // Update playlist last played time
                            try databaseManager.updatePlaylistLastPlayed(playlistId: playlistId)
                            await playerEngine.playTrack(firstTrack, queue: tracks)
                            completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
                        } else {
                            print("❌ No tracks found in playlist \(playlistId)")
                            completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                        }
                    } else {
                        print("❌ Invalid playlist ID: '\(playlistIdString)'")
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
                    print("🎤 Searching for album: '\(albumName)'")
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
                    print("🎤 Searching for artist: '\(artistName)'")
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
                    print("🎤 Untyped search: '\(name)'")
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
                    print("❌ Untyped search found nothing for '\(name)'")
                    completion(INPlayMediaIntentResponse(code: .failure, userActivity: nil))
                } else if identifier == "no_favorites" {
                    // User requested favorites but none exist
                    print("🎵 No favorites found - user needs to add some favorites first")
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
                            print("🎵 Playing favorite track with favorites queue")
                            let favoritesTracks = try databaseManager.getTracksByStableIds(favoriteIds)
                            await playerEngine.playTrack(track, queue: favoritesTracks)
                        } else {
                            // Regular track - queue all tracks
                            print("🎵 Playing regular track with all tracks queue")
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
                print("❌ Error handling Siri playback: \(error)")
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
                print("❌ AddMedia: no track to act on")
                completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
                return
            }

            do {
                if case .playlist(let playlistName)? = intent.mediaDestination,
                   !Self.isFavoritesDestination(playlistName) {
                    let playlists = try databaseManager.searchPlaylists(query: playlistName)
                    guard let playlist = playlists.first, let playlistId = playlist.id else {
                        print("❌ AddMedia: playlist '\(playlistName)' not found")
                        completion(INAddMediaIntentResponse(code: .failure, userActivity: nil))
                        return
                    }
                    try addToPlaylist(playlistId: playlistId, trackStableId: track.stableId)
                    print("✅ AddMedia: added '\(track.title)' to playlist '\(playlist.title)'")
                } else {
                    // Library/favorites destination — add to favorites, idempotent.
                    if try !isFavorite(trackStableId: track.stableId) {
                        try toggleFavorite(trackStableId: track.stableId)
                    }
                    print("✅ AddMedia: '\(track.title)' is now a favorite")
                }
                completion(INAddMediaIntentResponse(code: .success, userActivity: nil))
            } catch {
                print("❌ AddMedia failed: \(error)")
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
