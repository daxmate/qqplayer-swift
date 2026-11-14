//
//  ScrapeBatchService.swift
//  QQPlayer
//
//  批量刮削编排服务（web 版 app/routers/tags.py 的 scrape-batch 语义移植，
//  E1 刮削批 2026-09；2026-11-14 按用户新口径改造）。
//
//  语义（2026-11-14 用户拍板，取代此前的「高置信度 + 分模式字段集」）：
//  - 两种模式只差**目标集**，写入字段集合完全一致：
//    paths：对调用方指定的文件刮削；
//    library：只处理 year 为空 或 genre 为空 的曲目（getTracksMissingYearOrGenre）
//  - **不再有高置信度门槛**：按源优先级合并后的第一个候选直接写（候选不唯一 /
//    艺人不匹配都照写），错了由用户手工重刮。
//  - **写入候选全部可用字段**：title/artist/album/albumArtist/year/genre/track +
//    封面（候选有 coverURL 时下载校验后写；下载失败只记日志，不中断该文件）。
//    字段映射唯一入口 = ScrapeLogic.fieldValues(from:) / makeTagWriteRequest(...)。
//  - 开关：batchEnabled（设置 scraping.batch_enabled，默认关）→ 关时服务直接
//    拒绝（throw ScrapeBatchError.disabled「批量刮削未开启」；UI 层负责在设置
//    关时先提示不调 runBatch，服务层双保险）
//  - 单批最多 100 首（超出取前 100，truncated=true）；逐首间隔 batchSleepSeconds
//    防限流（Task.sleep 可取消）
//  - 单文件三态结果 written/skipped/failed（带 reason），单文件失败不中断整批；
//    skipped 原因：文件不存在 / 格式不支持（预检 ext ∈ TagWriterService.writableExtensions，
//    不进写流程也不发网络请求）/ 无候选 / 候选无任何可写字段
//  - 可取消（Task cancellation 检查点）：每文件处理开始/结束检查；逐首 sleep
//    用 try await Task.sleep；源查询内部吞错（catch 返回 []，含取消）→ 因此
//    每文件刮削完必须再查 Task.isCancelled，取消则 throw CancellationError，
//    绝不许把取消当 skipped 写下去
//  - 批量写完后统一触发一次 LibraryFolderContentChanged 刷新（不走逐首）
//
//  可测性：给定「候选 + 文件状态」的写入决策抽成纯 static 函数 decideWrite
//  （本文件唯一值得单测的新逻辑），runBatch 只负责取数/执行/进度回传。
//
//  ⚠️ 批量写入恒不改名（renameTemplate = nil）：批量改名会引发改名风暴（用户拍板）；
//  只有「下载完成后自动刮削」与单曲编辑（MacTagEditorView）才按设置模板改名。

import Foundation

/// 单文件批量刮削结果（字段冻结，UI 按此写）
struct ScrapeBatchResult: Sendable {
    var path: String
    var status: String        // "written" | "skipped" | "failed"
    var reason: String        // skipped/failed 原因
    var writtenFields: [String]
    var candidateCount: Int
}

/// 批量刮削服务错误（LocalizedError，UI 直接展示 errorDescription）
enum ScrapeBatchError: Error, LocalizedError {
    /// batchEnabled=false（设置 scraping.batch_enabled 关闭）
    case disabled
    /// 批量目标为空（无 paths / library 无待补曲目走正常空结果，不会到这）
    case emptyTarget

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "批量刮削未开启"
        case .emptyTarget:
            return "批量刮削目标为空"
        }
    }
}

enum ScrapeBatchService {
    // MARK: - skipped 原因（web routers/tags.py 文案逐字对齐）

    /// skipped 原因枚举（web reason 文案一致；status=skipped 的 reason 原样展示）
    enum SkipReason {
        static let fileMissing = "文件不存在"
        static let unsupportedFormat = "格式不支持"
        static let noCandidates = "无候选"
        /// 首候选在所有可写字段上都没有有效值（含封面地址）
        static let noWritableFields = "候选无有效字段"
    }

    // MARK: - 写入决策（纯逻辑，可单测）

    /// 写/跳过两态；写入值 = 字段映射唯一入口产出的 ScrapeFieldValues
    /// （nil 字段 = 不写，保留文件原值）
    enum WriteDecision: Equatable {
        case write(ScrapeFieldValues)
        case skip(reason: String)
    }

    /// 给定「候选 + 文件状态」→ 写入决策（原 web _process_batch_file 决策段，
    /// 2026-11-14 起按用户新口径简化）。
    ///
    /// 纯函数：无网络、无文件 IO。runBatch 预检（文件不存在/格式不支持）与
    /// 本函数同源判定（SkipReason 常量共享），预检不通过时不发起网络请求。
    ///
    /// ⚠️ 两种模式**写入字段完全一致**（候选全部可用字段），也不再判高置信度。
    /// `libraryMode` / `fileArtist` 保留在签名里，只为了让调用点与测试显式表达模式、
    /// 并锁住「艺人不再参与门槛」这条口径；判定逻辑不读取它们。
    /// - Parameters:
    ///   - libraryMode: true = library 模式（只影响 runBatch 的目标集，不影响字段集）
    ///   - fileExists: 文件是否在磁盘上（false → skip「文件不存在」）
    ///   - formatSupported: 扩展名是否可写（false → skip「格式不支持」）
    ///   - candidates: 已按 source_order 合并的三源候选
    ///   - fileArtist: 文件当前 artist 标签（历史高置信判定入参；现不参与判定）
    static func decideWrite(
        libraryMode: Bool,
        fileExists: Bool,
        formatSupported: Bool,
        candidates: [ScrapeCandidate],
        fileArtist: String?
    ) -> WriteDecision {
        guard fileExists else {
            return .skip(reason: SkipReason.fileMissing)
        }
        guard formatSupported else {
            return .skip(reason: SkipReason.unsupportedFormat)
        }
        // 只取按源优先级合并后的第一个候选（用户口径：不做高置信度门槛，
        // 写错由用户手工重刮）
        guard let first = candidates.first else {
            return .skip(reason: SkipReason.noCandidates)
        }
        let values = ScrapeLogic.fieldValues(from: first)
        guard !values.isEmpty else {
            return .skip(reason: SkipReason.noWritableFields)
        }
        return .write(values)
    }

    // MARK: - 批量写入请求（唯一构造点）

    /// 批量写入请求：字段映射走 ScrapeLogic 唯一入口，**恒不改名**（renameTemplate = nil）。
    /// 单独成函数是为了让「批量不改名」这条口径有可断言的落点（不要各调用点自己拼 request）。
    static func makeBatchWriteRequest(values: ScrapeFieldValues) -> TagWriteRequest {
        ScrapeLogic.makeTagWriteRequest(values: values, renameTemplate: nil)
    }

    // MARK: - runBatch

    /// 批量刮削。
    ///
    /// - Parameters:
    ///   - paths: paths 模式目标文件绝对路径数组（libraryMode=false 时使用；
    ///     空数组 → throw ScrapeBatchError.emptyTarget）
    ///   - libraryMode: true = 一键整库（忽略 paths，查库选 year/genre 缺失曲目）
    ///   - batchEnabled: 设置 scraping.batch_enabled；false → throw .disabled
    ///   - progress: 每处理完一首回调一次结果（后台 executor 调用，
    ///     UI 需自行 hop 回 MainActor；同步回调顺序 = 处理顺序）
    /// - Returns: (results, truncated)；truncated = 目标超过 100 首被截断。
    /// - Throws: ScrapeBatchError.disabled / .emptyTarget、DB 查询错误、CancellationError。
    static func runBatch(
        paths: [String],
        libraryMode: Bool,
        batchEnabled: Bool,
        progress: @escaping (ScrapeBatchResult) -> Void
    ) async throws -> (results: [ScrapeBatchResult], truncated: Bool) {
        guard batchEnabled else {
            throw ScrapeBatchError.disabled
        }

        // 目标文件集
        let files: [String]
        if libraryMode {
            files = try DatabaseManager.shared.getTracksMissingYearOrGenre().map(\.path)
        } else {
            files = paths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if files.isEmpty {
                throw ScrapeBatchError.emptyTarget
            }
        }

        // 上限 100（web BATCH_LIMIT；超出取前 100 返回 truncated）
        let truncated = files.count > ScrapeLogic.batchLimit
        let targetFiles = Array(files.prefix(ScrapeLogic.batchLimit))

        let settings = DeleteSettings.load()
        // 源顺序取自设置，并补齐缺失的源（旧设置无 itunes → 追加到末尾，保证新源参与合并）
        let sourceOrder = ScrapeSource.resolvedOrder(from: settings.scrapingSourceOrder)

        var results: [ScrapeBatchResult] = []
        for (index, path) in targetFiles.enumerated() {
            // 每文件开始前取消检查（含 sleep 前的检查点）
            try Task.checkCancellation()
            // 逐首防限流间隔（web BATCH_SLEEP_SECONDS；Task.sleep 可取消）
            if index > 0 {
                try await Task.sleep(nanoseconds: UInt64(ScrapeLogic.batchSleepSeconds * 1_000_000_000))
            }
            try Task.checkCancellation()

            let result = await processFile(path: path, libraryMode: libraryMode, sourceOrder: sourceOrder)
            results.append(result)
            progress(result)

            // ⚠️ 每文件刮削完必须查取消：MB/netease 查询内部吞错（catch 返回 []，
            // 含取消），只有这里能把取消正确传播出去——绝不把取消当 skipped 写下去
            try Task.checkCancellation()
        }

        // 批末成功完成（未取消）→ 统一发一次刷新通知（不走逐首）
        NotificationCenter.default.post(name: .libraryFolderContentChanged, object: nil)
        return (results, truncated)
    }

    // MARK: - 刮削源取数（runBatch 与 MacTagEditorView 共享的唯一入口）

    /// 单源取候选函数（生产实现见 liveSearch；测试注入 fake 用于形状断言）。
    typealias ScrapeSourceSearch = @Sendable (ScrapeSource, String, String) async -> [ScrapeCandidate]

    /// 三源刮削候选（web tag_scraper.scrape 语义：各源独立）。
    /// 单源失败返回空数组，绝不 throw（web「任何外部源挂掉都不影响其他源」）。
    /// 返回 [源: 候选]；源集合恒为 ScrapeSource.allCases（防漏源）。
    /// MacTagEditorView 自动刮削与 runBatch 单文件处理共用本入口（行为单一事实源）。
    static func scrapeSources(
        query: String,
        artist: String
    ) async -> [ScrapeSource: [ScrapeCandidate]] {
        await scrapeSources(query: query, artist: artist, search: liveSearch)
    }

    /// 测试 seam：注入检索实现（生产调用点不传，走 liveSearch）。
    static func scrapeSources(
        query: String,
        artist: String,
        search: @escaping ScrapeSourceSearch
    ) async -> [ScrapeSource: [ScrapeCandidate]] {
        await withTaskGroup(of: (ScrapeSource, [ScrapeCandidate]).self) { group in
            for source in ScrapeSource.allCases {
                group.addTask { (source, await search(source, query, artist)) }
            }
            var result: [ScrapeSource: [ScrapeCandidate]] = [:]
            for await (source, candidates) in group {
                result[source] = candidates
            }
            return result
        }
    }

    /// 每源完成回调（**在 MainActor 上调用**；@MainActor @Sendable 便于跨并发域传递）。
    typealias ScrapeSourceCallback = @MainActor @Sendable (ScrapeSource, [ScrapeCandidate]) -> Void

    /// 三源流式刮削：各源并发跑，**每源完成即按完成顺序回调一次**（不攒到最后）。
    /// 回调切到 MainActor。批量（runBatch）不用——批量仍等全部源合并后判定高置信度。
    static func scrapeSourcesStreaming(
        query: String,
        artist: String,
        onSource: @escaping ScrapeSourceCallback
    ) async {
        await scrapeSourcesStreaming(query: query, artist: artist, search: liveSearch, onSource: onSource)
    }

    /// 测试 seam 版本（注入检索实现）。
    static func scrapeSourcesStreaming(
        query: String,
        artist: String,
        search: @escaping ScrapeSourceSearch,
        onSource: @escaping ScrapeSourceCallback
    ) async {
        await withTaskGroup(of: (ScrapeSource, [ScrapeCandidate]).self) { group in
            for source in ScrapeSource.allCases {
                group.addTask { (source, await search(source, query, artist)) }
            }
            for await (source, candidates) in group {
                // onSource 为 @MainActor 闭包 → await 即 hop 到 MainActor
                await onSource(source, candidates)
            }
        }
    }

    /// 单源取候选的生产实现（唯一分发点）。@Sendable 闭包常量（直接作 seam 值，
    /// 避免把非 Sendable 的函数值转成 @Sendable 闭包的告警）。
    static let liveSearch: ScrapeSourceSearch = { source, query, artist in
        switch source {
        case .netease:
            return await scrapeNetease(query: query)
        case .itunes:
            return await ITunesScrapeClient().candidates(query: query)
        case .musicbrainz:
            return await scrapeMusicBrainz(query: query, artist: artist)
        }
    }

    /// 网易云搜索 → ScrapeCandidate（source=ScrapeSource.netease；id/title/artist/album/
    /// coverURL/durationMs 直填；year/genre/track/albumArtist 缺省 nil——cloudsearch 不返回）
    private static func scrapeNetease(query: String) async -> [ScrapeCandidate] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let songs: [NeteaseOnlineSong]
        do {
            songs = try await NeteaseOnlineClient().search(query: query, limit: 20)
        } catch {
            return []
        }
        return songs.map { song in
            ScrapeCandidate(
                source: ScrapeSource.netease.rawValue,
                id: String(song.id),
                title: song.title,
                artist: song.artist,
                album: song.album,
                coverURL: song.coverURL,
                year: nil,
                genre: nil,
                track: nil,
                albumArtist: nil,
                durationMs: song.durationMs
            )
        }
    }

    /// MusicBrainz recording 搜索 → ScrapeCandidate（source="musicbrainz"；全字段尽力取值）
    private static func scrapeMusicBrainz(query: String, artist: String) async -> [ScrapeCandidate] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        do {
            return try await MusicBrainzClient().searchMusicBrainz(title: query, artist: artist)
        } catch {
            return []
        }
    }

    // MARK: - 单文件处理（web _process_batch_file 移植）

    /// 单文件批量刮削：预检 → 读当前标签 → 双源搜索 → 合并 → 决策 → 写入。
    /// 任何单文件异常 → failed 结果，绝不中断整批（取消由外层 runBatch 检查点负责，
    /// 本函数不吞 CancellationError 之外的系统错误——网络搜索错误在此容错为空候选）。
    private static func processFile(
        path: String,
        libraryMode: Bool,
        sourceOrder: [ScrapeSource]
    ) async -> ScrapeBatchResult {
        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent

        // 预检 1：文件不存在（web extract_tags 后 is_file 检查同文案）
        guard FileManager.default.fileExists(atPath: path) else {
            return skippedResult(path: path, reason: SkipReason.fileMissing)
        }
        // 预检 2：格式不支持（不进写流程也不发网络请求）
        let ext = url.pathExtension.lowercased()
        guard TagWriterService.writableExtensions.contains(ext) else {
            return skippedResult(path: path, reason: SkipReason.unsupportedFormat)
        }

        // 读文件当前标签（artist 供检索加分 / title 供 query；解析失败容错为 nil
        // ——web extract_tags 异常回落 None 语义）
        let fileArtist: String?
        let fileTitle: String?
        if let metadata = try? await AudioMetadataParser.parseMetadata(from: url) {
            fileArtist = metadata.artist
            fileTitle = metadata.title
        } else {
            fileArtist = nil
            fileTitle = nil
        }
        let query = ScrapeLogic.searchQuery(title: fileTitle, fileName: fileName)

        // 三源搜索（单源失败返回空，绝不 throw；MB 内部含取消都吞 → 外层检查点兜底）
        let sources = await scrapeSources(query: query, artist: fileArtist ?? "")

        let candidates = ScrapeLogic.mergedCandidates(
            sources: sources,
            sourceOrder: sourceOrder
        )

        let decision = decideWrite(
            libraryMode: libraryMode,
            fileExists: true,
            formatSupported: true,
            candidates: candidates,
            fileArtist: fileArtist
        )

        switch decision {
        case .skip(let reason):
            return skippedResult(path: path, reason: reason, candidateCount: candidates.count)
        case .write(let values):
            return await writeFile(path: path, values: values, candidateCount: candidates.count)
        }
    }

    /// 执行写标签（paths/library 统一入口）。
    /// 字段映射走唯一入口 ScrapeLogic.makeTagWriteRequest（批量恒 renameTemplate=nil）；
    /// 封面走唯一入口 ScrapeCoverLoader（失败只记日志，不影响该文件其余字段）。
    /// 写失败 → failed 结果（不中断整批）。
    private static func writeFile(
        path: String,
        values: ScrapeFieldValues,
        candidateCount: Int
    ) async -> ScrapeBatchResult {
        let url = URL(fileURLWithPath: path)
        // 批量恒不改名（Mac 端拍板，见文件头 ⚠️）
        var request = makeBatchWriteRequest(values: values)
        var wroteCover = false
        if let coverURL = values.coverURL {
            if let data = await ScrapeCoverLoader.loadCoverData(from: coverURL) {
                request.coverData = data
                wroteCover = true
            } else {
                AppLog.warn(.general, "⚠️ [批量刮削] 封面下载失败（跳过封面，继续写其余字段） "
                    + "\(url.lastPathComponent) url=\(coverURL.absoluteString)")
            }
        }
        do {
            _ = try TagWriterService.writeTags(to: url, request: request)
            let written = values.writtenFieldNames(coverWritten: wroteCover)
            return ScrapeBatchResult(
                path: path,
                status: "written",
                reason: "",
                writtenFields: written,
                candidateCount: candidateCount
            )
        } catch {
            // web reason 文案：「写入失败: {e}」
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return ScrapeBatchResult(
                path: path,
                status: "failed",
                reason: "写入失败: \(reason)",
                writtenFields: [],
                candidateCount: candidateCount
            )
        }
    }

    private static func skippedResult(path: String, reason: String, candidateCount: Int = 0) -> ScrapeBatchResult {
        ScrapeBatchResult(
            path: path,
            status: "skipped",
            reason: reason,
            writtenFields: [],
            candidateCount: candidateCount
        )
    }
}
