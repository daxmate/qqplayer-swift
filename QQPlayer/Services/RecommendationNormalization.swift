//
//  RecommendationNormalization.swift
//  QQPlayer
//
//  推荐 v2 P1：跨源候选的归一化与去重键（纯函数、可单测、不读网络不碰 DB）。
//
//  口径（设计定稿 §4 / 任务包 §3A）：
//  1. 繁→简：唯一数据源 CharacterMapResourceLoader.load(.traditionalToSimplified)
//     （与 DisplayScriptNormalizer.canonical 同一张 OpenCC 表；禁止 StringTransform、
//     禁止自建映射表、禁止第二份简繁数据）。
//  2. 版本后缀（Live / 现场 / 演唱会 / Remastered / 重制 / 伴奏 / instrumental /
//     inst. / Demo / 试听版 / feat. xxx）一律剥离。
//  3. ASCII 小写、去标点、去多余空白、trim。
//  4. 幂等：同一输入连续两次结果一致（测试锁）。
//
//  与 RecommendationKey 的关系：括号段 / feat. 段 / " - <版本>" 尾段的剥离规则
//  复用 RecommendationKey（它是既有唯一实现）；本文件只在它之上补「繁→简 +
//  无分隔符版本尾缀 + 标点归一 + 艺人去空白」，不复制它的内部规则。
//

import Foundation

/// 推荐 v2 归一化（跨源去重键的唯一口径）。
enum RecommendationNormalization {
    // MARK: - 繁 → 简

    /// 逐字繁→简（未收录字形原样保留；空串安全）。
    ///
    /// 数据来源只有一处：CharacterMapResourceLoader（与显示层 / 入库规范形同表）。
    static func toSimplified(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let map = CharacterMapResourceLoader.load(.traditionalToSimplified)
        return String(text.map { map[$0] ?? $0 })
    }

    // MARK: - 版本尾缀

    /// 需要剥离的版本 / 现场 / 伴奏尾缀（英文需词边界，中文可紧贴）。
    ///
    /// 只剥离结尾出现且剥离后仍剩内容的情况；Live Forever 这类词在中间、
    /// 或整串就是标记时不动（避免把正常歌名削成空串）。
    static let trailingVersionMarkers: [String] = [
        "remastered", "remaster", "instrumental", "inst.", "inst",
        "acoustic", "unplugged", "live", "demo", "remix", "version", "edit",
        "演唱会", "现场版", "现场", "重制版", "重制", "伴奏版", "伴奏",
        "试听版", "翻唱", "纯音乐",
    ]

    // MARK: - 歌名

    /// 归一化歌名：繁→简 → 既有括号 / feat. / "- 版本" 剥离 → 无分隔符版本尾缀 → 去标点。
    static func normalizeTitle(_ raw: String) -> String {
        let simplified = toSimplified(raw)
        // 复用既有实现（括号段 / feat. 段 / "- Remastered" 类尾段 / 空白折叠 / 小写）。
        let base = RecommendationKey.normalizeTitle(simplified)
        let stripped = strippingTrailingVersionMarkers(base)
        return strippingPunctuation(stripped)
    }

    // MARK: - 艺人

    /// 归一化艺人：繁→简 → 拆 feat. / & / , / 、 / " x " → 取主艺人 → 小写 → 去空白。
    static func normalizeArtist(_ raw: String) -> String {
        let simplified = toSimplified(raw)
        // " x "（带空格的小写 x）是英文合作写法；& / , / 、 由既有 primaryArtist 处理。
        let withSeparator = simplified.replacingOccurrences(of: " x ", with: " & ")
        let primary = RecommendationKey.primaryArtist(withSeparator)
        return primary.filter { !$0.isWhitespace }
    }

    // MARK: - 去重键

    /// 跨源去重键："<归一化歌名>|<归一化主艺人>"。空串安全（"" → "|"）。
    static func dedupeKey(title: String, artist: String) -> String {
        normalizeTitle(title) + "|" + normalizeArtist(artist)
    }

    // MARK: - 内部步骤

    /// 反复剥离结尾版本标记（"song live remastered" → "song"）。
    private static func strippingTrailingVersionMarkers(_ text: String) -> String {
        var current = text
        // 最多三轮：尾缀可叠（"live remastered" / "现场版 live"）。
        for _ in 0 ..< 3 {
            guard let stripped = strippingOneTrailingMarker(current), stripped != current else { break }
            current = stripped
        }
        return current
    }

    private static func strippingOneTrailingMarker(_ text: String) -> String? {
        // 长标记优先，避免 "live" 先命中 "live remastered" 的尾段。
        for marker in trailingVersionMarkers.sorted(by: { $0.count > $1.count }) {
            guard text.hasSuffix(marker), text.count > marker.count else { continue }
            let prefix = String(text.dropLast(marker.count))
            let needsBoundary = marker.unicodeScalars.allSatisfy { $0.isASCII }
            if needsBoundary {
                // 英文标记必须独立成词（"songlive" 不是版本尾缀）。
                guard let boundary = prefix.last,
                      boundary.isWhitespace || boundary == "-" || boundary == "·"
                else { continue }
            }
            let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
            // 尾缀前必须有内容；只剩标记（如整串 "live"）时不动。
            guard !trimmed.isEmpty else { continue }
            return trimmed
        }
        return nil
    }

    /// 去标点 / 符号，折叠多余空白后 trim（英文撇号、中点、括号残片一并去掉）。
    private static func strippingPunctuation(_ text: String) -> String {
        let kept = text.unicodeScalars.filter { scalar in
            !CharacterSet.punctuationCharacters.contains(scalar)
                && !CharacterSet.symbols.contains(scalar)
        }
        let joined = String(String.UnicodeScalarView(kept))
        return joined.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
