//
//  ScrapeLogic.swift
//  QQPlayer
//
//  刮削编排纯逻辑（web 版 tag_scraper.scrape + routers/tags.py 的候选合并移植，
//  E1 刮削批 2026-09）。纯函数，全部可单测，无网络。
//
//  语义（2026-11-14 用户新口径：不再有高置信度门槛、不再按模式分字段集）：
//  - scrape 请求构造：query = 文件 title，title 空 → 文件名 stem（不含扩展名）；
//    artist 单独传（只用于检索加分，不作硬条件）
//  - 候选合并（web _merge_candidates）：按 source_order 顺序合并各源候选
//    （sourceOrder 为 [ScrapeSource]，如 [.netease, .itunes]），空源跳过
//  - **字段映射唯一入口**：fieldValues(from:) 把候选全字段映射成 ScrapeFieldValues，
//    makeTagWriteRequest(values:renameTemplate:) 组装写标签请求。自动刮削（下载完成后）
//    与批量刮削**必须**共用这两个函数，禁止各写一份字段映射。
//  - 自动刮削与批量刮削都取按源优先级合并后的**第一个候选直接写**（无高置信度
//    门槛，错了由用户手工重刮）。
//  - 批量上限 100（超出取前 100，truncated）；每首之间 sleep（MB 限流，web 0.8s
//    + MB 查询自身 1s/阶段；批量粒度由调用方控制，本逻辑只提供常数）

import Foundation

enum ScrapeLogic {
    /// web BATCH_LIMIT
    static let batchLimit = 100
    /// web BATCH_SLEEP_SECONDS（批量逐首防限流间隔）
    static let batchSleepSeconds: TimeInterval = 0.8
    /// 候选合并：按 sourceOrder 保序合并各源候选（web _merge_candidates）。
    /// sourceOrder 里出现的源按序取该源全部候选；空源跳过。
    /// 源枚举见 ScrapeSource（唯一注册表）；本函数不再持有任何源字符串列表。
    static func mergedCandidates(
        sources: [ScrapeSource: [ScrapeCandidate]],
        sourceOrder: [ScrapeSource]
    ) -> [ScrapeCandidate] {
        var merged: [ScrapeCandidate] = []
        for source in sourceOrder {
            merged.append(contentsOf: sources[source] ?? [])
        }
        return merged
    }

    /// 封面图片格式判据（**唯一入口**）：只接受 JPEG / PNG（魔数）。
    ///
    /// 供两处共用，**禁止**在别处再写第二份魔数判断：
    ///  · 「候选封面下载」`ScrapeCoverLoader.loadCoverData`（web tag_editor.fetch_cover 语义；
    ///    单曲点选 / 下载后自动刮削 / 批量刮削三条链路共用）；
    ///  · 「从本地选择图片…」`MacTagEditorView+Scrape.chooseLocalCoverImage`（B1，2026-10-10）。
    /// 空数据 / 其它格式（GIF / 文本 / 截断）一律拒。
    static func validateCoverData(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return data.starts(with: [0xFF, 0xD8, 0xFF])
            || data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    }

    /// query 构造：title 非空 → title；空 → 文件名去扩展名取末段（web query = title or f.stem）
    static func searchQuery(title: String?, fileName: String) -> String {
        if let title, !title.isEmpty {
            return title
        }
        return URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
    }

    // MARK: - 刮削字段映射（唯一入口）

    /// 候选 → 标签字段值（**唯一映射入口**）。
    /// 自动刮削（下载完成后）与批量刮削都走这里；空串/纯空白归一为 nil（= 不写，保留文件原值）。
    static func fieldValues(from candidate: ScrapeCandidate) -> ScrapeFieldValues {
        ScrapeFieldValues(
            title: nonBlank(candidate.title),
            artist: nonBlank(candidate.artist),
            album: nonBlank(candidate.album),
            albumArtist: nonBlank(candidate.albumArtist),
            genre: nonBlank(candidate.genre),
            year: candidate.year,
            trackNumber: candidate.track,
            coverURL: candidate.coverURL
        )
    }

    /// 字段值 → 写标签请求（有值才写）。封面数据由调用方异步下载校验后补到
    /// request.coverData（本函数不碰网络）。
    /// - Parameter renameTemplate: nil = 不改名（批量恒传 nil）；非 nil = 按模板改名
    static func makeTagWriteRequest(values: ScrapeFieldValues, renameTemplate: String?) -> TagWriteRequest {
        var request = TagWriteRequest()
        request.title = values.title
        request.artist = values.artist
        request.album = values.album
        request.albumArtist = values.albumArtist
        request.genre = values.genre
        request.year = values.year
        request.trackNumber = values.trackNumber
        request.renameTemplate = renameTemplate
        return request
    }

    /// 空串 / 纯空白 → nil（写标签语义：nil = 保留文件原值）
    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 刮削候选 → 标签字段值（**字段映射唯一入口**的数据形状）。
///
/// 自动刮削与批量刮削共用：不要再往别处复制一份「候选字段 → 请求字段」的映射。
/// coverURL 只携带地址；下载与格式校验统一走 ScrapeCoverLoader。
struct ScrapeFieldValues: Equatable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var coverURL: URL?

    /// 是否有任何可写内容（全空 = 写无可写，跳过）。封面单独也算内容。
    var isEmpty: Bool {
        title == nil && artist == nil && album == nil && albumArtist == nil
            && genre == nil && year == nil && trackNumber == nil && coverURL == nil
    }

    /// 实际写入的字段名（批量结果展示 / 自动刮削日志共用；字典序）。
    /// 封面是否写成由调用方告知（下载失败会跳过封面，与本结构的 coverURL 无关）。
    func writtenFieldNames(coverWritten: Bool) -> [String] {
        var fields: [String] = []
        if title != nil { fields.append("title") }
        if artist != nil { fields.append("artist") }
        if album != nil { fields.append("album") }
        if albumArtist != nil { fields.append("albumArtist") }
        if year != nil { fields.append("year") }
        if genre != nil { fields.append("genre") }
        if trackNumber != nil { fields.append("track") }
        if coverWritten { fields.append("cover") }
        return fields.sorted()
    }
}
