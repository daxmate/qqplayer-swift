//
//  CloudDownloadManager.swift
//  QQPlayer
//
//  Manages downloading and monitoring iCloud Drive files
//

import Combine
import Foundation

@MainActor
class CloudDownloadManager: NSObject, ObservableObject {
    static let shared = CloudDownloadManager()

    @Published var downloadProgress: [URL: Double] = [:]
    @Published var downloadingFiles: Set<URL> = []

    private var downloadTasks: [URL: Task<Void, Error>] = [:]
    private nonisolated(unsafe) var progressQuery: NSMetadataQuery?
    private var isQueryRunning = false

    // Track if we've detected systematic iCloud failures
    // （2026-09-07 决策上收 CloudFailureDetector 纯逻辑，可单测；本类只执行副作用）
    private var failureDetector = CloudFailureDetector()

    private var hasDetectedSystematicFailure: Bool { failureDetector.hasDetectedSystematicFailure }

    override init() {
        super.init()
        setupProgressQuery()

        // Listen for authentication status changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAuthStatusChange),
            name: NSNotification.Name("iCloudAuthStatusChanged"),
            object: nil
        )
    }

    @objc private func handleAuthStatusChange() {
        Task { @MainActor in
            await updateQueryForAuthStatus()
        }
    }

    @MainActor
    private func updateQueryForAuthStatus() async {
        guard let query = progressQuery else { return }

        if AppCoordinator.shared.iCloudStatus == .authenticationRequired || !AppCoordinator.shared.isiCloudAvailable || hasDetectedSystematicFailure {
            // Stop query and clear all downloads when authentication fails
            if isQueryRunning {
                query.stop()
                isQueryRunning = false
                print("🛑 Stopped NSMetadataQuery due to authentication issues or systematic failures")

                // Clear all ongoing downloads
                downloadingFiles.removeAll()
                downloadProgress.removeAll()
                downloadTasks.values.forEach { $0.cancel() }
                downloadTasks.removeAll()
            }
        } else if AppCoordinator.shared.iCloudStatus == .available && !hasDetectedSystematicFailure {
            // Only resume monitoring if downloads are actually in flight -
            // restoring auth is not by itself a reason to start watching the
            // whole container again.
            startProgressQueryIfNeeded()
        }
    }

    @MainActor
    func detectSystematicFailure(for url: URL? = nil) {
        // 判定（窗口重置/同文件去重/阈值）全部在 CloudFailureDetector（纯逻辑，可单测）；
        // 此处仅执行切离线的副作用。触发瞬间保留 🚨 日志（stdout.log 诊断用）。
        let triggered = failureDetector.recordFailure(url: url, now: Date())
        if triggered {
            print("🚨 Systematic iCloud failure detected after \(failureDetector.maxConsecutiveFailures) consecutive failures - switching to offline mode")
            AppCoordinator.shared.handleiCloudAuthenticationError()
            Task {
                await updateQueryForAuthStatus()
            }
        }
    }

    @MainActor
    func resetFailureCount() {
        failureDetector.recordSuccess()
        print("✅ Reset iCloud failure count - successful operation detected")
    }

    @MainActor
    func attemptRecovery() {
        print("🔄 Attempting recovery from offline mode...")
        failureDetector.reset()

        // Restart the metadata query if needed
        Task {
            await updateQueryForAuthStatus()
        }
    }

    // Public method to allow other parts of the app to report iCloud failures
    static func reportiCloudFailure(error: Error) {
        if let nsError = error as NSError? {
            if nsError.domain == NSPOSIXErrorDomain && nsError.code == 60 {
                print("🚨 External timeout error reported - triggering systematic failure detection")
                Task { @MainActor in
                    CloudDownloadManager.shared.detectSystematicFailure()
                }
            } else if nsError.domain == NSPOSIXErrorDomain && nsError.code == 81 {
                print("🚨 External authentication error reported - triggering systematic failure detection")
                Task { @MainActor in
                    CloudDownloadManager.shared.detectSystematicFailure()
                }
            }
        }
    }

    private func setupProgressQuery() {
        progressQuery = NSMetadataQuery()
        progressQuery?.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]

        // Support all audio formats for progress monitoring
        let formats = ["*.flac", "*.mp3", "*.wav", "*.m4a", "*.aac", "*.opus", "*.ogg", "*.dsf", "*.dff"]
        let formatPredicates = formats.map { format in
            NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, format)
        }
        progressQuery?.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: formatPredicates)

        // Add notification observers for progress updates
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidUpdate),
            name: .NSMetadataQueryDidUpdate,
            object: progressQuery
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryDidFinishGathering),
            name: .NSMetadataQueryDidFinishGathering,
            object: progressQuery
        )

        // Deliberately NOT started here. A live NSMetadataQuery continuously
        // monitors the whole ubiquitous Documents scope, and every iCloud
        // change woke us to walk all results even with nothing downloading.
        // It is now started on demand by startProgressQueryIfNeeded() and torn
        // down again as soon as the last download finishes.
    }

    /// Begin monitoring download progress. Safe to call repeatedly; does
    /// nothing unless a download is actually in flight.
    private func startProgressQueryIfNeeded() {
        guard !isQueryRunning, !downloadingFiles.isEmpty, let query = progressQuery else { return }
        guard AppCoordinator.shared.iCloudStatus != .authenticationRequired,
              AppCoordinator.shared.isiCloudAvailable,
              !hasDetectedSystematicFailure else { return }

        query.start()
        isQueryRunning = true
        print("▶️ Started NSMetadataQuery to track \(downloadingFiles.count) download(s)")
    }

    /// Stop monitoring once nothing is being downloaded, so idle iCloud
    /// activity no longer wakes the app.
    private func stopProgressQueryIfIdle() {
        guard isQueryRunning, downloadingFiles.isEmpty, let query = progressQuery else { return }
        query.stop()
        isQueryRunning = false
        print("🛑 Stopped NSMetadataQuery - no downloads in flight")
    }

    @objc private func queryDidUpdate(_ notification: Notification) {
        Task { @MainActor in
            await processQueryUpdate()
        }
    }

    @objc private func queryDidFinishGathering(_ notification: Notification) {
        Task { @MainActor in
            await processQueryUpdate()
        }
    }

    private func processQueryUpdate() async {
        // Skip processing if authentication is required or systematic failure detected
        if AppCoordinator.shared.iCloudStatus == .authenticationRequired || !AppCoordinator.shared.isiCloudAvailable || hasDetectedSystematicFailure {
            print("🚫 Skipping NSMetadataQuery update - authentication required, not available, or systematic failure detected")
            return
        }

        guard let query = progressQuery else {
            print("❌ No progressQuery available")
            return
        }

        // Nothing to track: don't walk every file in the container (this loop
        // used to run over the entire library on every iCloud change, logging
        // two lines per file), and shut the query down until a download starts.
        guard !downloadingFiles.isEmpty else {
            stopProgressQueryIfIdle()
            return
        }

        print("🔍 NSMetadataQuery update - resultCount: \(query.resultCount)")
        print("📋 Currently tracking downloads for: \(downloadingFiles.map { $0.lastPathComponent })")

        query.disableUpdates()
        defer { query.enableUpdates() }

        // Process all metadata items to check download progress
        for i in 0 ..< query.resultCount {
            guard let item = query.result(at: i) as? NSMetadataItem else {
                print("⚠️ Could not get NSMetadataItem at index \(i)")
                continue
            }

            // Get the file URL
            guard let url = item.value(forAttribute: NSMetadataItemURLKey) as? URL else {
                print("⚠️ Could not get URL for NSMetadataItem at index \(i)")
                continue
            }

            print("📁 NSMetadataQuery found file: \(url.lastPathComponent)")

            // Only process files we're tracking for download
            guard downloadingFiles.contains(url) else {
                print("⏭️ Not tracking download for: \(url.lastPathComponent)")
                continue
            }

            print("🎯 Processing tracked file: \(url.lastPathComponent)")

            // Check download status
            if let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? URLUbiquitousItemDownloadingStatus {
                print("📊 NSMetadataQuery status for \(url.lastPathComponent): \(status)")

                switch status {
                case .current:
                    // Download complete
                    downloadProgress[url] = 1.0
                    downloadingFiles.remove(url)
                    downloadTasks.removeValue(forKey: url)
                    print("✅ Download complete via NSMetadataQuery: \(url.lastPathComponent)")

                case .downloaded:
                    // Downloaded but may not be current
                    downloadProgress[url] = 1.0
                    downloadingFiles.remove(url)
                    downloadTasks.removeValue(forKey: url)
                    print("✅ Download finished via NSMetadataQuery: \(url.lastPathComponent)")

                case .notDownloaded:
                    // Get actual download progress
                    if let progress = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? NSNumber {
                        let progressValue = progress.doubleValue / 100.0
                        downloadProgress[url] = progressValue
                        print("📈 Real download progress: \(url.lastPathComponent) - \(Int(progressValue * 100))%")
                    } else {
                        print("⚠️ No progress percentage available for: \(url.lastPathComponent)")
                        // Set a small progress value to show download is happening
                        downloadProgress[url] = 0.1
                    }

                default:
                    print("⚠️ Unknown download status via NSMetadataQuery: \(url.lastPathComponent)")
                }
            } else {
                print("❌ No download status available for: \(url.lastPathComponent)")
            }
        }

        if query.resultCount == 0 {
            print("⚠️ NSMetadataQuery has no results - may need to restart query")
        }

        // The loop above may have completed the last tracked download.
        stopProgressQueryIfIdle()
    }

    func ensureLocal(_ url: URL) async throws {
        print("🔍 ensureLocal called for: \(url.lastPathComponent)")

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("❌ File does not exist: \(url.lastPathComponent)")
            throw CloudDownloadError.fileNotFound
        }

        print("✅ File exists: \(url.lastPathComponent)")

        // Early check for iCloud authentication issues or systematic failures - prevent ANY iCloud operations
        if AppCoordinator.shared.iCloudStatus == .authenticationRequired || !AppCoordinator.shared.isiCloudAvailable || hasDetectedSystematicFailure {
            print("🚫 Skipping iCloud operations - authentication required, not available, or systematic failure detected: \(url.lastPathComponent)")
            // For files that exist locally, just check if they're readable
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                print("❌ File is not readable and iCloud unavailable: \(url.lastPathComponent)")
                throw CloudDownloadError.fileNotFound
            }
            print("✅ File ensured local (offline mode): \(url.lastPathComponent)")
            return
        }

        // Check if this is an iCloud file that needs downloading
        if isUbiquitous(url) {
            print("☁️ File is ubiquitous: \(url.lastPathComponent)")
            do {
                let resourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])

                if let downloadStatus = resourceValues.ubiquitousItemDownloadingStatus {
                    print("📊 Download status for \(url.lastPathComponent): \(downloadStatus)")
                    switch downloadStatus {
                    case .notDownloaded:
                        // Check if file is already readable locally (cached/downloaded but not current)
                        if FileManager.default.isReadableFile(atPath: url.path) {
                            print("✅ File is readable locally despite notDownloaded status: \(url.lastPathComponent)")
                            resetFailureCount() // Success case
                            return
                        }

                        // Not downloaded and not readable. Starting the download
                        // is the NORMAL path for a not-yet-downloaded file — a
                        // large FLAC/DSF file legitimately takes minutes, so
                        // this is NOT counted as a failure here. Failures only
                        // accumulate from real error paths (auth errors,
                        // unreadable status, download-start errors) and are
                        // deduplicated per file.
                        if hasDetectedSystematicFailure {
                            print("❌ Systematic failure detected - cannot ensure file is local: \(url.lastPathComponent)")
                            throw CloudDownloadError.fileNotFound
                        }
                        print("🔽 Attempting to download file: \(url.lastPathComponent)")
                        await startDownload(url)
                        return

                    case .downloaded:
                        print("✅ File already downloaded: \(url.lastPathComponent)")
                        resetFailureCount() // Success case
                        return
                    case .current:
                        print("✅ File is current: \(url.lastPathComponent)")
                        resetFailureCount() // Success case
                        return
                    default:
                        print("⚠️ Unknown download status for \(url.lastPathComponent): \(downloadStatus)")
                        // Check if file is readable despite unknown status
                        if FileManager.default.isReadableFile(atPath: url.path) {
                            print("✅ File is readable despite unknown status: \(url.lastPathComponent)")
                            resetFailureCount()
                            return
                        }
                        detectSystematicFailure(for: url)
                        if hasDetectedSystematicFailure {
                            throw CloudDownloadError.fileNotFound
                        }
                        return
                    }
                } else {
                    print("⚠️ No download status available - checking if file is readable")
                    // Check if file is readable despite missing status
                    if FileManager.default.isReadableFile(atPath: url.path) {
                        print("✅ File is readable despite missing download status: \(url.lastPathComponent)")
                        resetFailureCount()
                        return
                    }

                    // Only detect failure if file is not readable
                    detectSystematicFailure(for: url)
                    if hasDetectedSystematicFailure {
                        throw CloudDownloadError.fileNotFound
                    }
                    return
                }
            } catch {
                print("❌ Failed to get download status for \(url.lastPathComponent): \(error)")

                // Check if this is an authentication error
                if let nsError = error as NSError? {
                    if nsError.domain == NSPOSIXErrorDomain && nsError.code == 81 {
                        print("🔐 iCloud authentication required - throwing specific error")
                        throw CloudDownloadError.authenticationRequired
                    } else if nsError.domain == NSCocoaErrorDomain && (nsError.code == 256 || nsError.code == 257) {
                        print("🚫 iCloud access denied - throwing specific error")
                        throw CloudDownloadError.accessDenied
                    }
                }

                // Check if file is locally readable before detecting failure
                if FileManager.default.isReadableFile(atPath: url.path) {
                    print("✅ File is readable despite iCloud error: \(url.lastPathComponent)")
                    resetFailureCount()
                    return
                }

                // Only detect failure if file is not readable
                print("⚠️ iCloud error and file not readable - detecting failure")
                detectSystematicFailure(for: url)

                if hasDetectedSystematicFailure {
                    print("❌ Systematic failure - file not available: \(url.lastPathComponent)")
                    throw CloudDownloadError.fileNotFound
                }

                return
            }
        } else {
            print("📁 File is local (not iCloud): \(url.lastPathComponent)")
        }

        // For non-iCloud files, just check if readable
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            print("❌ File is not readable: \(url.lastPathComponent)")
            throw CloudDownloadError.fileNotFound
        }

        print("✅ File is readable: \(url.lastPathComponent)")
    }

    @MainActor
    private func startDownload(_ url: URL) async {
        guard !downloadingFiles.contains(url) else {
            print("⏭️ Already downloading: \(url.lastPathComponent)")
            return
        }

        // Check if we're in offline mode due to authentication issues or systematic failures
        if AppCoordinator.shared.iCloudStatus == .authenticationRequired || !AppCoordinator.shared.isiCloudAvailable || hasDetectedSystematicFailure {
            print("🚫 Skipping download - iCloud authentication required, not available, or systematic failure detected: \(url.lastPathComponent)")
            return
        }

        // Check if file is already downloaded and readable - don't re-download
        if FileManager.default.fileExists(atPath: url.path) && FileManager.default.isReadableFile(atPath: url.path) {
            // For iCloud files, check actual download status to avoid unnecessary downloads
            if isUbiquitous(url) {
                do {
                    let resourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                    if let status = resourceValues.ubiquitousItemDownloadingStatus {
                        switch status {
                        case .current, .downloaded:
                            print("✅ File already downloaded and readable - skipping: \(url.lastPathComponent)")
                            resetFailureCount()
                            return
                        case .notDownloaded:
                            print("🔽 File needs downloading despite being readable: \(url.lastPathComponent)")
                        // Continue with download
                        default:
                            print("🔽 Unknown status - will attempt download: \(url.lastPathComponent)")
                            // Continue with download
                        }
                    } else {
                        print("✅ File is readable, assuming already available: \(url.lastPathComponent)")
                        resetFailureCount()
                        return
                    }
                } catch {
                    print("✅ File is readable despite status check error - skipping download: \(url.lastPathComponent)")
                    resetFailureCount()
                    return
                }
            } else {
                print("✅ Local file already readable - skipping download: \(url.lastPathComponent)")
                return
            }
        } else {
            print("🚫 File not found or not readable: \(url.lastPathComponent)")
            return
        }

        print("🔽 Starting download for: \(url.lastPathComponent)")
        downloadingFiles.insert(url)
        downloadProgress[url] = 0.0
        // Progress monitoring only runs while something is actually downloading.
        startProgressQueryIfNeeded()

        do {
            // Start downloading the iCloud file
            if isUbiquitous(url) {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
                print("📡 Initiated iCloud download for: \(url.lastPathComponent)")
                print("🎯 NSMetadataQuery will now track real progress...")

                // Start a fallback progress monitor in case NSMetadataQuery doesn't work
                startFallbackProgressMonitor(url)

            } else {
                print("⚠️ File is not ubiquitous: \(url.lastPathComponent)")
                // For local files, mark as complete immediately
                downloadProgress[url] = 1.0
                downloadingFiles.remove(url)
                stopProgressQueryIfIdle()
            }
        } catch {
            print("💥 Failed to start download for \(url.lastPathComponent): \(error)")

            // Check if this is a timeout or authentication error
            if let nsError = error as NSError? {
                if nsError.domain == NSPOSIXErrorDomain && nsError.code == 60 {
                    // Timeout at download start is a per-file/transient issue
                    // (a large file can take a while to begin streaming) — not
                    // evidence of a system-wide iCloud failure, so it is not
                    // counted.
                    print("⏰ Timeout error at download start - not counted as systematic failure")
                } else if nsError.domain == NSPOSIXErrorDomain && nsError.code == 81 {
                    print("🔐 Authentication error at download start - detecting systematic failure")
                    detectSystematicFailure(for: url)
                }
            }

            downloadingFiles.remove(url)
            downloadProgress.removeValue(forKey: url)
            stopProgressQueryIfIdle()
        }
    }

    private func startFallbackProgressMonitor(_ url: URL) {
        let task = Task {
            var attempts = 0
            // 2 minutes max (0.5s per poll). Large FLAC/DSF downloads routinely
            // outlive the old 30s window; a timeout here only means THIS file is
            // slow or stalled, never that iCloud is down as a whole.
            let maxAttempts = 240

            while attempts < maxAttempts && downloadingFiles.contains(url) {
                do {
                    let resourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])

                    if let status = resourceValues.ubiquitousItemDownloadingStatus {
                        print("🔄 Fallback check - \(url.lastPathComponent): \(status)")

                        switch status {
                        case .current, .downloaded:
                            await MainActor.run {
                                downloadProgress[url] = 1.0
                                downloadingFiles.remove(url)
                                downloadTasks.removeValue(forKey: url)
                                stopProgressQueryIfIdle()
                            }
                            print("✅ Download complete via fallback: \(url.lastPathComponent)")
                            return

                        case .notDownloaded:
                            // Show incremental progress
                            let progress = min(0.9, Double(attempts) / Double(maxAttempts))
                            await MainActor.run {
                                downloadProgress[url] = progress
                            }
                            print("⏳ Fallback progress: \(url.lastPathComponent) - \(Int(progress * 100))%")

                        default:
                            break
                        }
                    }
                } catch {
                    print("❌ Fallback progress check failed: \(error)")

                    // Classify the error: only true authentication errors (code
                    // 81) are system-level and count toward offline mode.
                    // Timeouts (code 60) are per-file/transient — a large
                    // download may simply be slow — so they are logged and we
                    // keep polling until the monitor window ends, where the task
                    // is dropped without counting.
                    if let nsError = error as NSError? {
                        if nsError.domain == NSPOSIXErrorDomain && nsError.code == 81 {
                            print("🔐 Authentication error detected during progress check - detecting systematic failure")
                            await MainActor.run {
                                CloudDownloadManager.shared.detectSystematicFailure(for: url)
                            }
                            return
                        }
                    }
                }

                attempts += 1
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }

            // Timeout — the file was still not downloaded when the monitor
            // window ended. This means only that THIS download was slow or
            // stalled; it is not evidence of a system-wide iCloud failure, so we
            // simply drop the task (the user can retry via ensureLocal).
            await MainActor.run {
                if downloadingFiles.contains(url) {
                    print("⏰ Download timeout for: \(url.lastPathComponent) - removing task (not counted as systematic failure)")
                    downloadingFiles.remove(url)
                    downloadProgress.removeValue(forKey: url)
                    downloadTasks.removeValue(forKey: url)
                    stopProgressQueryIfIdle()
                }
            }
        }

        downloadTasks[url] = task
    }

    func cancelDownload(_ url: URL) {
        downloadTasks[url]?.cancel()
        downloadTasks.removeValue(forKey: url)
        downloadingFiles.remove(url)
        downloadProgress.removeValue(forKey: url)
        stopProgressQueryIfIdle()

        // Try to cancel the iCloud download
        if isUbiquitous(url) {
            // Note: There's no direct API to cancel iCloud downloads
            // The system manages this automatically
            print("🚫 Cancelled download for: \(url.lastPathComponent)")
        }
    }

    deinit {
        progressQuery?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    func isDownloaded(_ url: URL) -> Bool {
        // For iCloud files, check the proper download status
        if isUbiquitous(url) {
            do {
                let resourceValues = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])

                if let status = resourceValues.ubiquitousItemDownloadingStatus {
                    let isDownloaded = status == .downloaded || status == .current
                    print("📋 File \(url.lastPathComponent) download status: \(status), isDownloaded: \(isDownloaded)")
                    return isDownloaded
                }

                print("⚠️ No download status available for \(url.lastPathComponent)")
                return false
            } catch {
                print("❌ Failed to check download status for \(url.lastPathComponent): \(error)")
                return FileManager.default.isReadableFile(atPath: url.path)
            }
        }

        // For local files, just check if readable
        let isReadable = FileManager.default.isReadableFile(atPath: url.path)
        print("📄 Local file \(url.lastPathComponent) isReadable: \(isReadable)")
        return isReadable
    }

    func isUbiquitous(_ url: URL) -> Bool {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.isUbiquitousItemKey])
            let isUbiquitous = resourceValues.isUbiquitousItem ?? false
            print("🔍 File \(url.lastPathComponent) isUbiquitous: \(isUbiquitous)")
            return isUbiquitous
        } catch {
            print("❌ Error checking if file is ubiquitous: \(error)")
            return false
        }
    }
}
