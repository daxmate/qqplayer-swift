//
//  LibraryIndexer+SharedImport.swift
//  QQPlayer
//
//  共享容器导入（App Group / Share Extension）：processSharedURLs /
//  processLegacySharedFiles。
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

                } catch {
                    AppLog.error(.general, "❌ Failed to resolve bookmark for \(filename): \(error)")
                }
            }

            // Clear the shared files list after processing and storing bookmarks permanently
            try FileManager.default.removeItem(at: sharedDataURL)
            AppLog.info(.general, "🗑️ Cleared shared audio files list (bookmarks moved to permanent storage)")

        } catch {
            AppLog.error(.general, "❌ Failed to process shared audio files: \(error)")
        }
    }

    /// 分片：跨文件可见（原 private）
    func processLegacySharedFiles(from sharedContainer: URL) async {
        // 共享容器（App Group）自己的 Documents/Music 布局——与曲库根无关，名字取同一常量。
        let sharedMusicURL = sharedContainer
            .appendingPathComponent("Documents")
            .appendingPathComponent(LibraryRoot.musicDirectoryName)
        // 目标 = 曲库根（`Documents/Music`），经 LibraryRoot 单一入口派生。
        guard let localMusicURL = LibraryRoot.plannedDirectoryURL(LibraryRoot.musicDirectoryName) else {
            AppLog.error(.general, "❌ Failed to resolve local Music directory (Documents unavailable)")
            return
        }

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
