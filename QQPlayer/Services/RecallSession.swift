//
//  RecallSession.swift
//  QQPlayer
//
//  推荐 P2：会话池 + 游标 + 已推集合（「换一批」不重新请求网络）。
//
//  - 首批 15 首；游标推进；池剩余 < 一批 = needsRefill（由调用方做增量查询）
//  - 同批约束：同艺人 ≤4、同专辑 ≤2（设计 §5）
//  - `seen` 会话内持久：同一候选不会被两批重复推荐
//

import Foundation

/// 推荐会话池（值类型；由调用方持有并更新）。
struct RecallSession: Sendable, Equatable {
    enum RefillState: String, Sendable {
        /// 剩余足够下一批。
        case ready
        /// 不足一批，仍需增量查询（调用方可在换批前补池）。
        case needsRefill
        /// 池已耗尽。
        case exhausted
    }

    /// 单批多样性报告（P3：放宽了的多样性目标绝不静默）。
    struct BatchDiversityReport: Sendable, Equatable {
        /// 本批不同艺人个数。
        var distinctArtists: Int = 0
        /// 被放宽的目标（空 = 全部满足）。
        var relaxed: [RecommendationBatchDiversity.Relaxation] = []

        var isRelaxed: Bool { !relaxed.isEmpty }
        /// 日志 token：`diversity_relaxed=decade,genre`（未放宽为空串）。
        var logToken: String { relaxed.map(\.rawValue).joined(separator: ",") }
    }

    private(set) var pool: [RecommendedCandidate]
    private(set) var seen: Set<String>
    let batchSize: Int
    let maxPerArtist: Int
    let maxPerAlbum: Int
    /// 最近一批的多样性结果（`nextBatch()` 写入）。
    private(set) var lastBatchDiversity = BatchDiversityReport()

    init(
        pool: [RecommendedCandidate] = [],
        batchSize: Int = RecommendationBatchPolicy.batchSize,
        maxPerArtist: Int = RecommendationBatchPolicy.maxSongsPerArtist,
        maxPerAlbum: Int = RecommendationBatchPolicy.maxSongsPerAlbum
    ) {
        self.pool = pool
        self.seen = []
        self.batchSize = max(1, batchSize)
        self.maxPerArtist = max(1, maxPerArtist)
        self.maxPerAlbum = max(1, maxPerAlbum)
    }

    /// 池里还没被消费/标记的候选数。
    var remaining: Int {
        pool.reduce(into: 0) { count, candidate in
            if !seen.contains(Self.key(candidate)) { count += 1 }
        }
    }

    var state: RefillState {
        if remaining == 0 { return .exhausted }
        return remaining < batchSize ? .needsRefill : .ready
    }

    /// 取下一批：推进游标、标记 seen、应用同批上限 + 多样性目标（P3）。
    ///
    /// 选择口径在 `RecommendationBatchDiversity`（纯函数）：艺人 ≤4 / 专辑 ≤2 是硬上限，
    /// 不同艺人 ≥8、同 decade / 同 genre ≤9 是目标；池不够时放宽并写进 `lastBatchDiversity`。
    mutating func nextBatch() -> [RecommendedCandidate] {
        // 口径：在「本轮还没推过」的候选里按池顺序（= 排名顺序）选一批。
        // ⚠️ 不能用「游标后缀 + 只推进到扫过的位置」：多样性替换会从池后段取新艺人，
        // 中间没被选中的候选会被游标跨过去却仍算 remaining（漏池、池利用率骤降）。
        let eligible = pool.filter { !seen.contains(Self.key($0)) }
        let outcome = RecommendationBatchDiversity.select(eligible, limits: diversityLimits)
        for candidate in outcome.candidates {
            seen.insert(Self.key(candidate))
        }
        lastBatchDiversity = BatchDiversityReport(
            distinctArtists: Set(outcome.candidates.map(Self.artistKey)).count,
            relaxed: outcome.relaxed
        )
        return outcome.candidates
    }

    /// 单批多样性口径（batchSize / 上限可注入，保持 P2 的可配置性）。
    private var diversityLimits: RecommendationBatchDiversity.Limits {
        RecommendationBatchDiversity.Limits(
            batchSize: batchSize,
            maxPerArtist: maxPerArtist,
            maxPerAlbum: maxPerAlbum,
            minDistinctArtists: min(RecommendationBatchPolicy.minDistinctArtists, batchSize),
            maxPerDecade: RecommendationBatchPolicy.maxSongsPerDecade,
            maxPerGenre: RecommendationBatchPolicy.maxSongsPerGenre
        )
    }

    /// 取一整批；不足 `minimum` 且池未耗尽时 **不消费**（游标 / seen 原样保留），返回 nil。
    ///
    /// 语义要点：调用方可在补池后重试；只有池真正耗尽时才返回不足一批的剩余。
    mutating func takeFullBatchOrNil(minimum: Int? = nil) -> [RecommendedCandidate]? {
        let target = min(max(1, minimum ?? batchSize), batchSize)
        var working = self
        let batch = working.nextBatch()
        if batch.count < target {
            return nil
        }
        self = working
        return batch
    }

    /// 增量补池（去重；返回实际加入条数）。游标保持不动，新条目追加在末尾。
    @discardableResult
    mutating func append(pool newItems: [RecommendedCandidate]) -> Int {
        var added = 0
        for item in newItems {
            let key = Self.key(item)
            guard !seen.contains(key), !pool.contains(where: { Self.key($0) == key }) else { continue }
            pool.append(item)
            added += 1
        }
        return added
    }

    /// 标记一批已展示但未消费的候选（例如缓存恢复的历史结果）。
    mutating func markSeen(_ candidates: [RecommendedCandidate]) {
        for candidate in candidates {
            seen.insert(Self.key(candidate))
        }
    }

    /// 与引擎排除集 / 软黑名单同口径（`RecommendationKey.normalize`），保证 seen 可直接喂回 `excludedTrackKeys`。
    static func key(_ candidate: RecommendedCandidate) -> String {
        RecommendationKey.normalize(title: candidate.title, artist: candidate.artist)
    }

    static func artistKey(_ candidate: RecommendedCandidate) -> String {
        RecommendationNormalization.normalizeArtist(candidate.artist)
    }

    static func albumKey(_ candidate: RecommendedCandidate) -> String {
        guard let album = candidate.album, !album.isEmpty else {
            return "no-album#\(artistKey(candidate))"
        }
        return RecommendationNormalization.normalizeTitle(album)
    }
}
