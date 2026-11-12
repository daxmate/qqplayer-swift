//
//  RecommendationReasonPrompt.swift
//  QQPlayer
//
//  推荐 v2 P3：一次整批的理由 prompt（system + user）。
//
//  口径：15 首一批**只发一次**请求（不做逐曲调用）；prompt 只喂 title / artist / album / year
//  + 目标语言，禁止夹带画像、播放历史、文件路径等。
//  ⚠️ 纯逻辑层：iOS / macOS 共享。
//

import Foundation

enum RecommendationReasonPrompt {
    /// 每首理由的硬上限（中文字符数 / 拉丁词数），校验与 prompt 共用。
    static let maxCharacters = 60
    static let maxWords = 20

    static func system(locale: Locale) -> String {
        """
        You write one short listening reason for each recommended song.
        Rules:
        - Reply with JSON only. No markdown, no code fences, no explanations.
        - Schema: {"1":"reason for song 1","2":"reason for song 2"} with one key per input id, ids as given.
        - Every reason is a single sentence on one line: at most \(maxCharacters) characters (CJK) or \(maxWords) words.
        - Use ONLY the given title, artist, album and year. Never invent artists, albums, years, genres or awards.
        - Do not add quotes, brackets, braces, emoji or JSON fragments inside a reason.
        - Do not mention playlists, file paths, database ids, personal data or the listener's identity.
        - Write in \(languageInstruction(for: locale)).
        """
    }

    static func user(for items: [RecommendationReasonItem]) -> String {
        var lines: [String] = ["Songs:"]
        for (index, item) in items.enumerated() {
            var parts = ["title: " + singleLine(item.title), "artist: " + singleLine(item.artist)]
            if let album = item.album, !album.isEmpty {
                parts.append("album: " + singleLine(album))
            }
            if let year = item.year {
                parts.append("year: \(year)")
            }
            lines.append("\(index + 1). " + parts.joined(separator: " | "))
        }
        lines.append("")
        lines.append("Return exactly \(items.count) entries, ids 1...\(items.count).")
        return lines.joined(separator: "\n")
    }

    /// 目标语言（prompt 里用英文语言名，避免模型把语言名当歌名）。
    static func languageInstruction(for locale: Locale) -> String {
        let identifier = locale.identifier.lowercased()
        if identifier.contains("hant") || identifier.contains("tw") || identifier.contains("hk") {
            return "Traditional Chinese"
        }
        if identifier.hasPrefix("zh") {
            return "Simplified Chinese"
        }
        if identifier.hasPrefix("ru") {
            return "Russian"
        }
        if identifier.hasPrefix("fr") {
            return "French"
        }
        if identifier.hasPrefix("ja") {
            return "Japanese"
        }
        return "English"
    }

    /// 单行化 + 去掉会破坏「id. title | artist」结构的字符。
    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
