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

        /// 指令输入是否可用：必须是可用的本地模型（模型未就绪禁用，绝不回退规则）。
        static func chatAvailability(useLocalModel: Bool) -> RecommendationChatAvailability {
            RecommendationChatAvailability.resolve(
                mlxSupported: mlxSupported,
                useLocalModel: useLocalModel,
                modelReady: isModelReady()
            )
        }

        static var mlxSupported: Bool {
            #if canImport(MLXLLM) && arch(arm64)
                return true
            #else
                return false
            #endif
        }

        /// 模型文件是否完整（不触发加载 / 网络）。
        static func isModelReady() -> Bool {
            #if canImport(MLXLLM) && arch(arm64)
                return MLXRecommendationPlanner.isModelReady()
            #else
                return false
            #endif
        }

        /// 指令输入专用 planner：只有本地模型，返回 nil 表示不可用。
        @MainActor
        static func makeChatPlanner() -> (any RecommendationRequestPlanning)? {
            #if canImport(MLXLLM) && arch(arm64)
                return MLXRecommendationPlanner.shared
            #else
                return nil
            #endif
        }
    }

#endif
