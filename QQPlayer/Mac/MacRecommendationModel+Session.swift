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
        logDiversity(session.lastBatchDiversity)
        candidates = batch
        phase = .loaded
        startReasonRefresh(for: batch)
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
        let target = min(max(1, count), RecommendationBatchPolicy.batchSize)
        var working: RecallSession
        var added = 0
        if isRefillingSession, let existing = session {
            working = existing
            added = working.append(pool: pool)
        } else {
            working = RecallSession(pool: pool)
        }

        if let batch = working.takeFullBatchOrNil(minimum: target) {
            session = working
            batchRemaining = working.remaining
            logDiversity(working.lastBatchDiversity)
            return batch
        }

        // 不足一批：
        // - 新请求本身池小 / 补池没有新增 → 允许返回剩余（UI 显示已看完）
        // - 补池有新增 → 不消费、保留新池，batchRemaining 反映真实剩余
        if !isRefillingSession || added == 0 {
            var final = working
            let rest = final.nextBatch()
            session = final
            batchRemaining = final.remaining
            logDiversity(final.lastBatchDiversity)
            return rest
        }
        session = working
        batchRemaining = working.remaining
        return []
    }

    /// 召回排除集：会话内 seen ∪ 最近 7 天软黑名单（跨会话）。
    var excludedTrackKeys: Set<String> {
        blacklist.activeRecentKeys(at: clock()).union(session?.seen ?? [])
    }

    /// P2 池构建引擎：**池不设**每艺人 / 每专辑 / 每意图上限（目标 60）。
    /// 同艺人 ≤4、同专辑 ≤2 是「首批 15」的约束，由 `RecallSession.nextBatch()` 执行。
    /// 批次多样性日志：放宽时显式标记 `diversity_relaxed=`（禁止静默）。
    private func logDiversity(_ report: RecallSession.BatchDiversityReport) {
        guard report.isRelaxed else { return }
        AppLog.info(.general, "diversity_relaxed=\(report.logToken) artists=\(report.distinctArtists)")
    }

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
