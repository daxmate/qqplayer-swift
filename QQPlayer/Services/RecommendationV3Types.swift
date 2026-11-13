//
//  RecommendationV3Types.swift
//  QQPlayer
//
//  推荐 v3：通道 / 画像权重 / 通道配额 / 候选上下文（纯逻辑，iOS + macOS 共享）。
//
//  ⚠️ 纯函数层：只依赖 Foundation，不读 DB、不发网络、不引入平台 API。
//

import Foundation

// MARK: - 通道

/// 召回通道（rawValue 进候选标识与缓存，不得随意改）。
enum RecommendationChannel: String, Codable, CaseIterable, Sendable {
    /// A：种子艺人（常听 / 曲库高频）的热门曲。
    case seed
    /// B：与种子艺人风格相近的艺人的热门曲。
    case similar
    /// C：同风格簇（genre × decade × language）的其他艺人热门曲。
    case explore
    /// 附加通道：用户点名 / 指令输入（不占配额）。
    case request

    var localizationKey: String {
        switch self {
        case .seed: return "recommendation_channel_seed"
        case .similar: return "recommendation_channel_similar"
        case .explore: return "recommendation_channel_explore"
        case .request: return "recommendation_channel_request"
        }
    }

    /// 通道权重（进排序公式；request 最高，避免被画像通道挤掉）。
    var scoreWeight: Double {
        switch self {
        case .seed: return 1.0
        case .similar: return 0.85
        case .explore: return 0.7
        case .request: return 1.1
        }
    }
}

// MARK: - 画像权重

/// 口味画像四项权重（写入设置时归一到和 1）。
struct RecommendationProfileWeights: Sendable, Equatable, Codable {
    /// 曲库曲目数（log1p 归一）。
    var library: Double
    /// 总播放次数（log1p 归一）。
    var play: Double
    /// 收藏 / 歌单命中。
    var favorite: Double
    /// 加入曲库时间（180 天半衰指数衰减）。
    var recency: Double

    static let defaults = RecommendationProfileWeights(
        library: 0.35,
        play: 0.40,
        favorite: 0.15,
        recency: 0.10
    )

    static let valueRange: ClosedRange<Double> = 0 ... 1
    static let valueStep: Double = 0.05

    /// 单项夹取（NaN / ∞ → 默认值；越界 → 边界）。
    static func clamp(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        let clamped = min(valueRange.upperBound, max(valueRange.lowerBound, value))
        let steps = (clamped / valueStep).rounded()
        return min(valueRange.upperBound, max(valueRange.lowerBound, steps * valueStep))
    }

    /// 四项夹取（各自套用默认值兜底，不改变相对权重）。
    func clamped() -> RecommendationProfileWeights {
        RecommendationProfileWeights(
            library: Self.clamp(library, fallback: Self.defaults.library),
            play: Self.clamp(play, fallback: Self.defaults.play),
            favorite: Self.clamp(favorite, fallback: Self.defaults.favorite),
            recency: Self.clamp(recency, fallback: Self.defaults.recency)
        )
    }

    /// 归一到和 1（全零 → 默认权重；夹取后再归一，保证确定性）。
    func normalized() -> RecommendationProfileWeights {
        let base = clamped()
        let sum = base.library + base.play + base.favorite + base.recency
        guard sum > 0 else { return .defaults }
        return RecommendationProfileWeights(
            library: base.library / sum,
            play: base.play / sum,
            favorite: base.favorite / sum,
            recency: base.recency / sum
        )
    }

    /// 四项之和（UI 校验 / 单测用）。
    var sum: Double { library + play + favorite + recency }
}

// MARK: - 通道配额

/// 三通道配额（A 种子 / B 相似 / C 探索；写入设置时校验和 = 1）。
struct RecommendationChannelQuotas: Sendable, Equatable, Codable {
    var seed: Double
    var similar: Double
    var explore: Double

    static let defaults = RecommendationChannelQuotas(seed: 0.40, similar: 0.40, explore: 0.20)

    static let valueRange: ClosedRange<Double> = 0 ... 1
    static let valueStep: Double = 0.05

    /// 和是否等于 1（±0.001；UI 校验用）。
    var isValid: Bool {
        abs(seed + similar + explore - 1) <= 0.001
    }

    var sum: Double { seed + similar + explore }

    func clamped() -> RecommendationChannelQuotas {
        RecommendationChannelQuotas(
            seed: RecommendationProfileWeights.clamp(seed, fallback: Self.defaults.seed),
            similar: RecommendationProfileWeights.clamp(similar, fallback: Self.defaults.similar),
            explore: RecommendationProfileWeights.clamp(explore, fallback: Self.defaults.explore)
        )
    }

    /// 归一到和 1（全零 → 默认配额）。
    func normalized() -> RecommendationChannelQuotas {
        let base = clamped()
        let total = base.sum
        guard total > 0 else { return .defaults }
        return RecommendationChannelQuotas(
            seed: base.seed / total,
            similar: base.similar / total,
            explore: base.explore / total
        )
    }

    /// 按配额拆分条数（最大余数法；顺序固定 seed → similar → explore，保证同输入同结果）。
    ///
    /// 不变量：返回三者之和 == max(0, total)。
    func allocation(total: Int) -> (seed: Int, similar: Int, explore: Int) {
        let count = max(0, total)
        guard count > 0 else { return (0, 0, 0) }
        let normalized = self.normalized()
        let shares = [normalized.seed, normalized.similar, normalized.explore]
        let raw = shares.map { $0 * Double(count) }
        var counts = raw.map { Int(floor($0)) }
        var remainder = count - counts.reduce(0, +)
        // 最大余数：余数相同按固定顺序（下标小者优先），不依赖排序稳定性。
        let order = (0 ..< 3).sorted { lhs, rhs in
            let l = raw[lhs] - floor(raw[lhs])
            let r = raw[rhs] - floor(raw[rhs])
            if abs(l - r) > 0.000_001 { return l > r }
            return lhs < rhs
        }
        var index = 0
        while remainder > 0 {
            counts[order[index % 3]] += 1
            remainder -= 1
            index += 1
        }
        return (counts[0], counts[1], counts[2])
    }
}

// MARK: - 语言

/// 语种推断结果（只做文字特征判断，不做语言学模型）。
enum RecommendationLanguage: String, Codable, CaseIterable, Sendable {
    case zhHans
    case zhHant
    case japanese
    case korean
    case latin
    case unknown

    var localizationKey: String {
        switch self {
        case .zhHans: return "recommendation_language_zh_hans"
        case .zhHant: return "recommendation_language_zh_hant"
        case .japanese: return "recommendation_language_ja"
        case .korean: return "recommendation_language_ko"
        case .latin: return "recommendation_language_latin"
        case .unknown: return "recommendation_language_unknown"
        }
    }
}

/// 语种推断（假名 / 谚文 / 汉字简繁 / 拉丁；多信号取首个命中，顺序固定）。
enum RecommendationLanguageDetector {
    /// 繁体专用字（简体文本里几乎不出现；只作启发式判据，不求完备）。
    private static let traditionalOnly: Set<Character> = [
        "們", "這", "說", "國", "愛", "樂", "時", "間", "學", "開", "關", "聽", "聲",
        "夢", "風", "雲", "舊", "讓", "還", "會", "與", "為", "從", "無", "語", "記",
    ]

    static func detect(_ text: String) -> RecommendationLanguage {
        var hasHan = false
        var hasTraditional = false
        var hasLatin = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (0x3040 ... 0x30FF).contains(value) { return .japanese }
            if (0xAC00 ... 0xD7AF).contains(value) { return .korean }
            if (0x4E00 ... 0x9FFF).contains(value) {
                hasHan = true
                if traditionalOnly.contains(Character(scalar)) { hasTraditional = true }
                continue
            }
            if (0x41 ... 0x5A).contains(value) || (0x61 ... 0x7A).contains(value) {
                hasLatin = true
            }
        }
        if hasHan { return hasTraditional ? .zhHant : .zhHans }
        if hasLatin { return .latin }
        return .unknown
    }

    /// 多段文本投票（出现次数最多者胜；同票按 allCases 顺序，保证确定性）。
    static func detect(in texts: [String]) -> RecommendationLanguage {
        var votes: [RecommendationLanguage: Int] = [:]
        for text in texts {
            let language = detect(text)
            guard language != .unknown else { continue }
            votes[language, default: 0] += 1
        }
        return RecommendationLanguage.allCases
            .filter { votes[$0] != nil }
            .max { lhs, rhs in
                let l = votes[lhs] ?? 0
                let r = votes[rhs] ?? 0
                if l != r { return l < r }
                let li = RecommendationLanguage.allCases.firstIndex(of: lhs) ?? 0
                let ri = RecommendationLanguage.allCases.firstIndex(of: rhs) ?? 0
                return li > ri
            } ?? .unknown
    }
}

// MARK: - 画像产物

/// 种子艺人（画像 Top 15 的一项）。
struct RecommendationSeedArtist: Sendable, Equatable, Codable {
    var artist: String
    /// 0…1（四项权重加权后归一）。
    var affinity: Double
    var libraryCount: Int
    var playCount: Int
    /// 代表曲（最多 3 首，供召回 / 展示兜底）。
    var representativeTitles: [String]
}

/// 风格簇（genre × decade × language 占比 Top）。
struct RecommendationStyleCluster: Sendable, Equatable, Codable {
    var genre: String
    /// 十年起点（如 1990）；nil = 曲库缺年份。
    var decade: Int?
    var language: RecommendationLanguage
    /// 0…1（该簇曲目数 / 有 genre 的曲目总数）。
    var share: Double
}

/// 画像为空的可读原因（UI 直接展示）。
enum RecommendationProfileEmptyReason: String, Sendable, Equatable {
    case emptyLibrary
    case noArtistData

    var localizationKey: String {
        switch self {
        case .emptyLibrary: return "recommendation_profile_empty_library"
        case .noArtistData: return "recommendation_profile_no_artist"
        }
    }
}

/// 口味画像 v3：三通道召回与排序的唯一输入。
struct RecommendationTasteProfileV3: Sendable, Equatable {
    var seeds: [RecommendationSeedArtist] = []
    var clusters: [RecommendationStyleCluster] = []
    /// 曲库归一化曲目键（排除用）。
    var libraryKeys: Set<String> = []
    /// 播放过的归一化曲目键。
    var playedKeys: Set<String> = []
    var blacklistTracks: Set<String> = []
    var blacklistArtists: Set<String> = []
    /// nil = 画像可用；非 nil = 画像为空且有可读原因。
    var emptyReason: RecommendationProfileEmptyReason?

    var isEmpty: Bool { seeds.isEmpty }

    /// 艺人亲和度查表（artist 为归一化主艺人键；缺失 = 0）。
    func affinity(forArtist artist: String) -> Double {
        let key = RecommendationLibraryMatcher.artistKey(artist)
        return seeds.first { RecommendationLibraryMatcher.artistKey($0.artist) == key }?.affinity ?? 0
    }
}

// MARK: - 候选上下文

/// 候选的召回上下文（排序 / 理由 / 诊断用；nil 字段 = 来源给不出，不编造）。
struct RecommendationCandidateContext: Sendable, Equatable, Codable {
    var channel: RecommendationChannel
    /// 召回用的种子艺人（B 通道 = 被相似的种子；C 通道 = nil）。
    var seedArtist: String?
    /// 相似度（Last.fm match，0…1；别的来源给不出 = nil）。
    var similarity: Double?
    /// 热度（来源榜内位置归一，0…1；位置越靠前越高）。
    var popularity: Double?
    var language: RecommendationLanguage?
    /// 曲目年份（与候选的 year 同值，便于排序不读候选）。
    var year: Int?
    /// 召回阶段已知的亲和度（如风格簇占比）；nil = 排序时按种子艺人查表。
    var affinity: Double?
    /// 风格簇的 genre（C 通道理由文案用；别的通道为 nil）。
    var genre: String?

    init(
        channel: RecommendationChannel,
        seedArtist: String? = nil,
        similarity: Double? = nil,
        popularity: Double? = nil,
        language: RecommendationLanguage? = nil,
        year: Int? = nil,
        affinity: Double? = nil,
        genre: String? = nil
    ) {
        self.channel = channel
        self.seedArtist = seedArtist
        self.similarity = similarity
        self.popularity = popularity
        self.language = language
        self.year = year
        self.affinity = affinity
        self.genre = genre
    }
}
