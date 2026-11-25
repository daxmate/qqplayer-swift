//
//  RecommendationPlannerFactory.swift
//  QQPlayer
//
//  推荐 planner 选择点（macOS only）。
//
//  v3（2026-11-13）起本地模型已整体移除：planner 恒为规则实现，
//  planSource 恒为 .rule、modelIdentity 恒为 "none"（进缓存键）。
//  保留本文件是为了让「planner 选择」与「缓存键身份」仍只有一个决策点，
//  调用方（MacRecommendationModel / MacRecommendationView）不需要知道模型已下线。
//

#if os(macOS)

    import Foundation

    /// 缓存键身份（来源 + 模型身份在同一处决策，避免两份判断漂移）。
    struct RecommendationPlannerSelection {
        var planSource: RecommendationPlanSource
        var modelIdentity: String
    }

    enum RecommendationPlannerFactory {
        @MainActor
        static func selection(settings _: DeleteSettings) -> RecommendationPlannerSelection {
            RecommendationPlannerSelection(
                planSource: .rule,
                modelIdentity: "none"
            )
        }

        /// 逐曲理由来源：v3 起恒为模板文案（无模型）。
        static func makeReasonProvider(settings _: DeleteSettings) -> any RecommendationReasonProviding {
            RuleRecommendationReasonProvider()
        }
    }

#endif
