//
//  ScrapeBatchService.swift
//  QQPlayer
//
//  批量刮削编排服务（web 版 app/routers/tags.py 的 scrape-batch 语义移植，
//  E1 刮削批 2026-09）。骨架：S4（UI 批）实现，依赖 S1 TagWriterService + S2 源。
//
//  语义对齐 web（/api/tags/scrape-batch）：
//  - 两种模式：
//    paths：对指定文件刮削，高置信度自动写入 title/artist/album/year/genre
//      （覆盖现有值；不写封面/track/album_artist）
//    library：整库只处理 year 为空 或 genre 为空 的曲目，只补 year/genre
//  - 开关：batchEnabled（设置 scraping.batch_enabled，默认关）→ 关时服务直接
//    拒绝（throw ScrapeBatchError.disabled「批量刮削未开启」；UI 层负责在设置
//    关时先提示不调 runBatch，服务层双保险）
//  - 单批最多 100 首（超出取前 100，truncated=true）；逐首间隔 batchSleepSeconds
//    防限流（Task.sleep 可取消）
//  - 单文件三态结果 written/skipped/failed（带 reason），单文件失败不中断整批；
//    skipped 原因：文件不存在 / 无候选 / （paths 模式）候选不唯一且非高置信 /
//    （library 模式）候选无 year/genre / 格式不支持（预检 ext ∈
//    TagWriterService.writableExtensions，不进写流程也不发网络请求）
//  - 高置信度判定与字段集见 ScrapeLogic
//  - 可取消（Task cancellation 检查点）：每文件处理开始/结束检查；逐首 sleep
//    用 try await Task.sleep；MB 查询内部吞错（catch 返回 []，含取消）→ 因此
//    每文件刮削完必须再查 Task.isCancelled，取消则 throw CancellationError，
//    绝不许把取消当 skipped 写下去
//  - 批量写完后统一触发一次 LibraryFolderContentChanged 刷新（不走逐首）
//
//  可测性：给定「候选 + fileArtist + 模式 + 文件状态」的写入决策抽成纯 static
//  函数 decideWrite（本文件唯一值得单测的新逻辑），runBatch 只负责取数/执行/
//  进度回传，不做网络/文件 IO 单测。
//
//  ⚠️ 批量写入恒不改名（renameTemplate = nil）：web 批量会把文件按设置模板
//  改名，Mac 端拍板批量只写标签不碰文件名（避免批量改名风暴），单曲编辑
//  （MacTagEditorView）才处理改名。
//
//  ⚠️ 批量不写封面/track/album_artist（web BATCH_WRITABLE_FIELDS 对齐，避免刮错）。

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
        /// paths 模式：候选 >1 且首候选 artist 与文件 artist 不归一化匹配
        static let notHighConfidence = "候选不唯一"
        /// library 模式：首候选无 year 也无 genre
        static let noYearGenre = "候选无 year/genre"
        /// paths 模式：首候选在 BATCH_WRITABLE_FIELDS 内无有效值
        static let noWritableFields = "候选无有效字段"
    }

    // MARK: - 写入决策（纯逻辑，可单测）

    /// 决策要写入的字段值（nil = 该字段不写，保留文件原值）
    struct ScrapeWriteValues: Equatable {
        var title: String?
        var artist: String?
        var album: String?
        var year: Int?
        var genre: String?

        var isEmpty: Bool {
            let titleNonEmpty = title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let artistNonEmpty = artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let albumNonEmpty = album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let genreNonEmpty = genre?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            return !titleNonEmpty && !artistNonEmpty && !albumNonEmpty && year == nil && !genreNonEmpty
        }
    }

    enum WriteDecision: Equatable {
        case write(ScrapeWriteValues)
        case skip(reason: String)
    }

    /// 给定「候选 + 文件状态 + 模式」→ 写入决策（web _process_batch_file 决策段移植）。
    ///
    /// 纯函数：无网络、无文件 IO。runBatch 预检（文件不存在/格式不支持）与
    /// 本函数同源判定（SkipReason 常量共享），预检不通过时不发起网络请求。
    /// - Parameters:
    ///   - libraryMode: true = library 模式（只补 year/genre、不判高置信）
    ///   - fileExists: 文件是否在磁盘上（false → skip「文件不存在」）
    ///   - formatSupported: 扩展名是否可写（false → skip「格式不支持」）
    ///   - candidates: 已按 source_order 合并的双源候选（netease + musicbrainz）
    ///   - fileArtist: 文件当前 artist 标签（paths 模式高置信判定用）
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
        guard !candidates.isEmpty else {
            return .skip(reason: SkipReason.noCandidates)
        }
        // paths 模式高置信门禁；library 模式不判（web 对齐）
        if !libraryMode && !ScrapeLogic.isHighConfidence(candidates: candidates, fileArtist: fileArtist) {
            return .skip(reason: SkipReason.notHighConfidence)
        }

        // 只取首候选（web candidates[0]）
        let first = candidates[0]
        if libraryMode {
            // 只补 year/genre（候选有值才写）
            var values = ScrapeWriteValues()
            values.year = first.year
            if let genre = first.genre?.trimmingCharacters(in: .whitespacesAndNewlines),
               !genre.isEmpty {
                values.genre = genre
            }
            if values.year == nil && values.genre == nil {
                return .skip(reason: SkipReason.noYearGenre)
            }
            return .write(values)
        }

        // paths 模式：BATCH_WRITABLE_FIELDS 有值才写（覆盖现有值）
        var values = ScrapeWriteValues()
        values.title = trimmed(first.title)
        values.artist = trimmed(first.artist)
        values.album = trimmed(first.album)
        values.year = first.year
        values.genre = trimmed(first.genre)
        if values.isEmpty {
            return .skip(reason: SkipReason.noWritableFields)
        }
        return .write(values)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
        let sourceOrder = settings.scrapingSourceOrder

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
        NotificationCenter.default.post(name: NSNotification.Name("LibraryFolderContentChanged"), object: nil)
        return (results, truncated)
    }

    // MARK: - 双源刮削（runBatch 与 MacTagEditorView 共享的唯一入口）

    /// 双源刮削候选（web tag_scraper.scrape 语义：netease + musicbrainz 两源独立）。
    /// 单源失败返回空数组，绝不 throw（web「任何外部源挂掉都不影响其他源」）。
    /// MacTagEditorView 自动刮削与 runBatch 单文件处理共用本入口（行为单一事实源）。
    static func scrapeSources(
        query: String,
        artist: String
    ) async -> (netease: [ScrapeCandidate], musicbrainz: [ScrapeCandidate]) {
        async let neteaseTask = scrapeNetease(query: query)
        async let mbTask = scrapeMusicBrainz(query: query, artist: artist)
        return await (neteaseTask, mbTask)
    }

    /// 网易云搜索 → ScrapeCandidate（source="netease"；id/title/artist/album/coverURL/
    /// durationMs 直填；year/genre/track/albumArtist 缺省 nil——cloudsearch 不返回）
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
                source: "netease",
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
        sourceOrder: [String]
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

        // 读文件当前标签（artist 供高置信判定 / title 供 query；解析失败容错为 nil
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

        // 双源搜索（单源失败返回空，绝不 throw；MB 内部含取消都吞 → 外层检查点兜底）
        let sources = await scrapeSources(query: query, artist: fileArtist ?? "")
        let neteaseCandidates = sources.netease
        let musicbrainzCandidates = sources.musicbrainz

        let candidates = ScrapeLogic.mergedCandidates(
            netease: neteaseCandidates,
            musicbrainz: musicbrainzCandidates,
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
            return writeFile(path: path, values: values, candidateCount: candidates.count)
        }
    }

    /// 执行写标签（paths/library 统一入口）。写失败 → failed 结果（不中断整批）。
    private static func writeFile(path: String, values: ScrapeWriteValues, candidateCount: Int) -> ScrapeBatchResult {
        let url = URL(fileURLWithPath: path)
        var request = TagWriteRequest()
        // 批量恒不改名（Mac 端拍板，见文件头 ⚠️）
        request.renameTemplate = nil
        // 只写决策字段；nil/空 = 保留文件原值（TagWriterService 语义）
        request.title = values.title
        request.artist = values.artist
        request.album = values.album
        request.year = values.year
        if let genre = values.genre?.trimmingCharacters(in: .whitespacesAndNewlines),
           !genre.isEmpty {
            request.genre = genre
        }
        do {
            _ = try TagWriterService.writeTags(to: url, request: request)
            let written = writtenFieldNames(values)
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

    /// 写了的字段名（web sorted(write) 字典序对齐）
    private static func writtenFieldNames(_ values: ScrapeWriteValues) -> [String] {
        var fields: [String] = []
        if values.title != nil { fields.append("title") }
        if values.artist != nil { fields.append("artist") }
        if values.album != nil { fields.append("album") }
        if values.year != nil { fields.append("year") }
        if values.genre != nil { fields.append("genre") }
        return fields.sorted()
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
