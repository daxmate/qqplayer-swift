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

    /// planner 选择结果 + 缓存键身份（make 与缓存键共用同一处决策，避免两份判断漂移）。
    struct RecommendationPlannerSelection {
        var planner: any RecommendationPlanning
        var planSource: RecommendationPlanSource
        var modelIdentity: String
    }

    enum RecommendationPlannerFactory {
        @MainActor
        static func make(settings: DeleteSettings) -> any RecommendationPlanning {
            selection(settings: settings).planner
        }

        @MainActor
        static func selection(settings: DeleteSettings) -> RecommendationPlannerSelection {
            let rule = RuleRecommendationPlanner()
            guard settings.recommendationUseLocalModel else {
                #if canImport(MLXLLM) && arch(arm64)
                    MLXRecommendationPlanner.shared.unload()
                #endif
                return RecommendationPlannerSelection(planner: rule, planSource: .rule, modelIdentity: "none")
            }

            #if canImport(MLXLLM) && arch(arm64)
                MLXRecommendationPlanner.shared.setKeepLoaded(settings.recommendationKeepModelLoaded)
                guard let identity = localModelIdentity() else {
                    return RecommendationPlannerSelection(planner: rule, planSource: .rule, modelIdentity: "none")
                }
                return RecommendationPlannerSelection(
                    planner: FallbackRecommendationPlanner(primary: MLXRecommendationPlanner.shared, fallback: rule),
                    planSource: .localModel,
                    modelIdentity: identity
                )
            #else
                return RecommendationPlannerSelection(planner: rule, planSource: .rule, modelIdentity: "none")
            #endif
        }

        /// 本地模型身份（id + 体量；体量变化视为换模型）；未就绪 / 平台不支持返回 nil。
        static func localModelIdentity() -> String? {
            #if canImport(MLXLLM) && arch(arm64)
                let layout = RecommendationModelLayout.resolved(
                    modelId: RecommendationModelManager.defaultModelId
                )
                let store = RecommendationModelStore(layout: layout)
                guard let manifest = store.loadManifest(), store.isComplete(manifest: manifest) else {
                    return nil
                }
                return "\(manifest.id)#\(manifest.totalBytes)"
            #else
                return nil
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
