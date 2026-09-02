//
//  StateManager.swift
//  QQPlayer
//
//  Manages JSON state files for favorites and playlists in iCloud Drive
//

import Foundation

class StateManager: @unchecked Sendable {
    static let shared = StateManager()

    private var resolvedContainerURL: URL?
    private var hasResolvedContainer = false
    private let containerLock = NSLock()

    private init() {
        // Deliberately empty. Resolving the ubiquity container is expensive -
        // Apple documents url(forUbiquityContainerIdentifier:) as slow enough
        // that it must not be called on the main thread, and on a first install
        // it blocks while the container is registered. This singleton is a
        // stored property of the main-actor AppCoordinator, so doing it here
        // froze the UI during launch. It is resolved lazily instead, by which
        // point the callers that need it run off the main actor.
    }

    /// The iCloud container URL, resolved once on first use.
    private var iCloudContainerURL: URL? {
        containerLock.lock()
        defer { containerLock.unlock() }

        if !hasResolvedContainer {
            hasResolvedContainer = true
            if FileManager.default.ubiquityIdentityToken != nil {
                resolvedContainerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)
            }
        }
        return resolvedContainerURL
    }

    /// Resolves the container ahead of time so the first real caller doesn't
    /// pay for it. Call from a background context during launch.
    func prewarmiCloudContainer() {
        _ = iCloudContainerURL
    }

    /// One-time migration for paths renamed during the Cosmos → QQPlayer rebrand.
    /// Older installs created files/folders under the Cosmos names; the new code
    /// reads the QQPlayer names, so without this the old data would be orphaned
    /// (and the old folder would linger in the Files app). Idempotent: safe to
    /// call on every launch, each item migrates at most once.
    func migrateLegacyPaths() {
        let fm = FileManager.default
        let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        let migrations: [(from: String, to: String)] = [
            ("cosmos-playlists", "qqplayer-playlists"),
            ("cosmos-favorites.json", "qqplayer-favorites.json"),
            ("cosmos-player-state.json", "qqplayer-player-state.json"),
        ]

        for m in migrations {
            let from = documentsURL.appendingPathComponent(m.from)
            let to = documentsURL.appendingPathComponent(m.to)
            guard fm.fileExists(atPath: from.path) else { continue }
            if fm.fileExists(atPath: to.path) {
                // New location already in use; the legacy copy is just residue.
                try? fm.removeItem(at: from)
                print("🧹 Removed legacy \(m.from) (new \(m.to) already exists)")
            } else {
                do {
                    try fm.moveItem(at: from, to: to)
                    print("✅ Migrated \(m.from) → \(m.to)")
                } catch {
                    print("⚠️ Failed to migrate \(m.from): \(error)")
                }
            }
        }

        // App Group container database (shared with Siri/Widget extensions)
        if let containerURL = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.daxmate.qqplayer.ios") {
            let fromDB = containerURL.appendingPathComponent("cosmos_music.db")
            let toDB = containerURL.appendingPathComponent("qqplayer.db")
            if fm.fileExists(atPath: fromDB.path) {
                if fm.fileExists(atPath: toDB.path) {
                    try? fm.removeItem(at: fromDB)
                    print("🧹 Removed legacy cosmos_music.db (qqplayer.db exists)")
                } else {
                    try? fm.moveItem(at: fromDB, to: toDB)
                    print("✅ Migrated cosmos_music.db → qqplayer.db")
                }
            }
        }
    }

    private func getAppFolderURL() -> URL? {
        guard let containerURL = iCloudContainerURL else { return nil }
        return containerURL.appendingPathComponent("Documents", isDirectory: true)
    }

    func createAppFolderIfNeeded() throws {
        guard let appFolderURL = getAppFolderURL() else {
            throw StateManagerError.iCloudNotAvailable
        }

        if !FileManager.default.fileExists(atPath: appFolderURL.path) {
            try FileManager.default.createDirectory(at: appFolderURL,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
        }
    }

    // MARK: - Favorites

    func saveFavorites(_ favorites: [String]) throws {
        print("💾 StateManager: Saving \(favorites.count) favorites - \(favorites)")
        let favoritesState = FavoritesState(favorites: favorites)

        // Always save to local Documents first (survives app reinstall)
        try saveToLocalDocuments(favoritesState)

        // Also try to save to iCloud Drive if available
        do {
            try createAppFolderIfNeeded()
            guard let appFolderURL = getAppFolderURL() else {
                print("⚠️ iCloud not available, favorites saved locally only")
                return
            }

            let favoritesURL = appFolderURL.appendingPathComponent("favorites.json")
            try saveJSONAtomically(favoritesState, to: favoritesURL)
            print("✅ Favorites saved to both local and iCloud")
        } catch {
            print("⚠️ Failed to save to iCloud, but local save succeeded: \(error)")
        }
    }

    private func saveToLocalDocuments(_ favoritesState: FavoritesState) throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localFavoritesURL = documentsURL.appendingPathComponent("qqplayer-favorites.json")
        try saveJSONAtomically(favoritesState, to: localFavoritesURL)
        print("📱 Favorites saved locally to: \(localFavoritesURL.path)")
    }

    func loadFavorites() throws -> [String] {
        print("📂 StateManager: Loading favorites...")

        // Try loading from local Documents first (survives app reinstall)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localFavoritesURL = documentsURL.appendingPathComponent("qqplayer-favorites.json")

        print("📂 StateManager: Checking local file at: \(localFavoritesURL.path)")

        if FileManager.default.fileExists(atPath: localFavoritesURL.path) {
            do {
                let data = try Data(contentsOf: localFavoritesURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let favoritesState = try decoder.decode(FavoritesState.self, from: data)
                print("📱 Loaded favorites from local storage: \(favoritesState.favorites.count) items - \(favoritesState.favorites)")

                // If local file exists but has no favorites, still try iCloud as fallback
                // (this handles the case where a new app installation created an empty local file)
                if favoritesState.favorites.isEmpty {
                    print("📂 Local file has 0 favorites, checking iCloud for any existing favorites...")
                    // Don't return here - continue to iCloud fallback
                } else {
                    return favoritesState.favorites
                }
            } catch {
                print("⚠️ Failed to load local favorites: \(error)")
            }
        } else {
            print("📂 StateManager: Local file does not exist")
        }

        // Fallback to iCloud Drive if local doesn't exist
        guard let appFolderURL = getAppFolderURL() else {
            print("📭 No favorites found (neither local nor iCloud)")
            return []
        }

        let favoritesURL = appFolderURL.appendingPathComponent("favorites.json")
        print("📂 StateManager: Checking iCloud file at: \(favoritesURL.path)")

        guard FileManager.default.fileExists(atPath: favoritesURL.path) else {
            print("📭 No iCloud favorites file found")
            return []
        }

        do {
            // Check if this is an iCloud file and ensure it's downloaded
            let resourceValues = try favoritesURL.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])

            if let isUbiquitous = resourceValues.isUbiquitousItem, isUbiquitous {
                print("☁️ iCloud favorites file detected, checking download status...")

                if let downloadingStatus = resourceValues.ubiquitousItemDownloadingStatus {
                    print("📊 iCloud favorites download status: \(downloadingStatus)")

                    if downloadingStatus == .notDownloaded {
                        print("🔽 iCloud favorites file needs downloading, starting download...")
                        try FileManager.default.startDownloadingUbiquitousItem(at: favoritesURL)
                        // No sleep here: startDownloadingUbiquitousItem only
                        // requests the download, and the coordinated read below
                        // already blocks until the file is available. The old
                        // half-second Thread.sleep just stalled the caller -
                        // on first launch that was the main thread.
                    }
                }
            }

            // Use NSFileCoordinator for proper iCloud file access
            var coordinatorError: NSError?
            var data: Data?

            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: favoritesURL, options: .withoutChanges, error: &coordinatorError) { (url) in
                do {
                    data = try Data(contentsOf: url)
                    print("☁️ Successfully read favorites from iCloud via NSFileCoordinator")
                } catch {
                    print("❌ Failed to read iCloud favorites via coordinator: \(error)")
                }
            }

            if let coordinatorError = coordinatorError {
                print("❌ NSFileCoordinator error: \(coordinatorError)")
                return []
            }

            guard let favoritesData = data else {
                print("❌ No data read from iCloud favorites file")
                return []
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let favoritesState = try decoder.decode(FavoritesState.self, from: favoritesData)
            print("☁️ Loaded favorites from iCloud: \(favoritesState.favorites.count) items - \(favoritesState.favorites)")
            return favoritesState.favorites
        } catch {
            print("❌ Failed to load favorites from iCloud: \(error)")
            return []
        }
    }

    // MARK: - Playlists

    func savePlaylist(_ playlist: PlaylistState) throws {
        // Always save to local Documents first (survives app reinstall)
        try savePlaylistToLocalDocuments(playlist)

        // Also try to save to iCloud Drive if available
        do {
            try createAppFolderIfNeeded()
            guard let appFolderURL = getAppFolderURL() else {
                print("⚠️ iCloud not available, playlist saved locally only")
                return
            }

            let playlistsFolder = appFolderURL.appendingPathComponent("playlists", isDirectory: true)
            if !FileManager.default.fileExists(atPath: playlistsFolder.path) {
                try FileManager.default.createDirectory(at: playlistsFolder,
                                                        withIntermediateDirectories: true,
                                                        attributes: nil)
            }

            let playlistURL = playlistsFolder.appendingPathComponent("playlist-\(playlist.slug).json")
            try saveJSONAtomically(playlist, to: playlistURL)
            print("✅ Playlist saved to both local and iCloud")
        } catch {
            print("⚠️ Failed to save playlist to iCloud, but local save succeeded: \(error)")
        }
    }

    private func savePlaylistToLocalDocuments(_ playlist: PlaylistState) throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlaylistsFolder = documentsURL.appendingPathComponent("qqplayer-playlists", isDirectory: true)

        if !FileManager.default.fileExists(atPath: localPlaylistsFolder.path) {
            try FileManager.default.createDirectory(at: localPlaylistsFolder,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
        }

        let localPlaylistURL = localPlaylistsFolder.appendingPathComponent("playlist-\(playlist.slug).json")
        try saveJSONAtomically(playlist, to: localPlaylistURL)
        print("📱 Playlist saved locally to: \(localPlaylistURL.path)")
    }

    func loadPlaylist(slug: String) throws -> PlaylistState? {
        // 本地优先（与 loadFavorites 对称）：iCloud 不可用时本地歌单不"丢失"
        // （2026-08-29 审计 #10）。savePlaylist 永远先写本地，本地版本 >= 云端。
        if let localPlaylist = try? loadPlaylistFromLocalDocuments(slug: slug) {
            print("📱 Loaded playlist '\(slug)' from local Documents")
            return localPlaylist
        }

        // iCloud 仅作补充/迁移源
        guard let appFolderURL = getAppFolderURL() else {
            print("⚠️ iCloud not available and no local copy of '\(slug)'")
            return nil
        }

        let playlistsFolder = appFolderURL.appendingPathComponent("playlists", isDirectory: true)
        let playlistURL = playlistsFolder.appendingPathComponent("playlist-\(slug).json")

        guard FileManager.default.fileExists(atPath: playlistURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: playlistURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let playlist = try decoder.decode(PlaylistState.self, from: data)
            return playlist
        } catch {
            print("⚠️ Failed to load playlist '\(slug)': \(error)")
            // Try to load from local backup
            if let localPlaylist = try? loadPlaylistFromLocalDocuments(slug: slug) {
                print("✅ Recovered playlist '\(slug)' from local backup")
                return localPlaylist
            }
            print("❌ Unable to recover playlist '\(slug)' from local backup")
            throw error
        }
    }

    /// 读取本地 Documents 全部歌单（本地优先策略核心；iCloud 不可用时兜底，
    /// 2026-08-29 审计 #10）
    private func loadAllPlaylistsFromLocalDocuments() throws -> [PlaylistState] {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlaylistsFolder = documentsURL.appendingPathComponent("qqplayer-playlists", isDirectory: true)
        guard FileManager.default.fileExists(atPath: localPlaylistsFolder.path) else {
            return []
        }

        let playlistFiles = try FileManager.default.contentsOfDirectory(at: localPlaylistsFolder,
                                                                        includingPropertiesForKeys: nil)
        var playlists: [PlaylistState] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for fileURL in playlistFiles where fileURL.pathExtension == "json" {
            if let data = try? Data(contentsOf: fileURL),
               let playlist = try? decoder.decode(PlaylistState.self, from: data) {
                playlists.append(playlist)
            }
        }
        return playlists
    }

    private func loadPlaylistFromLocalDocuments(slug: String) throws -> PlaylistState? {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlaylistsFolder = documentsURL.appendingPathComponent("qqplayer-playlists", isDirectory: true)
        let localPlaylistURL = localPlaylistsFolder.appendingPathComponent("playlist-\(slug).json")

        guard FileManager.default.fileExists(atPath: localPlaylistURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: localPlaylistURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PlaylistState.self, from: data)
    }

    func getAllPlaylists() throws -> [PlaylistState] {
        // 本地优先（与 loadFavorites 对称）：iCloud 不可用时本地歌单不"丢失"
        // （2026-08-29 审计 #10）。savePlaylist 永远先写本地，本地版本 >= 云端，
        // 故同 slug 以本地为准。
        var merged: [String: PlaylistState] = [:]
        for playlist in try loadAllPlaylistsFromLocalDocuments() {
            merged[playlist.slug] = playlist
        }

        // iCloud 仅作补充/迁移源：补充本地没有的 slug（旧版本只写云端的场景）
        guard let appFolderURL = getAppFolderURL() else {
            print("⚠️ iCloud not available - returning \(merged.count) local playlists")
            return merged.values.sorted { $0.updatedAt > $1.updatedAt }
        }

        let playlistsFolder = appFolderURL.appendingPathComponent("playlists", isDirectory: true)

        guard FileManager.default.fileExists(atPath: playlistsFolder.path) else {
            return merged.values.sorted { $0.updatedAt > $1.updatedAt }
        }

        do {
            let playlistFiles = try FileManager.default.contentsOfDirectory(at: playlistsFolder,
                                                                            includingPropertiesForKeys: nil)
            var corruptedFiles: [URL] = []
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            for fileURL in playlistFiles where fileURL.pathExtension == "json" {
                do {
                    let data = try Data(contentsOf: fileURL)
                    let playlist = try decoder.decode(PlaylistState.self, from: data)
                    if merged[playlist.slug] == nil {
                        merged[playlist.slug] = playlist
                    }
                } catch {
                    // Check for authentication errors
                    if let nsError = error as NSError? {
                        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 81 {
                            print("🔐 Authentication required - returning local playlists only")
                            break
                        }
                    }
                    print("⚠️ Failed to read playlist file \(fileURL.lastPathComponent): \(error)")

                    // Try to recover from local backup
                    let slug = fileURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "playlist-", with: "")
                    if merged[slug] == nil, let recoveredPlaylist = try? loadPlaylistFromLocalDocuments(slug: slug) {
                        print("✅ Recovered playlist from local backup: \(slug)")
                        merged[slug] = recoveredPlaylist
                        // Try to repair cloud file
                        try? savePlaylist(recoveredPlaylist)
                    } else {
                        corruptedFiles.append(fileURL)
                        print("❌ Unable to recover playlist: \(fileURL.lastPathComponent)")
                    }
                }
            }

            // Move corrupted files to a quarantine folder
            if !corruptedFiles.isEmpty {
                try? quarantineCorruptedFiles(corruptedFiles, in: playlistsFolder)
            }
        } catch {
            print("⚠️ Failed to read iCloud playlists: \(error)")
        }

        return merged.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func quarantineCorruptedFiles(_ files: [URL], in folder: URL) throws {
        let quarantineFolder = folder.appendingPathComponent("corrupted", isDirectory: true)

        if !FileManager.default.fileExists(atPath: quarantineFolder.path) {
            try FileManager.default.createDirectory(at: quarantineFolder,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
        }

        for file in files {
            let destination = quarantineFolder.appendingPathComponent(file.lastPathComponent)
            try? FileManager.default.moveItem(at: file, to: destination)
            print("🗄️ Moved corrupted file to quarantine: \(file.lastPathComponent)")
        }
    }

    func deletePlaylist(slug: String) throws {
        // Delete from local Documents first
        try deletePlaylistFromLocalDocuments(slug: slug)

        // Also try to delete from iCloud Drive if available
        do {
            guard let appFolderURL = getAppFolderURL() else {
                print("⚠️ iCloud not available, playlist deleted locally only")
                return
            }

            let playlistsFolder = appFolderURL.appendingPathComponent("playlists", isDirectory: true)
            let playlistURL = playlistsFolder.appendingPathComponent("playlist-\(slug).json")

            if FileManager.default.fileExists(atPath: playlistURL.path) {
                try FileManager.default.removeItem(at: playlistURL)
                print("☁️ Playlist deleted from iCloud: \(playlistURL.path)")
            }
        } catch {
            print("⚠️ Failed to delete playlist from iCloud, but local delete succeeded: \(error)")
        }
    }

    private func deletePlaylistFromLocalDocuments(slug: String) throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlaylistsFolder = documentsURL.appendingPathComponent("qqplayer-playlists", isDirectory: true)
        let localPlaylistURL = localPlaylistsFolder.appendingPathComponent("playlist-\(slug).json")

        if FileManager.default.fileExists(atPath: localPlaylistURL.path) {
            try FileManager.default.removeItem(at: localPlaylistURL)
            print("📱 Playlist deleted locally: \(localPlaylistURL.path)")
        }
    }

    // MARK: - Helper methods

    private func saveJSONAtomically<T: Codable>(_ object: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(object)

        let tempURL = url.appendingPathExtension("tmp")
        try data.write(to: tempURL)
        _ = try FileManager.default.replaceItem(at: url, withItemAt: tempURL,
                                                backupItemName: nil, options: [],
                                                resultingItemURL: nil)
    }

    func getMusicFolderURL() -> URL? {
        #if os(macOS)
            // macOS 无 iCloud 容器语义（MVP）：沿用桌面端约定，默认 ~/Music/QQPlayer。
            // 用户拍板（2026-08-30）：音乐库 = 本地文件夹扫描，默认路径 ~/Music/QQPlayer。
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Music", isDirectory: true)
                .appendingPathComponent("QQPlayer", isDirectory: true)
        #else
            return getAppFolderURL()
        #endif
    }

    #if os(macOS)
        /// macOS 曲库文件夹列表：设置页「音乐库」添加的外部文件夹；
        /// 未配置（空数组）时回退默认 ~/Music/QQPlayer（对齐桌面端约定）。
        func getMusicFolderURLs() -> [URL] {
            let defaultURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Music", isDirectory: true)
                .appendingPathComponent("QQPlayer", isDirectory: true)
            let configured = DeleteSettings.load().libraryFolders
            guard !configured.isEmpty else { return [defaultURL] }
            return configured.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        }
    #endif

    func checkiCloudAvailability() -> Bool {
        // Check if user is signed into iCloud
        guard FileManager.default.ubiquityIdentityToken != nil else {
            return false
        }

        // Check if we can get the container URL
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return false
        }

        // Refresh the cache with what we just resolved, so a container that
        // only became available after launch is picked up.
        containerLock.lock()
        hasResolvedContainer = true
        resolvedContainerURL = containerURL
        containerLock.unlock()

        return true
    }
}

// MARK: - Player State Persistence

extension StateManager {
    func savePlayerState(_ playerState: PlayerState) throws {
        print("💾 StateManager: Saving player state - track: \(playerState.currentTrackStableId ?? "nil"), time: \(playerState.playbackTime)")

        // Always save to local Documents first (survives app reinstall)
        try savePlayerStateToLocalDocuments(playerState)

        // Also try to save to iCloud Drive if available
        do {
            try createAppFolderIfNeeded()
            guard let appFolderURL = getAppFolderURL() else {
                print("⚠️ iCloud not available, player state saved locally only")
                return
            }

            let playerStateURL = appFolderURL.appendingPathComponent("player-state.json")
            try saveJSONAtomically(playerState, to: playerStateURL)
            print("✅ Player state saved to both local and iCloud")
        } catch {
            print("⚠️ Failed to save player state to iCloud, but local save succeeded: \(error)")
        }
    }

    private func savePlayerStateToLocalDocuments(_ playerState: PlayerState) throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlayerStateURL = documentsURL.appendingPathComponent("qqplayer-player-state.json")
        try saveJSONAtomically(playerState, to: localPlayerStateURL)
        print("📱 Player state saved locally to: \(localPlayerStateURL.path)")
    }

    func loadPlayerState() throws -> PlayerState? {
        print("📂 StateManager: Loading player state...")

        // Try loading from local Documents first (survives app reinstall)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlayerStateURL = documentsURL.appendingPathComponent("qqplayer-player-state.json")

        print("📂 StateManager: Checking local player state at: \(localPlayerStateURL.path)")

        if FileManager.default.fileExists(atPath: localPlayerStateURL.path) {
            do {
                let data = try Data(contentsOf: localPlayerStateURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let playerState = try decoder.decode(PlayerState.self, from: data)
                print("📱 Loaded player state from local storage - track: \(playerState.currentTrackStableId ?? "nil"), time: \(playerState.playbackTime)")
                return playerState
            } catch {
                print("⚠️ Failed to load local player state: \(error)")
            }
        } else {
            print("📂 StateManager: Local player state file does not exist")
        }

        // Fallback to iCloud Drive if local doesn't exist
        guard let appFolderURL = getAppFolderURL() else {
            print("📭 No player state found (neither local nor iCloud)")
            return nil
        }

        let playerStateURL = appFolderURL.appendingPathComponent("player-state.json")
        print("📂 StateManager: Checking iCloud player state at: \(playerStateURL.path)")

        guard FileManager.default.fileExists(atPath: playerStateURL.path) else {
            print("📭 No iCloud player state file found")
            return nil
        }

        do {
            // Check if this is an iCloud file and ensure it's downloaded
            let resourceValues = try playerStateURL.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])

            if let isUbiquitous = resourceValues.isUbiquitousItem, isUbiquitous {
                print("☁️ iCloud player state file detected, checking download status...")

                if let downloadingStatus = resourceValues.ubiquitousItemDownloadingStatus {
                    print("📊 iCloud player state download status: \(downloadingStatus)")

                    if downloadingStatus == .notDownloaded {
                        print("🔽 iCloud player state file needs downloading, starting download...")
                        try FileManager.default.startDownloadingUbiquitousItem(at: playerStateURL)
                        // See loadFavorites: the coordinated read below waits
                        // for the file, so sleeping here only stalled the caller.
                    }
                }
            }

            // Use NSFileCoordinator for proper iCloud file access
            var coordinatorError: NSError?
            var data: Data?

            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: playerStateURL, options: .withoutChanges, error: &coordinatorError) { (url) in
                do {
                    data = try Data(contentsOf: url)
                    print("☁️ Successfully read player state from iCloud via NSFileCoordinator")
                } catch {
                    print("❌ Failed to read iCloud player state via coordinator: \(error)")
                }
            }

            if let coordinatorError = coordinatorError {
                print("❌ NSFileCoordinator error: \(coordinatorError)")
                return nil
            }

            guard let playerStateData = data else {
                print("❌ No data read from iCloud player state file")
                return nil
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let playerState = try decoder.decode(PlayerState.self, from: playerStateData)
            print("☁️ Loaded player state from iCloud - track: \(playerState.currentTrackStableId ?? "nil"), time: \(playerState.playbackTime)")
            return playerState
        } catch {
            print("❌ Failed to load player state from iCloud: \(error)")
            return nil
        }
    }
}
