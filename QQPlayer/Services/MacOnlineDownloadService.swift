//
//  MacOnlineDownloadService.swift
//  QQPlayer
//
//  网易云在线下载编排（web 版 /api/online/download 对齐，2026-09 C 组①）。
//  落盘语义逐条对齐 web backend/app/routers/stream.py + services/download.py：
//  - 目标目录 = 设置 onlineDownloadDirectory（空 → 曲库默认目录恒在列的首个）
//  - 文件名 = {title}-{artist}.{ext}（清洗后空回落 id，见 NeteaseOnlineLogic）
//  - 重名加序号 (1)、(2)…
//  - 完成后发 LibraryFolderContentChanged → FSEvents/索引自动收录（与 B3 导入同链路）
//  QQPlayerMac target only 的 UI 使用；本文件只依赖共享层（iOS 侧编译无害，
//  纯逻辑随 iOS 测试兜底回归，照 MacImportNaming/MacFolderWatchPolicy 先例）。
//

import Foundation

enum MacOnlineDownloadService {
    /// 下载结果
    struct DownloadResult {
        let fileName: String
        let filePath: String
    }

    /// 浏览器 UA（下载直链服务端校验 UA；web download.DOWNLOAD_UA 对齐）
    static let downloadUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/120.0 Safari/537.36"

    // MARK: - 纯决策（可单测）

    /// 设置值 → 生效音质等级（旧数据/非法回落 exhigh）
    static func effectiveQuality(from settingsValue: String?) -> String {
        NeteaseOnlineLogic.normalizeLevel(settingsValue)
    }

    /// 目标目录：设置非空用设置路径；空 = 曲库目录列表首个（默认目录恒在列）。
    /// 目录不存在时返回 nil（由调用方创建或报错）。
    static func destinationDirectory(
        configuredDirectory: String,
        libraryDirectories: [String]
    ) -> URL? {
        let trimmed = configuredDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return URL(fileURLWithPath: trimmed, isDirectory: true)
        }
        guard let first = libraryDirectories.first, !first.isEmpty else { return nil }
        return URL(fileURLWithPath: first, isDirectory: true)
    }

    /// 曲库目录列表（跨平台：默认 ~/Music/QQPlayer 恒在列首位 + 设置附加目录，
    /// macOS 语义与扫描一致；避免依赖 macOS-only 的 StateManager API）
    static func libraryDirectoryPaths() -> [String] {
        let settings = DeleteSettings.load()
        var paths = settings.libraryFolders
        // NSHomeDirectory() 跨平台：macOS = ~（真实用户目录）；iOS = 沙盒目录（该
        // 服务仅 Mac 运行时使用，iOS 编译兜底测试用，落盘路径语义以 macOS 为准）
        let defaultPath = NSHomeDirectory() + "/Music/QQPlayer"
        if !paths.contains(defaultPath) {
            paths.insert(defaultPath, at: 0)
        }
        return paths
    }

    /// 最终落盘路径：目录内重名自动加序号（name (1).ext…）。
    /// 重名检查针对「目录内完整路径」（exists 闭包收到绝对路径，避免对裸文件名判重）。
    static func destinationURL(
        directory: URL,
        fileName: String,
        fileExists: (String) -> Bool
    ) -> URL {
        let unique = NeteaseOnlineLogic.uniqueFileName(base: fileName) { candidate in
            fileExists(directory.appendingPathComponent(candidate).path)
        }
        return directory.appendingPathComponent(unique)
    }

    // MARK: - 下载编排

    /// 下载网易云在线歌曲到曲库目录并触发重扫收录。
    /// - Returns: 最终落盘文件路径。
    static func download(
        song: NeteaseOnlineSong,
        client: NeteaseOnlineClient = .shared,
        level: String? = nil,
        transport: (any NetworkTransport)? = nil,
        fileManager: FileManager = .default
    ) async throws -> String {
        let settings = DeleteSettings.load()
        let quality = effectiveQuality(from: level ?? settings.onlineDownloadQuality)

        // 1. 取直链（Meting → cenguigui 兜底）
        let info: NeteasePlayInfo
        do {
            info = try await client.playInfo(songID: song.id, level: quality)
        } catch {
            print("❌ [在线下载] 直链获取失败 songID=\(song.id) level=\(quality): \(error)")
            throw error
        }

        // 2. 目标目录
        guard let directory = destinationDirectory(
            configuredDirectory: settings.onlineDownloadDirectory,
            libraryDirectories: libraryDirectoryPaths()
        ) else {
            print("❌ [在线下载] 无可用下载目录（onlineDownloadDirectory=空且曲库目录列表为空）")
            throw NeteaseOnlineError.downloadFailed("no download directory")
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("❌ [在线下载] 创建目录失败 \(directory.path): \(error)")
            throw error
        }

        // 3. 文件名 + 重名序号
        let baseName = NeteaseOnlineLogic.downloadFileName(
            title: song.title,
            artist: song.artist,
            ext: info.ext,
            songID: song.id
        )
        let destination = destinationURL(
            directory: directory,
            fileName: baseName,
            fileExists: { fileManager.fileExists(atPath: $0) }
        )

        // 4. 流式下载（.part 原子改名，避免 FSEvents 收到半截文件）
        let partURL = destination.appendingPathExtension("part")
        let downloader: any NetworkTransport = transport ?? URLSessionNetworkTransport()
        do {
            try await downloader.download(
                url: info.url,
                to: partURL,
                timeout: 300,
                headers: ["User-Agent": downloadUserAgent]
            )
        } catch {
            print("❌ [在线下载] 文件下载失败 url=\(info.url.absoluteString): \(error)")
            throw error
        }
        do {
            try fileManager.moveItem(at: partURL, to: destination)
        } catch {
            print("❌ [在线下载] 落盘改名失败 \(partURL.path) → \(destination.path): \(error)")
            throw error
        }

        // 5. 入曲库信号（web 落盘后 watchdog 自动刷新；本地 FSEvents created 事件双保险）
        NotificationCenter.default.post(
            name: .libraryImportFinished,
            object: nil,
            userInfo: ["count": 1]
        )
        NotificationCenter.default.post(name: NSNotification.Name("LibraryFolderContentChanged"), object: nil)

        return destination.path
    }
}
