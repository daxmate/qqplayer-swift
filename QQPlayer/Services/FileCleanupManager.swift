//
//  FileCleanupManager.swift
//  QQPlayer
//
//  Manages cleanup of library files deleted from disk (Documents / external
//  security-scoped files). M3-2: iCloud cleanup semantics retired.
//

import Foundation

@MainActor
class FileCleanupManager: ObservableObject {
    static let shared = FileCleanupManager()

    private let databaseManager = DatabaseManager.shared
    private let stateManager = StateManager.shared

    private init() {}

    /// Reconciles only roots that the indexer successfully enumerated during
    /// this scan. This avoids treating an unavailable root as an empty library
    /// while still removing files that were genuinely deleted.
    ///
    /// 移除两类曲目（2026-09-03 B 组「文件类型设置」对齐 web）：
    /// 1. 文件已从磁盘删除（历史行为）
    /// 2. 文件仍在磁盘、但扩展名已不在当前收录设置内（用户取消了该格式——
    ///    web 版取消勾选后重扫即从曲库消失、文件保留；勾回重扫自动恢复。
    ///    iOS 无此设置 UI，audioExtensions 恒为全量 → 本条永不触发）
    func reconcileMissingFiles(in successfullyScannedRoots: [URL]) async {
        let roots = successfullyScannedRoots.map(\.standardizedFileURL)
        guard !roots.isEmpty else { return }

        // 文件类型设置单一事实源（默认全 9 种；macOS 设置页可裁剪）
        let settings = DeleteSettings.load()
        let enabledExtensions = settings.audioExtensions.isEmpty
            ? LibraryAudioFormats.defaultEnabled
            : settings.audioExtensions

        do {
            let tracks = try databaseManager.getAllTracks()
            // 两类移除原因分开：文件真没了 → 全量删除；仅格式不收录 → 只移除曲目行
            // （D7：文件与用户数据都保留，勾回格式重扫即恢复）
            let removals: [(track: Track, fileMissing: Bool)] = tracks.compactMap { track in
                let trackURL = URL(fileURLWithPath: track.path).standardizedFileURL
                let belongsToScannedRoot = roots.contains { isURL(trackURL, inside: $0) }
                guard belongsToScannedRoot else { return nil }
                let fileExists = FileManager.default.fileExists(atPath: trackURL.path)
                if !fileExists {
                    return (track, true) // 磁盘已删除
                }
                // 文件在但扩展名被取消收录 → 从曲库移除（文件保留，勾回重扫恢复）
                guard !LibraryAudioFormats.isEnabled(path: track.path, enabled: enabledExtensions) else {
                    return nil
                }
                return (track, false)
            }

            guard !removals.isEmpty else {
                print("🧹 Scan reconciliation found no deleted files")
                return
            }

            let missingCount = removals.filter { $0.fileMissing }.count
            print("🧹 Scan reconciliation removing \(removals.count) track(s) (\(missingCount) missing file, \(removals.count - missingCount) format disabled)")
            for removal in removals {
                do {
                    if removal.fileMissing {
                        try databaseManager.deleteTrack(byStableId: removal.track.stableId)
                        print("🧹 Removed missing track: \(removal.track.title)")
                    } else {
                        // D7：取消收录的格式 → 文件与收藏/歌单/播放历史全部保留，
                        // 只把曲目行从库中移除（重扫入库后同一 stableId 自动重新关联）。
                        // 此前走的是全量 deleteTrack，勾回格式后收藏与歌单成员资格永久丢失。
                        try databaseManager.removeTrackFromLibrary(byStableId: removal.track.stableId)
                        print("🧹 Removed format-disabled track from library (file and references kept): \(removal.track.title)")
                    }
                } catch {
                    print("🧹 Failed to remove missing track \(removal.track.title): \(error)")
                }
            }

            NotificationCenter.default.post(
                name: NSNotification.Name("LibraryNeedsRefresh"),
                object: nil
            )
        } catch {
            print("🧹 Scan reconciliation failed: \(error)")
        }
    }

    func checkForOrphanedFiles() async {
        print("🧹 Checking for library files that no longer exist...")

        // M3-2：退役 iCloud 容器——内部文件 = 本地 Documents（沙盒）内的文件；
        // 外部文件 = share/document picker 引入的安全域文件（走书签校验）。
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!

        do {
            // Get all tracks from database
            let allTracks = try databaseManager.getAllTracks()
            print("🧹 Found \(allTracks.count) tracks in database")

            var nonExistentTracks: [Track] = []

            for track in allTracks {
                let trackURL = URL(fileURLWithPath: track.path)
                print("🧹 Checking track: \(trackURL.lastPathComponent)")
                print("🧹   Path: \(trackURL.path)")

                let isInternalFile = isURL(trackURL, inside: documentsURL) ||
                    trackURL.path.contains("/Documents/")
                print("🧹   Is internal file: \(isInternalFile)")

                if isInternalFile {
                    // For internal files, simple existence check
                    let fileExists = FileManager.default.fileExists(atPath: trackURL.path)
                    print("🧹   Internal file exists: \(fileExists)")

                    if fileExists {
                        print("🧹 ✅ Internal file exists (keeping): \(trackURL.lastPathComponent)")
                    } else {
                        // Check if this is a local Documents file with a moved path
                        if trackURL.path.contains("/Documents/") {
                            // Try to find the file in the current Documents directory
                            let filename = trackURL.lastPathComponent
                            let newURL = documentsURL.appendingPathComponent(filename)

                            if FileManager.default.fileExists(atPath: newURL.path) {
                                print("🧹   Found file in current Documents folder, updating path...")
                                print("🧹   Old path: \(trackURL.path)")
                                print("🧹   New path: \(newURL.path)")

                                // Update the track's path in the database
                                do {
                                    // 路径变更 = stableId 重算，走同一迁移入口（D5）
                                    try databaseManager.migrateTrackForMovedFile(
                                        oldStableId: track.stableId,
                                        newPath: newURL.path
                                    )
                                    print("🧹 ✅ Updated path for: \(filename)")
                                } catch {
                                    print("🧹 ❌ Failed to update path: \(error)")
                                    nonExistentTracks.append(track)
                                }
                            } else {
                                print("🧹   Internal file doesn't exist - will auto-clean from database")
                                nonExistentTracks.append(track)
                            }
                        } else {
                            print("🧹   Internal file doesn't exist - will auto-clean from database")
                            nonExistentTracks.append(track)
                        }
                    }
                } else {
                    // For external files (from share/document picker), check if still accessible
                    let isAccessible = await checkExternalFileAccessibility(trackURL, stableId: track.stableId)
                    print("🧹   External file accessible: \(isAccessible)")

                    if isAccessible {
                        print("🧹 ✅ External file still accessible (keeping): \(trackURL.lastPathComponent)")
                    } else {
                        print("🧹   External file no longer accessible - will auto-clean from database")
                        nonExistentTracks.append(track)
                    }
                }
            }

            // Auto-clean files that don't exist anywhere
            if !nonExistentTracks.isEmpty {
                print("🧹 Auto-cleaning \(nonExistentTracks.count) files that don't exist anywhere")

                for track in nonExistentTracks {
                    do {
                        print("🧹 Auto-cleaning database entry for non-existent file: \(URL(fileURLWithPath: track.path).lastPathComponent)")
                        print("🧹 Auto-removing track from database: \(track.title)")
                        // Use the ID stored with the row. Re-hashing the
                        // filename was incompatible with path-based IDs and
                        // silently left deleted tracks in previous builds.
                        try databaseManager.deleteTrack(byStableId: track.stableId)
                    } catch {
                        print("🧹 Error auto-cleaning file \(track.path): \(error)")
                    }
                }

                // Notify UI to refresh since we made database changes
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            }

            print("🧹 No additional cleanup needed")

        } catch {
            print("🧹 Error checking for orphaned files: \(error)")
        }
    }

    private func isURL(_ url: URL, inside rootURL: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = rootURL.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func checkExternalFileAccessibility(_ fileURL: URL, stableId: String) async -> Bool {
        // First check if file exists at the path
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // File exists at original path, try to access it
            do {
                _ = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                print("🧹     External file accessible at original path")
                return true
            } catch {
                print("🧹     External file exists but not accessible: \(error)")
                return false
            }
        }

        // File doesn't exist at original path, check if we have bookmark data for it
        print("🧹     External file doesn't exist at original path, checking bookmark data")
        return await checkBookmarkAccessibility(for: fileURL, stableId: stableId)
    }

    /// 书签解析结果：**必须区分「没有书签」与「书签读不出来」**（D2）。
    /// 前者是事实（可据此判定文件真没了），后者是未知——清理路径必须保守保留曲目。
    private enum BookmarkResolution {
        case resolved(URL)
        case missing
        case unknown(Error)
    }

    private func checkBookmarkAccessibility(for fileURL: URL, stableId: String) async -> Bool {
        // Check document picker bookmarks (now using stableId as key)
        switch await resolveDocumentPickerBookmark(for: stableId) {
        case .resolved(let resolvedURL):
            // Bookmark found! Check if file is still accessible
            if resolvedURL.path != fileURL.path {
                print("🧹     File has been moved from \(fileURL.path) to \(resolvedURL.path) - bookmark is tracking it ✅")
            }

            // Test if the resolved location is accessible
            let isAccessible = await testFileAccessibility(resolvedURL)
            if isAccessible {
                print("🧹     External file is accessible via bookmark ✅")
            }
            return isAccessible

        case .unknown(let error):
            // D2：书签 plist 在但读不出来 = 未知，**绝不能当作“无书签”去删曲目**
            // （一次非原子写的截断曾让全部书签不可解析 → 库里外部文件被批量误删）。
            print("🧹     ⚠️ Bookmark store unreadable - keeping track conservatively: \(error)")
            return true

        case .missing:
            break
        }

        // Check share extension bookmarks (legacy - should be migrated)
        if let resolvedURL = await resolveShareExtensionBookmark(for: stableId) {
            if resolvedURL.path != fileURL.path {
                print("🧹     File has been moved from \(fileURL.path) to \(resolvedURL.path) - bookmark is tracking it ✅")
            }
            return await testFileAccessibility(resolvedURL)
        }

        print("🧹     No valid bookmark found for external file")
        return false
    }

    private func resolveDocumentPickerBookmark(for stableId: String) async -> BookmarkResolution {
        guard let store = ExternalFileBookmarkStore.default else {
            print("🧹     No document picker bookmarks file found")
            return .missing
        }

        let bookmarks: [String: Data]
        switch store.load() {
        case .loaded(let loaded):
            bookmarks = loaded
        case .unreadable(let error):
            return .unknown(error)
        }

        guard let bookmarkData = bookmarks[stableId] else {
            print("🧹     No bookmark found for stableId: \(stableId)")
            return .missing
        }

        do {
            var isStale = false
            let resolvedURL = try URL(resolvingBookmarkData: bookmarkData, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &isStale)

            if isStale {
                print("🧹     Document picker bookmark is STALE for stableId: \(stableId)")
                print("🧹     Resolved path: \(resolvedURL.path)")
                // 同 D2 的“不确定不删”原则：stale = 位置信息需刷新，不是“文件没了”。
                // 仍返回解析结果，由调用方的可访问性探测决定去留（探测不过才删）。
            }

            print("🧹     Document picker bookmark resolved successfully for stableId: \(stableId)")
            print("🧹     Resolved path: \(resolvedURL.path)")
            return .resolved(resolvedURL)
        } catch {
            print("🧹     Failed to resolve document picker bookmark: \(error)")
            return .missing
        }
    }

    private func resolveShareExtensionBookmark(for stableId: String) async -> URL? {
        // Share extension bookmarks are now migrated to the main bookmark storage
        // This function is kept for backward compatibility but should not be needed
        print("🧹     Share extension bookmarks have been migrated to main storage")
        return nil
    }

    private func testFileAccessibility(_ fileURL: URL) async -> Bool {
        print("🧹     Testing accessibility for resolved URL: \(fileURL.path)")

        guard fileURL.startAccessingSecurityScopedResource() else {
            print("🧹     ❌ Failed to start accessing security-scoped resource")
            return false
        }

        defer {
            fileURL.stopAccessingSecurityScopedResource()
            print("🧹     ⏹️ Stopped accessing security-scoped resource")
        }

        // Check if file exists at the resolved path
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("🧹     ❌ File doesn't exist at resolved bookmark path: \(fileURL.path)")
            return false
        }

        print("🧹     ✅ File exists at resolved path")

        do {
            // Try to get file attributes - this tests basic access permissions
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            let fileSize = attributes[.size] as? Int64 ?? 0
            print("🧹     ✅ Got file attributes - size: \(fileSize) bytes")

            // For additional verification, try to actually read the file
            // This will catch cases where the file exists but is corrupted or inaccessible
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            defer {
                do {
                    try fileHandle.close()
                    print("🧹     ✅ Successfully closed file handle")
                } catch {
                    print("🧹     ⚠️ Error closing file handle: \(error)")
                }
            }

            let data = try fileHandle.read(upToCount: 1024)

            if let data = data, !data.isEmpty {
                print("🧹     ✅ External file accessible and readable via bookmark (\(data.count) bytes read)")
                return true
            } else {
                print("🧹     ❌ External file exists but appears to be empty or unreadable")
                return false
            }
        } catch {
            print("🧹     ❌ External file not accessible or readable via bookmark")
            print("🧹     ❌ Error details: \(error)")
            print("🧹     ❌ Error type: \(type(of: error))")
            return false
        }
    }
}
