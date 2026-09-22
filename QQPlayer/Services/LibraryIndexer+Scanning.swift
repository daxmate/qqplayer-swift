//
//  LibraryIndexer+Scanning.swift
//  QQPlayer
//
//  扫描与调度：文件夹歌单生成、本地 Documents 扫描（iOS）、macOS 音乐文件夹
//  扫描/自动补扫、dataless 分区。纯搬家自 LibraryIndexer.swift（无行为变化；
//  仅按分片放宽可见性）。
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import GRDB
import SFBAudioEngine

extension LibraryIndexer {
    private func processFolderPlaylists(allMusicFiles: [URL]) async {
        guard DeleteSettings.load().autoCreateFolderPlaylists else {
            AppLog.warn(.general, "📁 Folder playlist auto-creation disabled in settings - skipping")
            return
        }
        AppLog.info(.general, "📁 Processing folder playlists...")

        // Group music files by their parent directory
        var folderGroups: [String: [URL]] = [:]

        for fileURL in allMusicFiles {
            let parentFolder = fileURL.deletingLastPathComponent()
            let folderPath = parentFolder.path

            // Skip if it's directly in the music root（Documents/Music / macOS 曲库根）
            let documentsPath = LibraryRoot.documentsRootURL()?.path
            #if os(macOS)
                let musicRootPath = stateManager.getMusicFolderURL()?.path
            #else
                let musicRootPath = MusicFolderResolver.iosMusicLibraryDirectoryURL().path
            #endif

            if folderPath == documentsPath || folderPath == musicRootPath {
                continue
            }

            if folderGroups[folderPath] == nil {
                folderGroups[folderPath] = []
            }
            folderGroups[folderPath]?.append(fileURL)
        }

        AppLog.info(.general, "📁 Found \(folderGroups.count) folders with music files")

        for (folderPath, musicFiles) in folderGroups {
            await processFolderPlaylist(folderPath: folderPath, musicFiles: musicFiles)
        }

        AppLog.info(.general, "✅ Folder playlist processing completed")
    }

    private func processFolderPlaylist(folderPath: String, musicFiles: [URL]) async {
        let folderURL = URL(fileURLWithPath: folderPath)
        let folderName = folderURL.lastPathComponent

        if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "📂 Processing folder playlist for: \(folderName)") }

        do {
            // Generate stable IDs for all music files in this folder
            var trackStableIds: [String] = []

            for musicFile in musicFiles {
                let stableId = try generateStableId(for: musicFile)
                trackStableIds.append(stableId)
            }

            if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🎵 Found \(trackStableIds.count) tracks in folder: \(folderName)") }

            // Check if a folder playlist already exists for this path
            if let existingPlaylist = try databaseManager.getFolderPlaylist(forPath: folderPath) {
                if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🔄 Syncing existing folder playlist: \(existingPlaylist.title)") }

                // The DB primary key should never be nil here, but a nil row
                // must not crash the folder-sync hot path (audit: force unwrap)
                guard let playlistId = existingPlaylist.id else {
                    AppLog.error(.general, "❌ Skipping folder playlist sync - existing playlist has no id: \(existingPlaylist.title)")
                    return
                }
                try databaseManager.syncPlaylistWithFolder(playlistId: playlistId, trackStableIds: trackStableIds)
                if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "✅ Synced playlist '\(existingPlaylist.title)' with folder contents") }
            } else {
                // Create new folder playlist
                if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "➕ Creating new folder playlist: \(folderName)") }

                let playlist = try databaseManager.createFolderPlaylist(title: folderName, folderPath: folderPath)
                guard let playlistId = playlist.id else {
                    AppLog.error(.general, "❌ Skipping folder playlist sync - created playlist has no id: \(playlist.title)")
                    return
                }
                try databaseManager.syncPlaylistWithFolder(playlistId: playlistId, trackStableIds: trackStableIds)
                if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "✅ Created folder playlist '\(playlist.title)' with \(trackStableIds.count) tracks") }
            }

        } catch {
            AppLog.error(.general, "❌ Failed to process folder playlist for \(folderName): \(error)")
        }
    }

    /// iOS 主扫/offline 统一入口（M3-2 起 = 唯一主扫；2026-09-22 起曲库根 = `Documents/Music`）。
    /// 带 generation guard，与 macOS scanMusicFolder 同一套取消语义。
    /// 分片：跨文件可见（原 private）
    ///
    /// 扫描口径（用户 2026-09-22 拍板）：
    /// · 只认 `Documents/Music`；· **单层不递归** —— `Music/<子目录>/*.flac` **不收录**
    ///   （历史子目录本批不递归也不搬平）；· 根不存在时**不 reconcile**（扫不到 ≠ 空库，
    ///   否则会把库里全部行删掉）。
    func scanLocalDocuments(generation: Int) async {
        let musicDirectory = MusicFolderResolver.iosMusicLibraryDirectoryURL()
        // 根不存在（首启迁移器还没跑）= 本轮无扫描根 → reconcile 收到空 roots，一条不删。
        let rootExists = FileManager.default.fileExists(atPath: musicDirectory.path)

        guard generation == indexingGeneration else { return }

        do {
            let musicFiles = try await findMusicFiles(in: musicDirectory, recursive: false)

            let totalFiles = musicFiles.count

            // Same bounded-concurrency treatment as the macOS scan so first
            // runs don't serialize every file behind the main actor.
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

                    guard generation == indexingGeneration, !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }

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

            // Only a current scan may finalize.
            guard generation == indexingGeneration else { return }
            await FileCleanupManager.shared.reconcileMissingFiles(in: rootExists ? [musicDirectory] : [])
            postPendingLibraryRefresh()

            await MainActor.run {
                markScanEnded()
                // 主扫跑到这里 = 曲库行已建立（空库也算终态）→ 开 changeLog 同步前置门。
                markMainScanCompletedThisLaunch()
                AppLog.info(.general, "✅ iOS library scan completed. Found \(tracksFound) tracks.")
            }

            // Process folder playlists after scan completion
            await processFolderPlaylists(allMusicFiles: musicFiles)
        } catch {
            await MainActor.run {
                markScanEnded()
                AppLog.error(.general, "Offline library scan failed: \(error)")
            }
        }
    }
    #if os(macOS)
        /// macOS 数据源：FileManager 目录扫描音乐文件夹（默认 ~/Music/QQPlayer）。
        /// 复用 iOS 的 findMusicFiles/indexFile/processFolderPlaylists 逻辑，
        /// 仅替换数据源（NSMetadataQuery → 目录枚举）。MVP 为启动全扫，
        /// FSEvents 实时监控后补（调研报告 §3.5 风险 2）。
        /// 分片：跨文件可见（原 private）
        func startMacScan() {
            // 决策上收：是否启动扫描由 MacIndexingGate.shouldBeginScan 决定（有单测锁定）。
            // 必须与 iOS 分支保持同一套状态前置：isIndexing 置 true 才能通过
            // scanMusicFolder 首行的 guard（否则扫描被直接拦截、永远不会执行）。
            guard MacIndexingGate.shouldBeginScan(currentlyIndexing: isIndexing) else { return }

            markScanStarted()

            let generation = indexingGeneration
            activeScanTask = Task {
                await scanMusicFolder(generation: generation)
            }
        }

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
            AppLog.info(.general, "📁 macOS scanning folders: \(folders.map(\.path))")
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
                AppLog.info(.general, "📁 macOS found \(totalFiles) music files")
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
                    AppLog.warn(.general, "⏭️ Skipping \(skippedDataless) dataless iCloud files (not downloaded locally)")
                }

                guard !musicFiles.isEmpty else {
                    // 全为云端未下载：不 reconcile（避免误删本地入列曲目）
                    guard generation == indexingGeneration else { return }
                    markScanEnded()
                    AppLog.error(.general, "❌ All \(skippedDataless) files are dataless; nothing to index this round")
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

                        guard generation == indexingGeneration, !Task.isCancelled else {
                            group.cancelAll()
                            return
                        }

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

                markScanEnded()
                // 主扫跑到这里 = 曲库行已建立（空库也算终态）→ 开 changeLog 同步前置门。
                markMainScanCompletedThisLaunch()
                AppLog.info(.general, "✅ macOS scan completed. Found \(tracksFound) tracks.")
                MacScanLogger.log("scan completed, tracksFound: \(tracksFound), skippedDataless: \(skippedDataless)")

                // 云端文件下载完成后自动补扫入列（60s 后重扫，最多 5 轮）
                autoscheduleRescan(skippedDataless: skippedDataless)

                await processFolderPlaylists(allMusicFiles: musicFiles)
            } catch {
                AppLog.error(.general, "❌ macOS scan failed: \(error)")
                MacScanLogger.log("scan failed: \(error)")
                markScanEnded()
            }
        }
    #endif

    /// macOS：分区本地已实体化文件与 iCloud dataless（云端未下载）文件。
    /// 返回 (本地文件, dataless 数)。无 iCloud entitlement 时无法主动触发
    /// 下载（2026-09-02 实测 startDownloadingUbiquitousItem 无效），dataless
    /// 文件只跳过不等待，下载完成后由 autoscheduleRescan 补扫入列。
    ///
    /// 判定统一走 CloudFileAvailability（单一事实源）；本方法行为与提取前逐字一致。
    nonisolated private static func partitionLocalFiles(_ files: [URL]) async -> ([URL], Int) {
        var local: [URL] = []
        var dataless = 0
        for file in files {
            if CloudFileAvailability.isLocallyAvailable(file) {
                local.append(file)
            } else {
                dataless += 1
            }
        }
        return (local, dataless)
    }

}
