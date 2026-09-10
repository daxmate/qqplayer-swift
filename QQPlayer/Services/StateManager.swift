//
//  StateManager.swift
//  QQPlayer
//
//  Manages JSON state files for favorites/playlists/player-state in local
//  sandbox Documents (M3-2: iCloud ubiquity mirror retired)
//

import Foundation

class StateManager: @unchecked Sendable {
    static let shared = StateManager()

    private init() {
        // M3-2：退役 iCloud ubiquity 容器——不再有需惰性解析的容器 URL。
        // 音乐/收藏/歌单/播放状态的持久化全部在本地 Documents（沙盒）。
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

    // M3-2：退役 iCloud 容器——getAppFolderURL/createAppFolderIfNeeded 为
    // ubiquity 容器目录创建逻辑，已随 iCloud 存储退役删除（音乐存沙盒 Documents）。

    // MARK: - Favorites

    func saveFavorites(_ favorites: [String]) throws {
        print("💾 StateManager: Saving \(favorites.count) favorites - \(favorites)")
        let favoritesState = FavoritesState(favorites: favorites)

        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud 镜像）
        try saveToLocalDocuments(favoritesState)
    }

    private func saveToLocalDocuments(_ favoritesState: FavoritesState) throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localFavoritesURL = documentsURL.appendingPathComponent("qqplayer-favorites.json")
        try saveJSONAtomically(favoritesState, to: localFavoritesURL)
        print("📱 Favorites saved locally to: \(localFavoritesURL.path)")
    }

    func loadFavorites() throws -> [String] {
        print("📂 StateManager: Loading favorites...")

        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud fallback）
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localFavoritesURL = documentsURL.appendingPathComponent("qqplayer-favorites.json")

        print("📂 StateManager: Checking local file at: \(localFavoritesURL.path)")

        guard FileManager.default.fileExists(atPath: localFavoritesURL.path) else {
            print("📂 StateManager: Local file does not exist")
            return []
        }

        do {
            let data = try Data(contentsOf: localFavoritesURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let favoritesState = try decoder.decode(FavoritesState.self, from: data)
            print("📱 Loaded favorites from local storage: \(favoritesState.favorites.count) items - \(favoritesState.favorites)")
            return favoritesState.favorites
        } catch {
            print("⚠️ Failed to load local favorites: \(error)")
            return []
        }
    }

    // MARK: - Playlists

    func savePlaylist(_ playlist: PlaylistState) throws {
        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud 镜像）
        try savePlaylistToLocalDocuments(playlist)
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
        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud 补充/迁移源）
        if let localPlaylist = try? loadPlaylistFromLocalDocuments(slug: slug) {
            print("📱 Loaded playlist '\(slug)' from local Documents")
            return localPlaylist
        }

        print("⚠️ No local copy of playlist '\(slug)'")
        return nil
    }

    /// 读取本地 Documents 全部歌单（M3-2：本地是唯一位置，退役 iCloud 补充段）
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
        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud 补充/迁移源）。
        let playlists = try loadAllPlaylistsFromLocalDocuments()
        return playlists.sorted { $0.updatedAt > $1.updatedAt }
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
        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud 删除段）
        try deletePlaylistFromLocalDocuments(slug: slug)
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

    #if os(macOS)
        /// 音乐库默认目录（macOS 仅本地文件夹语义）。M3-2 起 iOS 无此入口——
        /// iOS 音乐位置 = 沙盒 Documents（LibraryIndexer 直接使用），不再有
        /// ubiquity 容器 URL 可返回。
        func getMusicFolderURL() -> URL? {
            return MusicFolderResolver.macDefaultFolderURL(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        }

        /// macOS 曲库文件夹列表：默认 ~/Music/QQPlayer 始终在列，加上设置页
        /// 「音乐库」添加的外部文件夹（多根共存，去重）。对齐用户期望：添加
        /// 新路径不冲掉默认目录。决策上收 MusicFolderResolver（A0-prep：行为不变）。
        func getMusicFolderURLs() -> [URL] {
            MusicFolderResolver.macFolderURLs(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                extraFolderPaths: DeleteSettings.load().libraryFolders
            )
        }
    #endif
}

// MARK: - Player State Persistence

extension StateManager {
    func savePlayerState(_ playerState: PlayerState) throws {
        print("💾 StateManager: Saving player state - track: \(playerState.currentTrackStableId ?? "nil"), time: \(playerState.playbackTime)")

        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud 镜像）
        try savePlayerStateToLocalDocuments(playerState)
    }

    private func savePlayerStateToLocalDocuments(_ playerState: PlayerState) throws {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlayerStateURL = documentsURL.appendingPathComponent("qqplayer-player-state.json")
        try saveJSONAtomically(playerState, to: localPlayerStateURL)
        print("📱 Player state saved locally to: \(localPlayerStateURL.path)")
    }

    func loadPlayerState() throws -> PlayerState? {
        print("📂 StateManager: Loading player state...")

        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud fallback）
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let localPlayerStateURL = documentsURL.appendingPathComponent("qqplayer-player-state.json")

        print("📂 StateManager: Checking local player state at: \(localPlayerStateURL.path)")

        guard FileManager.default.fileExists(atPath: localPlayerStateURL.path) else {
            print("📂 StateManager: Local player state file does not exist")
            return nil
        }

        do {
            let data = try Data(contentsOf: localPlayerStateURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let playerState = try decoder.decode(PlayerState.self, from: data)
            print("📱 Loaded player state from local storage - track: \(playerState.currentTrackStableId ?? "nil"), time: \(playerState.playbackTime)")
            return playerState
        } catch {
            print("⚠️ Failed to load local player state: \(error)")
            return nil
        }
    }
}
