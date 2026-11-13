//
//  RecommendationV3Settings.swift
//  QQPlayer
//
//  推荐 v3 设置（画像权重 / 通道配额）。从 SettingsModels 拆出：主体已触 600 行结构预算。
//
//  - 存储：DeleteSettings 内以单个 `recommendationV3` 字段承载（旧设置文件缺 key → 默认值）。
//  - 读写：`DeleteSettings` 上的便捷访问器保持调用点不变。
//  - 归一：权重 / 配额写入后归一到和 1（UI 与解码都走同一口径）。
//

import Foundation

struct RecommendationV3Settings: Codable, Sendable, Equatable {
    /// 口味画像四项权重（0…1，步进 0.05；落盘前归一到和 1）。
    var weightLibrary: Double = RecommendationProfileWeights.defaults.library
    var weightPlay: Double = RecommendationProfileWeights.defaults.play
    var weightFavorite: Double = RecommendationProfileWeights.defaults.favorite
    var weightRecency: Double = RecommendationProfileWeights.defaults.recency

    /// 三通道配额（落盘前归一到和 1）。
    var quotaSeed: Double = RecommendationChannelQuotas.defaults.seed
    var quotaSimilar: Double = RecommendationChannelQuotas.defaults.similar
    var quotaExplore: Double = RecommendationChannelQuotas.defaults.explore

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        weightLibrary = try container.decodeIfPresent(Double.self, forKey: .weightLibrary)
            ?? RecommendationProfileWeights.defaults.library
        weightPlay = try container.decodeIfPresent(Double.self, forKey: .weightPlay)
            ?? RecommendationProfileWeights.defaults.play
        weightFavorite = try container.decodeIfPresent(Double.self, forKey: .weightFavorite)
            ?? RecommendationProfileWeights.defaults.favorite
        weightRecency = try container.decodeIfPresent(Double.self, forKey: .weightRecency)
            ?? RecommendationProfileWeights.defaults.recency
        quotaSeed = try container.decodeIfPresent(Double.self, forKey: .quotaSeed)
            ?? RecommendationChannelQuotas.defaults.seed
        quotaSimilar = try container.decodeIfPresent(Double.self, forKey: .quotaSimilar)
            ?? RecommendationChannelQuotas.defaults.similar
        quotaExplore = try container.decodeIfPresent(Double.self, forKey: .quotaExplore)
            ?? RecommendationChannelQuotas.defaults.explore
        normalizeWeights()
        normalizeQuotas()
    }

    /// 归一化视图（读取侧永远拿到和 = 1 的权重）。
    var profileWeights: RecommendationProfileWeights {
        RecommendationProfileWeights(
            library: weightLibrary,
            play: weightPlay,
            favorite: weightFavorite,
            recency: weightRecency
        ).normalized()
    }

    var channelQuotas: RecommendationChannelQuotas {
        RecommendationChannelQuotas(
            seed: quotaSeed,
            similar: quotaSimilar,
            explore: quotaExplore
        ).normalized()
    }

    mutating func normalizeWeights() {
        let normalized = profileWeights
        weightLibrary = normalized.library
        weightPlay = normalized.play
        weightFavorite = normalized.favorite
        weightRecency = normalized.recency
    }

    mutating func normalizeQuotas() {
        let normalized = channelQuotas
        quotaSeed = normalized.seed
        quotaSimilar = normalized.similar
        quotaExplore = normalized.explore
    }
}

extension DeleteSettings {
    /// 画像权重（读 = 归一化后的值；写 = 归一化落盘）。
    var recommendationProfileWeights: RecommendationProfileWeights {
        get { recommendationV3.profileWeights }
        set {
            recommendationV3.weightLibrary = newValue.library
            recommendationV3.weightPlay = newValue.play
            recommendationV3.weightFavorite = newValue.favorite
            recommendationV3.weightRecency = newValue.recency
            recommendationV3.normalizeWeights()
        }
    }

    var recommendationChannelQuotas: RecommendationChannelQuotas {
        get { recommendationV3.channelQuotas }
        set {
            recommendationV3.quotaSeed = newValue.seed
            recommendationV3.quotaSimilar = newValue.similar
            recommendationV3.quotaExplore = newValue.explore
            recommendationV3.normalizeQuotas()
        }
    }

    mutating func normalizeRecommendationWeights() {
        recommendationV3.normalizeWeights()
    }

    mutating func normalizeRecommendationQuotas() {
        recommendationV3.normalizeQuotas()
    }
}
