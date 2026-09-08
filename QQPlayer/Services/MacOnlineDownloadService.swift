//
//  MacOnlineDownloadService.swift
//  QQPlayer
//
//  在线下载编排（web 版 /api/online/download 对齐，2026-09 C 组①；E2 批2b 扩展
//  通用直链下载入口；B1 批：下载引擎分发（aria2 RPC，不可用自动降级内置 HTTP）+
//  进度回调（UI 进度圆环打基础））。落盘语义逐条对齐 web backend/app/routers/stream.py +
//  services/download.py：
//  - 目标目录 = 设置 onlineDownloadDirectory（空 → 曲库默认目录恒在列的首个）
//  - 文件名 = 网易云 {title}-{artist}.{ext}（清洗后空回落 id，见 NeteaseOnlineLogic）；
//    直链下载 downloadDirect 用调用方建议文件名（同样做非法字符清洗）
//  - 重名加序号 (1)、(2)…
//  - .part 下载 + 原子改名（FSEvents 不会收到半截文件）；引擎：settings.downloadEngine
//    == "aria2" → MacAria2Client（addUri + 1s 轮询 tellStatus，web 降级语义：任何失败
//    自动降级内置 HTTP）；否则/降级 → NetworkTransport（URLSession，delegate 进度）
//  - download(song:)（网易云）完成后发 LibraryFolderContentChanged → FSEvents/索引
//    自动收录（与 B3 导入同链路）；downloadDirect 不自动刷新——刷新由调用方按场景
//    决定（歌曲海 UI 落盘后自行 post LibraryFolderContentChanged）
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
    /// - Parameters:
    ///   - progress: 下载进度回调 (completed, total) 字节数（默认 nil 不回调）
    /// - Returns: 最终落盘文件路径。
    static func download(
        song: NeteaseOnlineSong,
        client: NeteaseOnlineClient = .shared,
        level: String? = nil,
        transport: (any NetworkTransport)? = nil,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil,
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

        // 2-4. 目标目录 + 重名序号 + .part 原子落盘（persistDownload 通用段；
        // 错误类型/文案/落盘结果与既有实现一致）
        let baseName = NeteaseOnlineLogic.downloadFileName(
            title: song.title,
            artist: song.artist,
            ext: info.ext,
            songID: song.id
        )
        let path = try await persistDownload(
            fileName: baseName,
            url: info.url,
            headers: ["User-Agent": downloadUserAgent],
            fileManager: fileManager,
            transport: transport,
            logPrefix: "在线下载",
            progress: progress
        )

        // 5. 入曲库信号（web 落盘后 watchdog 自动刷新；本地 FSEvents created 事件双保险）
        NotificationCenter.default.post(
            name: .libraryImportFinished,
            object: nil,
            userInfo: ["count": 1]
        )
        NotificationCenter.default.post(name: NSNotification.Name("LibraryFolderContentChanged"), object: nil)

        return path
    }

    /// 通用直链下载（歌曲海等非网易云来源；E2 批2b 新增入口）。
    ///
    /// 契约（落盘语义与 download(song:) 步骤 2-4 完全一致，共用 persistDownload）：
    /// - 目标目录 = 设置 onlineDownloadDirectory（空 → 曲库默认目录恒在列的首个）
    /// - 文件名 = suggestedFileName 经非法字符清洗（\ / : * ? " < > | 与首尾空白）；
    ///   清洗后为空 → 抛错（调用方传空名属编程错误）
    /// - 目录内重名自动加序号 (1)、(2)…
    /// - .part 流式下载成功后原子改名（FSEvents 不会收到半截文件）
    /// - 下载 headers 原样透传（夸克直链签名绑定 UA/Cookie/Referer，缺失会 412）
    /// - 完成不自动刷新——调用方按需 post LibraryFolderContentChanged
    /// - Parameters:
    ///   - progress: 下载进度回调 (completed, total) 字节数（默认 nil 不回调）
    /// - Returns: 最终落盘文件路径。
    static func downloadDirect(
        url: URL,
        headers: [String: String],
        suggestedFileName: String,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil,
        fileManager: FileManager = .default
    ) async throws -> String {
        let cleaned = NeteaseOnlineLogic.sanitizeFilename(suggestedFileName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            print("❌ [直链下载] 文件名清洗后为空 suggestedFileName=\(suggestedFileName)")
            throw NeteaseOnlineError.downloadFailed("invalid file name: \(suggestedFileName)")
        }
        return try await persistDownload(
            fileName: cleaned,
            url: url,
            headers: headers,
            fileManager: fileManager,
            transport: nil,
            logPrefix: "直链下载",
            progress: progress
        )
    }

    /// 落盘通用段（download(song:) 步骤 2-4 抽取，downloadDirect 共用）：
    /// 目标目录解析 → 建目录 → 目录内重名加序号 → .part 下载（引擎分发：
    /// 设置 aria2 → aria2 RPC，失败自动降级内置 HTTP）→ 原子改名。
    /// 不 post 任何通知（刷新时机由调用方决定）。logPrefix 只影响诊断日志前缀
    /// （download(song:) 传「在线下载」保持既有日志逐字不变）。
    /// - Parameters:
    ///   - progress: 下载进度回调 (completed, total) 字节数（默认 nil 不回调）
    /// - Returns: 最终落盘文件路径。
    private static func persistDownload( // swiftlint:disable:this function_parameter_count
        fileName: String,
        url: URL,
        headers: [String: String],
        fileManager: FileManager,
        transport: (any NetworkTransport)?,
        logPrefix: String,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> String {
        let settings = DeleteSettings.load()

        // 2. 目标目录
        guard let directory = destinationDirectory(
            configuredDirectory: settings.onlineDownloadDirectory,
            libraryDirectories: libraryDirectoryPaths()
        ) else {
            print("❌ [\(logPrefix)] 无可用下载目录（onlineDownloadDirectory=空且曲库目录列表为空）")
            throw NeteaseOnlineError.downloadFailed("no download directory")
        }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            print("❌ [\(logPrefix)] 创建目录失败 \(directory.path): \(error)")
            throw error
        }

        // 3. 重名序号（重名检查针对「目录内完整路径」）
        let destination = destinationURL(
            directory: directory,
            fileName: fileName,
            fileExists: { fileManager.fileExists(atPath: $0) }
        )

        // 4. .part 下载（引擎分发：设置 aria2 → aria2 RPC；不可用/失败自动降级内置
        // HTTP——web _download_with_engine 降级语义）。两种引擎都把数据写到 partURL，
        // 下面的原子改名逻辑共用不变。
        let partURL = destination.appendingPathExtension("part")
        let downloader: any NetworkTransport = transport ?? URLSessionNetworkTransport()
        if settings.downloadEngine == "aria2" {
            do {
                try await downloadViaAria2(
                    url: url,
                    partURL: partURL,
                    headers: headers,
                    rpcURLString: settings.aria2Rpc,
                    secret: settings.aria2Secret,
                    maxSpeedMbps: settings.downloadMaxSpeed,
                    progress: progress
                )
            } catch {
                // 任何 aria2 失败（addUri 连接失败/RPC 错/轮询 error/超时）→ 降级内置
                print("⚠️ [下载引擎] aria2 不可用降级内置：\(error.localizedDescription)")
                try await downloadViaHTTP(
                    url: url,
                    partURL: partURL,
                    headers: headers,
                    downloader: downloader,
                    logPrefix: logPrefix,
                    progress: progress
                )
            }
        } else {
            try await downloadViaHTTP(
                url: url,
                partURL: partURL,
                headers: headers,
                downloader: downloader,
                logPrefix: logPrefix,
                progress: progress
            )
        }
        do {
            try fileManager.moveItem(at: partURL, to: destination)
        } catch {
            print("❌ [\(logPrefix)] 落盘改名失败 \(partURL.path) → \(destination.path): \(error)")
            throw error
        }

        return destination.path
    }

    /// 内置 HTTP 下载 .part（原 persistDownload 步骤 4 逻辑逐字；引擎降级后也走这里）
    private static func downloadViaHTTP( // swiftlint:disable:this function_parameter_count
        url: URL,
        partURL: URL,
        headers: [String: String],
        downloader: any NetworkTransport,
        logPrefix: String,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        do {
            try await downloader.download(
                url: url,
                to: partURL,
                timeout: 300,
                headers: headers,
                progress: progress
            )
        } catch {
            print("❌ [\(logPrefix)] 文件下载失败 url=\(url.absoluteString): \(error)")
            throw error
        }
    }

    /// aria2 引擎下载 .part（web _download_with_engine aria2 分支对齐）：
    /// addUri 提交（dir=目录 out=.part 文件名，headers 全量透传，限速）→ 1s 轮询
    /// tellStatus → complete 返回；error 抛（携带 errorMessage）；总超时 300s
    /// （与内置 timeout 对齐）→ 先 remove(gid)（失败忽略）再抛。
    /// 抛错语义：任何失败都抛，由调用方降级内置 HTTP（web 降级语义）。
    private static func downloadViaAria2( // swiftlint:disable:this function_parameter_count
        url: URL,
        partURL: URL,
        headers: [String: String],
        rpcURLString: String,
        secret: String,
        maxSpeedMbps: Double,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws {
        let trimmedRPC = rpcURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let rpcURL = URL(string: trimmedRPC) ?? MacAria2Client.defaultRPCURL
        let client = MacAria2Client(rpcURL: rpcURL, secret: secret)
        let gid = try await client.addUri(
            url: url.absoluteString,
            headers: headers,
            dir: partURL.deletingLastPathComponent().path,
            out: partURL.lastPathComponent,
            maxSpeedMbps: maxSpeedMbps
        )
        print("✅ [下载引擎] aria2 提交 gid=\(gid)")

        // 轮询 1s 间隔；active/waiting → 进度回调；complete → 成功；error → 抛
        let deadline = Date().addingTimeInterval(300)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let status = try await client.tellStatus(gid: gid)
            switch status.status {
            case "active", "waiting":
                print("✅ [下载引擎] aria2 轮询 gid=\(gid) status=\(status.status) "
                    + "completed=\(status.completedLength)/\(status.totalLength)")
                progress?(status.completedLength, status.totalLength)
            case "complete":
                print("✅ [下载引擎] aria2 下载完成 gid=\(gid)")
                return
            case "error":
                let message = status.errorMessage ?? status.status
                print("❌ [下载引擎] aria2 下载 error gid=\(gid) message=\(message)")
                throw NeteaseOnlineError.downloadFailed("aria2 下载失败: \(message)")
            default:
                // paused/removed 等非终态：继续轮询至超时（web 只认 complete/error）
                break
            }
        }
        // 超时：先 remove 清理任务（失败忽略），再抛 → 调用方降级
        try? await client.remove(gid: gid)
        print("❌ [下载引擎] aria2 下载超时 gid=\(gid)")
        throw NeteaseOnlineError.downloadFailed("aria2 下载超时")
    }
}
