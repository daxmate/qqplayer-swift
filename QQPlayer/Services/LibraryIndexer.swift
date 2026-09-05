//
//  LibraryIndexer.swift
//  QQPlayer
//
//  Indexes audio files (FLAC, MP3, WAV, AAC, Opus, Vorbis, DSD) in iCloud Drive using NSMetadataQuery
//

import AVFoundation
import CryptoKit
import Foundation
import SFBAudioEngine

enum LibraryIndexerError: Error {
    case parseTimeout
    case metadataParsingFailed
}

private struct ParsedAudioFile {
    let track: Track
    let trackArtistIds: [Int64]
    let albumArtistIds: [Int64]
}

private struct FileFingerprint {
    let modificationDate: Int64?
    let fileSize: Int64?
}

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
    private var indexingGeneration = 0

    private let metadataQuery = NSMetadataQuery()
    private let databaseManager = DatabaseManager.shared
    private let stateManager = StateManager.shared

    override init() {
        super.init()
        setupMetadataQuery()
    }

    private func setupMetadataQuery() {
        metadataQuery.delegate = self

        // The search scope is NOT resolved here. This runs from init(), which
        // happens on the main actor while the app launches, and asking
        // StateManager for the music folder forces the ubiquity container to
        // resolve - a call Apple documents as unsafe for the main thread.
        // start() narrows the scope later, off the main actor.
        metadataQuery.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]

        // Support all audio formats according to plan
        // （单一事实源 LibraryAudioFormats.allSupported；iOS 无文件类型设置 UI，
        // NSMetadataQuery predicate 只按支持全集收——设置只影响 macOS 目录扫描）
        let formats = LibraryAudioFormats.allSupported.map { "*." + $0 }
        let formatPredicates = formats.map { format in
            NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, format)
        }
        metadataQuery.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: formatPredicates)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidGatherInitialResults),
            name: NSNotification.Name.NSMetadataQueryDidFinishGathering,
            object: metadataQuery
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate),
            name: NSNotification.Name.NSMetadataQueryDidUpdate,
            object: metadataQuery
        )
    }

    func start() {
        guard !isIndexing else { return }

        #if os(macOS)
            // macOS 数据源：FileManager 目录扫描（默认 ~/Music/QQPlayer）。
            // 2026-09-02：支持设置页「音乐库」添加的多个外部文件夹。
            // MVP 策略：启动全扫 + 手动刷新；FSEvents 实时监控后补（调研报告 §3.5 风险 2）。
            startMacScan()
        #else
            // Attempt recovery from offline mode when manually syncing
            CloudDownloadManager.shared.attemptRecovery()

            isIndexing = true
            indexingProgress = 0.0
            tracksFound = 0

            // Copy any new files from share extension first
            Task {
                await copyFilesFromSharedContainer()
            }

            let generation = indexingGeneration

            Task {
                // Resolve the container off the main actor, then start the query
                // back on it - NSMetadataQuery needs a run loop. Both the resolve
                // and the diagnostic directory listing used to run inline here, on
                // the main thread, during launch.
                let musicFolderURL = await resolveMusicFolderURL()

                // stop() or switchToOfflineMode() may have run while the container
                // was resolving. Without this the query would be started again just
                // after being stopped, leaving an iCloud query alive in offline
                // mode and racing the local scan.
                guard generation == indexingGeneration, isIndexing else {
                    print("🛑 Metadata query start cancelled - indexing was stopped")
                    return
                }

                if let musicFolderURL {
                    metadataQuery.searchScopes = [musicFolderURL]
                }
                metadataQuery.start()

                // Add a timeout to trigger fallback if NSMetadataQuery doesn't work
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
                print("Timeout check: resultCount=\(metadataQuery.resultCount), isIndexing=\(isIndexing)")
                // The generation check matters as much as isIndexing here: a switch
                // to offline mode sets isIndexing back to true for its own scan, and
                // without this the fallback would run alongside it.
                guard generation == indexingGeneration else { return }
                if metadataQuery.resultCount == 0 && isIndexing {
                    print("NSMetadataQuery timeout - triggering fallback scan")
                    await fallbackToDirectScan()
                }
            }
        #endif
    }

    /// Reads the music folder URL away from the main actor, since the first
    /// call forces the ubiquity container to resolve.
    nonisolated private func resolveMusicFolderURL() async -> URL? {
        stateManager.getMusicFolderURL()
    }

    func startOfflineMode() {
        guard !isIndexing else { return }

        isIndexing = true
        indexingProgress = 0.0
        tracksFound = 0

        Task {
            await scanLocalDocuments()
        }
    }

    func stop() {
        indexingGeneration &+= 1
        metadataQuery.stop()
        isIndexing = false
    }

    func switchToOfflineMode() {
        print("🔄 Switching LibraryIndexer to offline mode")
        stop()
        startOfflineMode()
    }

    nonisolated private static func modificationTimestamp(_ date: Date?) -> Int64? {
        guard let date else { return nil }
        // Microseconds retain sub-second filesystem precision while remaining
        // stable when round-tripped through SQLite INTEGER.
        return Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    nonisolated private func fileFingerprint(for url: URL) throws -> FileFingerprint {
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return FileFingerprint(
            modificationDate: Self.modificationTimestamp(values.contentModificationDate),
            fileSize: values.fileSize.map(Int64.init)
        )
    }

    private func metadataFingerprint(for item: NSMetadataItem) -> FileFingerprint {
        let modificationDate = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
        let fileSize = (item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value
        return FileFingerprint(
            modificationDate: Self.modificationTimestamp(modificationDate),
            fileSize: fileSize
        )
    }

    nonisolated private func needsMetadataRefresh(_ track: Track, fingerprint: FileFingerprint) -> Bool {
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

    nonisolated private func existingTrack(stableId: String, path: String) throws -> Track? {
        if let existing = try databaseManager.getTrack(byStableId: stableId) {
            return existing
        }

        guard var existing = try databaseManager.getTrack(byPath: path) else {
            return nil
        }

        print("🔁 Track already exists by path with old stable ID: \(existing.stableId)")
        try databaseManager.migrateTrackStableIdAndPath(
            oldStableId: existing.stableId,
            newStableId: stableId,
            newPath: path
        )
        existing.stableId = stableId
        existing.path = path
        return existing
    }

    nonisolated private func saveParsedFile(
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
                        name: NSNotification.Name("LibraryNeedsRefresh"),
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
                    name: NSNotification.Name("TrackFound"),
                    object: notificationTrack
                )
            }
        }
    }

    private func postPendingLibraryRefresh() {
        guard hasPendingLibraryRefresh else { return }
        hasPendingLibraryRefresh = false
        do {
            // Run once for the whole scan instead of once per refreshed row.
            try databaseManager.cleanupOrphanedLibraryEntries()
        } catch {
            print("⚠️ Failed to clean orphaned metadata after refresh: \(error)")
        }
        NotificationCenter.default.post(
            name: NSNotification.Name("LibraryNeedsRefresh"),
            object: nil
        )
    }

    @discardableResult
    func processExternalFile(_ fileURL: URL, allowExcludedReimport: Bool = false) async -> Bool {
        // Reject network URLs
        if let scheme = fileURL.scheme?.lowercased(), ["http", "https", "ftp", "sftp"].contains(scheme) {
            print("❌ Rejected network URL: \(fileURL.absoluteString)")
            return false
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
                    NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
                }
                return false
            }
            if existingTrack != nil {
                print("🔄 File changed; reparsing external metadata: \(fileURL.lastPathComponent)")
            }

            // Check if track was excluded (removed from library only)
            let isExcluded = DeleteSettings.isTrackExcluded(stableId)
            if isExcluded && !allowExcludedReimport {
                print("⏭️ Track excluded from library: \(fileURL.lastPathComponent)")
                return false
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

            return existingTrack == nil

        } catch LibraryIndexerError.parseTimeout {
            print("⏰ Timeout parsing external audio file: \(fileURL.lastPathComponent)")
            print("❌ Skipping external file due to parsing timeout")
            return false
        } catch {
            print("❌ Failed to process external track at \(fileURL.lastPathComponent): \(error)")
            print("❌ Error type: \(type(of: error))")
            print("❌ Error details: \(String(describing: error))")
            return false
        }
    }

    @objc private func queryDidGatherInitialResults() {
        print("🔍 NSMetadataQuery gathered initial results: \(metadataQuery.resultCount) items")
        for i in 0 ..< metadataQuery.resultCount {
            if let item = metadataQuery.result(at: i) as? NSMetadataItem,
               let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL {
                print("  Found: \(url.lastPathComponent)")
            }
        }
        Task {
            await processQueryResults()
        }
    }

    @objc private func queryDidUpdate() {
        Task {
            await processQueryResults()
        }
    }

    private func processQueryResults() async {
        // Capture the generation this run belongs to. stop() bumps it, so a
        // scan superseded by switchToOfflineMode() (or another stop) must not
        // touch shared state afterwards - in particular it must not flip
        // isIndexing back to false and hide the offline scan.
        let generation = indexingGeneration
        guard generation == indexingGeneration else { return }

        metadataQuery.disableUpdates()
        defer { metadataQuery.enableUpdates() }

        let itemCount = metadataQuery.resultCount

        if itemCount == 0 {
            // Only the current scan may start the fallback; a query stopped by
            // switchToOfflineMode() must not run a full direct scan alongside
            // the offline scan.
            guard generation == indexingGeneration else { return }
            print("NSMetadataQuery found 0 results, falling back to direct file system scan")
            await fallbackToDirectScan()
            return
        }

        var processedCount = 0

        for i in 0 ..< itemCount {
            // Bail out of a superseded scan instead of letting it run to
            // completion: the new scan owns isIndexing from here on.
            guard generation == indexingGeneration else { return }
            guard let item = metadataQuery.result(at: i) as? NSMetadataItem else { continue }

            await processMetadataItem(item)

            processedCount += 1
            // Throttle progress updates and yield so the UI stays responsive
            // during large imports
            if processedCount % 10 == 0 || processedCount == itemCount {
                indexingProgress = Double(processedCount) / Double(itemCount)
            }
            await Task.yield()
        }

        // The query completed successfully, so it is safe to reconcile only
        // the iCloud root it actually scanned. Never infer deletion from a
        // failed or unavailable root. Only a current scan may finalize.
        guard generation == indexingGeneration else { return }
        if AppCoordinator.shared.iCloudStatus == .available,
           let musicFolderURL = stateManager.getMusicFolderURL() {
            await FileCleanupManager.shared.reconcileMissingFiles(in: [musicFolderURL])
        }
        postPendingLibraryRefresh()

        isIndexing = false
        print("Library indexing completed. Found \(tracksFound) tracks.")
    }

    private func fallbackToDirectScan() async {
        // Same generation guard as processQueryResults(): if this scan was
        // superseded while it was being dispatched, do nothing.
        let generation = indexingGeneration
        guard generation == indexingGeneration else { return }

        print("🔄 Starting fallback direct scan of both iCloud and local folders")

        var allMusicFiles: [URL] = []
        var successfullyScannedRoots: [URL] = []

        // First, copy any new files from shared container to Documents
        await copyFilesFromSharedContainer()

        // Scan iCloud folder if available
        if let iCloudMusicFolderURL = stateManager.getMusicFolderURL() {
            print("📁 Scanning iCloud folder: \(iCloudMusicFolderURL.path)")
            do {
                let iCloudFiles = try await findMusicFiles(in: iCloudMusicFolderURL)
                print("📁 Found \(iCloudFiles.count) files in iCloud folder")
                allMusicFiles.append(contentsOf: iCloudFiles)
                if AppCoordinator.shared.iCloudStatus == .available {
                    successfullyScannedRoots.append(iCloudMusicFolderURL)
                }
            } catch {
                print("⚠️ Failed to scan iCloud folder: \(error)")
            }
        }

        // Scan local Documents folder
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        print("📱 Scanning local Documents folder: \(documentsPath.path)")
        do {
            let localFiles = try await findMusicFiles(in: documentsPath)
            print("📱 Found \(localFiles.count) files in local Documents folder")
            for file in localFiles {
                print("  📄 Local file: \(file.lastPathComponent)")
            }
            allMusicFiles.append(contentsOf: localFiles)
            successfullyScannedRoots.append(documentsPath)
        } catch {
            print("⚠️ Failed to scan local Documents folder: \(error)")
        }

        let totalFiles = allMusicFiles.count
        print("📁 Total music files found (iCloud + local): \(totalFiles)")

        guard totalFiles > 0 else {
            // Only a current scan may finalize; a superseded one must not
            // touch isIndexing or schedule a library refresh.
            guard generation == indexingGeneration else { return }
            // An empty, successfully enumerated root is meaningful: all of
            // its former tracks may have been deleted.
            await FileCleanupManager.shared.reconcileMissingFiles(in: successfullyScannedRoots)
            postPendingLibraryRefresh()
            isIndexing = false
            print("❌ No music files found in any location")
            return
        }

        // Set initial queue. Guard again so a superseded scan does not
        // overwrite the queue a newer scan is showing.
        guard generation == indexingGeneration else { return }
        await MainActor.run {
            queuedFiles = allMusicFiles.map { $0.lastPathComponent }
            currentlyProcessing = ""
        }

        let allFileNames = allMusicFiles.map { $0.lastPathComponent }

        // Parse and persist with bounded concurrency. Each file's work runs off
        // the main actor, so metadata reads and the per-track SQLite writes no
        // longer serialize behind (and block) UI work - previously a 90-file
        // first run spent ~20s with the main thread pinned. The cap keeps
        // memory and the single GRDB writer from being swamped.
        let maxConcurrentFiles = 4
        var completedCount = 0
        var nextIndex = 0

        await withTaskGroup(of: Void.self) { group in
            while nextIndex < min(maxConcurrentFiles, totalFiles) {
                let url = allMusicFiles[nextIndex]
                group.addTask { [weak self] in await self?.indexFile(url) }
                nextIndex += 1
            }

            while await group.next() != nil {
                completedCount += 1

                // Stop feeding a superseded scan; remaining in-flight files
                // drain harmlessly and the finalization guard below skips all
                // state changes.
                guard generation == indexingGeneration else { return }

                // Throttle @Published updates: rebuilding the 2000-element
                // queuedFiles array per file made SwiftUI re-diff the whole list
                // for every import - a major cause of freezes on large libraries
                if completedCount % 20 == 0 || completedCount == totalFiles {
                    currentlyProcessing = allFileNames[min(completedCount, totalFiles - 1)]
                    queuedFiles = Array(allFileNames.suffix(from: min(completedCount, totalFiles)))
                    indexingProgress = Double(completedCount) / Double(totalFiles)
                }

                if nextIndex < totalFiles {
                    let url = allMusicFiles[nextIndex]
                    group.addTask { [weak self] in await self?.indexFile(url) }
                    nextIndex += 1
                }
            }
        }

        // Clear processing state when done
        await MainActor.run {
            currentlyProcessing = ""
            queuedFiles = []
        }

        // Only a current scan may finalize: a stale one must not set
        // isIndexing = false over an offline scan nor reconcile files it no
        // longer owns.
        guard generation == indexingGeneration else { return }
        await FileCleanupManager.shared.reconcileMissingFiles(in: successfullyScannedRoots)
        postPendingLibraryRefresh()

        isIndexing = false
        print("✅ Direct scan completed. Found \(tracksFound) tracks from both iCloud and local folders.")

        // Process folder playlists after scan completion
        await processFolderPlaylists(allMusicFiles: allMusicFiles)
    }

    private func processFolderPlaylists(allMusicFiles: [URL]) async {
        guard DeleteSettings.load().autoCreateFolderPlaylists else {
            print("📁 Folder playlist auto-creation disabled in settings - skipping")
            return
        }
        print("📁 Processing folder playlists...")

        // Group music files by their parent directory
        var folderGroups: [String: [URL]] = [:]

        for fileURL in allMusicFiles {
            let parentFolder = fileURL.deletingLastPathComponent()
            let folderPath = parentFolder.path

            // Skip if it's directly in Documents or iCloud root
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path
            let iCloudMusicPath = stateManager.getMusicFolderURL()?.path

            if folderPath == documentsPath || folderPath == iCloudMusicPath {
                continue
            }

            if folderGroups[folderPath] == nil {
                folderGroups[folderPath] = []
            }
            folderGroups[folderPath]?.append(fileURL)
        }

        print("📁 Found \(folderGroups.count) folders with music files")

        for (folderPath, musicFiles) in folderGroups {
            await processFolderPlaylist(folderPath: folderPath, musicFiles: musicFiles)
        }

        print("✅ Folder playlist processing completed")
    }

    private func processFolderPlaylist(folderPath: String, musicFiles: [URL]) async {
        let folderURL = URL(fileURLWithPath: folderPath)
        let folderName = folderURL.lastPathComponent

        print("📂 Processing folder playlist for: \(folderName)")

        do {
            // Generate stable IDs for all music files in this folder
            var trackStableIds: [String] = []

            for musicFile in musicFiles {
                let stableId = try generateStableId(for: musicFile)
                trackStableIds.append(stableId)
            }

            print("🎵 Found \(trackStableIds.count) tracks in folder: \(folderName)")

            // Check if a folder playlist already exists for this path
            if let existingPlaylist = try databaseManager.getFolderPlaylist(forPath: folderPath) {
                print("🔄 Syncing existing folder playlist: \(existingPlaylist.title)")

                // The DB primary key should never be nil here, but a nil row
                // must not crash the folder-sync hot path (audit: force unwrap)
                guard let playlistId = existingPlaylist.id else {
                    print("❌ Skipping folder playlist sync - existing playlist has no id: \(existingPlaylist.title)")
                    return
                }
                try databaseManager.syncPlaylistWithFolder(playlistId: playlistId, trackStableIds: trackStableIds)
                print("✅ Synced playlist '\(existingPlaylist.title)' with folder contents")
            } else {
                // Create new folder playlist
                print("➕ Creating new folder playlist: \(folderName)")

                let playlist = try databaseManager.createFolderPlaylist(title: folderName, folderPath: folderPath)
                guard let playlistId = playlist.id else {
                    print("❌ Skipping folder playlist sync - created playlist has no id: \(playlist.title)")
                    return
                }
                try databaseManager.syncPlaylistWithFolder(playlistId: playlistId, trackStableIds: trackStableIds)
                print("✅ Created folder playlist '\(playlist.title)' with \(trackStableIds.count) tracks")
            }

        } catch {
            print("❌ Failed to process folder playlist for \(folderName): \(error)")
        }
    }

    private func scanLocalDocuments() async {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

        do {
            let musicFiles = try await findMusicFiles(in: documentsPath)

            let totalFiles = musicFiles.count

            // Same bounded-concurrency treatment as the iCloud fallback scan so
            // offline first runs don't serialize every file behind the main actor.
            let maxConcurrentFiles = 4
            var processedFiles = 0
            var nextIndex = 0

            await withTaskGroup(of: Void.self) { group in
                while nextIndex < min(maxConcurrentFiles, totalFiles) {
                    let url = musicFiles[nextIndex]
                    group.addTask { [weak self] in await self?.indexFile(url) }
                    nextIndex += 1
                }

                while await group.next() != nil {
                    processedFiles += 1
                    if processedFiles % 10 == 0 || processedFiles == totalFiles {
                        indexingProgress = Double(processedFiles) / Double(totalFiles)
                    }

                    if nextIndex < totalFiles {
                        let url = musicFiles[nextIndex]
                        group.addTask { [weak self] in await self?.indexFile(url) }
                        nextIndex += 1
                    }
                }
            }

            await FileCleanupManager.shared.reconcileMissingFiles(in: [documentsPath])
            postPendingLibraryRefresh()

            await MainActor.run {
                isIndexing = false
                print("Offline library scan completed. Found \(tracksFound) tracks.")
            }

            // Process folder playlists after offline scan
            await processFolderPlaylists(allMusicFiles: musicFiles)
        } catch {
            await MainActor.run {
                isIndexing = false
                print("Offline library scan failed: \(error)")
            }
        }
    }

    #if os(macOS)
        /// macOS 数据源：FileManager 目录扫描音乐文件夹（默认 ~/Music/QQPlayer）。
        /// 复用 iOS 的 findMusicFiles/indexFile/processFolderPlaylists 逻辑，
        /// 仅替换数据源（NSMetadataQuery → 目录枚举）。MVP 为启动全扫，
        /// FSEvents 实时监控后补（调研报告 §3.5 风险 2）。
        private func startMacScan() {
            // 决策上收：是否启动扫描由 MacIndexingGate.shouldBeginScan 决定（有单测锁定）。
            // 必须与 iOS 分支保持同一套状态前置：isIndexing 置 true 才能通过
            // scanMusicFolder 首行的 guard（否则扫描被直接拦截、永远不会执行）。
            guard MacIndexingGate.shouldBeginScan(currentlyIndexing: isIndexing) else { return }

            isIndexing = true
            indexingProgress = 0.0
            tracksFound = 0

            let generation = indexingGeneration
            Task {
                await scanMusicFolder(generation: generation)
            }
        }

        /// 云端（dataless）文件下载完成后自动补扫入列：60s 后重扫一轮，最多 5 轮。
        private var macRescanRounds = 0

        private func autoscheduleRescan(skippedDataless: Int) {
            guard skippedDataless > 0, macRescanRounds < 5 else { return }
            macRescanRounds += 1
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 60_000_000_000) // 60s
                guard !isIndexing else { return }
                MacScanLogger.log("autoschedule rescan (round \(macRescanRounds))")
                start()
            }
        }

        private func scanMusicFolder(generation: Int) async {
            // 决策上收：首行 guard 语义与 MacIndexingGate.canProceedScan 一致（有单测锁定）。
            guard MacIndexingGate.canProceedScan(
                generationMatches: generation == indexingGeneration,
                isIndexing: isIndexing
            ) else { return }

            // 多文件夹曲库：收集所有配置文件夹的音乐文件（去重后统一进度）
            let folders = stateManager.getMusicFolderURLs()
            print("📁 macOS scanning folders: \(folders.map(\.path))")
            MacScanLogger.log("scan start, folders: \(folders.map(\.path))")

            do {
                var musicFiles: [URL] = []
                var seen = Set<String>()
                for folder in folders {
                    let files = try await findMusicFiles(in: folder)
                    MacScanLogger.log("folder \(folder.path): \(files.count) files")
                    for file in files where !seen.contains(file.path) {
                        seen.insert(file.path)
                        musicFiles.append(file)
                    }
                }
                let totalFiles = musicFiles.count
                print("📁 macOS found \(totalFiles) music files")
                MacScanLogger.log("total files: \(totalFiles)")

                // iCloud Drive dataless（云端未下载）本轮不 parse：无 iCloud
                // entitlement 时 startDownloadingUbiquitousItem 无效（2026-09-02
                // 实测），等待会让索引卡死。只索引已本地化文件；云端文件由用户
                // 在 Finder 下载（或 entitlement 就绪）后自动补入（scan 尾部调度）。
                let (localFiles, skippedDataless) = await Task.detached {
                    await Self.partitionLocalFiles(musicFiles)
                }.value
                musicFiles = localFiles
                if skippedDataless > 0 {
                    MacScanLogger.log("skipped dataless (cloud not downloaded): \(skippedDataless)")
                    print("⏭️ Skipping \(skippedDataless) dataless iCloud files (not downloaded locally)")
                }

                guard !musicFiles.isEmpty else {
                    // 全为云端未下载：不 reconcile（避免误删本地入列曲目）
                    guard generation == indexingGeneration else { return }
                    isIndexing = false
                    print("❌ All \(skippedDataless) files are dataless; nothing to index this round")
                    autoscheduleRescan(skippedDataless: skippedDataless)
                    return
                }

                await MainActor.run {
                    queuedFiles = musicFiles.map { $0.lastPathComponent }
                    currentlyProcessing = ""
                }

                let allFileNames = musicFiles.map { $0.lastPathComponent }
                // 进度以分区后实际处理数为准：totalFiles 是全量（含 dataless），
                // 用它做 musicFiles 下标会数组越界 fatal error——2026-09-02
                // 主线程卡死根因（sample 定位 Array.subscript → assertionFailure）
                let processTotal = musicFiles.count
                let maxConcurrentFiles = 6
                var completedCount = 0
                var nextIndex = 0

                await withTaskGroup(of: Void.self) { group in
                    while nextIndex < min(maxConcurrentFiles, processTotal) {
                        let url = musicFiles[nextIndex]
                        group.addTask { [weak self] in await self?.indexFile(url) }
                        nextIndex += 1
                    }

                    while await group.next() != nil {
                        completedCount += 1

                        guard generation == indexingGeneration else { return }

                        if completedCount % 20 == 0 || completedCount == processTotal {
                            currentlyProcessing = allFileNames[min(completedCount, processTotal - 1)]
                            queuedFiles = Array(allFileNames.suffix(from: min(completedCount, processTotal)))
                            indexingProgress = Double(completedCount) / Double(processTotal)
                        }

                        if nextIndex < processTotal {
                            let url = musicFiles[nextIndex]
                            group.addTask { [weak self] in await self?.indexFile(url) }
                            nextIndex += 1
                        }
                    }
                }

                await MainActor.run {
                    currentlyProcessing = ""
                    queuedFiles = []
                }

                guard generation == indexingGeneration else { return }
                await FileCleanupManager.shared.reconcileMissingFiles(in: folders)
                postPendingLibraryRefresh()

                isIndexing = false
                print("✅ macOS scan completed. Found \(tracksFound) tracks.")
                MacScanLogger.log("scan completed, tracksFound: \(tracksFound), skippedDataless: \(skippedDataless)")

                // 云端文件下载完成后自动补扫入列（60s 后重扫，最多 5 轮）
                autoscheduleRescan(skippedDataless: skippedDataless)

                await processFolderPlaylists(allMusicFiles: musicFiles)
            } catch {
                print("❌ macOS scan failed: \(error)")
                MacScanLogger.log("scan failed: \(error)")
                isIndexing = false
            }
        }
    #endif

    /// macOS：分区本地已实体化文件与 iCloud dataless（云端未下载）文件。
    /// 返回 (本地文件, dataless 数)。无 iCloud entitlement 时无法主动触发
    /// 下载（2026-09-02 实测 startDownloadingUbiquitousItem 无效），dataless
    /// 文件只跳过不等待，下载完成后由 autoscheduleRescan 补扫入列。
    nonisolated private static func partitionLocalFiles(_ files: [URL]) async -> ([URL], Int) {
        var local: [URL] = []
        var dataless = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if values?.isUbiquitousItem == true {
                if let status = values?.ubiquitousItemDownloadingStatus,
                   status == .downloaded || status == .current {
                    local.append(file)
                } else {
                    dataless += 1
                }
            } else {
                local.append(file)
            }
        }
        return (local, dataless)
    }

    private func findMusicFiles(in directory: URL) async throws -> [URL] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    var musicFiles: [URL] = []

                    // 文件类型设置（web 版 audioExts 对齐）：扫描只收录启用格式。
                    // 默认全 9 种 = 历史行为；取消格式后此列表不含该格式 → 该格式
                    // 文件不再入列，已入库曲目由 reconcile 收尾移除（2026-09-03 B 组）。
                    let settings = DeleteSettings.load()
                    let enabledExtensions = settings.audioExtensions.isEmpty
                        ? LibraryAudioFormats.defaultEnabled
                        : settings.audioExtensions

                    let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .nameKey]
                    let directoryEnumerator = FileManager.default.enumerator(
                        at: directory,
                        includingPropertiesForKeys: resourceKeys,
                        options: [.skipsHiddenFiles]
                    )

                    guard let enumerator = directoryEnumerator else {
                        continuation.resume(returning: musicFiles)
                        return
                    }

                    for case let fileURL as URL in enumerator {
                        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))

                        guard let isRegularFile = resourceValues.isRegularFile, isRegularFile else {
                            continue
                        }

                        let pathExtension = fileURL.pathExtension.lowercased()
                        if enabledExtensions.contains(pathExtension) {
                            musicFiles.append(fileURL)
                        }
                    }

                    continuation.resume(returning: musicFiles)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// One unit of scan work, safe to run concurrently off the main actor.
    /// The iCloud status is re-read per file rather than snapshotted so a
    /// mid-scan auth failure still halts further iCloud reads.
    nonisolated private func indexFile(_ fileURL: URL) async {
        #if os(macOS)
            // macOS：用户添加的文件夹（含 iCloud Drive 路径）一律按本地文件处理——
            // Mobile Documents 判断是 iOS 容器语义；Mac 的 iCloud Drive 在本地
            // 文件系统直接可读，无鉴权/下载门（2026-09-02 用户添加 iOS 版 iCloud
            // 曲库全被跳过的根因）。
            await processLocalFile(fileURL)
        #else
            let isLocalFile = !fileURL.path.contains("Mobile Documents")

            if !isLocalFile {
                let status = await AppCoordinator.shared.iCloudStatus
                let isAvailable = await AppCoordinator.shared.isiCloudAvailable
                if status == .authenticationRequired || !isAvailable {
                    print("🚫 Skipping iCloud file processing - iCloud authentication required: \(fileURL.lastPathComponent)")
                    return
                }
            }

            await processLocalFile(fileURL)
        #endif
    }

    nonisolated private func processLocalFile(_ fileURL: URL) async {
        do {
            print("🎵 Starting to process file: \(fileURL.lastPathComponent)")

            #if os(macOS)
                // macOS 本地文件：dataless 已在 scanMusicFolder 分区时过滤，
                // 此处全是本地已实体化文件，无 iCloud 下载步骤
                print("📱 Processing local file (macOS): \(fileURL.lastPathComponent)")
            #else
                let isLocalFile = !fileURL.path.contains("Mobile Documents")

                // Only try to download from iCloud if it's actually an iCloud file
                if !isLocalFile {
                    do {
                        try await CloudDownloadManager.shared.ensureLocal(fileURL)
                        print("✅ iCloud file ensured local: \(fileURL.lastPathComponent)")
                    } catch {
                        print("⚠️ Failed to ensure iCloud file is local: \(fileURL.lastPathComponent) - \(error)")

                        // Check for authentication errors
                        if let cloudError = error as? CloudDownloadError {
                            switch cloudError {
                            case .authenticationRequired, .accessDenied:
                                print("🔐 Authentication error in LibraryIndexer - switching to offline mode")
                                await AppCoordinator.shared.handleiCloudAuthenticationError()
                                return // Skip this file
                            default:
                                break
                            }
                        }

                        // Continue processing even if download fails (for other errors)
                    }
                } else {
                    print("📱 Processing local file (no iCloud download needed): \(fileURL.lastPathComponent)")
                }
            #endif

            print("🆔 Generating stable ID for: \(fileURL.lastPathComponent)")
            let stableId = try generateStableId(for: fileURL)
            print("🆔 Generated stable ID: \(stableId)")

            let fingerprint = try fileFingerprint(for: fileURL)
            let existingTrack = try existingTrack(stableId: stableId, path: fileURL.path)

            if let existingTrack, !needsMetadataRefresh(existingTrack, fingerprint: fingerprint) {
                print("⏭️ Track metadata is current: \(fileURL.lastPathComponent)")
                return
            }
            if existingTrack != nil {
                print("🔄 File changed; reparsing metadata: \(fileURL.lastPathComponent)")
            }

            // Check if track was excluded (removed from library only)
            if DeleteSettings.isTrackExcluded(stableId) {
                print("⏭️ Track excluded from library: \(fileURL.lastPathComponent)")
                return
            }

            print("🎶 Parsing audio file: \(fileURL.lastPathComponent)")
            let parsedFile = try await parseAudioFile(at: fileURL, stableId: stableId)
            print("✅ Audio file parsed successfully: \(parsedFile.track.title)")
            try await saveParsedFile(
                parsedFile,
                replacing: existingTrack,
                sourceDescription: "file"
            )

            // Check if file is downloaded (for iCloud files)
            await checkDownloadStatus(for: fileURL)

        } catch LibraryIndexerError.parseTimeout {
            print("⏰ Timeout parsing audio file: \(fileURL.lastPathComponent)")
            print("❌ Skipping file due to parsing timeout")
        } catch {
            print("❌ Failed to process local track at \(fileURL.lastPathComponent): \(error)")
            print("❌ Error type: \(type(of: error))")
            print("❌ Error details: \(String(describing: error))")
        }
    }

    nonisolated private func checkDownloadStatus(for fileURL: URL) async {
        do {
            let resourceValues = try fileURL.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey])

            if let isUbiquitous = resourceValues.isUbiquitousItem, isUbiquitous {
                if let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus {
                    switch downloadStatus {
                    case .notDownloaded:
                        print("File not downloaded: \(fileURL.lastPathComponent)")
                        // Trigger download
                        try FileManager.default.startDownloadingUbiquitousItem(at: fileURL)
                    case .downloaded:
                        print("File is downloaded: \(fileURL.lastPathComponent)")
                    case .current:
                        print("File is current: \(fileURL.lastPathComponent)")
                    default:
                        print("Unknown download status for: \(fileURL.lastPathComponent)")
                    }
                }
            }
        } catch {
            print("Failed to check download status for \(fileURL.lastPathComponent): \(error)")
        }
    }

    private func processMetadataItem(_ item: NSMetadataItem) async {
        guard let fileURL = item.value(forAttribute: NSMetadataItemURLKey) as? URL else { return }
        let ext = fileURL.pathExtension.lowercased()
        // iOS 侧：无文件类型设置 UI，按支持全集过滤（与 NSMetadataQuery predicate
        // 同一事实源 LibraryAudioFormats.allSupported）
        guard LibraryAudioFormats.allSupported.contains(ext) else { return }

        do {
            let stableId = try generateStableId(for: fileURL)
            let fingerprint = metadataFingerprint(for: item)
            let existingTrack = try existingTrack(stableId: stableId, path: fileURL.path)

            if let existingTrack, !needsMetadataRefresh(existingTrack, fingerprint: fingerprint) {
                return
            }
            if existingTrack != nil {
                print("🔄 iCloud file changed; reparsing metadata: \(fileURL.lastPathComponent)")
            }

            if DeleteSettings.isTrackExcluded(stableId) {
                return
            }

            try await CloudDownloadManager.shared.ensureLocal(fileURL)

            let parsedFile = try await parseAudioFile(at: fileURL, stableId: stableId)
            try await saveParsedFile(
                parsedFile,
                replacing: existingTrack,
                sourceDescription: "iCloud file"
            )

            // Check if file is downloaded (for iCloud files)
            await checkDownloadStatus(for: fileURL)

        } catch {
            print("Failed to process track at \(fileURL): \(error)")
        }
    }

    nonisolated func generateStableId(for url: URL) throws -> String {
        DatabaseManager.generatePathStableId(forPath: url.path)
    }

    nonisolated private func parseAudioFile(at url: URL, stableId: String) async throws -> ParsedAudioFile {
        print("🔍 Calling AudioMetadataParser for: \(url.lastPathComponent)")

        // Add timeout to prevent hanging
        let metadata = try await withThrowingTaskGroup(of: AudioMetadata.self) { group in
            group.addTask {
                return try await AudioMetadataParser.parseMetadata(from: url)
            }

            group.addTask {
                // Files are parsed several at a time, so a single file's
                // wall-clock time now includes contention with its peers (and,
                // on a fresh install, iCloud still materialising the data).
                // 10s was tight enough that large files were being skipped
                // outright; this only bounds a genuine hang.
                try await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds timeout
                throw LibraryIndexerError.parseTimeout
            }

            guard let result = try await group.next() else {
                throw LibraryIndexerError.parseTimeout
            }

            group.cancelAll()
            return result
        }

        print("✅ AudioMetadataParser completed for: \(url.lastPathComponent)")

        let artistNames = parseArtistNames(metadata.artist)
        let rawAlbumArtist = metadata.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let albumArtistNames = rawAlbumArtist.isEmpty ? artistNames : parseArtistNames(rawAlbumArtist)
        let displayAlbumArtist = displayArtistName(from: albumArtistNames)
        print("🎤 Creating artist(s): '\(displayArtistName(from: artistNames))'")

        let artists = try artistNames.map { try databaseManager.upsertArtist(name: $0) }
        let albumArtists = try albumArtistNames.map { try databaseManager.upsertArtist(name: $0) }
        let artist: Artist
        if let firstArtist = artists.first {
            artist = firstArtist
        } else {
            artist = try databaseManager.upsertArtist(name: Localized.unknownArtist)
        }
        // Key the album on the ALBUM artist, not the track's artist - keying
        // on the track artist split albums whenever a track featured a guest
        // (issue #81). candidateArtistIds lets upsertAlbum group tracks whose
        // artist order differs (e.g. "Guest; Main") into the existing album.
        let albumPrimaryArtist = albumArtists.first ?? artist
        let album = try databaseManager.upsertAlbum(
            title: metadata.album ?? Localized.unknownAlbum,
            artistId: albumPrimaryArtist.id,
            year: metadata.year,
            albumArtist: displayAlbumArtist,
            candidateArtistIds: (artists + albumArtists).compactMap(\.id)
        )

        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])

        let track = Track(
            stableId: stableId,
            albumId: album.id,
            artistId: artist.id,
            title: metadata.title ?? url.deletingPathExtension().lastPathComponent,
            genre: metadata.genre,
            trackNo: metadata.trackNumber,
            discNo: metadata.discNumber,
            durationMs: metadata.durationMs,
            sampleRate: metadata.sampleRate,
            bitDepth: metadata.bitDepth,
            channels: metadata.channels,
            path: url.path,
            fileSize: Int64(resourceValues.fileSize ?? 0),
            modificationDate: Self.modificationTimestamp(resourceValues.contentModificationDate),
            replaygainTrackGain: metadata.replaygainTrackGain,
            replaygainAlbumGain: metadata.replaygainAlbumGain,
            replaygainTrackPeak: metadata.replaygainTrackPeak,
            replaygainAlbumPeak: metadata.replaygainAlbumPeak,
            hasEmbeddedArt: metadata.hasEmbeddedArt
        )

        return ParsedAudioFile(
            track: track,
            trackArtistIds: artists.compactMap(\.id),
            albumArtistIds: albumArtists.compactMap(\.id)
        )
    }

    nonisolated private func parseArtistNames(_ artistName: String?) -> [String] {
        let rawName = artistName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawName.isEmpty else { return [Localized.unknownArtist] }

        // Treat "feat."-style credits as additional artists so featured
        // tracks group under the same artists and albums (issues #16, #81)
        let featSeparated = rawName.replacingOccurrences(
            of: "(?i)\\s*[\\(\\[]?\\s*\\b(?:featuring|feat\\.?|ft\\.?)\\s+",
            with: ";",
            options: .regularExpression
        )

        // Split on the common multi-artist separators (issue #16):
        // "\\" (ID3 joined-value convention), ";" (most taggers), and
        // NUL (ID3v2.4 multi-value text frames)
        let delimiters = ["\\\\", ";", "\u{0}"]
        var rawComponents = [featSeparated]
        for delimiter in delimiters {
            rawComponents = rawComponents.flatMap { $0.components(separatedBy: delimiter) }
        }

        var seenNames = Set<String>()
        var artists: [String] = []

        for component in rawComponents {
            let cleaned = cleanArtistName(component)
            let normalized = cleaned.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            guard !cleaned.isEmpty, !seenNames.contains(normalized) else { continue }
            seenNames.insert(normalized)
            artists.append(cleaned)
        }

        return artists.isEmpty ? [Localized.unknownArtist] : artists
    }

    nonisolated private func displayArtistName(from artistNames: [String]) -> String {
        artistNames.joined(separator: " / ")
    }

    nonisolated private func cleanArtistName(_ artistName: String) -> String {
        var cleaned = artistName.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove common YouTube/streaming suffixes
        let suffixesToRemove = [
            " - Topic",
            " Topic",
            "- Topic",
            ", Topic",
            " (Topic)",
        ]

        for suffix in suffixesToRemove where cleaned.hasSuffix(suffix) {
            cleaned = String(cleaned.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Remove brackets and additional info that might cause duplicates
        if let bracketStart = cleaned.firstIndex(of: "[") {
            cleaned = String(cleaned[..<bracketStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Drop unbalanced trailing brackets left over when a "(feat. X)"
        // credit was converted into a separator (keeps names like "(G)I-DLE")
        while let last = cleaned.last,
              (last == ")" && !cleaned.contains("(")) || (last == "]" && !cleaned.contains("[")) {
            cleaned = String(cleaned.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return cleaned.isEmpty ? Localized.unknownArtist : cleaned
    }

    func copyFilesFromSharedContainer() async {
        print("📁 Checking shared container for new music files...")

        guard let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.daxmate.qqplayer.ios") else {
            print("❌ Failed to get shared container URL")
            return
        }

        // Process shared URLs from share extension
        await processSharedURLs(from: sharedContainer)

        // Also check for legacy copied files (for backward compatibility)
        await processLegacySharedFiles(from: sharedContainer)

        // Process previously stored external bookmarks (both document picker and share extension files)
        await processStoredExternalBookmarks()
    }

    private func processSharedURLs(from sharedContainer: URL) async {
        let sharedDataURL = sharedContainer.appendingPathComponent("SharedAudioFiles.plist")

        guard FileManager.default.fileExists(atPath: sharedDataURL.path) else {
            print("📁 No shared audio files found")
            return
        }

        do {
            let data = try Data(contentsOf: sharedDataURL)
            guard let sharedFiles = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Data]] else {
                return
            }

            print("📁 Found \(sharedFiles.count) shared audio file references")

            // Group files by folder for playlist creation
            var folderGroups: [String: [URL]] = [:]
            var processedFiles: [URL] = []

            for fileInfo in sharedFiles {
                guard let bookmarkData = fileInfo["bookmark"],
                      let filenameData = fileInfo["filename"],
                      let filename = String(data: filenameData, encoding: .utf8) else {
                    continue
                }

                do {
                    // Resolve bookmark to get access to the original file
                    var isStale = false
                    let url = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)

                    if isStale {
                        print("⚠️ Bookmark is stale for: \(filename)")
                        continue
                    }

                    // Reject network URLs
                    if let scheme = url.scheme?.lowercased(), ["http", "https", "ftp", "sftp"].contains(scheme) {
                        print("❌ Rejected network URL: \(url.absoluteString)")
                        continue
                    }

                    // Start accessing security-scoped resource
                    guard url.startAccessingSecurityScopedResource() else {
                        print("❌ Failed to access security-scoped resource for: \(filename)")
                        continue
                    }

                    defer {
                        url.stopAccessingSecurityScopedResource()
                    }

                    // Process the file directly from its original location
                    await processExternalFile(url, allowExcludedReimport: true)
                    print("✅ Processed shared file from original location: \(filename)")

                    // Store the bookmark permanently for future access after app updates
                    await storeBookmarkPermanently(bookmarkData, for: url)

                    // Group by folder path for playlist creation
                    if let folderPathData = fileInfo["folderPath"],
                       let folderPath = String(data: folderPathData, encoding: .utf8) {
                        if folderGroups[folderPath] == nil {
                            folderGroups[folderPath] = []
                        }
                        folderGroups[folderPath]?.append(url)
                    }

                    processedFiles.append(url)

                } catch {
                    print("❌ Failed to resolve bookmark for \(filename): \(error)")
                }
            }

            // Create folder playlists for shared files
            await processSharedFolderPlaylists(folderGroups: folderGroups)

            // Clear the shared files list after processing and storing bookmarks permanently
            try FileManager.default.removeItem(at: sharedDataURL)
            print("🗑️ Cleared shared audio files list (bookmarks moved to permanent storage)")

        } catch {
            print("❌ Failed to process shared audio files: \(error)")
        }
    }

    private func processSharedFolderPlaylists(folderGroups: [String: [URL]]) async {
        guard !folderGroups.isEmpty else { return }
        guard DeleteSettings.load().autoCreateFolderPlaylists else {
            print("📁 Folder playlist auto-creation disabled in settings - skipping shared folders")
            return
        }

        print("📁 Processing \(folderGroups.count) shared folder playlists...")

        for (folderPath, musicFiles) in folderGroups {
            let folderURL = URL(fileURLWithPath: folderPath)
            let folderName = folderURL.lastPathComponent

            print("📂 Processing shared folder playlist for: \(folderName)")

            do {
                // Generate stable IDs for all music files in this folder
                var trackStableIds: [String] = []

                for musicFile in musicFiles {
                    let stableId = try generateStableId(for: musicFile)
                    trackStableIds.append(stableId)
                }

                print("🎵 Found \(trackStableIds.count) tracks in shared folder: \(folderName)")

                // Check if a folder playlist already exists for this path
                if let existingPlaylist = try databaseManager.getFolderPlaylist(forPath: folderPath) {
                    print("🔄 Syncing existing shared folder playlist: \(existingPlaylist.title)")

                    // The DB primary key should never be nil here, but a nil
                    // row must not crash the folder-sync hot path (audit)
                    guard let playlistId = existingPlaylist.id else {
                        print("❌ Skipping shared folder playlist sync - existing playlist has no id: \(existingPlaylist.title)")
                        return
                    }
                    try databaseManager.syncPlaylistWithFolder(playlistId: playlistId, trackStableIds: trackStableIds)
                    print("✅ Synced shared playlist '\(existingPlaylist.title)' with folder contents")
                } else {
                    // Create new folder playlist for shared folder
                    print("➕ Creating new shared folder playlist: \(folderName)")

                    let playlist = try databaseManager.createFolderPlaylist(title: folderName, folderPath: folderPath)
                    guard let playlistId = playlist.id else {
                        print("❌ Skipping shared folder playlist sync - created playlist has no id: \(playlist.title)")
                        return
                    }
                    try databaseManager.syncPlaylistWithFolder(playlistId: playlistId, trackStableIds: trackStableIds)
                    print("✅ Created shared folder playlist '\(playlist.title)' with \(trackStableIds.count) tracks")
                }

            } catch {
                print("❌ Failed to process shared folder playlist for \(folderName): \(error)")
            }
        }

        print("✅ Shared folder playlist processing completed")
    }

    private func processLegacySharedFiles(from sharedContainer: URL) async {
        let sharedMusicURL = sharedContainer.appendingPathComponent("Documents").appendingPathComponent("Music")
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localMusicURL = documentsURL.appendingPathComponent("Music")

        // Create local Music directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: localMusicURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("❌ Failed to create local Music directory: \(error)")
            return
        }

        // Check if shared Music directory exists
        guard FileManager.default.fileExists(atPath: sharedMusicURL.path) else {
            print("📁 No shared Music directory found")
            return
        }

        do {
            let sharedFiles = try FileManager.default.contentsOfDirectory(at: sharedMusicURL, includingPropertiesForKeys: nil)
            let audioFiles = sharedFiles.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "mp3" || ext == "flac" || ext == "wav"
            }

            print("📁 Found \(audioFiles.count) legacy audio files in shared container")

            for audioFile in audioFiles {
                let localDestination = localMusicURL.appendingPathComponent(audioFile.lastPathComponent)

                // Skip if file already exists in local directory
                if FileManager.default.fileExists(atPath: localDestination.path) {
                    print("⏭️ File already exists locally: \(audioFile.lastPathComponent)")
                    continue
                }

                do {
                    try FileManager.default.copyItem(at: audioFile, to: localDestination)
                    print("✅ Copied legacy file to Documents/Music: \(audioFile.lastPathComponent)")

                    // Remove from shared container after successful copy
                    try FileManager.default.removeItem(at: audioFile)
                    print("🗑️ Removed legacy file from shared container: \(audioFile.lastPathComponent)")

                } catch {
                    print("❌ Failed to copy legacy file \(audioFile.lastPathComponent): \(error)")
                }
            }

        } catch {
            print("❌ Failed to read shared container directory: \(error)")
        }
    }

    private func storeBookmarkPermanently(_ bookmarkData: Data, for url: URL) async {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        do {
            // Load existing bookmarks or create new dictionary
            var bookmarks: [String: Data] = [:]
            if FileManager.default.fileExists(atPath: bookmarksURL.path) {
                let data = try Data(contentsOf: bookmarksURL)
                if let existingBookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] {
                    bookmarks = existingBookmarks
                }
            }

            // Generate stableId for this file
            let stableId = try generateStableId(for: url)

            // Store bookmark data using stableId as key (survives file moves)
            bookmarks[stableId] = bookmarkData

            // Save updated bookmarks
            let plistData = try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .xml, options: 0)
            try plistData.write(to: bookmarksURL)

            print("💾 Stored permanent bookmark for shared file: \(url.lastPathComponent) with stableId: \(stableId)")
        } catch {
            print("❌ Failed to store permanent bookmark for \(url.lastPathComponent): \(error)")
        }
    }

    private func processStoredExternalBookmarks() async {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        guard FileManager.default.fileExists(atPath: bookmarksURL.path) else {
            print("📁 No stored external bookmarks found")
            return
        }

        do {
            let data = try Data(contentsOf: bookmarksURL)
            guard var bookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data] else {
                print("❌ Invalid external bookmarks format")
                return
            }
            var bookmarksChanged = false

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
                            bookmarks.removeValue(forKey: stableId)
                            bookmarks[resolvedStableId] = bookmarkData
                            bookmarksChanged = true
                            print("✅ Updated database path for: \(resolvedURL.lastPathComponent)")
                        } else {
                            print("📍 External file path unchanged: \(resolvedURL.lastPathComponent)")
                        }
                    } else if try databaseManager.getTrack(byStableId: resolvedStableId) != nil {
                        trackAlreadyExists = true
                        bookmarks.removeValue(forKey: stableId)
                        bookmarks[resolvedStableId] = bookmarkData
                        bookmarksChanged = true
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

            if bookmarksChanged {
                let plistData = try PropertyListSerialization.data(fromPropertyList: bookmarks, format: .xml, options: 0)
                try plistData.write(to: bookmarksURL, options: .atomic)
                print("✅ Updated external bookmark keys after stable ID migration")
            }

        } catch {
            print("❌ Failed to process stored external bookmarks: \(error)")
        }
    }

    /// Resolve bookmark for a specific track and update database path if file moved
    func resolveBookmarkForTrack(_ track: Track) async -> URL? {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let bookmarksURL = documentsURL.appendingPathComponent("ExternalFileBookmarks.plist")

        guard FileManager.default.fileExists(atPath: bookmarksURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: bookmarksURL)
            guard let bookmarks = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Data],
                  let bookmarkData = bookmarks[track.stableId] else {
                return nil // No bookmark for this track
            }

            // Resolve bookmark to get current file location
            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)

            if isStale {
                print("⚠️ Bookmark is stale for: \(track.title)")
                return nil
            }

            // Update database path if file moved
            if track.path != resolvedURL.path {
                print("📍 Playback: File moved detected! Old: \(track.path)")
                print("📍 Playback: File moved detected! New: \(resolvedURL.path)")

                try databaseManager.write { db in
                    var updatedTrack = track
                    updatedTrack.path = resolvedURL.path
                    try updatedTrack.update(db)
                }
                print("✅ Updated database path for playback: \(resolvedURL.lastPathComponent)")
            }

            return resolvedURL

        } catch {
            print("❌ Failed to resolve bookmark for track \(track.title): \(error)")
            return nil
        }
    }
}

extension LibraryIndexer: NSMetadataQueryDelegate {
    nonisolated func metadataQuery(_ query: NSMetadataQuery, replacementObjectForResultObject result: NSMetadataItem) -> Any {
        return result
    }
}
