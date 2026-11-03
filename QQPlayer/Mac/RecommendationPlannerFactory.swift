//
//  RecommendationPlannerFactory.swift
//  QQPlayer
//
//  本地 AI 推荐 P2：按设置 / 模型就绪状态选择 planner（macOS only）。
//
//  - 关闭「使用本地模型」→ 规则。
//  - 模型文件不完整 / Intel Mac → 规则。
//  - 否则 MLX planner 优先，失败自动回退规则（FallbackRecommendationPlanner）。
//

#if os(macOS)

    import Foundation

    enum RecommendationPlannerFactory {
        @MainActor
        static func make(settings: DeleteSettings) -> any RecommendationPlanning {
            let rule = RuleRecommendationPlanner()
            guard settings.recommendationUseLocalModel else {
                #if canImport(MLXLLM) && arch(arm64)
                    MLXRecommendationPlanner.shared.unload()
                #endif
                return rule
            }

            #if canImport(MLXLLM) && arch(arm64)
                MLXRecommendationPlanner.shared.setKeepLoaded(settings.recommendationKeepModelLoaded)
                let layout = RecommendationModelLayout(
                    root: RecommendationModelLayout.defaultRoot(),
                    modelId: RecommendationModelManager.defaultModelId
                )
                let store = RecommendationModelStore(layout: layout)
                guard let manifest = store.loadManifest(), store.isComplete(manifest: manifest) else {
                    return rule
                }
                return FallbackRecommendationPlanner(primary: MLXRecommendationPlanner.shared, fallback: rule)
            #else
                return rule
            #endif
        }
    }

#endif
