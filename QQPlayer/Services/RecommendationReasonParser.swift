//
//  RecommendationReasonParser.swift
//  QQPlayer
//
//  推荐 v2 P3：模型理由的统一校验（纯函数，可单测）。
//
//  拒绝（→ 该条回落规则理由）：
//  - 空 / 含换行 / 超过 maxCharacters(CJK) 或 maxWords(拉丁)
//  - 含 JSON 残片或引号（{ } [ ] " “ ” < > \\）
//  - 引号内的名字（「…」 / 《…》）不在本批输入的歌名 / 艺人 / 专辑里
//  - 出现 4 位年份但与输入年份不符，或输入没给年份却自己编了年份
//
//  ⚠️ 纯逻辑层：iOS / macOS 共享。
//

import Foundation

enum RecommendationReasonParser {
    /// 模型原始输出 → `key → [理由]`（只保留通过校验的条目）。
    static func parse(_ text: String, items: [RecommendationReasonItem]) -> [String: [String]] {
        guard let payload = jsonObject(in: text) else { return [:] }
        let allowedNames = allowedNames(in: items)
        var result: [String: [String]] = [:]
        for (index, item) in items.enumerated() {
            guard let raw = payload[String(index + 1)] as? String else { continue }
            guard let reason = validate(raw, item: item, allowedNames: allowedNames) else { continue }
            result[item.key] = [reason]
        }
        return result
    }

    // MARK: - 单条校验

    /// 合格 → 规范化后的理由；不合格 → nil（调用方保留规则理由）。
    static func validate(
        _ raw: String,
        item: RecommendationReasonItem,
        allowedNames: Set<String>
    ) -> String? {
        let reason = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return nil }
        guard !reason.contains("\n"), !reason.contains("\r") else { return nil }
        guard !containsForbiddenMarkup(reason) else { return nil }
        guard withinLengthLimit(reason) else { return nil }
        guard quotedNamesAllowed(reason, allowedNames: allowedNames) else { return nil }
        guard yearsAllowed(reason, item: item) else { return nil }
        return reason
    }

    /// 本批输入里允许出现的名字（歌名 / 艺人 / 专辑），归一化后比对。
    static func allowedNames(in items: [RecommendationReasonItem]) -> Set<String> {
        var names = Set<String>()
        for item in items {
            names.insert(normalizedName(item.title))
            names.insert(normalizedName(item.artist))
            if let album = item.album, !album.isEmpty {
                names.insert(normalizedName(album))
            }
        }
        names.remove("")
        return names
    }

    // MARK: - 细则

    private static func containsForbiddenMarkup(_ reason: String) -> Bool {
        let forbidden: [Character] = ["{", "}", "[", "]", "\"", "“", "”", "<", ">"]
        if reason.contains(where: { forbidden.contains($0) }) { return true }
        return reason.contains("\\")
    }

    /// CJK 文案按字符数，拉丁文案按词数（取任一满足即可，避免中英混排误杀）。
    private static func withinLengthLimit(_ reason: String) -> Bool {
        if reason.unicodeScalars.contains(where: { $0.value >= 0x2E80 }) {
            return reason.count <= RecommendationReasonPrompt.maxCharacters
        }
        let words = reason.split(whereSeparator: { $0.isWhitespace }).count
        return words <= RecommendationReasonPrompt.maxWords
    }

    /// 「…」/《…》里的名字必须是本批输入里出现过的名字。
    private static func quotedNamesAllowed(_ reason: String, allowedNames: Set<String>) -> Bool {
        for quoted in quotedSegments(in: reason) {
            let name = normalizedName(quoted)
            guard !name.isEmpty else { return false }
            guard allowedNames.contains(where: { $0.contains(name) || name.contains($0) }) else {
                return false
            }
        }
        return true
    }

    /// 4 位年份必须与输入一致；输入没给年份就不许出现年份。
    private static func yearsAllowed(_ reason: String, item: RecommendationReasonItem) -> Bool {
        for year in fourDigitYears(in: reason) {
            guard let itemYear = item.year, itemYear == year else { return false }
        }
        return true
    }

    private static func quotedSegments(in reason: String) -> [String] {
        var result: [String] = []
        result.append(contentsOf: segments(in: reason, open: "「", close: "」"))
        result.append(contentsOf: segments(in: reason, open: "《", close: "》"))
        return result
    }

    private static func segments(in reason: String, open: Character, close: Character) -> [String] {
        var result: [String] = []
        var current: String?
        for character in reason {
            if character == open {
                current = ""
            } else if character == close, let value = current {
                result.append(value)
                current = nil
            } else if current != nil {
                current?.append(character)
            }
        }
        return result
    }

    private static func fourDigitYears(in reason: String) -> [Int] {
        let characters = Array(reason)
        var years: [Int] = []
        var index = 0
        while index + 3 < characters.count {
            let window = characters[index ... index + 3]
            let isBoundary = (index == 0 || !characters[index - 1].isNumber)
                && (index + 4 == characters.count || !characters[index + 4].isNumber)
            if isBoundary,
               window.allSatisfy({ $0.isNumber }),
               let value = Int(String(window)),
               (1900 ... 2030).contains(value) {
                years.append(value)
                index += 4
                continue
            }
            index += 1
        }
        return years
    }

    // MARK: - JSON

    /// 从模型输出里取第一个 JSON 对象（容忍 code fence / 前后废话）。
    private static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        let json = String(text[start ... end])
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private static func normalizedName(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
