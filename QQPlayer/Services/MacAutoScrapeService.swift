//
//  MacAutoScrapeService.swift
//  QQPlayer
//
//  「下载完成 → 后台自动刮削」编排（2026-11-14 用户拍板口径）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  口径（用户拍板，不得自行更改）
//  ════════════════════════════════════════════════════════════════════════════
//  ① 下载落盘完成后自动刮削，并按设置里的重命名模板改文件名（文件名要改）；
//  ② 不做高置信度门槛：按源优先级合并后的**第一个候选直接写**，错了用户手工重刮；
//  ③ 设置开关 scraping.auto_after_download **默认关**（老用户升级后不自动改文件）；
//  ④ 全链路 fire-and-forget：绝不把错误抛给下载调用方，绝不影响下载成功状态。
//
//  ════════════════════════════════════════════════════════════════════════════
//  为什么放在 QQPlayer/Services/（而不是 QQPlayer/Mac/）
//  ════════════════════════════════════════════════════════════════════════════
//  运行时只有 macOS 下载链路会调用，但纯决策 shouldEnqueue 必须能被 QQPlayerTests
//  覆盖：仓库没有 macOS 单测 target，且 QQPlayer/Mac/** 被 iOS target 排除 →
//  放 Mac/ 就永远没有单测。同先例：MacOnlineDownloadService / MacImportNaming /
//  MacFolderWatchPolicy 都在共享 Services（iOS 侧编译无事，运行只走 macOS）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  链路（串行，避免 MusicBrainz 限流）
//  ════════════════════════════════════════════════════════════════════════════
//  入队（同路径去重）→ 等初次索引（最多约 3s，超时继续）→ 读现有标签组装检索词
//  → 三源检索 + 按设置源顺序合并 → 取第一个候选 → 字段映射（唯一入口
//  ScrapeLogic.fieldValues / makeTagWriteRequest）+ 封面（唯一入口 ScrapeCoverLoader）
//  → TagWriterService 写标签并按模板改名 → moveTrack 迁移 DB 引用
//  → LibraryIndexer 单文件入库 → **主线程跟随播放上下文 + 发 LibraryNeedsRefresh**。
//
//  刷新口径（2026-11-14 用户追加）：「自动刮削完成后，要刷新一下界面」——
//  写入标签 / 改名 / 入库完成后，曲库列表、歌单/专辑/艺人视图、正在播放条（标题/封面）
//  都要立刻跟随，不能等整库重扫或手动刷新。
//  实现 = 与标签保存路径**同一个入口**（`AppCoordinator.followRenamedTrack` + LibraryNeedsRefresh 通知），
//  不再发 LibraryFolderContentChanged（那个信号会让 MacLibraryView 起一次整库重扫）。
//

import Foundation

/// 文件身份：判断「现在这个路径上的文件还是不是同一个文件」，跨改名/移动稳定。
///
/// 存在理由：入队后要等初次索引 + 三源网络检索（实测 6–13s），期间
/// `LibraryIndexer+RenameNormalize` 可能已按模板改名（`夜曲-周杰伦.mp3` → `周杰伦 - 夜曲.mp3`）。
/// 仍按下载时的旧路径写标签 → `TagWriterService` 抛 `fileNotReadable`，整次自动刮削静默失败。
///
/// 判据（与 TrackFileRenameService.isSameFile 同口径）：
/// 1. 首选 `URLResourceValues.fileResourceIdentifierKey`（Data）；
/// 2. 回落 `FileManager.attributesOfItem` 的 `.systemNumber`（st_dev）+ `.systemFileNumber`（st_ino）。
struct MacAutoScrapeFileIdentity: Sendable, Equatable {
    private enum Kind: Sendable, Equatable {
        case resourceIdentifier(Data)
        case deviceAndInode(device: UInt64, inode: UInt64)
    }

    private let kind: Kind

    /// 文件存在且能取到身份才返回；否则 nil（调用方按「无法判定」处理）。
    static func capture(at url: URL, fileManager: FileManager = .default) -> MacAutoScrapeFileIdentity? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        if let identifier = (try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier,
           let data = identifier as? Data {
            return MacAutoScrapeFileIdentity(kind: .resourceIdentifier(data))
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value,
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        else { return nil }
        return MacAutoScrapeFileIdentity(kind: .deviceAndInode(device: device, inode: inode))
    }

    /// 给定 URL 现在是否仍是同一个文件（改名/移动不影响；文件不在或取不到身份 → false）。
    func matches(_ url: URL, fileManager: FileManager = .default) -> Bool {
        guard let current = MacAutoScrapeFileIdentity.capture(at: url, fileManager: fileManager) else {
            return false
        }
        return current == self
    }
}

/// 单次自动刮削任务（值类型，可跨并发域传递）
struct MacAutoScrapeJob: Sendable {
    let path: String
    /// 下载时已知的歌曲信息（在线搜索结果的 title/artist，比落盘文件名更准）
    let knownTitle: String?
    let knownArtist: String?
    /// 入队时捕获的文件身份（此刻文件刚下载完、必然存在）；网络检索后据此重新定位被索引改名的文件。
    let identity: MacAutoScrapeFileIdentity?

    init(
        path: String,
        knownTitle: String?,
        knownArtist: String?,
        identity: MacAutoScrapeFileIdentity? = nil
    ) {
        self.path = path
        self.knownTitle = knownTitle
        self.knownArtist = knownArtist
        self.identity = identity
    }
}

enum MacAutoScrapeService {
    /// 日志统一前缀（真机日志按此筛一条链路）
    static let logPrefix = "[自动刮削]"

    // MARK: - 纯决策（可单测）

    /// 是否应该入队：开关开 且 扩展名可写标签（mp3/m4a/mp4/flac/ogg/opus）。
    /// 任一不满足 → 零副作用返回（不建 Task、不读文件、不发网络请求）。
    static func shouldEnqueue(enabled: Bool, `extension`: String) -> Bool {
        guard enabled else { return false }
        return TagWriterService.writableExtensions.contains(`extension`.lowercased())
    }

    /// 下载落盘成功后调用（fire-and-forget：不阻塞下载 UI、不弹窗、不抛错）。
    /// - Parameters:
    ///   - path: 落盘后的绝对路径
    ///   - title: 下载时已知的歌曲名（可 nil）
    ///   - artist: 下载时已知的艺人（可 nil）
    static func enqueueDownloadedFile(path: String, title: String?, artist: String?) {
        let enabled = DeleteSettings.load().scrapingAutoAfterDownload
        let ext = URL(fileURLWithPath: path).pathExtension
        guard shouldEnqueue(enabled: enabled, extension: ext) else { return }
        let job = MacAutoScrapeJob(
            path: path,
            knownTitle: title,
            knownArtist: artist,
            identity: MacAutoScrapeFileIdentity.capture(at: URL(fileURLWithPath: path))
        )
        Task.detached(priority: .utility) {
            await MacAutoScrapeQueue.shared.enqueue(job)
        }
    }
}

/// 串行执行器：同一路径去重；多首下载按入队顺序逐首处理（MusicBrainz 限流）。
actor MacAutoScrapeQueue {
    static let shared = MacAutoScrapeQueue()

    private var pending: [MacAutoScrapeJob] = []
    private var queuedPaths: Set<String> = []
    private var draining = false

    private init() {}

    /// 入队并（若当前空闲）开始串行处理；同路径已在队列/处理中 → 忽略。
    func enqueue(_ job: MacAutoScrapeJob) async {
        guard !queuedPaths.contains(job.path) else { return }
        queuedPaths.insert(job.path)
        pending.append(job)
        // 已有 drain 在跑 → 直接返回，由它按顺序取走本次任务
        guard !draining else { return }
        draining = true
        while !pending.isEmpty {
            let next = pending.removeFirst()
            await MacAutoScrapeWorker.process(next)
            queuedPaths.remove(next.path)
        }
        draining = false
    }
}

/// 单文件自动刮削流水（不抛错：所有失败只落日志，绝不影响下载成功状态）。
enum MacAutoScrapeWorker {
    /// 定位任务文件的**当前**路径（任何改名来源：索引扫掠、手动改名都兜住）。
    ///
    /// - 旧路径存在且身份匹配（或无法判定身份）→ 用旧路径；
    /// - 旧路径不存在 / 已被别的文件占用 → 在同目录枚举，按 identity **唯一**命中返回新路径；
    /// - 0 或多命中 / 无处可找 → nil（调用方跳过，绝不猜）。
    static func resolveCurrentURL(for job: MacAutoScrapeJob, fileManager: FileManager = .default) -> URL? {
        let originalURL = URL(fileURLWithPath: job.path)
        let identity = job.identity
        if fileManager.fileExists(atPath: originalURL.path) {
            if identity == nil || identity?.matches(originalURL, fileManager: fileManager) == true {
                return originalURL
            }
        }
        guard let identity else { return nil }

        let directory = originalURL.deletingLastPathComponent()
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        ) else { return nil }
        let matched = entries.filter { identity.matches($0, fileManager: fileManager) }
        return matched.count == 1 ? matched[0] : nil
    }

    static func process(_ job: MacAutoScrapeJob) async {
        let originalName = URL(fileURLWithPath: job.path).lastPathComponent

        // 0. 先定位文件当前路径：下载落盘到入队之间/之后，索引扫掠可能已按模板改名。
        guard let currentURL = resolveCurrentURL(for: job) else {
            log(.warn, "文件已被移走/改名，跳过 \(originalName)")
            return
        }
        var fileName = currentURL.lastPathComponent
        if currentURL.path != job.path {
            log(.info, "路径已变更（索引改名），改用 \(fileName)（原 \(originalName)）")
        }

        // 1. 等文件被初次索引（最多约 3s）。索引慢也继续——不能因索引没到就丢功能。
        let indexed = await waitForInitialIndex(path: currentURL.path)
        if !indexed {
            log(.info, "等待索引超时（继续刮削）\(fileName)")
        }

        // 1b. 写标签**之前**抓旧 stableId：写完后 stableId 可能变化，播放上下文
        //     （正在播放条 / 播放队列）要靠它找到旧行做替换。取不到（未入库）→ 后续跳过跟随。
        let oldStableId = (try? LibraryReads.track(path: currentURL.path))?.stableId

        // 2. 读现有标签；检索词 = 下载时已知 title → 文件 title → 文件名 stem
        let metadata = try? await AudioMetadataParser.parseMetadata(from: currentURL)
        let queryTitle = firstNonBlank(job.knownTitle, metadata?.title)
        let query = ScrapeLogic.searchQuery(title: queryTitle, fileName: fileName)
        let artist = firstNonBlank(job.knownArtist, metadata?.artist) ?? ""

        // 3. 三源检索 + 按设置源顺序合并
        let settings = DeleteSettings.load()
        let sources = await ScrapeBatchService.scrapeSources(query: query, artist: artist)
        let candidates = ScrapeLogic.mergedCandidates(
            sources: sources,
            sourceOrder: ScrapeSource.resolvedOrder(from: settings.scrapingSourceOrder)
        )
        // 4. 第一个候选直接写（用户口径：不做高置信度门槛）
        guard let candidate = candidates.first else {
            log(.warn, "无候选，未改动文件 \(fileName) query=\(query)")
            return
        }

        // 5. 字段映射（唯一入口）+ 封面（唯一入口；失败只跳过封面）
        let values = ScrapeLogic.fieldValues(from: candidate)
        var request = ScrapeLogic.makeTagWriteRequest(
            values: values,
            renameTemplate: settings.scrapingRenameTemplate
        )
        var wroteCover = false
        if let coverURL = values.coverURL {
            if let data = await ScrapeCoverLoader.loadCoverData(from: coverURL) {
                request.coverData = data
                wroteCover = true
            } else {
                log(.warn, "封面下载失败（跳过封面，继续写其余字段）\(fileName) url=\(coverURL.absoluteString)")
            }
        }

        // 5b. 写前再解析一次：网络检索 + 封面下载要 6–13s，这期间索引扫掠的改名正是
        //     真机 fileNotReadable 的实际出事窗口。解析不到 → 文件已被移走，跳过（不抛给下载调用方）。
        guard let writeURL = resolveCurrentURL(for: job) else {
            log(.warn, "文件已被移走/改名，跳过 \(fileName)")
            return
        }
        if writeURL.path != currentURL.path {
            log(.info, "路径已变更（索引改名），改用 \(writeURL.lastPathComponent)（原 \(fileName)）")
        }
        fileName = writeURL.lastPathComponent

        // 6. 写标签 + 按模板改名
        do {
            let result = try TagWriterService.writeTags(to: writeURL, request: request)
            if result.renamed {
                // DB 写操作唯一入口是 @MainActor 的 AppCoordinator → 从后台 hop 回主线程。
                // 迁移失败仍继续单文件入库（processExternalFile 会按新路径补行），但必须留日志：
                // 否则旧行可能悬空，真机上无法定位（单曲保存同路径会向用户报错，后台链路只能落日志）。
                do {
                    try await MainActor.run {
                        try AppCoordinator.shared.moveTrack(from: writeURL.path, to: result.finalURL.path)
                    }
                } catch {
                    log(.warn, "改名后 DB 引用迁移失败（继续按新路径入库）\(fileName) → \(result.finalURL.lastPathComponent): \(error)")
                }
            }
            // 7. 单文件入库（刷新 DB / 封面缓存）
            let indexed = await LibraryIndexer.shared.processExternalFile(result.finalURL)
            if !indexed {
                log(.warn, "写入成功但单文件入库未通过（等待列表刷新兜底）\(result.finalURL.lastPathComponent)")
            }
            // 8. 主线程收尾（统一在这里 hop 一次，与标签保存路径同口径）：
            //    ① 播放上下文跟随——**改名与未改名都要调**：未改名时标题/歌手/封面也要跟随；
            //       stableId 相同时该调用是幂等 no-op。
            //    ② 补发 LibraryNeedsRefresh：所有列表容器（主库/歌单详情/专辑卡/艺人页/搜索结果）重拉。
            //    不再发 LibraryFolderContentChanged：单文件已由上面入过库，文件夹变化另有 FSEvents
            //    （MacFolderMonitor → 同通知）覆盖；那条会让列表等一次**整库重扫**。
            await MainActor.run {
                if let oldStableId, let fresh = try? LibraryReads.track(path: result.finalURL.path) {
                    AppCoordinator.shared.followRenamedTrack(oldStableId: oldStableId, newTrack: fresh)
                }
                NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)
            }

            let fields = values.writtenFieldNames(coverWritten: wroteCover).joined(separator: ",")
            log(
                .info,
                "完成 \(fileName) → \(result.finalURL.lastPathComponent) 源=\(candidate.source) "
                    + "字段=[\(fields)] 封面=\(wroteCover ? "是" : "否") 改名=\(result.renamed ? "是" : "否")"
                    + " 刷新=已发"
            )
        } catch {
            log(.error, "写入失败（不影响下载结果）\(fileName): \(error)")
        }
    }

    // MARK: - 工具

    /// 轮询曲库索引直到能查到该文件（200ms × 15 次 ≈ 3s）；超时返回 false 由调用方继续。
    private static func waitForInitialIndex(path: String) async -> Bool {
        let attempts = 15
        for attempt in 0 ..< attempts {
            if (try? LibraryReads.track(path: path)) != nil {
                return true
            }
            guard attempt < attempts - 1 else { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }

    /// 首个非空字符串（去首尾空白；全为空 → nil）
    private static func firstNonBlank(_ values: String?...) -> String? {
        for value in values {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private enum LogLevel {
        case info
        case warn
        case error
    }

    private static func log(_ level: LogLevel, _ message: String) {
        let line = "\(MacAutoScrapeService.logPrefix) \(message)"
        switch level {
        case .info: AppLog.info(.general, line)
        case .warn: AppLog.warn(.general, line)
        case .error: AppLog.error(.general, line)
        }
    }
}
