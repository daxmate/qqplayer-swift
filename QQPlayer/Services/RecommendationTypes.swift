//
//  RecommendationTypes.swift
//  QQPlayer
//
//  本地 AI 推荐 P1：候选模型 / 归一化键 / 打分权重（纯逻辑、可单测，不读 DB 不发网络）。
//  全部权重与阈值集中在 `RecommendationWeights` / `RecommendationScorer`，
//  P2 接模型时只替换打分输入来源，不动召回与 UI。
//
//  ⚠️ 本文件与 `RecommendationProfile.swift` 都是纯函数层：iOS / macOS 共享，
//  不得引入平台 API 或视图依赖。
//

import Foundation

// MARK: - 来源

/// 推荐候选来源（P1 只有两个在线源；rawValue 进候选 id，不得随意改）。
enum RecommendationSource: String, CaseIterable, Sendable {
    case netease
    case gequhai

    /// 源可靠度（打分权重 `sourceReliability` 的输入）：网易云走官方 eapi，歌曲海是 HTML 解析。
    var reliability: Double {
        switch self {
        case .netease: return 1.0
        case .gequhai: return 0.6
        }
    }

    /// 展示名本地化键（与刮削源共用 `source_netease` / `source_gequhai`，不另立第二套）。
    var localizationKey: String {
        switch self {
        case .netease: return "source_netease"
        case .gequhai: return "source_gequhai"
        }
    }
}

// MARK: - 归一化键

/// 归一化口径（去重 / 黑名单 / 库内比对的**唯一**入口）。
///
/// 去括号（中英文）、去 `feat./ft.` 尾段、去 `- Remaster/版本` 后缀、
/// 全角半角统一（NFKC 兼容映射）、大小写归并、多艺人取主艺人。
enum RecommendationKey {
    /// 单曲键：`<归一化歌名>|<主艺人>`（全仓唯一的单曲比对口径）。
    static func normalize(title: String, artist: String) -> String {
        "\(normalizeTitle(title))|\(primaryArtist(artist))"
    }

    /// 归一化歌名（不含艺人）。
    static func normalizeTitle(_ raw: String) -> String {
        var text = raw.precomposedStringWithCompatibilityMapping
        text = removingBracketedSegments(text)
        text = removingFeaturingSegment(text)
        text = removingVersionSuffix(text)
        return collapseWhitespace(text).lowercased()
    }

    /// 主艺人（多艺人只取第一个；大小写/全角半角归并）。
    static func primaryArtist(_ raw: String) -> String {
        var text = raw.precomposedStringWithCompatibilityMapping
        text = truncatingAtFirstSeparator(text)
        // `A feat. B` / `A ft. B`：feat 段不是主艺人（与歌名同一条去尾规则）。
        text = removingFeaturingSegment(text)
        return collapseWhitespace(text).lowercased()
    }

    /// 展示用主艺人（保留原始大小写与空格，只截断多艺人）。
    static func displayPrimaryArtist(_ raw: String) -> String {
        var text = raw.precomposedStringWithCompatibilityMapping
        text = truncatingAtFirstSeparator(text)
        text = removingFeaturingSegment(text)
        return collapseWhitespace(text)
    }

    // MARK: 内部步骤

    /// 去掉所有成对括号段（含括号内容）：`Song (Live)` → `Song`。
    /// 兼容 NFKC 之前的全角括号，以及未闭合时不吞后文。
    private static func removingBracketedSegments(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            switch character {
            case "(", "（", "[", "【":
                depth += 1
            case ")", "）", "]", "】":
                if depth > 0 { depth -= 1 }
            default:
                if depth == 0 { result.append(character) }
            }
        }
        return result
    }

    /// 去掉 `feat. X` / `ft. X` 尾段（词首边界判定，避免误伤 `football`）。
    private static func removingFeaturingSegment(_ text: String) -> String {
        for token in ["feat.", "feat", "ft.", "ft"] {
            guard let range = text.range(of: token, options: [.caseInsensitive]) else { continue }
            let prefix = text[text.startIndex ..< range.lowerBound]
            let boundaryBefore = prefix.isEmpty || prefix.last?.isWhitespace == true
            let boundaryAfter = range.upperBound == text.endIndex
                || text[range.upperBound].isWhitespace
                || text[range.upperBound] == "."
            guard boundaryBefore, boundaryAfter else { continue }
            return String(prefix)
        }
        return text
    }

    /// 去掉 ` - Remastered 2011` / ` - Live` / ` - 中文版` 这类版本后缀。
    private static func removingVersionSuffix(_ text: String) -> String {
        guard let separator = text.range(of: " - ", options: .backwards) else { return text }
        let prefix = text[text.startIndex ..< separator.lowerBound]
        let suffix = text[separator.upperBound...].lowercased()
        let keywords = [
            "remaster", "live", "version", "mix", "edit", "mono", "stereo",
            "demo", "bonus", "acoustic", "instrumental", "deluxe", "remix",
            "版本", "现场", "重制", "伴奏", "混音", "版",
        ]
        guard keywords.contains(where: { suffix.contains($0) }) else { return text }
        return String(prefix)
    }

    /// 在第一个多艺人分隔符处截断（`/`、`&`、`、`、`,`、`;`、`×`）。
    private static func truncatingAtFirstSeparator(_ text: String) -> String {
        let separators: Set<Character> = ["/", "&", "、", ",", "，", ";", "；", "×"]
        if let index = text.firstIndex(where: { separators.contains($0) }) {
            return String(text[text.startIndex ..< index])
        }
        return text
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - 候选

/// 一条推荐候选（召回 → 去重 → 打分后的展示模型）。
struct RecommendedCandidate: Identifiable, Equatable, Sendable {
    var title: String
    var artist: String
    var album: String?
    /// 专辑 / 单曲年份（来源给不出时为 nil，打分按中性处理，不编造）。
    var year: Int?
    var source: RecommendationSource
    var score: Double = 0
    /// 推荐理由（已本地化的成品文案；P1 由规则产出，P3 由模型产出）。
    var reasons: [String] = []

    var id: String {
        "\(RecommendationKey.normalize(title: title, artist: artist))#\(source.rawValue)"
    }
}

// MARK: - 打分

/// 打分输入（只放候选侧可观测的事实，画像侧统一从 `TasteProfile` 读）。
struct RecommendationScoreInput: Sendable, Equatable {
    var artist: String
    var year: Int?
    var source: RecommendationSource
    /// 是否已在本曲库 / 播放历史里（引擎已过滤库内，这里只影响 novelty 权重）。
    var isKnownTrack: Bool = false
}

/// 打分结果（分量留档便于 P2 对照模型输出）。
struct RecommendationScore: Sendable, Equatable {
    var total: Double
    var reasons: [String]
    var artistAffinity: Double
    var eraMatch: Double
    var freshness: Double
    var sourceReliability: Double
    var novelty: Double
}

/// 权重集中处（P2 替换为模型分数时只改这里）。
enum RecommendationWeights {
    static let artistAffinity = 0.45
    static let eraMatch = 0.20
    static let freshness = 0.10
    static let sourceReliability = 0.10
    static let novelty = 0.15

    /// 无年代 / 无漂移数据时的中性分。
    static let neutral = 0.5
    /// 已播过（但不在库）的单曲 novelty 分。
    static let repeatedTrackNovelty = 0.4
}

/// 规则打分（纯函数）：艺人亲和 0.45 / 年代 0.20 / 近期漂移 0.10 /
/// 源可靠度 0.10 / 新鲜度 0.15。
enum RecommendationScorer {
    static func score(_ input: RecommendationScoreInput, profile: TasteProfile) -> RecommendationScore {
        let artistKey = RecommendationKey.primaryArtist(input.artist)

        let maxArtistWeight = profile.topArtists.first?.weight ?? 0
        let artistWeight = profile.weight(forArtist: artistKey)
        let artistAffinity = maxArtistWeight > 0 ? min(1, artistWeight / maxArtistWeight) : 0

        let eraMatch = eraScore(year: input.year, profile: profile)
        let freshness = freshnessScore(artistKey: artistKey, profile: profile)
        let sourceReliability = input.source.reliability
        let novelty = input.isKnownTrack ? RecommendationWeights.repeatedTrackNovelty : 1.0

        let total = artistAffinity * RecommendationWeights.artistAffinity
            + eraMatch * RecommendationWeights.eraMatch
            + freshness * RecommendationWeights.freshness
            + sourceReliability * RecommendationWeights.sourceReliability
            + novelty * RecommendationWeights.novelty

        var reasons: [String] = []
        if artistAffinity >= 0.5 {
            reasons.append("recommendation_reason_artist".localized(with: RecommendationKey.displayPrimaryArtist(input.artist)))
        }
        if eraMatch >= 0.6, let year = input.year {
            let decade = decadeBucket(for: year)
            reasons.append("recommendation_reason_era".localized(with: decade))
        }
        if freshness >= 0.6 {
            reasons.append("recommendation_reason_trend".localized(with: RecommendationKey.displayPrimaryArtist(input.artist)))
        }
        if !input.isKnownTrack {
            reasons.append("recommendation_reason_new".localized)
        }

        return RecommendationScore(
            total: total,
            reasons: reasons,
            artistAffinity: artistAffinity,
            eraMatch: eraMatch,
            freshness: freshness,
            sourceReliability: sourceReliability,
            novelty: novelty
        )
    }

    /// 年份 → 十年桶（1998 → 1990）。
    static func decadeBucket(for year: Int) -> Int {
        (year / 10) * 10
    }

    private static func eraScore(year: Int?, profile: TasteProfile) -> Double {
        guard let year, !profile.decadeShare.isEmpty else { return RecommendationWeights.neutral }
        let bucket = decadeBucket(for: year)
        guard let share = profile.decadeShare[bucket] else { return 0 }
        let maxShare = profile.decadeShare.values.max() ?? 0
        return maxShare > 0 ? min(1, share / maxShare) : RecommendationWeights.neutral
    }

    private static func freshnessScore(artistKey: String, profile: TasteProfile) -> Double {
        // 没有任何漂移数据（新库 / 历史太短）→ 中性，不惩罚。
        guard !profile.recentArtistDrift.isEmpty else { return RecommendationWeights.neutral }
        let drift = profile.recentArtistDrift[artistKey] ?? 0
        let maxPositive = profile.recentArtistDrift.values.filter { $0 > 0 }.max() ?? 0
        guard maxPositive > 0, drift > 0 else { return 0 }
        return min(1, drift / maxPositive)
    }
}
