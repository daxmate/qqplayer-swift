//  MacImportService.swift
//  QQPlayer
//
//  macOS 文件拖入导入（web 版 useDragImport + 侧栏歌单 drop 对齐，
//  2026-09-03 B 组；QQPlayerMac target only）。
//
//  语义（web 版调研对齐）：
//  - 拖入音频文件 → 复制进曲库默认目录（不移动源文件，同名加后缀）
//  - 复制后触发曲库重扫（LibraryFolderContentChanged → reload + start/排队，
//    FSEvents 也会因 created 事件自动补扫一次，双保险）
//  - 拖到歌单行：复制后立即把新文件（按 final path 的 stableId）加入该歌单
//    ——playlist_item 无 FK，可先插引用，扫描入库后详情自动出现
//  - 过滤：只收引擎支持格式（MacImportNaming.isImportable，静态白名单语义，
//    不随「文件类型设置」裁剪——取消格式只影响扫描收录，不影响显式导入）
//

import Foundation

enum MacImportService {
    struct ImportResult {
        var importedCount = 0
        var skippedCount = 0
    }

    /// 拖入文件导入曲库。
    /// - Parameters:
    ///   - urls: 拖入的文件 URL（Finder/任何来源，非沙盒直接可读）
    ///   - playlistId: 非 nil 时把导入的文件同时加入该歌单
    ///   - importFolder: 目标目录；nil = 默认曲库目录（~/Music/QQPlayer，恒在列）
    /// - Returns: 结果统计（供 UI 提示「已导入 n 首」）
    @discardableResult
    static func importFiles(
        _ urls: [URL],
        intoPlaylistId playlistId: Int64? = nil,
        importFolder: URL? = nil
    ) async -> ImportResult {
        var result = ImportResult()
        let fileManager = FileManager.default

        // 目标目录：默认取曲库首个目录（StateManager 保证默认 ~/Music/QQPlayer 恒在列）
        let destinationDirectory: URL
        if let importFolder {
            destinationDirectory = importFolder
        } else if let first = StateManager.shared.getMusicFolderURLs().first {
            destinationDirectory = first
        } else {
            MacScanLogger.log("import: no destination folder")
            return result
        }

        // 确保目录存在（默认目录可能尚未创建）
        try? fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        var copiedPaths: [String] = []

        for url in urls {
            // 网络/非文件 URL 跳过
            guard url.isFileURL else {
                result.skippedCount += 1
                continue
            }
            // 只收引擎支持格式（静态白名单）
            guard MacImportNaming.isImportable(url: url) else {
                result.skippedCount += 1
                continue
            }
            // 已在目标目录内（本来就是库内文件）→ 不重复复制
            let standardizedDestination = destinationDirectory.standardizedFileURL.path
            let sourceStandardized = url.standardizedFileURL.path
            if sourceStandardized.hasPrefix(standardizedDestination + "/") {
                MacScanLogger.log("import: \(url.lastPathComponent) already inside library folder")
                result.importedCount += 1
                copiedPaths.append(sourceStandardized)
                continue
            }

            do {
                let destination = MacImportNaming.uniqueDestinationURL(
                    in: destinationDirectory,
                    sourceName: url.lastPathComponent
                )
                try fileManager.copyItem(at: url, to: destination)
                MacScanLogger.log("import: copied \(url.lastPathComponent) → \(destination.path)")
                result.importedCount += 1
                copiedPaths.append(destination.path)
            } catch {
                MacScanLogger.log("import failed: \(url.lastPathComponent): \(error)")
                result.skippedCount += 1
            }
        }

        guard !copiedPaths.isEmpty else { return result }

        // 拖到歌单：按 final path 的 stableId 立即插入歌单引用（无 FK，可先于入库）
        if let playlistId {
            do {
                for path in copiedPaths {
                    let stableId = DatabaseManager.generatePathStableId(forPath: path)
                    try DatabaseManager.shared.addToPlaylist(playlistId: playlistId, trackStableId: stableId)
                }
                NotificationCenter.default.post(name: NSNotification.Name("PlaylistsChanged"), object: nil)
            } catch {
                MacScanLogger.log("import: add to playlist failed: \(error)")
            }
        }

        // 瞬时反馈（web toast 语义）：成功数投给主窗口显示
        NotificationCenter.default.post(
            name: .libraryImportFinished,
            object: nil,
            userInfo: ["count": result.importedCount]
        )

        // 触发曲库重扫收录（若正在扫描，通知处理器会排队；FSEvents created 事件双保险）
        NotificationCenter.default.post(name: NSNotification.Name("LibraryFolderContentChanged"), object: nil)

        return result
    }
}
