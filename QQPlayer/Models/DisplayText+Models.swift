//
//  DisplayText+Models.swift
//  QQPlayer
//
//  模型字段的显示字形访问器：UI 一律读这些属性，而不是直接读原始字段，
//  从而保证曲名/专辑名/流派/歌词的简繁字形跟随系统 UI 语言（DisplayScriptNormalizer）。
//
//  ⚠️ 只影响"显示出来的字符串"：数据库写入、同步载荷、Spotlight 索引、
//  歌词磁盘缓存依旧使用模型原始字段，一个字都不改。
//

import Foundation

extension Track {
    /// 曲名（按当前 UI 语言归一字形）
    var displayTitle: String {
        DisplayScriptNormalizer.display(title)
    }

    /// 流派（可空；空值与原始字段一致为 nil）
    var displayGenre: String? {
        genre.map { DisplayScriptNormalizer.display($0) }
    }
}

extension Album {
    /// 专辑名（按当前 UI 语言归一字形）
    var displayTitle: String {
        DisplayScriptNormalizer.display(title)
    }
}

extension LyricsLine {
    /// 歌词原文（按当前 UI 语言归一字形）
    var displayText: String {
        DisplayScriptNormalizer.display(text)
    }

    /// 歌词翻译（可空；空值与原始字段一致为 nil）
    var displayTranslation: String? {
        translation.map { DisplayScriptNormalizer.display($0) }
    }

    /// 歌词罗马音（可空；空值与原始字段一致为 nil）
    var displayRoman: String? {
        roman.map { DisplayScriptNormalizer.display($0) }
    }
}
