//
//  LyricAlignmentTextNormalizer.swift
//  QQPlayer
//
//  对齐前的文本归一化：NFKC + 小写 + 去空白/标点/符号 + 中文繁→简。
//  只用于「比较」；落库永远是原始歌词文本。
//

import Foundation

enum LyricAlignmentTextNormalizer {
    // MARK: - 公开入口

    /// 归一化后的完整字符串（保留空白与标点，仅做等价化）。
    static func normalizedText(of text: String, simplifyChinese: Bool) -> String {
        var value = text.precomposedStringWithCompatibilityMapping
        if simplifyChinese {
            value = simplified(value)
        }
        return value.lowercased()
    }

    /// 逐字符归一化结果：只保留字母/数字（空白、标点、符号、emoji 全丢）。
    ///
    /// 用 Character（字形簇）而不是 Unicode.Scalar：emoji / 组合音标是多个
    /// scalar，按 scalar 切会把一个显示字符拆成多个匹配单位。
    static func normalizedCharacters(of text: String, simplifyChinese: Bool) -> [Character] {
        normalizedText(of: text, simplifyChinese: simplifyChinese).filter(isMeaningful)
    }

    /// 该字符是否参与匹配（含任一个字母或数字即可）。
    ///
    /// 用 Unicode 通用类别白名单，而不是 CharacterSet.letters：
    /// 后者会把 ❤️（U+2764，Other Symbol）也算成「字母」，emoji 会污染匹配。
    static func isMeaningful(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
                 .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - 繁→简

    /// 繁→简。
    ///
    /// 复用项目唯一数据源 DisplayScriptNormalizer.toSimplified（OpenCC TSCharacters，
    /// 已由 CharacterMapResourceTests 逐键校验），**不另建映射表、也不用 ICU
    /// StringTransform**：两套映射会让「显示字形」和「对齐归一化」漂移，
    /// 而且 iOS 18 上 ICU 繁简 transform 的可用性没有工程内保证。
    static func simplified(_ text: String) -> String {
        DisplayScriptNormalizer.toSimplified(text)
    }
}
