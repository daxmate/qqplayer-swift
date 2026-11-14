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
//  → LibraryIndexer 单文件入库 → 发 LibraryFolderContentChanged。
//

import Foundation

/// 单次自动刮削任务（值类型，可跨并发域传递）
struct MacAutoScrapeJob: Sendable {
    let path: String
    /// 下载时已知的歌曲信息（在线搜索结果的 title/artist，比落盘文件名更准）
    let knownTitle: String?
    let knownArtist: String?
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
        let job = MacAutoScrapeJob(path: path, knownTitle: title, knownArtist: artist)
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
    static func process(_ job: MacAutoScrapeJob) async {
        let url = URL(fileURLWithPath: job.path)
        let fileName = url.lastPathComponent

        guard FileManager.default.fileExists(atPath: job.path) else {
            log(.warn, "文件不存在，跳过 \(fileName)")
            return
        }

        // 1. 等文件被初次索引（最多约 3s）。索引慢也继续——不能因索引没到就丢功能。
        let indexed = await waitForInitialIndex(path: job.path)
        if !indexed {
            log(.info, "等待索引超时（继续刮削）\(fileName)")
        }

        // 2. 读现有标签；检索词 = 下载时已知 title → 文件 title → 文件名 stem
        let metadata = try? await AudioMetadataParser.parseMetadata(from: url)
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

        // 6. 写标签 + 按模板改名
        do {
            let result = try TagWriterService.writeTags(to: url, request: request)
            if result.renamed {
                // DB 写操作唯一入口是 @MainActor 的 AppCoordinator → 从后台 hop 回主线程
                try? await MainActor.run {
                    try AppCoordinator.shared.moveTrack(from: job.path, to: result.finalURL.path)
                }
            }
            // 7. 单文件入库（刷新 DB / 封面缓存）→ 列表刷新信号
            _ = await LibraryIndexer.shared.processExternalFile(result.finalURL)
            NotificationCenter.default.post(name: .libraryFolderContentChanged, object: nil)

            let fields = values.writtenFieldNames(coverWritten: wroteCover).joined(separator: ",")
            log(
                .info,
                "完成 \(fileName) → \(result.finalURL.lastPathComponent) 源=\(candidate.source) "
                    + "字段=[\(fields)] 封面=\(wroteCover ? "是" : "否") 改名=\(result.renamed ? "是" : "否")"
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
