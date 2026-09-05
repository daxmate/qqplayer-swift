//
//  ScrapeLogic.swift
//  QQPlayer
//
//  刮削编排纯逻辑（web 版 tag_scraper.scrape + routers/tags.py 的候选合并/高置信度
//  判定移植，E1 刮削批 2026-09）。纯函数，全部可单测，无网络。
//
//  语义对齐 web：
//  - scrape 请求构造：query = 文件 title，title 空 → 文件名 stem（不含扩展名）；
//    artist 单独传（只用于排序加分，不作硬条件）
//  - 候选合并（web _merge_candidates）：按 source_order 顺序合并各源候选
//    （source_order 如 ["netease", "musicbrainz"]），空源跳过
//  - 高置信度判定（web _is_high_confidence，批量 paths 模式自动写入用）：
//    候选数 == 1 → true；文件 artist 为空 → true（取首候选）；否则
//    首候选 artist 与文件 artist 归一化匹配（MusicBrainzClient.artistMatches）→ true
//  - 批量字段集（web BATCH_WRITABLE_FIELDS）：paths 模式写
//    title/artist/album/year/genre（不写封面/track/album_artist，避免刮错）；
//    library 模式只补 year/genre（候选有值才写）
//  - 批量上限 100（超出取前 100，truncated）；每首之间 sleep（MB 限流，web 0.8s
//    + MB 查询自身 1s/阶段；批量粒度由调用方控制，本逻辑只提供常数）

import Foundation

enum ScrapeLogic {
    /// web BATCH_LIMIT
    static let batchLimit = 100
    /// web BATCH_SLEEP_SECONDS（批量逐首防限流间隔）
    static let batchSleepSeconds: TimeInterval = 0.8
    /// paths 模式批量可写字段（web BATCH_WRITABLE_FIELDS）
    static let batchWritableFields: Set<String> = ["title", "artist", "album", "year", "genre"]

    /// 候选合并：按 source_order 保序合并各源（web _merge_candidates）。S2 实现。
    static func mergedCandidates(
        netease: [ScrapeCandidate],
        musicbrainz: [ScrapeCandidate],
        sourceOrder: [String]
    ) -> [ScrapeCandidate] {
        fatalError("S2 实现")
    }

    /// 高置信度判定（web _is_high_confidence）。S2 实现。
    static func isHighConfidence(candidates: [ScrapeCandidate], fileArtist: String?) -> Bool {
        fatalError("S2 实现")
    }

    /// query 构造：title 空回落文件名 stem（web routers/tags.py 语义）。S2 实现。
    static func searchQuery(title: String?, fileName: String) -> String {
        fatalError("S2 实现")
    }
}
