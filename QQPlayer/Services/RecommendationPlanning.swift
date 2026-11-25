//
//  RecommendationPlanning.swift
//  QQPlayer
//
//  本地 AI 推荐：计划来源与画像摘要（纯逻辑层）。
//
//  - `RecommendationPlanSource`：缓存键 / 页脚展示用的来源标记（旧缓存 JSON 仍含 .localModel，
//    保留该 case 只为解码兼容；生产代码只会产出 .rule）。
//  - `RecommendationProfileSummary`：画像摘要（纯值，不含路径 / DB / 歌名）。
//
//  批次 C（2026-11-25）移除了输入框 / 本地模型，一并删掉 Plan 契约、Prompt、Parser 与
//  Rule/Fallback planner（planner 选择点已无处调用）。
//
//  ⚠️ 本文件是纯逻辑层：iOS / macOS 共享，只依赖 Foundation，不引入平台 API。
//

import Foundation

// MARK: - 计划来源

/// 检索计划来源（用于设置页 / 推荐页脚注展示，不参与召回打分）。
enum RecommendationPlanSource: String, Codable, Sendable, Equatable {
    case rule
    case localModel

    var localizationKey: String {
        switch self {
        case .rule: return "recommendation_source_rule"
        case .localModel: return "recommendation_source_local_model"
        }
    }
}

/// 一次生成的完整检索计划。
struct RecommendationPlan: Sendable, Equatable {
    var intents: [RecommendationIntent]
    var source: RecommendationPlanSource

    static let empty = RecommendationPlan(intents: [], source: .rule)
}

/// 检索计划生成器：规则与本地模型都实现这一协议。
protocol RecommendationPlanning: Sendable {
    func makePlan(for profile: TasteProfile) async -> RecommendationPlan
}

// MARK: - 画像摘要

/// 模型输入摘要：只包含口味统计，**不**包含文件路径 / 曲库内部 id / 歌曲列表。
struct RecommendationProfileSummary: Sendable {
    /// 归一化后的 top 艺人（最多 8 个）。
    var topArtists: [String] = []
    /// 年代分布（key = 十年起点，value = 0…1 占比；最多 3 个）。
    var decades: [(decade: Int, share: Double)] = []
    /// 干净 genre（最多 5 个）。
    var genres: [String] = []
    /// 平均完成率（0…1）。
    var completionRate: Double = 0
    /// 曲库规模（归一化单曲键数量）。
    var librarySize: Int = 0
    /// 语言线索（从 genre 里能明确识别的语种，识别不出就为空）。
    var languageHints: [String] = []

    static let maxArtists = 8
    static let maxDecades = 3
    static let maxGenres = 5

    /// 从画像构建摘要（纯函数）。
    static func make(from profile: TasteProfile) -> RecommendationProfileSummary {
        let artists = profile.topArtists
            .prefix(maxArtists)
            .map(\.artist)
            .filter { !$0.isEmpty }

        let decades = profile.decadeShare
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(maxDecades)
            .map { (decade: $0.key, share: $0.value) }

        let genres = Array(profile.topGenres.prefix(maxGenres))
        let languages = Self.detectLanguages(in: genres)

        return RecommendationProfileSummary(
            topArtists: Array(artists),
            decades: Array(decades),
            genres: genres,
            completionRate: min(1, max(0, profile.completionRate)),
            librarySize: profile.libraryKeys.count,
            languageHints: languages
        )
    }

    /// 从 genre 文本里识别语种线索（只认明确词，不猜）。
    static func detectLanguages(in genres: [String]) -> [String] {
        let table: [(token: String, hint: String)] = [
            ("华语", "Chinese"), ("国语", "Chinese"), ("中文", "Chinese"), ("mandarin", "Chinese"),
            ("粤语", "Cantonese"), ("cantonese", "Cantonese"),
            ("日语", "Japanese"), ("j-pop", "Japanese"), ("jpop", "Japanese"),
            ("韩语", "Korean"), ("k-pop", "Korean"), ("kpop", "Korean"),
            ("英语", "English"), ("western", "English"),
        ]
        var hints: [String] = []
        for genre in genres {
            let lower = genre.lowercased()
            for row in table where lower.contains(row.token) {
                if !hints.contains(row.hint) { hints.append(row.hint) }
            }
        }
        return hints
    }

    /// 摘要是否足够生成计划（新库 / 无播放历史时直接走规则）。
    var isEmpty: Bool {
        topArtists.isEmpty && decades.isEmpty && genres.isEmpty
    }
}
