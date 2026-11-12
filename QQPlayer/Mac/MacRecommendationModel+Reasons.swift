//
//  MacRecommendationModel+Reasons.swift
//  QQPlayer
//
//  推荐 v2 P3：模型理由异步替换（macOS）。
//
//  UX 契约：首屏先显示规则理由 → 模型理由在后台算完再原地替换；
//  模型慢 / 失败 / 校验不过都不阻塞列表，也不让理由区域**留空**。
//  缓存契约：结果缓存里始终是规则理由（模型理由只在显示层覆盖，不写缓存）。
//

import Foundation

extension MacRecommendationModel {
    /// 为刚展示的一批候选启动理由刷新（同批只保留最后一轮，换批自动作废）。
    func startReasonRefresh(for batch: [RecommendedCandidate]) {
        reasonTask?.cancel()
        reasonGeneration += 1
        let generation = reasonGeneration
        guard !batch.isEmpty else { return }

        let provider = reasonProvider
            ?? RecommendationPlannerFactory.makeReasonProvider(settings: DeleteSettings.load())
        guard !(provider is RuleRecommendationReasonProvider) else {
            AppLog.info(.general, "reasons=rules:ok")
            return
        }

        let items = batch.map { RecommendationReasonItem(candidate: $0) }
        reasonTask = Task { [weak self] in
            let map = await provider.reasons(for: items, locale: .current)
            guard !Task.isCancelled, let self, self.reasonGeneration == generation else { return }
            self.applyModelReasons(map)
        }
    }

    /// 回填模型理由（按归一化单曲键匹配；缺失条目保留规则理由）。
    private func applyModelReasons(_ map: [String: [String]]) {
        guard !map.isEmpty else {
            AppLog.info(.general, "reasons=rules:fallback")
            return
        }

        let bound = RecommendationReasonBinder.bind(map, to: candidates)
        guard bound.replaced > 0 else {
            AppLog.info(.general, "reasons=rules:fallback")
            return
        }
        candidates = bound.candidates
        let source = bound.isPartial ? "mixed" : "model"
        AppLog.info(.general, "reasons=\(source):ok replaced=\(bound.replaced)/\(bound.candidates.count)")
    }
}
