//
//  MacRecommendationModel+Session.swift
//  QQPlayer
//
//  推荐 P2 会话池：15 首一批 / 换一批游标 / 池不足补池。
//  从 MacRecommendationModel.swift 拆出：加补池逻辑后触及 600 行结构预算，本次只搬家。
//

import Foundation

extension MacRecommendationModel {
    // MARK: - 会话池（P2：15 首 / 换一批）

    /// 推进到下一批；只有「剩余 ≥ 一批」才直接换批，否则 false（调用方走补池）。
    @discardableResult
    func advanceBatchIfAvailable() -> Bool {
        guard var session else { return false }
        guard session.state == .ready else {
            batchRemaining = session.remaining
            return false
        }
        let batch = session.nextBatch()
        self.session = session
        batchRemaining = session.remaining
        guard !batch.isEmpty else { return false }
        candidates = batch
        phase = .loaded
        blacklist.markRecommended(batch, at: clock())
        _ = RecommendationBlacklistStore.save(blacklist, to: blacklistURL)
        if let key = lastCacheKey {
            storeCache(key, planSource: planSource, candidates: batch, requestedArtist: requestedArtist)
        }
        return true
    }

    /// 一轮召回结果入池：新请求建会话；补池时追加到现有会话（不丢旧池）。
    ///
    /// 规则：补池后不足一批且仍有剩余 → 不返回残批（等下一次补池）；
    /// 只有「补池后为空或已耗尽」才允许返回剩余。
    func applyPool(_ pool: [RecommendedCandidate], count: Int) -> [RecommendedCandidate] {
        var session: RecallSession
        if isRefillingSession, let existing = self.session {
            session = existing
            session.append(pool: pool)
        } else {
            session = RecallSession(pool: pool)
        }
        self.session = session
        let target = min(count, RecommendationBatchPolicy.batchSize)
        let batch = session.nextBatch()
        batchRemaining = session.remaining
        if batch.count < target, session.state != .exhausted {
            return []
        }
        return batch
    }

    /// 召回排除集：会话内 seen ∪ 最近 7 天软黑名单（跨会话）。
    var excludedTrackKeys: Set<String> {
        blacklist.activeRecentKeys(at: clock()).union(session?.seen ?? [])
    }

    /// P2 池构建引擎：**池不设**每艺人 / 每专辑 / 每意图上限（目标 60）。
    /// 同艺人 ≤4、同专辑 ≤2 是「首批 15」的约束，由 `RecallSession.nextBatch()` 执行。
    func poolEngine() -> RecommendationEngine {
        var engine = RecommendationEngine(
            perIntentLimit: 20,
            maxSongsPerArtist: 10_000,
            maxSongsPerAlbum: nil
        )
        engine.maxSongsPerIntent = 20
        engine.maxSourceShare = 1.0
        return engine
    }

}
