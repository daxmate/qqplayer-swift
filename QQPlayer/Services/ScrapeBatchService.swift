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
//  - 开关：batchEnabled（设置 scraping.batch_enabled，默认关）→ 关时返回 enabled=false
//  - 单批最多 100 首（超出取前 100，truncated=true）；逐首间隔 batchSleepSeconds 防限流
//  - 单文件三态结果 written/skipped/failed（带 reason），单文件失败不中断整批；
//    skipped 原因：文件不存在 / 无候选 / （paths 模式）候选不唯一且非高置信 /
//    （library 模式）候选无 year/genre / 格式不支持
//  - 高置信度判定与字段集见 ScrapeLogic
//  - 可取消（Task cancellation 检查点）；逐首结果回调（进度 UI）
//
//  批量写完后统一触发一次 LibraryFolderContentChanged 刷新（不走逐首）

import Foundation

struct ScrapeBatchResult: Sendable {
    var path: String
    var status: String        // "written" | "skipped" | "failed"
    var reason: String        // skipped/failed 原因
    var writtenFields: [String]
    var candidateCount: Int
}

enum ScrapeBatchService {
    /// 批量刮削。S4 实现。
    static func runBatch(
        paths: [String],
        libraryMode: Bool,
        batchEnabled: Bool,
        progress: @escaping (ScrapeBatchResult) -> Void
    ) async throws -> (results: [ScrapeBatchResult], truncated: Bool) {
        fatalError("S4 实现：见文件头契约（依赖 TagWriterService/MusicBrainzClient/ScrapeLogic）")
    }
}
