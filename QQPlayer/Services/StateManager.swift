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
    /// - Parameter fileManager: **Documents 根解析缝**（测试注入临时根用；生产一律默认 `.default`）。
    ///   legacy 源与新落点两侧同源同一个 `fileManager`。
    func migrateLegacyPaths(fileManager: FileManager = .default) {
        let fm = fileManager
        let documentsURL = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]

        // 旧 Cosmos 名一律在 Documents 根；新的 QQPlayer 名落到隐藏布局的落点
        // （2026-09-22 隐藏布局：iOS = `.qqplayer/state/…`；macOS 仍平铺在 Documents）。
        let migrations: [(from: String, to: URL?)] = [
            ("cosmos-playlists", LibraryRoot.playlistsDirectoryURL(fileManager: fm)),
            ("cosmos-favorites.json", LibraryRoot.favoritesFileURL(fileManager: fm)),
            ("cosmos-player-state.json", LibraryRoot.playerStateFileURL(fileManager: fm)),
        ]

        for m in migrations {
            let from = documentsURL.appendingPathComponent(m.from)
            guard let to = m.to else { continue }
            guard fm.fileExists(atPath: from.path) else { continue }
            if fm.fileExists(atPath: to.path) {
                // New location already in use; the legacy copy is just residue.
                try? fm.removeItem(at: from)
                AppLog.info(.general, "🧹 Removed legacy \(m.from) (new \(to.lastPathComponent) already exists)")
            } else {
                do {
                    try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: from, to: to)
                    AppLog.info(.general, "✅ Migrated \(m.from) → \(to.path)")
                } catch {
                    AppLog.warn(.general, "⚠️ Failed to migrate \(m.from): \(error)")
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
                    AppLog.info(.general, "🧹 Removed legacy cosmos_music.db (qqplayer.db exists)")
                } else {
                    try? fm.moveItem(at: fromDB, to: toDB)
                    AppLog.info(.general, "✅ Migrated cosmos_music.db → qqplayer.db")
                }
            }
        }
    }

    // M3-2：退役 iCloud 容器——getAppFolderURL/createAppFolderIfNeeded 为
    // ubiquity 容器目录创建逻辑，已随 iCloud 存储退役删除（音乐存沙盒 Documents）。

    // MARK: - 落点（隐藏布局唯一入口 + 旧位置只读兼容）

    /// 收藏文件落点（iOS = `.qqplayer/state/qqplayer-favorites.json`；macOS 现状平铺）。
    ///
    /// 全部落点解析都收 `fileManager`（**Documents 根解析缝**）：生产默认 `.default`
    /// ⇒ 行为逐字节不变；测试注入一个 `.documentDirectory` 指向临时根的 `FileManager`
    /// 即可脱离真机容器。（2026-09-22 起不再有进程级全局静态覆盖，见 `LibraryRoot.documentsRootURL`。）
    private func favoritesFileURL(fileManager: FileManager) -> URL? {
        LibraryRoot.favoritesFileURL(fileManager: fileManager)
    }
    /// 旧位置（`Documents/qqplayer-favorites.json`）—— v2 迁移未跑到时的只读兜底。
    private func legacyFavoritesFileURL(fileManager: FileManager) -> URL? {
        LibraryRoot.documentsRootURL(fileManager: fileManager)?
            .appendingPathComponent(LibraryRoot.favoritesFileName)
    }

    /// 歌单目录落点（iOS = `.qqplayer/state/playlists`；macOS = `Documents/qqplayer-playlists`）。
    private func playlistsDirectoryURL(fileManager: FileManager) -> URL? {
        LibraryRoot.playlistsDirectoryURL(fileManager: fileManager)
    }
    /// 旧位置（`Documents/qqplayer-playlists`）—— 只读兜底。
    private func legacyPlaylistsDirectoryURL(fileManager: FileManager) -> URL? {
        LibraryRoot.documentsRootURL(fileManager: fileManager)?
            .appendingPathComponent("qqplayer-playlists", isDirectory: true)
    }

    /// 播放状态文件落点（iOS = `.qqplayer/state/qqplayer-player-state.json`）。
    private func playerStateFileURL(fileManager: FileManager) -> URL? {
        LibraryRoot.playerStateFileURL(fileManager: fileManager)
    }
    /// 旧位置（`Documents/qqplayer-player-state.json`）—— 只读兜底。
    private func legacyPlayerStateFileURL(fileManager: FileManager) -> URL? {
        LibraryRoot.documentsRootURL(fileManager: fileManager)?
            .appendingPathComponent(LibraryRoot.playerStateFileName)
    }

    // MARK: - Favorites

    func saveFavorites(_ favorites: [String], fileManager: FileManager = .default) throws {
        AppLog.info(.general, "💾 StateManager: Saving \(favorites.count) favorites - \(favorites)")
        let favoritesState = FavoritesState(favorites: favorites)

        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud 镜像）
        try saveToLocalDocuments(favoritesState, fileManager: fileManager)
    }

    private func saveToLocalDocuments(_ favoritesState: FavoritesState, fileManager: FileManager) throws {
        guard let localFavoritesURL = favoritesFileURL(fileManager: fileManager) else {
            throw ExternalFileBookmarkStore.StoreError.documentsDirectoryUnavailable
        }
        try saveJSONAtomically(favoritesState, to: localFavoritesURL)
        AppLog.info(.general, "📱 Favorites saved locally to: \(localFavoritesURL.path)")
    }

    func loadFavorites(fileManager: FileManager = .default) throws -> [String] {
        AppLog.info(.general, "📂 StateManager: Loading favorites...")

        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud fallback）
        // 隐藏布局：新位置优先，旧位置只读兜底（v2 迁移未跑到时用户数据不能隐身）。
        guard let localFavoritesURL = [
            favoritesFileURL(fileManager: fileManager),
            legacyFavoritesFileURL(fileManager: fileManager),
        ]
        .compactMap({ $0 })
        .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            AppLog.info(.general, "📂 StateManager: Local file does not exist")
            return []
        }

        AppLog.info(.general, "📂 StateManager: Checking local file at: \(localFavoritesURL.path)")

        do {
            let data = try Data(contentsOf: localFavoritesURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let favoritesState = try decoder.decode(FavoritesState.self, from: data)
            AppLog.info(.general, "📱 Loaded favorites from local storage: \(favoritesState.favorites.count) items - \(favoritesState.favorites)")
            return favoritesState.favorites
        } catch {
            AppLog.warn(.general, "⚠️ Failed to load local favorites: \(error)")
            return []
        }
    }

    // MARK: - Playlists

    func savePlaylist(_ playlist: PlaylistState, fileManager: FileManager = .default) throws {
        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud 镜像）
        try savePlaylistToLocalDocuments(playlist, fileManager: fileManager)
    }

    private func savePlaylistToLocalDocuments(
        _ playlist: PlaylistState,
        fileManager: FileManager
    ) throws {
        guard let localPlaylistsFolder = playlistsDirectoryURL(fileManager: fileManager) else {
            throw ExternalFileBookmarkStore.StoreError.documentsDirectoryUnavailable
        }

        if !FileManager.default.fileExists(atPath: localPlaylistsFolder.path) {
            try FileManager.default.createDirectory(at: localPlaylistsFolder,
                                                    withIntermediateDirectories: true,
                                                    attributes: nil)
        }

        let localPlaylistURL = localPlaylistsFolder.appendingPathComponent("playlist-\(playlist.slug).json")
        try saveJSONAtomically(playlist, to: localPlaylistURL)
        AppLog.info(.general, "📱 Playlist saved locally to: \(localPlaylistURL.path)")
    }

    func loadPlaylist(slug: String, fileManager: FileManager = .default) throws -> PlaylistState? {
        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud 补充/迁移源）
        if let localPlaylist = try? loadPlaylistFromLocalDocuments(slug: slug, fileManager: fileManager) {
            AppLog.info(.general, "📱 Loaded playlist '\(slug)' from local Documents")
            return localPlaylist
        }

        AppLog.warn(.general, "⚠️ No local copy of playlist '\(slug)'")
        return nil
    }

    /// 读取本地 Documents 全部歌单（M3-2：本地是唯一位置，退役 iCloud 补充段）。
    /// 隐藏布局：新位置优先，旧位置只读兜底（同一 slug 新位置权威，不覆盖）。
    private func loadAllPlaylistsFromLocalDocuments(fileManager: FileManager) throws -> [PlaylistState] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var bySlug: [String: PlaylistState] = [:]

        for folder in [
            playlistsDirectoryURL(fileManager: fileManager),
            legacyPlaylistsDirectoryURL(fileManager: fileManager),
        ].compactMap({ $0 }) {
            guard FileManager.default.fileExists(atPath: folder.path),
                  let playlistFiles = try? FileManager.default.contentsOfDirectory(
                      at: folder, includingPropertiesForKeys: nil
                  )
            else { continue }

            for fileURL in playlistFiles where fileURL.pathExtension == "json" {
                guard let data = try? Data(contentsOf: fileURL),
                      let playlist = try? decoder.decode(PlaylistState.self, from: data),
                      bySlug[playlist.slug] == nil else { continue }
                bySlug[playlist.slug] = playlist
            }
        }
        return Array(bySlug.values)
    }

    private func loadPlaylistFromLocalDocuments(
        slug: String,
        fileManager: FileManager
    ) throws -> PlaylistState? {
        guard let folder = [
            playlistsDirectoryURL(fileManager: fileManager),
            legacyPlaylistsDirectoryURL(fileManager: fileManager),
        ]
        .compactMap({ $0 })
        .first(where: {
            FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("playlist-\(slug).json").path
            )
        })
        else {
            return nil
        }
        let localPlaylistURL = folder.appendingPathComponent("playlist-\(slug).json")

        let data = try Data(contentsOf: localPlaylistURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PlaylistState.self, from: data)
    }

    func getAllPlaylists(fileManager: FileManager = .default) throws -> [PlaylistState] {
        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud 补充/迁移源）。
        let playlists = try loadAllPlaylistsFromLocalDocuments(fileManager: fileManager)
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
            AppLog.info(.general, "🗄️ Moved corrupted file to quarantine: \(file.lastPathComponent)")
        }
    }

    func deletePlaylist(slug: String, fileManager: FileManager = .default) throws {
        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud 删除段）
        try deletePlaylistFromLocalDocuments(slug: slug, fileManager: fileManager)
    }

    private func deletePlaylistFromLocalDocuments(slug: String, fileManager: FileManager) throws {
        // 新旧两个位置都删：旧位置的残留不能让「删歌单」变成表面成功。
        for folder in [
            playlistsDirectoryURL(fileManager: fileManager),
            legacyPlaylistsDirectoryURL(fileManager: fileManager),
        ].compactMap({ $0 }) {
            let localPlaylistURL = folder.appendingPathComponent("playlist-\(slug).json")
            if FileManager.default.fileExists(atPath: localPlaylistURL.path) {
                try FileManager.default.removeItem(at: localPlaylistURL)
                AppLog.info(.general, "📱 Playlist deleted locally: \(localPlaylistURL.path)")
            }
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
    func savePlayerState(_ playerState: PlayerState, fileManager: FileManager = .default) throws {
        AppLog.info(.general, "💾 StateManager: Saving player state - track: \(playerState.currentTrackStableId ?? "nil"), time: \(playerState.playbackTime)")

        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud 镜像）
        try savePlayerStateToLocalDocuments(playerState, fileManager: fileManager)
    }

    private func savePlayerStateToLocalDocuments(
        _ playerState: PlayerState,
        fileManager: FileManager
    ) throws {
        guard let localPlayerStateURL = playerStateFileURL(fileManager: fileManager) else {
            throw ExternalFileBookmarkStore.StoreError.documentsDirectoryUnavailable
        }
        try saveJSONAtomically(playerState, to: localPlayerStateURL)
        AppLog.info(.general, "📱 Player state saved locally to: \(localPlayerStateURL.path)")
    }

    func loadPlayerState(fileManager: FileManager = .default) throws -> PlayerState? {
        AppLog.info(.general, "📂 StateManager: Loading player state...")

        // M3-2：本地 Documents 是唯一持久化位置（退役 iCloud fallback）
        // 隐藏布局：新位置优先，旧位置只读兜底。
        guard let localPlayerStateURL = [
            playerStateFileURL(fileManager: fileManager),
            legacyPlayerStateFileURL(fileManager: fileManager),
        ]
        .compactMap({ $0 })
        .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        else {
            AppLog.info(.general, "📂 StateManager: Local player state file does not exist")
            return nil
        }

        AppLog.info(.general, "📂 StateManager: Checking local player state at: \(localPlayerStateURL.path)")

        do {
            let data = try Data(contentsOf: localPlayerStateURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let playerState = try decoder.decode(PlayerState.self, from: data)
            AppLog.info(.general, "📱 Loaded player state from local storage - track: \(playerState.currentTrackStableId ?? "nil"), time: \(playerState.playbackTime)")
            return playerState
        } catch {
            AppLog.warn(.general, "⚠️ Failed to load local player state: \(error)")
            return nil
        }
    }
}

// MARK: - 跨端续播（播放位置）：落点 + 捕获（2026-09-15）

/// 跨端续播**落点**：把对端播放位置写进本机 `QQPlayerState`（**只改 playbackTime 一个键**）。
///
/// 语义（用户 2026-09-14 拍板：功能默认关，开关在同步面板）：
/// - **同一首歌续播**：远端位置必须指向本机当前曲目（`currentTrackStableId` 相同）；
///   不是同一首 → 不动本地状态（返回 false → 账目按「未支持」披露，绝不虚报已应用）；
/// - LWW：远端 `updatedAtMs` 必须比本机 `lastSavedAt` 新；
/// - 位置差 < `minDeltaMs` 视为无意义 → 不写（避免抖动）；
/// - **绝不改 isPlaying**（保存态恒为 false = 启动不自动播放，既有不变量）。
enum PlaybackPositionResumeSink {
    /// 位置差小于该值视为无意义（毫秒）。
    static let minDeltaMs: Int64 = 3_000
    /// 播放状态在 UserDefaults 里的键（`PlayerEngine.savePlayerState` 写入）。
    static let playerStateKey = "QQPlayerState"

    /// 纯判定（可单测）：远端这条是否应落到本机状态。
    static func shouldApply(
        snapshot: SyncPlaybackPositionSnapshot,
        localTrackStableId: String?,
        localPositionMs: Int64,
        localSavedAtMs: Int64
    ) -> Bool {
        guard let localTrackStableId, localTrackStableId == snapshot.trackStableId else { return false }
        guard snapshot.updatedAtMs > localSavedAtMs else { return false }
        return abs(snapshot.positionMs - localPositionMs) >= minDeltaMs
    }

    /// 生产落点：读-改-写**单个键**（不重建整个字典，免得弄丢队列等其余字段）。
    @discardableResult
    static func apply(
        _ snapshot: SyncPlaybackPositionSnapshot,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard var state = defaults.dictionary(forKey: playerStateKey) else { return false }
        let localPositionMs = Int64(((state["playbackTime"] as? Double) ?? 0) * 1000)
        let localSavedAtMs = Int64(((state["lastSavedAt"] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
        guard shouldApply(
            snapshot: snapshot,
            localTrackStableId: state["currentTrackStableId"] as? String,
            localPositionMs: localPositionMs,
            localSavedAtMs: localSavedAtMs
        ) else { return false }
        state["playbackTime"] = Double(snapshot.positionMs) / 1000
        defaults.set(state, forKey: playerStateKey)
        AppLog.info(.general, "ℹ️ 跨端续播：已接受对端播放位置（同曲续播）")
        return true
    }
}

/// 跨端续播**捕获**：开关开时把本机播放位置**节流**记入 `sync_outbox`。
/// 开关关 = 零 DB 访问（`recordIfEnabled` 直接返回），关着时完全无副作用。
enum PlaybackPositionCapture {
    /// 同曲内的最小上报间隔（换歌一定上报）。
    static let minIntervalMs: Int64 = 60_000

    struct Sample: Equatable, Sendable {
        var trackStableId: String
        var positionMs: Int64
        var updatedAtMs: Int64
    }

    /// 纯判定（可单测）：这一次「保存播放状态」该不该记一条 outbox。
    /// - 换歌 → 记（续播最需要的就是“换到哪首”）
    /// - 同曲：距上次上报 ≥ `minIntervalMs` → 记；否则不记（定时器每 30s 一次，
    ///   不节流会写出大量同键行）
    static func shouldRecord(previous: Sample?, current: Sample) -> Bool {
        guard let previous else { return true }
        guard previous.trackStableId == current.trackStableId else { return true }
        return current.updatedAtMs - previous.updatedAtMs >= minIntervalMs
    }

    /// 节流状态（锁保护）。`static let` 只共享**不可变引用**，可变状态在类内用锁串行化
    /// （Swift 6 并发检查不允许裸的 nonisolated 可变全局状态）。
    private final class ThrottleState: @unchecked Sendable {
        private let lock = NSLock()
        private var lastSample: Sample?

        /// 判定并**就地**更新状态（同一把锁内完成，调用方不会看到中间态）。
        func shouldRecord(_ current: Sample) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let decision = PlaybackPositionCapture.shouldRecord(previous: lastSample, current: current)
            if decision { lastSample = current }
            return decision
        }

        func reset() {
            lock.lock()
            lastSample = nil
            lock.unlock()
        }
    }

    private static let throttle = ThrottleState()

    /// 测试用：清掉节流状态（避免用例间相互影响）。
    static func resetThrottleForTesting() {
        throttle.reset()
    }

    /// 生产入口（`PlayerEngine.savePlayerState` 末尾调用）。
    static func recordIfEnabled(trackStableId: String, positionMs: Int64, enabled: Bool) {
        guard enabled, !trackStableId.isEmpty else { return }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let sample = Sample(trackStableId: trackStableId, positionMs: positionMs, updatedAtMs: nowMs)
        guard throttle.shouldRecord(sample) else { return }

        let snapshot = SyncPlaybackPositionSnapshot(
            trackStableId: trackStableId,
            positionMs: positionMs,
            updatedAtMs: nowMs
        )
        // DB 写在后台队列：本方法在播放/定时器上下文（主线程）里调用，不在这里同步写盘。
        DispatchQueue.global(qos: .utility).async {
            do {
                let payloadJSON = try SyncSnapshotCodec.encode(snapshot)
                try SyncChangeLogStore(database: .shared).record(
                    entity: .playbackPosition,
                    rowKey: trackStableId,
                    op: .upsert,
                    payloadJSON: payloadJSON,
                    updatedAtMs: nowMs
                )
            } catch {
                AppLog.warn(.general, "⚠️ 跨端续播：播放位置上报失败 \(error)")
            }
        }
    }
}
