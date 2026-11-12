//
//  MLXRecommendationReasonProvider.swift
//  QQPlayer
//
//  推荐 v2 P3：Mac 本地模型的理由来源（只编 macOS + Apple Silicon + MLX）。
//
//  薄包装：模型容器仍由 `MLXRecommendationPlanner.shared` 持有（同一份，不加载第二个）。
//  失败 / 超时 / 校验不过一律返回空字典 → 调用方保留规则理由（功能不退化）。
//

#if canImport(MLXLLM) && arch(arm64) && os(macOS)

    import Foundation

    struct MLXRecommendationReasonProvider: RecommendationReasonProviding {
        func reasons(for items: [RecommendationReasonItem], locale: Locale) async -> [String: [String]] {
            let planner = await MainActor.run { MLXRecommendationPlanner.shared }
            return await planner.reasons(for: items, locale: locale)
        }
    }

#endif
