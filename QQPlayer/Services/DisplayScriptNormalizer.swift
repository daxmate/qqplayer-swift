//
//  DisplayScriptNormalizer.swift
//  QQPlayer
//
//  显示层简繁字形归一的**唯一入口**（曲名/专辑名/流派/歌词/歌手名全走这里）。
//  只转换"显示出来的字符串"，数据库里的原始 tag 一个字都不动。
//
//  规则（2026-09-13 用户拍板）：
//  - 只有 UI 语言选繁体中文时显示繁体（zh-Hant/zh-HK/zh-TW/zh-MO → toTraditional）；
//    其余全部（zh-Hans、en、fr、ru、空、未知）→ toSimplified（英文界面也显示简体）。
//  - 日文豁免：文本含假名（平假名/片假名/半角片假名）视为日文，**两个方向都原样返回**。
//  - toTraditional：逐字查表后套词级修正（复用歌手名的通用词保护 + 本文件的"干"类语境词条）；
//    不做姓氏保护——姓氏是"人名"语境，曲名/歌词首字命中姓氏会误伤（如「干杯」）。
//  - toSimplified：逐字查表（反向）。
//
//  映射表数据只有一份：SimplifiedTraditionalMap.swift（3895 行 OpenCC STCharacters 数据，
//  Apache-2.0 + 台→台 特例）；繁→简映射由它反转生成，运行时构建一次。
//

import Foundation

enum DisplayScriptNormalizer {
    /// 归一方向
    enum Direction: Equatable, Sendable {
        /// 目标字形为简体（zh-Hans/en/fr/ru/未知/空）
        case toSimplified
        /// 目标字形为繁体（zh-Hant/zh-HK/zh-TW/zh-MO）
        case toTraditional
        /// 不转换（显式传入时使用；方向判定不再产出此值）
        case identity
    }

    // MARK: - 方向

    /// 当前 UI 语言决定的方向，进程内缓存一次（渲染热路径不重复读 Bundle）。
    static let current: Direction = direction(for: Bundle.main.preferredLocalizations)

    /// 纯函数：由 preferredLocalizations 首位决定方向，便于测试（不依赖宿主语言）。
    /// zh-Hant*/zh-HK/zh-TW/zh-MO → toTraditional；其余（含空列表、未知语言）→ toSimplified。
    static func direction(for preferredLocalizations: [String]) -> Direction {
        guard let first = preferredLocalizations.first?.lowercased() else { return .toSimplified }
        if first.hasPrefix("zh-hant")
            || first.hasPrefix("zh-hk")
            || first.hasPrefix("zh-tw")
            || first.hasPrefix("zh-mo") {
            return .toTraditional
        }
        return .toSimplified
    }

    // MARK: - 映射

    // 繁→简单字映射不在本文件构造：唯一数据源是 TraditionalToSimplifiedMap.swift 的
    // `traditionalToSimplifiedMap`（OpenCC TSCharacters 数据）。
    // ⚠️ 不要在这里由 simplifiedToTraditionalMap 反转生成——多个简体字对应同一繁体字时
    // （开/𫔭 → 開 共 27 组），反转结果取决于 Dictionary 的迭代顺序（哈希种子每进程随机），
    // 同一首歌在不同次启动可能显示 开 或 𫔭（非 BMP，字体无字形 = 豆腐块 囗）；
    // 且 為/髮/臺/隻 等次选字形在简→繁表里没有反查项，简体界面下会原样露出繁体。
    // 事故与修法记录（2026-09-16）见 TraditionalToSimplifiedMap.swift 文件头。

    // MARK: - 词级修正（toTraditional 方向）

    /// 本文件补充的"干"类文本语境词条（错误繁体词 → 正确繁体词）。
    /// 简→繁单字表把「干」固定映射为「幹」，丢失另外两个读音的字形，需按词回改：
    /// - 乾（gān，空/枯竭义）：乾杯（举杯）· 乾淨（清洁）· 乾脆（直截）· 乾燥（缺水）
    ///   · 乾旱（久不下雨）· 餅乾（面食）· 乾枯 · 乾糧
    /// - 干（gān，犯/盾/天干义）：干涉 · 干預 · 干擾 · 干戈 · 天干 · 干支（干支纪年）
    /// 「幹」（gàn，做事义：幹部/幹活/樹幹）由单字表直接给出，无需修正。
    static let ganWordCorrections: [(wrong: String, correct: String)] = [
        ("幹杯", "乾杯"), ("幹淨", "乾淨"), ("幹脆", "乾脆"), ("幹燥", "乾燥"),
        ("幹旱", "乾旱"), ("餅幹", "餅乾"), ("幹枯", "乾枯"), ("幹糧", "乾糧"),
        ("幹涉", "干涉"), ("幹預", "干預"), ("幹擾", "干擾"), ("幹戈", "干戈"),
        ("天幹", "天干"), ("幹支", "干支"),
    ]

    /// 全部词级修正 = 歌手名通用词保护（里/发/后/复 等语境，人名与文本共用）
    /// + 本文件的"干"类补充。逐条为二字词且互不冲突，顺序替换即安全。
    static let wordCorrections: [(wrong: String, correct: String)] =
        ArtistNameNormalizer.traditionalWordCorrections + ganWordCorrections

    // MARK: - 日文豁免

    /// 文本是否含假名（平假名 U+3041–U+309F、片假名 U+30A0–U+30FF、半角片假名 U+FF66–U+FF9D）。
    /// 含假名视为日文：日文汉字与简繁字形不同（如「学/學」），转换会破坏原文，故两个方向都豁免。
    static func containsKana(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3041 ... 0x309F, 0x30A0 ... 0x30FF, 0xFF66 ... 0xFF9D:
                return true
            default:
                continue
            }
        }
        return false
    }

    // MARK: - 转换原语

    /// 逐字繁→简（未收录的字形原样保留）
    static func toSimplified(_ text: String) -> String {
        String(text.map { traditionalToSimplifiedMap[$0] ?? $0 })
    }

    /// 逐字简→繁（未收录的字形原样保留）+ 词级修正
    static func toTraditional(_ text: String) -> String {
        let converted = String(text.map { simplifiedToTraditionalMap[$0] ?? $0 })
        var result = converted
        for (wrong, correct) in wordCorrections where result.contains(wrong) {
            result = result.replacingOccurrences(of: wrong, with: correct)
        }
        return result
    }

    // MARK: - 显示入口

    /// 按指定方向归一显示字形；空串、identity、含假名（日文）一律原样返回。
    static func display(_ text: String, direction: Direction) -> String {
        guard !text.isEmpty else { return text }
        switch direction {
        case .identity:
            return text
        case .toSimplified:
            guard !containsKana(text) else { return text }
            return toSimplified(text)
        case .toTraditional:
            guard !containsKana(text) else { return text }
            return toTraditional(text)
        }
    }

    /// 按当前 UI 语言方向归一显示字形（渲染路径用这个）
    static func display(_ text: String) -> String {
        display(text, direction: current)
    }

    // MARK: - 库内规范形（入库 / 存量迁移用）

    /// 库内规范形 = **简体**（2026-09-18 用户拍板：「落库全部是简体中文」）。
    ///
    /// 与显示方向**解耦**：这里固定 `.toSimplified`，不跟 `current`（Bundle 语言）走。
    /// 若跟语言走，用户改一次语言设置就会把库内形态重新分叉（旧行繁体 + 新行简体），
    /// 重复行随即再现——这正是本入口存在的理由。
    ///
    /// 实现即本文件的 `display(_:direction:)` 固定方向：同一套映射表、同一套假名豁免，
    /// **不是第二份实现**（契约测试锁 `canonical(t) == display(t, direction: .toSimplified)` 恒等）。
    ///
    /// 允许的调用点只有两类：**入库写入**（upsertArtist / upsertAlbum / upsertTrack）
    /// 与**存量迁移**（migrateCanonicalizeScriptForms）。显示路径不许用它
    /// （显示走 `display(_:)`，否则繁体界面也被拉成简体）。
    static func canonical(_ text: String) -> String {
        display(text, direction: .toSimplified)
    }

    // MARK: - 搜索变体

    /// 搜索变体：query 本身 + 双向字形转换（去重），供 SQL LIKE OR 匹配。
    /// 库里 tag 原文一个字都不动，同一首曲子可能以简体或繁体字形入库；
    /// 单一字形模式会漏召回（简体 UI 下用户输"周杰伦"搜不到库里的"周傑倫"，反之对称）。
    ///
    /// - 首元素恒为 query 本身：用户输入原样优先匹配，行为与加变体前一致。
    /// - identity 方向只返回 `[query]`。
    /// - 不做日文假名豁免：假名不在映射表内，两个方向的转换结果都与 query 相同 → 天然去重
    ///   （假名文本只可能因词级修正产生变体，属无害的超集匹配）。
    /// - 歌手名变体不走这里：`ArtistNameNormalizer.searchVariants` 的人名语境需要姓氏保护
    ///   （于文文 → 於文文 是误伤），曲名/专辑名按本文件语义不做姓氏保护（如「干杯」）。
    static func searchVariants(of query: String, direction: Direction) -> [String] {
        guard direction != .identity else { return [query] }
        var variants = [query]
        for variant in [toSimplified(query), toTraditional(query)] where !variants.contains(variant) {
            variants.append(variant)
        }
        return variants
    }

    /// 当前 UI 语言方向下的搜索变体
    static func searchVariants(of query: String) -> [String] {
        searchVariants(of: query, direction: current)
    }
}
