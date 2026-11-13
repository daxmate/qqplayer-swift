//
//  RecommendationRequest+Rule.swift
//  QQPlayer
//
//  推荐 v3：指令输入的规则解析器（本地模型移除后的唯一实现）。
//
//  只做**确定性**抽取，不做语义猜测：
//   - 年代：1990 / 90年代 / 九十年代 / 1990s
//   - 参考艺人：「和/跟/像 X 类似」里的 X，且必须能在画像种子里命中（防误抽）
//   - 关键词：整句原话（交给在线搜索）
//  解析不出正向条件时按关键词召回，不返回失败（用户输入永远可执行）。
//

import Foundation

struct RuleRecommendationRequestPlanner: RecommendationRequestPlanning {
    func makeRequest(
        text: String,
        history _: [RecommendationRequestHistoryEntry],
        profile: TasteProfile
    ) async -> Result<RecommendationUserRequest, RecommendationRequestError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyRequest) }

        var request = RecommendationUserRequest(rawText: trimmed)
        request.keywords = [trimmed]
        request.decades = RuleRecommendationTextParser.decades(in: trimmed)
        request.referenceArtists = RuleRecommendationTextParser.referenceArtists(
            in: trimmed,
            knownArtists: profile.topArtists.map(\.artist)
        )
        return .success(request)
    }
}

enum RuleRecommendationTextParser {
    private static let decadeDigits = try! NSRegularExpression(
        pattern: #"((?:19|20)\d{2})\s*(?:年代|s)?"#
    )
    private static let decadeShort = try! NSRegularExpression(
        pattern: #"([1-9])\s*0\s*年代"#
    )
    private static let referencePattern = try! NSRegularExpression(
        pattern: #"(?:和|跟|像|类似|同)\s*([^，。,.!?！？、\s]{1,20}?)\s*(?:类似|一样|差不多|风格)"#
    )

    /// 年代起点（十年；去重升序）。
    static func decades(in text: String) -> [Int] {
        var result = Set<Int>()
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        for match in decadeDigits.matches(in: text, range: range) {
            guard let raw = capture(1, match, text), let year = Int(raw) else { continue }
            result.insert(year / 10 * 10)
        }
        for match in decadeShort.matches(in: text, range: range) {
            guard let raw = capture(1, match, text), let value = Int(raw) else { continue }
            result.insert(1900 + value * 10)
        }
        return result.sorted()
    }

    /// 参考艺人：只在画像种子里命中时采纳（大小写 / 标点归一后比较）。
    static func referenceArtists(in text: String, knownArtists: [String]) -> [String] {
        guard !knownArtists.isEmpty else { return [] }
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        var result: [String] = []
        var seen = Set<String>()
        for match in referencePattern.matches(in: text, range: range) {
            guard let raw = capture(1, match, text) else { continue }
            let key = RecommendationLibraryMatcher.artistKey(raw)
            guard !key.isEmpty else { continue }
            guard let known = knownArtists.first(where: { RecommendationLibraryMatcher.artistKey($0) == key }) else { continue }
            let knownKey = RecommendationLibraryMatcher.artistKey(known)
            guard seen.insert(knownKey).inserted else { continue }
            result.append(known)
        }
        return result
    }

    private static func capture(_ index: Int, _ match: NSTextCheckingResult, _ text: String) -> String? {
        guard index < match.numberOfRanges else { return nil }
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}
