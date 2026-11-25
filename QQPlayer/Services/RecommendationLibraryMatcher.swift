//
//  RecommendationLibraryMatcher.swift
//  QQPlayer
//
//  推荐 v4：曲库匹配 / 已下载标记的唯一归一化入口（纯逻辑、无 IO）。
//
//  归一化口径（顺序固定）：
//   0. 繁简折叠（ICU `Hant-Hans`）：库里「周杰倫」与候选「周杰伦」必须同键；**只影响键，不改展示**；
//   1. 标题剥版本后缀（最多 4 轮）：半角/全角括号副标题、`【…】`、
//      `- 现场版 / - Live / - 演唱会 / - Remastered / - 伴奏 / - DJ版 / - 片段`、
//      `feat. X` 等；剥离后与原键**同时**参与匹配（原键做二次尝试，见 `titleKeys`）；
//   2. 艺人拆集合：`&` / `、` / `,` / `，` / `/` / `feat.` / `ft.` / `featuring` / `with`
//      全拆，**任一命中即算**（同时保留主艺人键）；
//   3. 折叠大小写 / 全半角 / 变音符号，只保留字母与数字（空白与标点全部丢弃）。
//
//  为什么丢弃空白：不同来源的 The Beatles / TheBeatles / the beatles 必须命中同一条曲库记录。
//  为什么保留多键：同一个键既要「精确去重」（`key`），又要「尽量命中」（`keys`），
//  两者口径不同，不能只留一套。
//

import Foundation

enum RecommendationLibraryMatcher {
    // MARK: - 版本后缀

    /// 括号版后缀（半角 / 全角都吃）：白名单命中才剥。
    private static let bracketSuffix = makeRegex(
        pattern: #"(?i)\s*[\(\[（【]\s*(?:live[^\)\]）】]*|remaster(?:ed)?[^\)\]）】]*|feat\.[^\)\]）】]*|ft\.[^\)\]）】]*|with [^\)\]）】]*|bonus track[^\)\]）】]*|deluxe[^\)\]）】]*|album version[^\)\]）】]*|single version[^\)\]）】]*|现场[^\)\]）】]*|演唱会[^\)\]）】]*|伴奏[^\)\]）】]*|片段[^\)\]）】]*)[\)\]）】]\s*$"#
    )

    /// 全角/半角括号里的**中文副标题**（`（电影《…》主题曲）` / `(电影《…》插曲)` / `【…】`）：
    /// 这类后缀不在白名单也能剥（否则整段残留 → 永远匹配不上曲库基准键）。
    private static let subtitleSuffix = makeRegex(
        pattern: #"(?i)\s*(?:[\(（【][^\)）】]*[《》][^\)）】]*[\)）】]|[\(（【][^\)）】]*(?:主题曲|插曲|片尾曲|片头曲|推广曲|宣传曲)[^\)）】]*[\)）】]|【[^】]*】)\s*$"#
    )

    /// dash 版后缀：`- Live` / `- Remastered` / `- 2011 Remaster` / `- 现场版` / `- 演唱会`
    /// / `- 伴奏` / `- DJ版` / `- 片段`。
    private static let dashSuffix = makeRegex(
        pattern: #"(?i)\s+-\s*(?:live\b.*|remastered?\b.*|\d{4}\s*remaster.*|现场版?.*|演唱会.*|伴奏.*|dj\s*版?.*|片段.*)$"#
    )

    /// 无括号的 feat 后缀（`Song feat. X`）。
    private static let featSuffix = makeRegex(
        pattern: #"(?i)\s+(?:feat\.|ft\.|featuring)\s+.*$"#
    )

    /// 编译一个字面量正则。
    ///
    /// 不用 try!：DangerousOperatorContract 把 try! 视为「一崩了之」，模式写坏时
    /// 要给可定位诊断（带模式串）。内置模式均有单测覆盖，编译失败 = 编程错误。
    private static func makeRegex(pattern: String) -> NSRegularExpression {
        do {
            return try NSRegularExpression(pattern: pattern)
        } catch {
            preconditionFailure("内置正则模式必须可编译（编程错误）：\(pattern) — \(error)")
        }
    }

    private static func replace(_ regex: NSRegularExpression, in text: String) -> String {
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    // MARK: - 标题

    /// 剥离标题版本后缀（最多 4 轮，覆盖「(Live) - Remastered 2011」这类叠加写法）。
    static func stripTitleSuffixes(_ raw: String) -> String {
        var text = raw.folding(options: [.widthInsensitive], locale: nil)
        for _ in 0 ..< 4 {
            let before = text
            text = replace(subtitleSuffix, in: text)
            text = replace(bracketSuffix, in: text)
            text = replace(dashSuffix, in: text)
            text = replace(featSuffix, in: text)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text == before { break }
        }
        return text.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : text
    }

    // MARK: - 艺人

    /// 艺人分隔符（`&` 也拆：多艺人合作曲库里常只存其中一个名字）。
    private static let artistSeparator = makeRegex(
        pattern: #"(?i)\s*(?:[&、,，/]|\s(?:feat\.?|ft\.?|featuring|with)\s)\s*"#
    )

    /// 主艺人分隔符：**不含 `&`**——`Simon & Garfunkel` 是组合名而不是两个人，
    /// 唯一键（去重 / 缓存身份）必须保住它；`&` 只在 `artistKeys`（匹配集合）里拆。
    private static let primaryArtistSeparators = [",", "，", "、", "/", " feat. ", " ft. ", " featuring ", " with "]

    /// 主艺人（第一个艺人；用于去重的唯一键）。
    static func primaryArtist(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in primaryArtistSeparators {
            if let range = text.range(of: separator, options: [.caseInsensitive]) {
                text = String(text[..<range.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 拆分多艺人（`A & B` → [A, B]；空段丢弃）。
    static func splitArtistNames(_ raw: String) -> [String] {
        let text = raw.folding(options: [.widthInsensitive], locale: nil)
        let range = NSRange(text.startIndex ..< text.endIndex, in: text)
        let normalized = artistSeparator.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "\u{1F}")
        return normalized
            .split(separator: "\u{1F}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 归一化（繁简 / 大小写 / 全半角 / 变音 / 标点 / 空白全部折叠）。**只用于键，不改展示。**
    static func normalize(_ raw: String) -> String {
        let folded = foldScript(raw)
            .folding(options: [.widthInsensitive, .diacriticInsensitive, .caseInsensitive], locale: nil)
        var out = String()
        out.reserveCapacity(folded.count)
        for character in folded where character.isLetter || character.isNumber {
            out.append(character)
        }
        return out
    }

    /// 繁简折叠（ICU Hant-Hans）：繁体 → 简体。失败时原样返回。
    private static func foldScript(_ raw: String) -> String {
        raw.applyingTransform(StringTransform(rawValue: "Hant-Hans"), reverse: false) ?? raw
    }

    /// 全部艺人键（多艺人拆开；去重保序）。
    static func artistKeys(_ raw: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in splitArtistNames(raw) {
            let key = normalize(name)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(key)
        }
        return out
    }

    /// 主艺人键（唯一键用这个）。
    static func artistKey(_ raw: String) -> String {
        normalize(primaryArtist(raw))
    }

    // MARK: - 键

    /// 标题键（剥后缀后归一化）。
    static func titleKey(_ raw: String) -> String {
        normalize(stripTitleSuffixes(raw))
    }

    /// 标题的全部候选键：剥离后 + 原键（二次尝试）。
    static func titleKeys(_ raw: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for variant in [stripTitleSuffixes(raw), raw] {
            let key = normalize(variant)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            out.append(key)
        }
        return out
    }

    /// 曲目唯一键（标题 + 主艺人；去重 / 缓存 / 排序共用，**不做多键扩展**）。
    static func key(title: String, artist: String) -> String {
        let resolved = resolveFilenameFallback(title: title, artist: artist)
        let t = titleKey(resolved.title)
        let a = artistKey(resolved.artist)
        if t.isEmpty, a.isEmpty { return "" }
        return t + "#" + a
    }

    /// 曲目全部匹配键（标题变体 × 艺人变体 + 纯标题兜底）。
    ///
    /// 纯标题键（`标题#`）只在**曲库那一侧缺艺人**时才会存在，因此候选侧带上它不会误伤
    /// 有艺人的曲库记录——这正是「库内无 artistId」那一档的兜底。
    static func keys(title: String, artist: String) -> Set<String> {
        let resolved = resolveFilenameFallback(title: title, artist: artist)
        let titles = titleKeys(resolved.title)
        let artists = artistKeys(resolved.artist)
        var out = Set<String>()
        guard !titles.isEmpty else { return out }
        guard !artists.isEmpty else {
            // 缺艺人：只产出纯标题键（由 `matches` 的兜底档负责跨侧比较）。
            for title in titles { out.insert(title + "#") }
            return out
        }
        for title in titles {
            for artist in artists {
                out.insert(title + "#" + artist)
            }
        }
        return out
    }

    /// 候选与曲库是否命中。
    ///
    /// 两档：① 完整键相等（标题 + 艺人，任一艺人命中即算）；
    /// ② 纯标题兜底——**只在一侧缺艺人**时启用（库内无 artistId / 候选无艺人），
    ///    两侧都有艺人时绝不放宽，否则同名的不同歌会互相误伤。
    static func matches(_ candidateKeys: Set<String>, libraryKeys: Set<String>) -> Bool {
        guard !candidateKeys.isEmpty, !libraryKeys.isEmpty else { return false }
        if !candidateKeys.isDisjoint(with: libraryKeys) { return true }
        let candidateTitles = Set(candidateKeys.map { titlePart($0) })
        if libraryKeys.contains(where: { artistPart($0).isEmpty && candidateTitles.contains(titlePart($0)) }) {
            return true
        }
        let libraryTitles = Set(libraryKeys.map { titlePart($0) })
        return candidateKeys.contains { artistPart($0).isEmpty && libraryTitles.contains(titlePart($0)) }
    }

    private static func titlePart(_ key: String) -> String {
        key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
    }

    private static func artistPart(_ key: String) -> String {
        let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return "" }
        return String(parts[1])
    }

    // MARK: - 文件名兜底

    /// 文件名兜底：`周杰伦-晴天.mp3` 被整串当标题且无艺人时，按 `艺人 - 标题` 拆开并交叉验证。
    ///
    /// 只在**艺人缺失**时启用（有艺人时标题里的 dash 是标题的一部分，不能猜）；
    /// 拆分后两侧都必须非空，否则原样返回——宁可匹配不上，也不要造出错的键。
    static func resolveFilenameFallback(title: String, artist: String) -> (title: String, artist: String) {
        let artistTrimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard artistTrimmed.isEmpty else { return (title, artist) }
        let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return (title, artist) }
        for separator in [" - ", "-", "–", "—"] {
            guard let range = raw.range(of: separator) else { continue }
            let left = String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let right = String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !left.isEmpty, !right.isEmpty else { continue }
            // 交叉验证：两侧都要有实质内容（纯数字/纯标点不算艺人名）。
            guard left.rangeOfCharacter(from: .letters) != nil, right.rangeOfCharacter(from: .letters) != nil else { continue }
            return (right, left)
        }
        return (title, artist)
    }
}
