//
//  LibraryIndexer+SharedImport.swift
//  QQPlayer
//
//  共享容器导入（App Group / Share Extension）：processSharedURLs /
//  processSharedFolderPlaylists / processLegacySharedFiles。
//  纯搬家自 LibraryIndexer.swift（无行为变化；仅按分片放宽可见性）。
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import GRDB
import SFBAudioEngine

extension LibraryIndexer {
    /// 分片：跨文件可见（原 private）
    func processSharedURLs(from sharedContainer: URL) async {
        let sharedDataURL = sharedContainer.appendingPathComponent("SharedAudioFiles.plist")

        guard FileManager.default.fileExists(atPath: sharedDataURL.path) else {
            AppLog.info(.general, "📁 No shared audio files found")
            return
        }

        do {
            let data = try Data(contentsOf: sharedDataURL)
            guard let sharedFiles = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Data]] else {
                return
            }

            AppLog.info(.general, "📁 Found \(sharedFiles.count) shared audio file references")

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
                        AppLog.warn(.general, "⚠️ Bookmark is stale for: \(filename)")
                        continue
                    }

                    // Reject network URLs
                    if let scheme = url.scheme?.lowercased(), ["http", "https", "ftp", "sftp"].contains(scheme) {
                        AppLog.error(.general, "❌ Rejected network URL: \(url.absoluteString)")
                        continue
                    }

                    // Start accessing security-scoped resource
                    guard url.startAccessingSecurityScopedResource() else {
                        AppLog.error(.general, "❌ Failed to access security-scoped resource for: \(filename)")
                        continue
                    }

                    defer {
                        url.stopAccessingSecurityScopedResource()
                    }

                    // Process the file directly from its original location
                    await processExternalFile(url, allowExcludedReimport: true)
                    if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "✅ Processed shared file from original location: \(filename)") }

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
                    AppLog.error(.general, "❌ Failed to resolve bookmark for \(filename): \(error)")
                }
            }

            // Create folder playlists for shared files
            await processSharedFolderPlaylists(folderGroups: folderGroups)

            // Clear the shared files list after processing and storing bookmarks permanently
            try FileManager.default.removeItem(at: sharedDataURL)
            AppLog.info(.general, "🗑️ Cleared shared audio files list (bookmarks moved to permanent storage)")

        } catch {
            AppLog.error(.general, "❌ Failed to process shared audio files: \(error)")
        }
    }

    private func processSharedFolderPlaylists(folderGroups: [String: [URL]]) async {
        guard !folderGroups.isEmpty else { return }
        guard DeleteSettings.load().autoCreateFolderPlaylists else {
            AppLog.warn(.general, "📁 Folder playlist auto-creation disabled in settings - skipping shared folders")
            return
        }

        AppLog.info(.general, "📁 Processing \(folderGroups.count) shared folder playlists...")

        for (folderPath, musicFiles) in folderGroups {
            let folderURL = URL(fileURLWithPath: folderPath)
            let folderName = folderURL.lastPathComponent

            if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "📂 Processing shared folder playlist for: \(folderName)") }

            do {
                // Generate stable IDs for all music files in this folder
                var trackStableIds: [String] = []

                for musicFile in musicFiles {
                    let stableId = try generateStableId(for: musicFile)
                    trackStableIds.append(stableId)
                }

                if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🎵 Found \(trackStableIds.count) tracks in shared folder: \(folderName)") }

                // Check if a folder playlist already exists for this path
                if let existingPlaylist = try databaseManager.getFolderPlaylist(forPath: folderPath) {
                    if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🔄 Syncing existing shared folder playlist: \(existingPlaylist.title)") }

                    // The DB primary key should never be nil here, but a nil
                    // row must not crash the folder-sync hot path (audit)
                    guard let playlistId = existingPlaylist.id else {
                        AppLog.error(.general, "❌ Skipping shared folder playlist sync - existing playlist has no id: \(existingPlaylist.title)")
                        return
                    }
                    try databaseManager.syncPlaylistWithFolder(playlistId: playlistId, trackStableIds: trackStableIds)
                    if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "✅ Synced shared playlist '\(existingPlaylist.title)' with folder contents") }
                } else {
                    // Create new folder playlist for shared folder
                    if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "➕ Creating new shared folder playlist: \(folderName)") }

                    let playlist = try databaseManager.createFolderPlaylist(title: folderName, folderPath: folderPath)
                    guard let playlistId = playlist.id else {
                        AppLog.error(.general, "❌ Skipping shared folder playlist sync - created playlist has no id: \(playlist.title)")
                        return
                    }
                    try databaseManager.syncPlaylistWithFolder(playlistId: playlistId, trackStableIds: trackStableIds)
                    if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "✅ Created shared folder playlist '\(playlist.title)' with \(trackStableIds.count) tracks") }
                }

            } catch {
                AppLog.error(.general, "❌ Failed to process shared folder playlist for \(folderName): \(error)")
            }
        }

        AppLog.info(.general, "✅ Shared folder playlist processing completed")
    }

    /// 分片：跨文件可见（原 private）
    func processLegacySharedFiles(from sharedContainer: URL) async {
        let sharedMusicURL = sharedContainer.appendingPathComponent("Documents").appendingPathComponent("Music")
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let localMusicURL = documentsURL.appendingPathComponent("Music")

        // Create local Music directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: localMusicURL, withIntermediateDirectories: true, attributes: nil)
        } catch {
            AppLog.error(.general, "❌ Failed to create local Music directory: \(error)")
            return
        }

        // Check if shared Music directory exists
        guard FileManager.default.fileExists(atPath: sharedMusicURL.path) else {
            AppLog.info(.general, "📁 No shared Music directory found")
            return
        }

        do {
            let sharedFiles = try FileManager.default.contentsOfDirectory(at: sharedMusicURL, includingPropertiesForKeys: nil)
            let audioFiles = sharedFiles.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "mp3" || ext == "flac" || ext == "wav"
            }

            AppLog.info(.general, "📁 Found \(audioFiles.count) legacy audio files in shared container")

            for audioFile in audioFiles {
                let localDestination = localMusicURL.appendingPathComponent(audioFile.lastPathComponent)

                // Skip if file already exists in local directory
                if FileManager.default.fileExists(atPath: localDestination.path) {
                    if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "⏭️ File already exists locally: \(audioFile.lastPathComponent)") }
                    continue
                }

                do {
                    try FileManager.default.copyItem(at: audioFile, to: localDestination)
                    if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "✅ Copied legacy file to Documents/Music: \(audioFile.lastPathComponent)") }

                    // Remove from shared container after successful copy
                    try FileManager.default.removeItem(at: audioFile)
                    if AppLog.isEnabled(.debug, .general) { AppLog.debug(.general, "🗑️ Removed legacy file from shared container: \(audioFile.lastPathComponent)") }

                } catch {
                    AppLog.error(.general, "❌ Failed to copy legacy file \(audioFile.lastPathComponent): \(error)")
                }
            }

        } catch {
            AppLog.error(.general, "❌ Failed to read shared container directory: \(error)")
        }
    }
}
