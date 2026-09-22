//
//  AppCoordinator.swift
//  QQPlayer
//  Main app coordinator that manages all services
//  核心：状态属性/初始化流程/公开业务 API/播放入口。
//  拆分见 AppCoordinator+iCloud/ImportExport/Models/Siri.swift。
//

import Combine
import Foundation
import Observation
#if os(iOS)
    import Intents
#endif

@MainActor
@Observable
class AppCoordinator {
    static let shared = AppCoordinator()

    var isInitialized = false

    let databaseManager = DatabaseManager.shared
    let stateManager = StateManager.shared
    let libraryIndexer = LibraryIndexer.shared
    let playerEngine = PlayerEngine.shared
    let fileCleanupManager = FileCleanupManager.shared

    private var cancellables = Set<AnyCancellable>()

    /// 上次已同步到小组件的强调色 token（配色变更去重；见 `setupBindings`）。
    /// 设置事件是所有设置项共用的信号，而 `syncPlaylistsToCloud()` 会写盘——
    /// 只有 token 真的变了才做 widget 同步。
    private var lastSyncedAccentKey: String = ""

    private init() {
        setupBindings()
    }

    func initialize() async {
        AppLog.info(.general, "🚀 AppCoordinator.initialize() started")

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

        // 2026-09-22 曲库文件夹化：Documents 根下的规划类文件搬进
        // `Music/` `Lyrics/` `Artwork/` `Logs/`，并把 DB 里仍是绝对路径的曲目行改写成
        // 「相对 Music 根」的相对路径。**顺序在 SandboxMusicMigrator 之后、首次扫描之前**：
        // 前者可能往 Documents 根落文件，先跑完再搬才能一并收进 Music；扫描根已是
        // `Documents/Music`，所以必须搬完再扫（否则首启扫到空目录）。
        // 迁移器内部在后台串行队列上做文件/DB 动作（不阻塞主线程），幂等 + 完成门 +
        // 失败不删原件；`--library-layout-dry-run` 启动参数可先看清单再放手。
        // **仅 iOS**：这是 iOS 沙盒语义（曲库根 = `<Documents>/Music`）；macOS 曲库在
        // `~/Music/QQPlayer`，跑迁移器只会去动用户的 `~/Documents` ⇒ 迁移器与计划器
        // 都是 iOS-only（`// target: ios-only`），这里同样按平台收口。
        #if os(iOS)
            let layoutSummary = await Self.runLibraryLayoutMigration()
            if layoutSummary.alreadyCompleted {
                AppLog.info(.general, "📦 LibraryLayout: 已完成过（完成门置位，本轮跳过）")
            } else {
                AppLog.info(.general, "📦 LibraryLayout: \(layoutSummary.logLine)")
            }

            // 2026-09-22 隐藏布局（v2）：Documents 根部只留 `Music/` 可见，其余全部收进
            // `Documents/.qqplayer/`。**顺序在 v1 之后、首次扫描之前**（v1 建的那几个
            // 目录也在 v2 的搬迁范围内）；两道完成门独立。同样幂等 + 只搬不删 + 冲突不覆盖 +
            // 失败下次重试；`--hidden-layout-dry-run` 启动参数可先看清单再放手。
            // DB 三件套不归 v2，由 `DatabaseManager` 在打开连接之前搬（见其注释）。
            let hiddenSummary = await Self.runHiddenLayoutMigration()
            if hiddenSummary.alreadyCompleted {
                AppLog.info(.general, "🫥 HiddenLayout v2: 已完成过（完成门置位，本轮跳过）")
            } else {
                AppLog.info(.general, "🫥 HiddenLayout v2: \(hiddenSummary.logLine)")
            }
        #endif

        // Check if we should auto-scan based on last scan date
        var settings = DeleteSettings.load()
        AppLog.info(.general, "📅 Current lastLibraryScanDate: \(settings.lastLibraryScanDate?.description ?? "nil")")
        let shouldAutoScan = shouldPerformAutoScan(lastScanDate: settings.lastLibraryScanDate)

        if shouldAutoScan {
            AppLog.info(.general, "🔄 App launched after long time - starting automatic library scan")
        } else {
            AppLog.warn(.general, "⏭️ Recent app launch - skipping automatic scan (use manual sync button)")
        }

        // M3-2：退役 iCloud 状态机后本地沙盒是唯一数据源，不再区分 online/offline
        // 分支——统一走本地主扫（FileManager 扫沙盒 Documents）。
        if shouldAutoScan {
            await startLibraryIndexing()
            settings.lastLibraryScanDate = Date()
            settings.save()
        }

        // Restore UI state only to show user what was playing without interrupting other apps
        Task {
            await playerEngine.restoreUIStateOnly()
        }

        isInitialized = true
    }

    #if os(iOS)
        /// 跑一轮曲库文件夹化迁移，等它跑完（动作本身在迁移器的后台串行队列上）。
        /// iOS-only：见 `initialize()` 里那段注释。
        private static func runLibraryLayoutMigration() async -> LibraryLayoutMigrator.Summary {
            await withCheckedContinuation { continuation in
                LibraryLayoutMigrator.shared.runInBackground { summary in
                    continuation.resume(returning: summary)
                }
            }
        }

        /// 跑一轮隐藏布局迁移（v2），等它跑完（动作本身在迁移器的后台串行队列上）。
        private static func runHiddenLayoutMigration() async -> LibraryLayoutMigrationV2Migrator.Summary {
            await withCheckedContinuation { continuation in
                LibraryLayoutMigrationV2Migrator.shared.runInBackground { summary in
                    continuation.resume(returning: summary)
                }
            }
        }
    #endif

    private func shouldPerformAutoScan(lastScanDate: Date?) -> Bool {
        // If never scanned before, definitely scan
        guard let lastScanDate = lastScanDate else {
            AppLog.info(.general, "🆕 Never scanned before - will perform scan")
            return true
        }

        // Check if it's been more than 1 hour since last scan
        // This prevents scanning when app was just backgrounded/resumed
        let hoursSinceLastScan = Date().timeIntervalSince(lastScanDate) / 3600
        let shouldScan = hoursSinceLastScan >= 1.0

        if shouldScan {
            AppLog.info(.general, "⏰ Last scan was \(String(format: "%.1f", hoursSinceLastScan)) hours ago - will scan")
        } else {
            AppLog.warn(.general, "⏰ Last scan was \(String(format: "%.1f", hoursSinceLastScan)) hours ago - skipping")
        }

        return shouldScan
    }

    private func startLibraryIndexing() async {
        libraryIndexer.start()
    }

    private func setupBindings() {
        libraryIndexer.isIndexingPublisher
            .sink { [weak self] isIndexing in
                if !isIndexing {
                    Task { @MainActor in
                        await self?.onIndexingCompleted()
                    }
                }
            }
            .store(in: &cancellables)

        // 配色变更 → 刷新小组件主题（2026-09-17 事件层收口）：唯一信号 = `.qqplayerSettingsDidChange`
        // （`DeleteSettings.save()` 每次写入都发它）；旧 `.backgroundColorChanged` 已退役。
        lastSyncedAccentKey = IOSAppearance.currentAccentKey
        NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    let key = IOSAppearance.currentAccentKey
                    guard key != self.lastSyncedAccentKey else { return }
                    self.lastSyncedAccentKey = key
                    AppLog.info(.general, "🎨 强调色变更 (\(key)) - 刷新小组件主题")
                    // Update playlist widget colors
                    self.syncPlaylistsToCloud()
                    // Update now playing widget color
                    self.playerEngine.updateWidgetData()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Public API

    func getAllTracks() throws -> [Track] {
        return try databaseManager.getAllTracks()
    }

    func manualSync() async {
        AppLog.info(.general, "🔄 Manual sync triggered - attempting library indexing")

        // Check if we're already indexing
        if libraryIndexer.isIndexing {
            AppLog.warn(.general, "⚠️ Library indexing already in progress - skipping manual sync")
            return
        }

        // For manual sync, always attempt to re-index to catch new files
        AppLog.info(.general, "📋 Performing manual sync - user requested fresh library scan")
        await startLibraryIndexing()
    }

    func getAllAlbums() throws -> [Album] {
        return try databaseManager.getAllAlbums()
    }

    func toggleFavorite(trackStableId: String) throws {
        AppLog.info(.general, "🔄 Toggle favorite for track: \(trackStableId)")

        let wasLiked = try databaseManager.isFavorite(trackStableId: trackStableId)
        AppLog.info(.general, "📊 Track was liked before toggle: \(wasLiked)")

        if wasLiked {
            try databaseManager.removeFromFavorites(trackStableId: trackStableId)
            AppLog.error(.general, "❌ Removed from favorites: \(trackStableId)")
        } else {
            try databaseManager.addToFavorites(trackStableId: trackStableId)
            AppLog.info(.general, "❤️ Added to favorites: \(trackStableId)")
        }

        try favoriteDidChange(trackStableId: trackStableId)
    }

    /// 幂等设置收藏状态 —— 单曲/批量/Siri 共用的唯一入口（审计 B5 · 🔴-1）。
    /// 与 toggleFavorite 的区别：不是取反，而是「设为指定状态」；已是目标状态时不写库。
    /// - Returns: true 表示状态确实变了（写库 + 通知 + 持久化）。
    @discardableResult
    func setFavorite(trackStableId: String, isFavorite wanted: Bool) throws -> Bool {
        guard try isFavorite(trackStableId: trackStableId) != wanted else { return false }
        try toggleFavorite(trackStableId: trackStableId)
        return true
    }

    /// 批量幂等收藏 —— 「加入喜欢 / 移出喜欢」菜单项的唯一入口（审计 B5 · 🔴-1）。
    /// 文案即目标状态：目标为「已喜欢」时，已喜欢的曲目保持喜欢（绝不取反）。
    /// - Returns: 实际发生变更的曲目数。
    @discardableResult
    func setFavorites(trackStableIds: [String], isFavorite wanted: Bool) throws -> Int {
        guard !trackStableIds.isEmpty else { return 0 }

        let toChange = try FavoriteBatchLogic.stableIdsNeedingChange(
            trackStableIds,
            desired: wanted,
            isFavorite: { try self.isFavorite(trackStableId: $0) }
        )
        guard !toChange.isEmpty else {
            AppLog.info(.general, "❤️ Bulk favorite: nothing to change (\(trackStableIds.count) selected)")
            return 0
        }

        if wanted {
            try databaseManager.addToFavorites(trackStableIds: toChange)
        } else {
            for trackStableId in toChange {
                try databaseManager.removeFromFavorites(trackStableId: trackStableId)
            }
        }

        AppLog.info(.general, "❤️ Bulk favorite: \(toChange.count)/\(trackStableIds.count) changed → \(wanted ? "liked" : "unliked")")
        try favoriteDidChange(trackStableId: toChange.last)
        return toChange.count
    }

    /// 收藏变更后的统一收尾：通知观察者 + 持久化（本地 / iCloud）。
    /// toggle 与批量路径共用，避免两套副作用。
    private func favoriteDidChange(trackStableId: String?) throws {
        // Notify observers that favorites changed
        NotificationCenter.default.post(name: .favoritesChanged, object: nil)

        // Verify the database operation worked
        if let trackStableId {
            let isNowLiked = try databaseManager.isFavorite(trackStableId: trackStableId)
            AppLog.info(.general, "📊 Track is now liked after toggle: \(isNowLiked)")
        }

        // Get current favorites count from database
        let currentFavorites = try databaseManager.getFavorites()
        AppLog.info(.general, "📊 Total favorites in database after toggle: \(currentFavorites.count)")

        // Always save favorites (both locally and to iCloud if available)
        Task {
            do {
                let favorites = try databaseManager.getFavorites()
                AppLog.info(.general, "📊 Favorites to save: \(favorites.count) - \(favorites)")
                try stateManager.saveFavorites(favorites)
                AppLog.info(.general, "💾 Favorites saved: \(favorites.count) total")

                // Verify save worked by loading back
                let loadedFavorites = try stateManager.loadFavorites()
                AppLog.info(.general, "📊 Loaded favorites after save: \(loadedFavorites.count) - \(loadedFavorites)")
            } catch {
                AppLog.error(.general, "❌ Failed to save favorites: \(error)")
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
}
