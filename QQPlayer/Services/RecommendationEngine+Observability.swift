//
//  RecommendationEngine+Observability.swift
//  QQPlayer
//
//  推荐 P1 观测：一次推荐一条 summary（AppLog.info）+ 每道闸 in/out 计数。
//  从 RecommendationEngine.swift 拆出：加观测后文件触及 600 行结构预算，本次只搬家、不改行为。
//

import Foundation

// MARK: - 观测（P1）

/// 一次推荐里单个在线源的召回结果（成功次数 / 失败次数 / 返回条数）。
struct RecommendationSourceStat: Sendable, Equatable {
    var source: RecommendationSource
    var ok: Int
    var failed: Int
    var songs: Int
}

/// 管线上一道闸的进出计数（in = 到达本闸的候选，out = 被本闸剔除）。
struct RecommendationGateStat: Sendable, Equatable {
    var name: String
    var inCount: Int
    var outCount: Int
}

/// 一次推荐的运行上下文（summary 日志的输入；开始时构造，收尾时打点）。
struct RecommendationRunContext: Sendable {
    /// 用户请求原文（画像路径下为意图词拼接）。
    var requestText: String
    /// 意图来源（规则 / 本地模型）；调用方未给 = 未知。
    var planSource: RecommendationPlanSource?
    /// 开始时间（summary 的 ms 从这里算）。
    var startedAt: Date

    init(requestText: String, planSource: RecommendationPlanSource?, startedAt: Date = Date()) {
        self.requestText = requestText
        self.planSource = planSource
        self.startedAt = startedAt
    }
}

extension RecommendationEngine {
    // MARK: 观测（P1 summary）

    /// 一次推荐一条结构化 summary（AppLog.info）；明细走 AppLog.debug。
    ///
    /// 字段固定、可 grep：request / intents / sources / gates / rejects / flagged / final / ms / planner。
    /// 打点只在管线边界（gather / select），**不绑定具体在线源实现**（P2 换源后字段不变）。
    func logRunSummary(
        context: RecommendationRunContext,
        intents: [RecommendationIntent],
        gathered: GatherResult?,
        finalCount: Int,
        targetCount: Int
    ) {
        let durationMs = Int(Date().timeIntervalSince(context.startedAt) * 1000)
        let kinds = Self.intentKindSummary(intents)
        let sources = (gathered?.sourceStats ?? [])
            .map { "\($0.source.rawValue)(ok:\($0.ok),fail:\($0.failed),n:\($0.songs))" }
            .joined(separator: ";")
        let gates = (gathered?.gateStats ?? [])
            .map { "\($0.name)(in:\($0.inCount),out:\($0.outCount))" }
            .joined(separator: ";")
        let rejects = (gathered?.rejectionCounts ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
        let flagged = (gathered?.flaggedCounts ?? [:])
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: ",")
        let sanitizedRequest = Self.singleLine(context.requestText, limit: 160)
        // P4：艺人关系扩展（off 也打点，字段位置固定便于历史对照）。
        let artistRel = artistRelation.map { "on:\($0.budget.summary)" } ?? "off:queries:0:artists:0"

        AppLog.info(
            .general,
            "🎵 推荐摘要 | request=\(sanitizedRequest) | intents=\(kinds) | sources=\(sources.isEmpty ? "none" : sources)"
                + " | gates=\(gates.isEmpty ? "none" : gates) | rejects=\(rejects.isEmpty ? "none" : rejects)"
                + " | flagged=\(flagged.isEmpty ? "none" : flagged)"
                + " | final=\(finalCount)/\(max(1, targetCount)) | ms=\(durationMs)"
                + " | planner=\(context.planSource?.rawValue ?? "unknown")"
                + " | chain=\(chainAudit?.summary ?? "none")"
                + " | artistRel=\(artistRel)"
        )
    }

    /// 意图种类计数（固定顺序，便于 grep 与历史对照）。
    static func intentKindSummary(_ intents: [RecommendationIntent]) -> String {
        guard !intents.isEmpty else { return "none" }
        let order: [RecommendationIntent.Kind] = [.artist, .similar, .decade, .genre, .keyword]
        return order
            .compactMap { kind in
                let count = intents.filter { $0.kind == kind }.count
                return count > 0 ? "\(kind.rawValue):\(count)" : nil
            }
            .joined(separator: ",")
    }

    /// 日志单行化（换行折叠 + 长度截断；日志解析不受用户输入影响）。
    static func singleLine(_ text: String, limit: Int) -> String {
        let folded = text
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard folded.count > limit else { return folded }
        return String(folded.prefix(limit)) + "…"
    }

    /// 观测：闸的固定顺序（日志字段稳定、可 grep；顺序 = 判定顺序）。
    static let gateOrder = [
        "fields", "artist_constraint", "admission", "library", "blacklist", "excluded_artists", "recent", "dedupe",
    ]

    func sortedGateStats(_ raw: [String: (inCount: Int, outCount: Int)]) -> [RecommendationGateStat] {
        raw.map { name, stat in
            RecommendationGateStat(name: name, inCount: stat.inCount, outCount: stat.outCount)
        }
        .sorted { lhs, rhs in
            let l = Self.gateOrder.firstIndex(of: lhs.name) ?? Int.max
            let r = Self.gateOrder.firstIndex(of: rhs.name) ?? Int.max
            return l == r ? lhs.name < rhs.name : l < r
        }
    }

    func sortedSourceStats(
        _ raw: [RecommendationSource: (ok: Int, failed: Int, songs: Int)]
    ) -> [RecommendationSourceStat] {
        raw.map { source, stat in
            RecommendationSourceStat(source: source, ok: stat.ok, failed: stat.failed, songs: stat.songs)
        }
        .sorted { $0.source.rawValue < $1.source.rawValue }
    }
}
