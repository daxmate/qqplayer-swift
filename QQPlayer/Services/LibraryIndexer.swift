//
//  LibraryIndexer.swift
//  QQPlayer
//
//  Indexes audio files (FLAC, MP3, WAV, AAC, Opus, Vorbis, DSD) in the iOS
//  sandbox Documents folder (M3-2: migrated off the iCloud ubiquity container)
//  or the macOS music folders, using FileManager directory scans.
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import GRDB
import SFBAudioEngine

@MainActor
class LibraryIndexer: NSObject, ObservableObject {
    static let shared = LibraryIndexer()

    @Published var isIndexing = false
    @Published var indexingProgress: Double = 0.0
    @Published var tracksFound = 0
    @Published var currentlyProcessing: String = ""
    @Published var queuedFiles: [String] = []
    private var hasPendingLibraryRefresh = false
    /// Bumped by stop(), so work deferred by an in-flight start() can tell that
    /// it belongs to a run that has since been cancelled.
    /// 分片：跨文件可见（原 private）
    var indexingGeneration = 0
    /// 在途扫描任务（start/startOfflineMode 注册，stop 取消）：generation 只让闭包
    /// 提前 return，任务组仍会等已入队文件跑完；cancel 才能让取消传播（审计 🔵-9）。
    /// 分片：跨文件可见（原 private(set)）
    var activeScanTask: Task<Void, Never>?

    // MARK: - 曲库索引终态（changeLog 同步前置门的事实位）

    /// **本启动**内一次完整主扫（含空库）是否已跑完。
    /// 分片：跨文件可见（原 private(set)）
    @Published var hasCompletedScanThisLaunch = false

    #if os(macOS)
        /// 云端（dataless）文件下载完成后自动补扫入列：60s 后重扫一轮，最多 5 轮。
        /// 原随 macOS 扫描段一起拆到 LibraryIndexer+Scanning.swift，但 stored property
        /// 不能放 extension → 留在主文件。
        /// 分片：跨文件可见（原 private）
        var macRescanRounds = 0
    #endif

    /// 曲库索引是否已到达终态（= 曲库行已由一次完整主扫建立）。
    ///
    /// 两个来源：① 本启动跑完过主扫（`hasCompletedScanThisLaunch`）；② `track` 表已有行
    /// （上次启动/上次安装的主扫确实落过库）。
    /// **fail-closed**：两个来源都不成立 → false。安装后第一次冷启动时 `track` 表还是空的
    /// （业务表仍在），此刻放行同步就会：把 outbox 行当悬空清掉、应答拉取的行全缺身份键。
    /// 注意不能只看 `isIndexing`：`.task` 里 `AppCoordinator.initialize()` 才起扫，
    /// 而同步可能**更早**（scenePhase → .active）就已经连上对端——那一瞬 `isIndexing` 仍是 false。
    var hasReachedIndexingTerminalState: Bool {
        if hasCompletedScanThisLaunch { return true }
        return libraryHasIndexedRows()
    }

    /// 终态事实**变化**信号（不携带值）：订阅方收到后重新走 `IndexingGate` 的唯一判定
    /// （本文件不复述判定，只报“变了”）。
    var indexingTerminalStatePublisher: AnyPublisher<Void, Never> {
        $hasCompletedScanThisLaunch.map { _ in () }.eraseToAnyPublisher()
    }

    /// `track` 表是否已有行。读失败按 false（fail-closed，宁可不放行）。
    private func libraryHasIndexedRows() -> Bool {
        let rows: Int? = try? databaseManager.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track") ?? 0
        }
        return (rows ?? 0) > 0
    }

    /// 分片：跨文件可见（原 private）
    let databaseManager: DatabaseManager
    /// 分片：跨文件可见（原 private）
    let stateManager = StateManager.shared

    /// 依赖注入缝（测试用）：指向内存库，避免用例写进真机 app 库。
    /// 生产恒走默认值 `.shared`，与 `DatabaseManager.init(dbWriter:)` 同一套路。
    init(databaseManager: DatabaseManager = .shared) {
        self.databaseManager = databaseManager
        super.init()
    }

    func start() {
        guard !isIndexing else { return }

        #if os(macOS)
            // macOS 数据源：FileManager 目录扫描（默认 ~/Music/QQPlayer）。
            // 2026-09-02：支持设置页「音乐库」添加的多个外部文件夹。
            // MVP 策略：启动全扫 + 手动刷新；FSEvents 实时监控后补（调研报告 §3.5 风险 2）。
            startMacScan()
        #else
            // iOS 数据源：FileManager 扫描沙盒 Documents（M3-2 切主扫，退役
            // NSMetadataQuery/iCloud ubiquity 路径）。启动全扫 + 手动刷新。
            isIndexing = true
            indexingProgress = 0.0
            tracksFound = 0

            let generation = indexingGeneration

            activeScanTask = Task {
                // 取消检查：stop() 已取消本轮 → 不再复制共享容器文件、不再起扫
                guard !Task.isCancelled else {
                    print("🛑 iOS scan cancelled - indexing was stopped")
                    return
                }

                // Copy any new files from share extension first
                await copyFilesFromSharedContainer()

                // stop() or switchToOfflineMode() may have run while the shared
                // container was being processed. Without this the scan would run
                // again just after being stopped.
                guard generation == indexingGeneration, isIndexing else {
                    print("🛑 iOS scan cancelled - indexing was stopped")
                    return
                }

                await scanLocalDocuments(generation: generation)
            }
        #endif
    }

    func startOfflineMode() {
        guard !isIndexing else { return }

        isIndexing = true
        indexingProgress = 0.0
        tracksFound = 0

        let generation = indexingGeneration
        activeScanTask = Task {
            await scanLocalDocuments(generation: generation)
        }
    }

    func stop() {
        indexingGeneration &+= 1
        isIndexing = false
        // 取消在途扫描：generation 只让任务组内的 guard 提前 return，任务组仍会
        // 等已入队文件跑完（审计 🔵-9）；cancel 让取消向子任务传播，配合扫描内
        // 的 Task.isCancelled 检查快速退出。
        activeScanTask?.cancel()
        activeScanTask = nil
    }

    func switchToOfflineMode() {
        print("🔄 Switching LibraryIndexer to offline mode")
        stop()
        startOfflineMode()
    }

    /// 分片：跨文件可见（原 private）
    nonisolated static func modificationTimestamp(_ date: Date?) -> Int64? {
        guard let date else { return nil }
        // Microseconds retain sub-second filesystem precision while remaining
        // stable when round-tripped through SQLite INTEGER.
        return Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    /// 分片：跨文件可见（原 private）
    nonisolated func fileFingerprint(for url: URL) throws -> FileFingerprint {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return FileFingerprint(
            modificationDate: Self.modificationTimestamp(values.contentModificationDate),
            fileSize: values.fileSize.map(Int64.init)
        )
    }

    /// 分片：跨文件可见（原 private）
    nonisolated func needsMetadataRefresh(_ track: Track, fingerprint: FileFingerprint) -> Bool {
        // Existing users have NULL here after the additive migration. Refresh
        // once so their metadata and fingerprint are brought up to date.
        guard let storedModificationDate = track.modificationDate else {
            return true
        }

        if let currentModificationDate = fingerprint.modificationDate,
           currentModificationDate != storedModificationDate {
            return true
        }

        if let currentFileSize = fingerprint.fileSize,
           currentFileSize != track.fileSize {
            return true
        }

        return false
    }

    /// 分片：跨文件可见（原 private）
    nonisolated func existingTrack(stableId: String, path: String) throws -> Track? {
        if let existing = try databaseManager.getTrack(byStableId: stableId) {
            return existing
        }

        guard var existing = try databaseManager.getTrack(byPath: path) else {
            return nil
        }

        print("🔁 Track already exists by path with old stable ID: \(existing.stableId)")
        try databaseManager.migrateTrackForMovedFile(oldStableId: existing.stableId, newPath: path)
        existing.stableId = stableId
        existing.path = path
        return existing
    }

    /// 分片：跨文件可见（原 private）
    nonisolated func saveParsedFile(
        _ parsedFile: ParsedAudioFile,
        replacing existingTrack: Track?,
        sourceDescription: String,
        notifyImmediately: Bool = false
    ) async throws {
        var track = parsedFile.track
        track.id = existingTrack?.id

        try databaseManager.upsertTrack(track)
        try databaseManager.setTrackArtists(
            trackStableId: track.stableId,
            artistIds: parsedFile.trackArtistIds
        )
        if let albumId = track.albumId {
            try databaseManager.setAlbumArtists(
                albumId: albumId,
                artistIds: parsedFile.albumArtistIds
            )
        }

        if let existingTrack {
            // Once a row has a fingerprint, a changed timestamp means cached
            // artwork may also be stale. Legacy rows are all refreshed once;
            // avoid synchronously re-extracting artwork for an entire large
            // upgraded library when no prior fingerprint can prove it changed.
            if existingTrack.modificationDate != nil {
                _ = await ArtworkManager.shared.forceRefreshArtwork(for: track)
            }
            print("🔄 Refreshed metadata for \(sourceDescription): \(track.title)")
            if notifyImmediately {
                // A changed album/artist can leave the old relationship empty.
                try databaseManager.cleanupOrphanedLibraryEntries()
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .libraryNeedsRefresh,
                        object: nil
                    )
                }
            } else {
                // Large upgraded libraries can refresh thousands of legacy
                // rows. Coalesce those UI reloads into one scan-end event.
                await MainActor.run { self.hasPendingLibraryRefresh = true }
            }
        } else {
            // Artwork is deliberately NOT extracted here. Decoding and
            // re-encoding every embedded cover inline made each file wait on a
            // full-resolution JPEG round trip, which dominated first-run scan
            // time. ArtworkManager.getArtwork/getThumbnail already extract and
            // fill the disk cache lazily the first time a row is displayed.
            let notificationTrack = track
            print("📢 Posting TrackFound notification for \(sourceDescription): \(notificationTrack.title)")
            await MainActor.run {
                self.tracksFound += 1
                NotificationCenter.default.post(
                    name: .trackFound,
                    object: notificationTrack
                )
            }
        }
    }

    /// 分片：跨文件可见（原 private）
    func postPendingLibraryRefresh() {
        guard hasPendingLibraryRefresh else { return }
        hasPendingLibraryRefresh = false
        do {
            // Run once for the whole scan instead of once per refreshed row.
            try databaseManager.cleanupOrphanedLibraryEntries()
        } catch {
            print("⚠️ Failed to clean orphaned metadata after refresh: \(error)")
        }
        NotificationCenter.default.post(
            name: .libraryNeedsRefresh,
            object: nil
        )
    }

    /// 旧 API：`Bool` 视图。语义 = `== .imported`（**只有新入库才是 true**），
    /// 与重构前的返回值逐分支一致，既有调用点行为零变化。
    /// 判定逻辑只在下面 `processExternalFileOutcome` 一处，本函数不得再长逻辑。
    @discardableResult
    func processExternalFile(_ fileURL: URL, allowExcludedReimport: Bool = false) async -> Bool {
        await processExternalFileOutcome(
            fileURL,
            allowExcludedReimport: allowExcludedReimport
        ) == .imported
    }

    /// 导入一个外部文件的**唯一入口**：返回穷尽的导入结果（见 `ExternalImportOutcome`）。
    @discardableResult
    func processExternalFileOutcome(
        _ fileURL: URL,
        allowExcludedReimport: Bool = false
    ) async -> ExternalImportOutcome {
        // Reject network URLs
        if let scheme = fileURL.scheme?.lowercased(), ["http", "https", "ftp", "sftp"].contains(scheme) {
            print("❌ Rejected network URL: \(fileURL.absoluteString)")
            return .failed(.unsupportedLocation)
        }

        do {
            print("🎵 Starting to process external file: \(fileURL.lastPathComponent)")
            print("📱 Processing external file from: \(fileURL.path)")

            print("🆔 Generating stable ID for: \(fileURL.lastPathComponent)")
            let stableId = try generateStableId(for: fileURL)
            print("🆔 Generated stable ID: \(stableId)")

            let fingerprint = try fileFingerprint(for: fileURL)
            let existingTrack = try existingTrack(stableId: stableId, path: fileURL.path)

            if let existingTrack, !needsMetadataRefresh(existingTrack, fingerprint: fingerprint) {
                print("⏭️ Track metadata is current: \(fileURL.lastPathComponent)")
                print("📍 Existing DB path: \(existingTrack.path)")
                if allowExcludedReimport && DeleteSettings.isTrackExcluded(stableId) {
                    DeleteSettings.removeExcludedTrack(stableId)
                    print("✅ Cleared exclusion for already-present track: \(fileURL.lastPathComponent)")
                }
                if allowExcludedReimport {
                    NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)
                }
                return .alreadyPresent
            }
            if existingTrack != nil {
                print("🔄 File changed; reparsing external metadata: \(fileURL.lastPathComponent)")
            }

            // Check if track was excluded (removed from library only)
            let isExcluded = DeleteSettings.isTrackExcluded(stableId)
            if isExcluded && !allowExcludedReimport {
                print("⏭️ Track excluded from library: \(fileURL.lastPathComponent)")
                return .excluded
            }
            if isExcluded && allowExcludedReimport {
                print("🔁 Re-importing excluded track by user request: \(fileURL.lastPathComponent)")
            }

            print("🎶 Parsing external audio file: \(fileURL.lastPathComponent)")
            let parsedFile = try await parseAudioFile(at: fileURL, stableId: stableId)
            print("✅ External audio file parsed successfully: \(parsedFile.track.title)")
            try await saveParsedFile(
                parsedFile,
                replacing: existingTrack,
                sourceDescription: "external file",
                notifyImmediately: true
            )

            // Remove only this track from exclusion after successful explicit re-import.
            if isExcluded && allowExcludedReimport {
                DeleteSettings.removeExcludedTrack(stableId)
                print("✅ Cleared exclusion for re-imported track: \(fileURL.lastPathComponent)")
            }

            // 指纹变了的老行重解析成功 = 「更新」，不是「已在库」也不是「新入库」。
            return existingTrack == nil ? .imported : .updatedExisting

        } catch LibraryIndexerError.parseTimeout {
            print("⏰ Timeout parsing external audio file: \(fileURL.lastPathComponent)")
            print("❌ Skipping external file due to parsing timeout")
            return .failed(.parseTimeout)
        } catch {
            print("❌ Failed to process external track at \(fileURL.lastPathComponent): \(error)")
            print("❌ Error type: \(type(of: error))")
            print("❌ Error details: \(String(describing: error))")
            return .failed(.processing)
        }
    }

    /// 分片：跨文件可见（原 private）
    func storeBookmarkPermanently(_ bookmarkData: Data, for url: URL) async {
        guard let store = ExternalFileBookmarkStore.default else {
            print("❌ Failed to resolve documents directory for bookmarks")
            return
        }

        do {
            // Generate stableId for this file
            let stableId = try generateStableId(for: url)

            // Store bookmark data using stableId as key (survives file moves)。
            // 经书签唯一入口写入：**原子写** —— 此前该写入是原地截断，进程被杀即
            // 整份书签 plist 不可解析 → 全部外部文件不再导入（审计 🔴-2）。
            try store.upsert(bookmarkData, forStableId: stableId)

            print("💾 Stored permanent bookmark for shared file: \(url.lastPathComponent) with stableId: \(stableId)")
        } catch {
            print("❌ Failed to store permanent bookmark for \(url.lastPathComponent): \(error)")
        }
    }

    /// 分片：跨文件可见（原 private）
    func processStoredExternalBookmarks() async {
        guard let store = ExternalFileBookmarkStore.default else {
            print("📁 No stored external bookmarks found")
            return
        }

        let bookmarks: [String: Data]
        switch store.load() {
        case .loaded(let loaded) where !loaded.isEmpty:
            bookmarks = loaded
        case .loaded:
            print("📁 No stored external bookmarks found")
            return
        case .unreadable(let error):
            // 读失败 ≠ 无书签：不拿空字典覆盖（还能救的书签会被抹掉），本轮跳过
            print("❌ Invalid external bookmarks format: \(error)")
            return
        }

        // 键改名先收集、结束时经唯一入口一次原子落盘
        var bookmarkKeyRemapping: [String: String] = [:]

        print("📁 Found \(bookmarks.count) stored external file bookmarks")

        for (stableId, bookmarkData) in Array(bookmarks) {
            do {
                // Resolve bookmark to get current file location
                var isStale = false
                let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)

                if isStale {
                    print("⚠️ Bookmark is stale for stableId: \(stableId)")
                    continue
                }

                // Reject network URLs
                if let scheme = resolvedURL.scheme?.lowercased(), ["http", "https", "ftp", "sftp"].contains(scheme) {
                    print("❌ Rejected network URL: \(resolvedURL.absoluteString)")
                    continue
                }

                let resolvedStableId = try generateStableId(for: resolvedURL)

                // Check if this file is in the database. Existing files
                // still flow through processExternalFile below so a
                // changed modification date can refresh their metadata.
                var trackAlreadyExists = false
                if let existingTrack = try databaseManager.getTrack(byStableId: stableId) {
                    trackAlreadyExists = true
                    // File exists in DB - check if path has changed
                    if existingTrack.path != resolvedURL.path {
                        print("📍 File moved detected! Old: \(existingTrack.path)")
                        print("📍 File moved detected! New: \(resolvedURL.path)")

                        try databaseManager.migrateTrackStableIdAndPath(
                            oldStableId: stableId,
                            newStableId: resolvedStableId,
                            newPath: resolvedURL.path
                        )
                        // 书签键改名由迁移唯一入口（TrackIdentityMigration）一并完成
                        print("✅ Updated database path for: \(resolvedURL.lastPathComponent)")
                    } else {
                        print("📍 External file path unchanged: \(resolvedURL.lastPathComponent)")
                    }
                } else if try databaseManager.getTrack(byStableId: resolvedStableId) != nil {
                    trackAlreadyExists = true
                    bookmarkKeyRemapping[stableId] = resolvedStableId
                    print("🔁 Updated stale bookmark key for existing track: \(resolvedURL.lastPathComponent)")
                }

                // Check if track was excluded (removed from library only)
                if !trackAlreadyExists &&
                    (DeleteSettings.isTrackExcluded(stableId) || DeleteSettings.isTrackExcluded(resolvedStableId)) {
                    print("⏭️ Track excluded from library: \(resolvedURL.lastPathComponent)")
                    continue
                }

                // File not in database yet - process it
                // Start accessing security-scoped resource
                guard resolvedURL.startAccessingSecurityScopedResource() else {
                    print("❌ Failed to access security-scoped resource for: \(resolvedURL.lastPathComponent)")
                    continue
                }

                defer {
                    resolvedURL.stopAccessingSecurityScopedResource()
                }

                // Import a new file or refresh an existing file whose
                // fingerprint changed.
                await processExternalFile(resolvedURL)
                print("✅ Processed stored external file: \(resolvedURL.lastPathComponent)")

            } catch {
                print("❌ Failed to resolve bookmark for stableId \(stableId): \(error)")
            }
        }

        if !bookmarkKeyRemapping.isEmpty {
            do {
                let renamed = try store.renameKeys(bookmarkKeyRemapping)
                print("✅ Updated \(renamed) external bookmark key(s) after stable ID migration")
            } catch {
                print("❌ Failed to update external bookmark keys: \(error)")
            }
        }
    }

    /// Resolve bookmark for a specific track and update database path if file moved
    func resolveBookmarkForTrack(_ track: Track) async -> URL? {
        guard let store = ExternalFileBookmarkStore.default else { return nil }

        let bookmarks: [String: Data]
        switch store.load() {
        case .loaded(let loaded):
            bookmarks = loaded
        case .unreadable(let error):
            print("⚠️ External bookmarks unreadable (treated as no bookmark): \(error)")
            return nil
        }

        guard let bookmarkData = bookmarks[track.stableId] else {
            return nil // No bookmark for this track
        }

        do {
            // Resolve bookmark to get current file location
            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)

            if isStale {
                print("⚠️ Bookmark is stale for: \(track.title)")
                return nil
            }

            // D5：文件移动 = stableId 变更（不变量 `stable_id == SHA256(标准化 path)`）。
            // 此前只改 path 不改 stable_id → 行内身份与实际路径错位，改名迁移/去重/
            // 内容指纹对账全部基于旧 id 追踪。改走完整迁移入口：stable_id + 四表引用
            // + 文件侧引用（书签键/歌词/封面）一次搬完。
            if track.path != resolvedURL.path {
                print("📍 Playback: File moved detected! Old: \(track.path)")
                print("📍 Playback: File moved detected! New: \(resolvedURL.path)")

                let migratedStableId = try databaseManager.migrateTrackForMovedFile(
                    oldStableId: track.stableId,
                    newPath: resolvedURL.path
                )
                print("✅ Updated database path for playback: \(resolvedURL.lastPathComponent) (stableId \(track.stableId) → \(migratedStableId ?? "no-op"))")
            }

            return resolvedURL

        } catch {
            print("❌ Failed to resolve bookmark for track \(track.title): \(error)")
            return nil
        }
    }
}
