//
//  SearchQuery.swift
//  QQPlayer
//
//  用户搜索串的唯一归一入口（2026-11-13 收口）。
//
//  背景：iOS `SearchView` 与 macOS `MacLibraryView+Content` 各自维护一份
//  「lowercased + folding」的 normalizedQuery；而底层 `DatabaseManager` 的搜索函数
//  对首尾空白处理不一致——曲目只在内部 trim、歌手/专辑/歌单完全没 trim，
//  并且「只有空白的 query」在曲目搜索里会命中**整库**（用户误敲一个空格 →
//  满屏「所有含空格的歌」）。
//
//  纪律：任何吃用户输入做搜索的代码都从这里取归一后的串——
//    · SQL 层（`DatabaseManager+Library`）用 `trimmed(_:)`（不做大小写折叠，SQL LIKE 自己处理）
//    · UI 层（`SearchView` / `MacLibraryView+Content`）用 `normalized(_:)`
//    · 「空查询」一律用 `isEmpty(_:)` 判断，且判断必须发生在 trim 之后
//

import Foundation

/// 搜索串归一（首尾空白 / 空查询判定 / 大小写折叠）的唯一入口。
enum SearchQuery {
    /// 去掉首尾空白：半角空格、全角空格（U+3000）、Tab、换行都算。
    /// 字符串**中间**的空白原样保留（多词搜索语义不变）。
    static func trimmed(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 空查询唯一判据（trim 之后仍为空 = 空查询）。
    static func isEmpty(_ raw: String) -> Bool {
        trimmed(raw).isEmpty
    }

    /// UI 侧归一：先 trim，再大小写 / 变音符号折叠（搜索不区分大小写与重音）。
    static func normalized(_ raw: String) -> String {
        trimmed(raw).lowercased().folding(options: .diacriticInsensitive, locale: .current)
    }
}
