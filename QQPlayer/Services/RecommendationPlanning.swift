//
//  RecommendationPlanning.swift
//  QQPlayer
//
//  本地 AI 推荐 P2：检索计划层（规则 / 本地模型共用契约）。
//
//  - `RecommendationProfileSummary`：喂给模型的画像摘要（纯值，不含路径 / DB / 歌名）。
//  - `RecommendationPlanPrompt`：严格 JSON prompt（system + user）。
//  - `RecommendationPlanParser`：从模型输出提取 JSON 并做统一校验（空 / 超长 / 重复 / >12 条）。
//  - `RuleRecommendationPlanner`：包装 P1 的 `RecommendationIntentBuilder`，行为保持不变。
//  - `FallbackRecommendationPlanner`：模型失败 / 空结果时 100% 回退规则，不向 UI 抛错。
//
//  ⚠️ 本文件是纯逻辑层：iOS / macOS 共享，只依赖 Foundation，不引入 MLX / 平台 API。
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

// MARK: - Prompt

/// 严格 JSON prompt。输出契约见 `RecommendationPlanParser`。
enum RecommendationPlanPrompt {
    static let system = """
    You are a music discovery planner. Based on the listener's taste summary, output a JSON search plan.
    Rules:
    - Reply with JSON only. No markdown, no code fences, no explanations.
    - Schema: {"queries":[{"query":"<search keywords>","kind":"artist|decade|genre"}]}
    - 6 to 12 queries, ordered by expected value.
    - If the listener names an artist, that artist MUST be the first query; never place it last.
    - "query" must be non-empty, no line breaks, at most 40 characters.
    - kind=artist: an artist name. kind=decade: a decade label such as "1990s". kind=genre: a music genre.
    - Never include file paths, database ids, URLs, or personal data.
    """

    /// 指令输入 system prompt：只输出结构化检索条件，不做推荐解释。
    static let requestSystem = """
    You are a music discovery planner. Convert the listener's request plus the recent background context
    into structured search conditions.
    Rules:
    - Reply with JSON only. No markdown, no code fences, no explanations.
    - Schema: {"referenceArtists":["..."],"keywords":["..."],"decades":[1990],"languages":["Chinese"],"moods":["..."],"excludeArtists":["..."]}
    - Every array holds at most 8 plain-text items; each item is a single line of at most 64 characters.
    - referenceArtists: artists the listener explicitly referenced ("similar to X" includes X).
    - If the listener names an artist, that artist MUST go in referenceArtists first; never bury it in keywords or place it last.
    - keywords: concrete searchable terms (specific song / album / artist names or themes); never generic words like "music", "songs", "hits".
    - decades: integer decade start between 1900 and 2030 (for example 1990).
    - languages: language hints implied by the request; keep the array empty when unsure.
    - moods: at most three short mood words.
    - excludeArtists: artists the listener wants to avoid.
    - Use an empty array for any field the listener did not ask for.
    - Never include file paths, database ids, URLs, or personal data.
    """

    /// 用户消息：把摘要渲染成稳定、可测试的文本（字段顺序固定）。
    static func user(for summary: RecommendationProfileSummary) -> String {
        var lines: [String] = []
        lines.append("Top artists: " + (summary.topArtists.isEmpty ? "(none)" : summary.topArtists.joined(separator: ", ")))
        if summary.decades.isEmpty {
            lines.append("Decades: (unknown)")
        } else {
            let decades = summary.decades.map { row in
                "\(row.decade)s \(Self.percent(row.share))"
            }
            lines.append("Decades: " + decades.joined(separator: ", "))
        }
        lines.append("Genres: " + (summary.genres.isEmpty ? "(none)" : summary.genres.joined(separator: ", ")))
        lines.append("Completion rate: \(Self.percent(summary.completionRate))")
        lines.append("Library size: \(summary.librarySize) tracks")
        if !summary.languageHints.isEmpty {
            lines.append("Language hints: " + summary.languageHints.joined(separator: ", "))
        }
        lines.append("")
        lines.append("Return the JSON plan now.")
        return lines.joined(separator: "\n")
    }

    /// 指令输入 user 消息：画像摘要 + 当前要求 + 最近 N 轮上下文（顺序固定）。
    static func requestUser(
        for summary: RecommendationProfileSummary,
        requestText: String,
        history: [RecommendationRequestHistoryEntry]
    ) -> String {
        var lines: [String] = []
        lines.append("Top artists: " + (summary.topArtists.isEmpty ? "(none)" : summary.topArtists.joined(separator: ", ")))
        if summary.decades.isEmpty {
            lines.append("Decades: (unknown)")
        } else {
            let decades = summary.decades.map { row in
                "\(row.decade)s \(Self.percent(row.share))"
            }
            lines.append("Decades: " + decades.joined(separator: ", "))
        }
        lines.append("Genres: " + (summary.genres.isEmpty ? "(none)" : summary.genres.joined(separator: ", ")))
        if !summary.languageHints.isEmpty {
            lines.append("Language hints: " + summary.languageHints.joined(separator: ", "))
        }
        lines.append("")
        lines.append("Current request: " + RecommendationRequestParser.singleLine(requestText))
        if history.isEmpty {
            lines.append("Recent context: (none)")
        } else {
            lines.append("Recent context (oldest first):")
            for entry in history {
                lines.append("- Request: " + RecommendationRequestParser.singleLine(entry.requestText))
                if !entry.results.isEmpty {
                    lines.append("  Returned: " + entry.results.joined(separator: "; "))
                }
            }
        }
        lines.append("")
        lines.append("Return the JSON request now.")
        return lines.joined(separator: "\n")
    }

    private static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

// MARK: - 解析

/// 模型输出解析 + 校验（纯函数，不依赖网络 / 文件系统）。
enum RecommendationPlanParser {
    static let maxIntents = 12
    static let maxQueryLength = 40

    struct Payload: Decodable {
        struct Item: Decodable {
            var query: String
            var kind: String?
        }
        var queries: [Item]
    }

    /// 从模型输出提取意图；无法解析或清洗后为空 → `nil`（调用方回退规则）。
    static func parse(_ output: String) -> [RecommendationIntent]? {
        guard let json = extractJSON(from: output) else {
            AppLog.warn(.general, "⚠️ 推荐计划解析失败：未找到 JSON 片段")
            return nil
        }

        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        var items: [Payload.Item] = []

        if let payload = try? decoder.decode(Payload.self, from: data) {
            items = payload.queries
        } else if let array = try? decoder.decode([Payload.Item].self, from: data) {
            items = array
        } else {
            AppLog.warn(.general, "⚠️ 推荐计划解析失败：JSON 结构与契约不符")
            return nil
        }

        let intents = sanitize(items)
        if intents.isEmpty {
            AppLog.warn(.general, "⚠️ 推荐计划解析失败：清洗后没有有效 query")
            return nil
        }
        return intents
    }

    /// 清洗：trim / 压空白 / 去空 / 长度 / 类型 / 去重 / 截断到 12。
    static func sanitize(_ items: [Payload.Item]) -> [RecommendationIntent] {
        var seen = Set<String>()
        var intents: [RecommendationIntent] = []

        for item in items {
            guard intents.count < maxIntents else { break }
            let query = normalizeQuery(item.query)
            guard !query.isEmpty, query.count <= maxQueryLength else { continue }
            guard let kind = parseKind(item.kind) else { continue }
            let key = query.lowercased()
            guard seen.insert(key).inserted else { continue }
            intents.append(RecommendationIntent(query: query, kind: kind))
        }
        return intents
    }

    /// 单行化 + 压连续空白（prompt 也禁止换行）。
    static func normalizeQuery(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 种类解析：大小写不敏感；未知种类返回 `nil`（丢弃该条）。
    static func parseKind(_ raw: String?) -> RecommendationIntent.Kind? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "artist": return .artist
        case "decade": return .decade
        case "genre": return .genre
        default: return nil
        }
    }

    /// 取第一个 `{` 到最后一个 `}`；没有对象则尝试数组片段（容忍代码围栏 / 前后废话）。
    static func extractJSON(from output: String) -> String? {
        if let first = output.firstIndex(of: "{"), let last = output.lastIndex(of: "}"), first < last {
            return String(output[first ... last])
        }
        if let first = output.firstIndex(of: "["), let last = output.lastIndex(of: "]"), first < last {
            return String(output[first ... last])
        }
        return nil
    }
}

// MARK: - 规则 planner

/// 包装 P1 规则意图生成器（行为不变，P2 只替换意图来源）。
struct RuleRecommendationPlanner: RecommendationPlanning {
    func makePlan(for profile: TasteProfile) async -> RecommendationPlan {
        RecommendationPlan(
            intents: RecommendationIntentBuilder.intents(from: profile),
            source: .rule
        )
    }
}

// MARK: - 回退

/// 主 planner（本地模型）失败 / 空结果 → 规则 planner，永不向 UI 抛错。
struct FallbackRecommendationPlanner: RecommendationPlanning {
    var primary: any RecommendationPlanning
    var fallback: any RecommendationPlanning

    init(primary: any RecommendationPlanning, fallback: any RecommendationPlanning = RuleRecommendationPlanner()) {
        self.primary = primary
        self.fallback = fallback
    }

    func makePlan(for profile: TasteProfile) async -> RecommendationPlan {
        let plan = await primary.makePlan(for: profile)
        guard !plan.intents.isEmpty else {
            AppLog.warn(.general, "⚠️ 本地模型未产出有效检索计划，回退规则 planner")
            return await fallback.makePlan(for: profile)
        }
        return plan
    }
}
