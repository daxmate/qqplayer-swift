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

    /// 分片：跨文件可见（原 private）
    func processLegacySharedFiles(from sharedContainer: URL) async {
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
}
