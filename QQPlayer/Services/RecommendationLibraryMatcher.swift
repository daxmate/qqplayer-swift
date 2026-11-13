//
//  RecommendationLibraryMatcher.swift
//  QQPlayer
//
//  推荐 v3：曲库排除 / 已下载标记的唯一归一化入口（纯逻辑）。
//
//  归一化口径（顺序固定）：
//   1. 剥离版本后缀：(Live) / [Live] / - Live / - Remastered YYYY / YYYY Remaster
//      / (feat. X) / feat. X / (Deluxe Edition) 等；
//   2. 主艺人取第一个（逗号 / 顿号 / 斜杠 / feat. / ft. / with 分隔；不切 &，保护 Simon & Garfunkel）；
//   3. 折叠大小写 / 全半角 / 变音符号，只保留字母与数字（空白与标点全部丢弃）。
//
//  为什么丢弃空白：不同来源的 The Beatles / TheBeatles / the beatles 必须命中同一条曲库记录。
//

import Foundation

enum RecommendationLibraryMatcher {
    // MARK: - 版本后缀

    private static let bracketSuffix = try! NSRegularExpression(
        pattern: #"(?i)\s*[\(\[](?:live[^\)\]]*|remaster(?:ed)?[^\)\]]*|feat\.[^\)\]]*|ft\.[^\)\]]*|with [^\)\]]*|bonus track[^\)\]]*|deluxe[^\)\]]*|album version[^\)\]]*|single version[^\)\]]*|现场[^\)\]]*|演唱会[^\)\]]*)[\)\]]\s*$"#
    )

    private static let dashSuffix = try! NSRegularExpression(
        pattern: #"(?i)\s+-\s*(?:live\b.*|remastered?\b.*|\d{4}\s*remaster.*)$"#
    )

    private static let featSuffix = try! NSRegularExpression(
        pattern: #"(?i)\s+(?:feat\.|ft\.|featuring)\s+.*$"#
    )

    /// 剥离标题版本后缀（最多 4 轮，覆盖「(Live) - Remastered 2011」这类叠加写法）。
    static func stripTitleSuffixes(_ raw: String) -> String {
        // 先做宽度折叠：中文全角括号「（）」也要能被 ASCII 模式命中（网易云常写「忘情水（现场版）」）。
        var text = raw.folding(options: [.widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for _ in 0 ..< 4 {
            let before = text
            text = replace(bracketSuffix, in: text)
            text = replace(dashSuffix, in: text)
            text = replace(featSuffix, in: text)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == before { break }
        }
        return text
    }

    private static func replace(_ regex: NSRegularExpression, in text: String) -> String {
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    // MARK: - 艺人

    private static let artistSeparators = [",", "，", "、", "/", " feat. ", " ft. ", " featuring ", " with "]

    /// 主艺人（第一个艺人；不切 &）。
    static func primaryArtist(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in artistSeparators {
            if let range = text.range(of: separator, options: [.caseInsensitive]) {
                text = String(text[..<range.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 归一化（大小写 / 全半角 / 变音 / 标点 / 空白全部折叠）。
    static func normalize(_ raw: String) -> String {
        let folded = raw.folding(
            options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        var out = String()
        out.reserveCapacity(folded.count)
        for character in folded where character.isLetter || character.isNumber {
            out.append(character)
        }
        return out
    }

    static func artistKey(_ raw: String) -> String {
        normalize(primaryArtist(raw))
    }

    static func titleKey(_ raw: String) -> String {
        normalize(stripTitleSuffixes(raw))
    }

    /// 曲目唯一键（标题 + 艺人；排除 / 去重 / 已下载标记共用）。
    static func key(title: String, artist: String) -> String {
        let t = titleKey(title)
        let a = artistKey(artist)
        if t.isEmpty, a.isEmpty { return "" }
        return t + "#" + a
    }
}
