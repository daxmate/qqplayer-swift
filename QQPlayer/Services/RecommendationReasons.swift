//
//  RecommendationReasons.swift
//  QQPlayer
//
//  推荐：逐曲理由的「可替换来源」契约。
//
//  - `RecommendationReasonProviding`：理由来源（默认规则；Mac 注入模板文案）。
//  - `RuleRecommendationReasonProvider`：原样返回引擎在选片阶段产出的规则理由（行为不变）。
//  - `RecommendationReasonBinder`：把来源给出的理由按归一化键绑回候选，逐条回落规则理由。
//  批次 C（2026-11-25）：本地模型 prompt / parser 随之删除，契约只剩规则与模板来源。
//
//  ⚠️ 纯逻辑层：iOS / macOS 共享，只依赖 Foundation，不引入平台 API。
//

import Foundation

// MARK: - 契约

/// 生成理由时的输入（**只**允许这些字段进 prompt；不夹带画像、历史等隐私数据）。
struct RecommendationReasonItem: Sendable, Equatable {
    /// 归一化单曲键（`RecommendationKey.normalize`），回填时按它匹配。
    var key: String
    var title: String
    var artist: String
    var album: String?
    var year: Int?
    /// 引擎已产出的规则理由（默认实现原样返回；模型实现**不得**把它们喂进 prompt）。
    var ruleReasons: [String] = []
}

extension RecommendationReasonItem {
    /// 从展示候选构造（键口径与 `RecommendedCandidate.id` 的单曲段一致）。
    init(candidate: RecommendedCandidate) {
        self.init(
            key: RecommendationKey.normalize(title: candidate.title, artist: candidate.artist),
            title: candidate.title,
            artist: candidate.artist,
            album: candidate.album,
            year: candidate.year,
            ruleReasons: candidate.reasons
        )
    }
}

/// 逐曲理由来源。返回 `key → 理由数组`（首条为主理由；缺失 / 空数组 = 保留规则理由）。
protocol RecommendationReasonProviding: Sendable {
    func reasons(for items: [RecommendationReasonItem], locale: Locale) async -> [String: [String]]
}

/// 默认实现：规则理由（两端可用；不改变 P2 行为）。
struct RuleRecommendationReasonProvider: RecommendationReasonProviding {
    func reasons(for items: [RecommendationReasonItem], locale: Locale) async -> [String: [String]] {
        var result: [String: [String]] = [:]
        for item in items where !item.ruleReasons.isEmpty {
            result[item.key] = item.ruleReasons
        }
        return result
    }
}

// MARK: - 回填

/// 把（可能不完整的）模型理由并回展示候选。
///
/// 逐条回落：`key` 缺失 / 空数组 → 保留该条原有的规则理由（绝不把理由清空）。
enum RecommendationReasonBinder {
    struct Result: Sendable, Equatable {
        var candidates: [RecommendedCandidate]
        /// 实际换成模型理由的条数。
        var replaced: Int

        /// 模型 / 规则混合（0 = 全规则，count = 全模型）。
        var isPartial: Bool { replaced > 0 && replaced < candidates.count }
    }

    static func bind(_ modelReasons: [String: [String]], to candidates: [RecommendedCandidate]) -> Result {
        guard !modelReasons.isEmpty, !candidates.isEmpty else {
            return Result(candidates: candidates, replaced: 0)
        }
        var updated = candidates
        var replaced = 0
        for index in updated.indices {
            // 相似补位行保留规则理由里的「相似艺人：X」来源标记，绝不被模型理由盖掉。
            guard updated[index].relatedTo == nil else { continue }
            let key = RecommendationKey.normalize(title: updated[index].title, artist: updated[index].artist)
            guard let reasons = modelReasons[key], !reasons.isEmpty else { continue }
            updated[index].reasons = reasons
            replaced += 1
        }
        return Result(candidates: updated, replaced: replaced)
    }
}
