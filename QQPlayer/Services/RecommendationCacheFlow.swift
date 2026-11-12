//
//  RecommendationCacheFlow.swift
//  QQPlayer
//
//  本地 AI 推荐 P3：缓存命中编排（exact 优先 → stale 垫底 + 后台重算 → miss 同步重算）。
//
//  语义（用户拍板「方案 A：列表优先」）：
//  - 精确命中：键完全一致且 ≤ 24h → 直接返回，不发任何请求。
//  - stale 命中：精确键失效，但存在「同请求身份」（rawText + planner + 模型 + locale）≤ 7 天的旧条目
//    → 立即返回旧候选（列表不清空、不进入 loading 空白态），后台重算完成后平滑替换并写回新键。
//  - 手动刷新（bypass）：不读 stale，清掉当前键与同 baseKey 的旧条目后同步重算。
//
//  ⚠️ 这里是共享层：Mac 模型只负责把结果映射到 UI 状态，本文件不碰视图、不读曲库。
//

import Foundation

/// 一次重算的产物（planner + 召回的最终结果）。
struct RecommendationRecompute: Equatable, Sendable {
    var candidates: [RecommendedCandidate]
    var planSource: RecommendationPlanSource
    var requestedArtist: String?
}

/// 缓存命中决策 + 后台重算编排。
///
/// 标注 @MainActor：与 UI 模型同一条执行线，后台重算的回写不会与用户操作竞态。
@MainActor
final class RecommendationCacheFlow {
    /// 一次请求的缓存决策。
    enum Lookup: Equatable {
        /// 精确命中：直接展示，不发起任何请求。
        case exact(RecommendationCacheHit)
        /// stale 命中：先展示旧候选，随后后台重算。
        case stale(RecommendationCacheHit)
        /// 未命中：同步重算。
        case miss
    }

    private let cache: RecommendationResultCache?
    private let clock: () -> Date
    /// 代次：每次新请求 +1。后台重算只在代次未变时写回，防止旧任务覆盖新结果。
    private var generation = 0
    private var backgroundTask: Task<Void, Never>?

    init(cache: RecommendationResultCache?, clock: @escaping () -> Date) {
        self.cache = cache
        self.clock = clock
    }

    /// 开启新一轮请求：在途后台重算立即作废（其回写会被丢弃）。
    @discardableResult
    func beginRequest() -> Int {
        generation += 1
        backgroundTask?.cancel()
        backgroundTask = nil
        return generation
    }

    /// 缓存决策：精确命中 → stale → miss。bypassCache 一律跳过缓存（并清掉旧条目）。
    func lookup(_ key: RecommendationCacheKeyInput, bypassCache: Bool) -> Lookup {
        guard let cache else { return .miss }
        if bypassCache {
            cache.invalidate(key)
            return .miss
        }
        if let hit = cache.load(key) {
            return .exact(hit)
        }
        if let stale = cache.loadStale(baseKey: key.baseKey, now: clock()) {
            return .stale(stale)
        }
        return .miss
    }

    /// 同步重算结果写缓存（空结果由缓存层丢弃）。
    func store(_ recompute: RecommendationRecompute, key: RecommendationCacheKeyInput) {
        cache?.store(
            key,
            planSource: recompute.planSource,
            candidates: recompute.candidates,
            requestedArtist: recompute.requestedArtist
        )
    }

    /// 手动刷新 / 拉黑：清掉精确键与同 baseKey 的 stale 兄弟条目。
    func invalidate(_ key: RecommendationCacheKeyInput) {
        cache?.invalidate(key)
    }

    /// 后台重算：完成后只在代次未变时写新键并回调（回调里做平滑替换）。
    ///
    /// - Parameters:
    ///   - token: beginRequest() 的返回值
    ///   - currentCandidates: 当前展示的候选；序列相同则 changed = false（避免无意义 UI 抖动）
    ///   - compute: 真正的重算（planner + 召回）；返回 nil 表示失败（保留旧候选，不打扰用户）
    ///   - apply: 主线程回调（changed 为 false 时调用方不应重设候选）
    func startBackgroundRefresh(
        token: Int,
        key: RecommendationCacheKeyInput,
        currentCandidates: [RecommendedCandidate],
        compute: @escaping @MainActor () async -> RecommendationRecompute?,
        apply: @escaping @MainActor (RecommendationRecompute, _ changed: Bool) -> Void
    ) {
        backgroundTask?.cancel()
        backgroundTask = Task { [weak self] in
            guard let self else { return }
            guard let recompute = await compute() else { return }
            guard !Task.isCancelled, token == generation else { return }
            store(recompute, key: key)
            backgroundTask = nil
            let changed = recompute.candidates.map(\.id) != currentCandidates.map(\.id)
            apply(recompute, changed)
        }
    }
}
