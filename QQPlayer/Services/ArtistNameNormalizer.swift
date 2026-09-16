//
//  ArtistNameNormalizer.swift
//  QQPlayer
//
//  歌手名简繁归一（显示层，不动数据库数据）。
//
//  背景：artist 表里同一歌手可能同时有繁体名（周杰倫）和简体名（周杰伦）两行，
//  被当作两个歌手。按当前 UI 语言归一字形：
//  - 繁体中文 UI（zh-Hant/zh-HK/zh-TW/zh-MO）→ 显示繁体名（简体名归并）
//  - 其余全部（zh-Hans/en/fr/ru/空/未知）→ 显示简体名（繁体名归并）
//  方向由系统语言决定（App 无应用内语言设置）：Bundle.main.preferredLocalizations 首位；
//  方向判定委托 DisplayScriptNormalizer（显示层字形归一的唯一入口），
//  保证歌手名与曲名/专辑名/歌词的字形方向完全一致。
//  （2026-09-13 语义变更：en/ru/fr 由 identity 改为 toSimplified——英文界面也显示简体字形。）
//
//  日文假名不受影响（映射表无假名字符）；日文汉字名在简体 UI 显示简体字形
//  （主流播放器一致做法）。
//
//  映射表：简→繁复用 SimplifiedTraditionalMap.swift 的 simplifiedToTraditionalMap
//  （OpenCC STCharacters 数据 + 台→台 特例）；繁→简用 TraditionalToSimplifiedMap.swift 的
//  traditionalToSimplifiedMap（OpenCC TSCharacters 数据，权威反查方向，不做运行时反转）。
//

import Foundation

/// 歌手名简繁归一工具（纯函数，无状态）
enum ArtistNameNormalizer {
    /// 归一方向
    enum Direction: Equatable, Sendable {
        /// 简体 UI：繁体名归并为简体
        case toSimplified
        /// 繁体 UI：简体名归并为繁体
        case toTraditional
        /// 不转换（仅显式传入时使用；方向判定不再产出此值）
        case identity
    }

    // MARK: - 方向

    /// 当前 UI 语言决定的归一方向（App 无应用内语言设置，跟随系统）
    static var direction: Direction {
        direction(for: Bundle.main.preferredLocalizations)
    }

    /// 纯函数：由 preferredLocalizations 首位决定方向，便于测试（不依赖宿主语言）。
    /// 委托 DisplayScriptNormalizer，与之保持同一语义：
    /// zh-Hant*/zh-HK/zh-TW/zh-MO → toTraditional；其余（zh-Hans/en/fr/ru/空/未知）→ toSimplified。
    static func direction(for preferredLocalizations: [String]) -> Direction {
        switch DisplayScriptNormalizer.direction(for: preferredLocalizations) {
        case .toSimplified: return .toSimplified
        case .toTraditional: return .toTraditional
        case .identity: return .identity
        }
    }

    // MARK: - 映射

    // 繁→简单字映射不在本文件构造：唯一数据源是 TraditionalToSimplifiedMap.swift 的
    // `traditionalToSimplifiedMap`。⚠️ 不要由 simplifiedToTraditionalMap 反转生成
    // （多简对一繁 → 结果随 Dictionary 哈希顺序变化、每进程随机；详见该文件头 2026-09-16 事故记录）。

    // MARK: - 保护表（单字映射丢失多义项的修正）

    /// 单字简→繁映射为每个简字只保留一个传统字形（发→發/干→幹/后→後/里→裏/复→復/于→於…），
    /// 丢失另一义项就会出语境错误（千里之外→千裏之外）与姓氏误转（于文文→於文文）。
    /// 这里用两层保护修正 toTraditional 方向的输出，不动 OpenCC 数据表
    /// （SimplifiedTraditionalMap.swift 简→繁 / TraditionalToSimplifiedMap.swift 繁→简）：
    /// 1. 姓氏保护：名字首字命中常见多义/多音姓氏时，保留原字或替换为正确传统姓氏字形；
    /// 2. 精确词保护：转换结果整词命中时回改为正确传统字形（千裏→千里、頭發→頭髮、
    ///    皇後→皇后、相幹→相干、重復→重複…）。
    /// 反向（toSimplified）无需保护：繁→简用的是 OpenCC 权威数据（TraditionalToSimplifiedMap.swift），
    /// 发音/干燥/台湾 等语境在繁→简方向没有歧义（髮→发、乾→干、臺→台 数据里直接给出）。

    /// 姓氏保护：首字命中这些常见多义/多音姓氏时，toTraditional 不再按单字表盲转。
    /// 注：单/叶/万/宁/种/钟 等姓氏单字表转换后即正确传统字形（單/葉/萬/寧/種/鍾），
    /// 不在保护之列，避免把本应转繁的姓氏留在简体。
    static let surnameProtectedChars: Set<Character> = [
        // 单字表会误转（发→發 式义项塌缩）
        "于", "范", "余", "郁", "云", "冲", "朴", "干", "涂", "后",
        // 单字表暂无对应项，显式保护防未来表变更引入误转
        "沈", "谷", "姜", "曲", "曾", "查", "仇", "解",
    ]

    /// 姓氏字形覆盖：正确传统字形与简体字不同的姓氏（冲→沖；其余姓氏保留原字）。
    static let surnameTraditionalOverrides: [Character: Character] = [
        "冲": "沖",
    ]

    /// 精确词保护：toTraditional 转换结果上的整词回改（错误繁体词 → 正确繁体词）。
    /// 均为二字词且互相无子串冲突，顺序替换即安全；若将来加入更长词，需改最长匹配。
    static let traditionalWordCorrections: [(wrong: String, correct: String)] = [
        // 里（长度单位/地名，非"裏"）
        ("千裏", "千里"), ("萬裏", "萬里"), ("公裏", "公里"), ("英裏", "英里"),
        ("海裏", "海里"), ("裏程", "里程"), ("故裏", "故里"), ("鄉裏", "鄉里"),
        ("鄰裏", "鄰里"), ("裏約", "里約"),
        // 发（头发/毛发，非"發"）
        ("頭發", "頭髮"), ("理發", "理髮"), ("毛發", "毛髮"), ("假發", "假髮"),
        ("發型", "髮型"), ("發夾", "髮夾"), ("發廊", "髮廊"), ("發絲", "髮絲"),
        ("發辮", "髮辮"), ("發質", "髮質"), ("發簪", "髮簪"),
        // 后（皇后/天后/后羿，非"後"）
        ("皇後", "皇后"), ("天後", "天后"), ("後羿", "后羿"), ("王後", "王后"),
        ("太後", "太后"),
        // 干（相干/若干，非"幹"；首字"干"按姓氏保护处理，干杯/干净 等不属歌手名语境）
        ("相幹", "相干"), ("若幹", "若干"),
        // 里（地名音译，非"裏"）
        ("馬裏", "馬里"), ("巴裏", "巴里"),
        // 复（複：重复/复习/复杂等，非"復"）
        ("重復", "重複"), ("復習", "複習"), ("復雜", "複雜"), ("復印", "複印"),
        ("復數", "複數"), ("反復", "反覆"), ("答復", "答覆"), ("復蓋", "覆蓋"),
        ("顛復", "顛覆"),
    ]

    /// toTraditional 转换 + 保护修正：先逐字转换（首字命中保护姓氏则用正确姓氏字形），
    /// 再对转换结果做精确词回改。
    static func convertToTraditional(_ name: String) -> String {
        let chars = Array(name)
        var converted = ""
        converted.reserveCapacity(name.utf16.count)
        for (index, char) in chars.enumerated() {
            if index == 0, surnameProtectedChars.contains(char) {
                converted.append(surnameTraditionalOverrides[char] ?? char)
            } else {
                converted.append(simplifiedToTraditionalMap[char] ?? char)
            }
        }
        var result = converted
        for (wrong, correct) in traditionalWordCorrections {
            result = result.replacingOccurrences(of: wrong, with: correct)
        }
        return result
    }

    // MARK: - 转换

    /// 归一 key（用于分组）：按方向逐字转换；identity 返回原名。
    /// toTraditional 方向带保护修正（姓氏/精确词），toSimplified 反向天然安全无需修正。
    static func normalizedKey(_ name: String, direction: Direction) -> String {
        switch direction {
        case .toSimplified:
            return String(name.map { traditionalToSimplifiedMap[$0] ?? $0 })
        case .toTraditional:
            return convertToTraditional(name)
        case .identity:
            return name
        }
    }

    /// 当前方向下的归一 key
    static func normalizedKey(_ name: String) -> String {
        normalizedKey(name, direction: direction)
    }

    /// 显示名：原名已是目标字形（转换后不变）则保留原名，否则返回转换后的字形。
    static func displayName(_ name: String, direction: Direction) -> String {
        let converted = normalizedKey(name, direction: direction)
        return converted == name ? name : converted
    }

    /// 当前方向下的显示名
    static func displayName(_ name: String) -> String {
        displayName(name, direction: direction)
    }

    /// 组内多名字选显示名：优先组内"原名 == 归一 key"（本来就是目标字形）的名字，
    /// 否则取第一个的转换结果。
    static func displayName(for names: [String], direction: Direction) -> String {
        guard let first = names.first else { return "" }
        if let alreadyTarget = names.first(where: { normalizedKey($0, direction: direction) == $0 }) {
            return alreadyTarget
        }
        return normalizedKey(first, direction: direction)
    }

    /// 当前方向下的组内显示名
    static func displayName(for names: [String]) -> String {
        displayName(for: names, direction: direction)
    }

    // MARK: - 搜索变体

    /// 搜索变体：query 当前字形 + 反向字形各一份，供 SQL LIKE OR 匹配
    /// （简体 UI 下用户输"周杰伦"也能搜到库里的"周傑倫"，反之对称）。
    /// identity 方向只返回原名。
    static func searchVariants(of query: String, direction: Direction) -> [String] {
        guard direction != .identity else { return [query] }
        let toTraditional = convertToTraditional(query)
        let toSimplified = String(query.map { traditionalToSimplifiedMap[$0] ?? $0 })
        var variants = [query]
        for variant in [toSimplified, toTraditional] where !variants.contains(variant) {
            variants.append(variant)
        }
        return variants
    }

    /// 当前方向下的搜索变体
    static func searchVariants(of query: String) -> [String] {
        searchVariants(of: query, direction: direction)
    }
}

// 注：按归一 key 分组（groupedArtists / NormalizedArtist，需要 GRDB 模型 Artist）
// 已移到 ArtistNameGrouping.swift —— Siri 扩展只编译本文件的纯归一部分，不带模型层。
