//
//  RecommendationTypes.swift
//  QQPlayer
//
//  本地 AI 推荐 P1：候选模型 / 归一化键 / 打分权重（纯逻辑、可单测，不读 DB 不发网络）。
//  全部权重与阈值集中在 `RecommendationWeights` / `RecommendationScorer`，
//  P2 接模型时只替换打分输入来源，不动召回与 UI。
//
//  ⚠️ 本文件与 `RecommendationProfile.swift` 都是纯函数层：iOS / macOS 共享，
//  不得引入平台 API 或视图依赖。
//

import Foundation

// MARK: - 来源

/// 推荐候选来源（P1 只有两个在线源；rawValue 进候选 id，不得随意改）。
enum RecommendationSource: String, CaseIterable, Codable, Sendable {
    case itunes
    case musicbrainz
    case netease
    case gequhai
    case lastfm

    /// 源可靠度（打分权重 `sourceReliability` 的输入）：
    /// iTunes 官方 Search API 元数据最全；MusicBrainz 是社区库；网易云 eapi 稳定；歌曲海是 HTML 解析。
    var reliability: Double {
        switch self {
        case .itunes: return 1.0
        case .musicbrainz: return 0.8
        case .netease: return 1.0
        case .gequhai: return 0.6
        case .lastfm: return 0.9
        }
    }

    /// 展示名本地化键（与刮削源共用 `source_*`，不另立第二套）。
    var localizationKey: String {
        switch self {
        case .itunes: return "source_itunes"
        case .musicbrainz: return "source_musicbrainz"
        case .netease: return "source_netease"
        case .gequhai: return "source_gequhai"
        case .lastfm: return "source_lastfm"
        }
    }
}

// MARK: - 批量策略（P2）

/// 「为你推荐」v2 P2 的批量口径（设计 §5：15 首一批、池 ≥60、同艺人 ≤4、同专辑 ≤2）。
enum RecommendationBatchPolicy {
    /// 单批展示条数。
    static let batchSize = 15
    /// 会话池目标（15 × 4 余量）。
    static let poolTarget = 60
    /// 同艺人上限（30%）。
    static let maxSongsPerArtist = 4
    /// 同专辑上限。
    static let maxSongsPerAlbum = 2
    /// 单批至少多少个不同艺人（15 首 ≥ 8 个）。
    static let minDistinctArtists = 8
    /// 同一十年代上限（15 首的 60%，池不足时放宽并标记）。
    static let maxSongsPerDecade = 9
    /// 同一曲风上限（15 首的 60%；缺 genre 的条目不参与该约束）。
    static let maxSongsPerGenre = 9
    /// 跨会话「最近推过」软黑名单窗口（7 天）。
    static let recentBlacklistWindow: TimeInterval = 7 * 24 * 3600
}

// MARK: - 归一化键

/// 归一化口径（去重 / 黑名单 / 库内比对的**唯一**入口）。
///
/// 去括号（中英文）、去 `feat./ft.` 尾段、去 `- Remaster/版本` 后缀、
/// 全角半角统一（NFKC 兼容映射）、大小写归并、多艺人取主艺人。
enum RecommendationKey {
    /// 单曲键：`<归一化歌名>|<主艺人>`（全仓唯一的单曲比对口径）。
    static func normalize(title: String, artist: String) -> String {
        "\(normalizeTitle(title))|\(primaryArtist(artist))"
    }

    /// 归一化歌名（不含艺人）。
    static func normalizeTitle(_ raw: String) -> String {
        var text = raw.precomposedStringWithCompatibilityMapping
        text = removingBracketedSegments(text)
        text = removingFeaturingSegment(text)
        text = removingVersionSuffix(text)
        return collapseWhitespace(text).lowercased()
    }

    /// 主艺人（多艺人只取第一个；大小写/全角半角归并）。
    static func primaryArtist(_ raw: String) -> String {
        var text = raw.precomposedStringWithCompatibilityMapping
        text = truncatingAtFirstSeparator(text)
        // `A feat. B` / `A ft. B`：feat 段不是主艺人（与歌名同一条去尾规则）。
        text = removingFeaturingSegment(text)
        return collapseWhitespace(text).lowercased()
    }

    /// 展示用主艺人（保留原始大小写与空格，只截断多艺人）。
    static func displayPrimaryArtist(_ raw: String) -> String {
        var text = raw.precomposedStringWithCompatibilityMapping
        text = truncatingAtFirstSeparator(text)
        text = removingFeaturingSegment(text)
        return collapseWhitespace(text)
    }

    /// 文本比对口径：全半角归并 + 小写 + 空白折叠（不截断多艺人 / 不删括号）。
    ///
    /// 用于「用户点名的艺人」与 intent.query / 候选艺人之间的匹配；
    /// 与 primaryArtist 的区别是不做截断，避免把关键词短语误截成半截。
    static func comparisonToken(_ raw: String) -> String {
        let folded = raw.precomposedStringWithCompatibilityMapping.lowercased()
        return folded.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// 艺人比对键：主艺人再去掉所有空白（大小写 / 全半角 / 空白归一的统一口径）。
    static func artistMatchKey(_ raw: String) -> String {
        primaryArtist(raw).filter { !$0.isWhitespace }
    }

    // MARK: 内部步骤

    /// 去掉所有成对括号段（含括号内容）：`Song (Live)` → `Song`。
    /// 兼容 NFKC 之前的全角括号，以及未闭合时不吞后文。
    private static func removingBracketedSegments(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            switch character {
            case "(", "（", "[", "【":
                depth += 1
            case ")", "）", "]", "】":
                if depth > 0 { depth -= 1 }
            default:
                if depth == 0 { result.append(character) }
            }
        }
        return result
    }

    /// 去掉 `feat. X` / `ft. X` 尾段（词首边界判定，避免误伤 `football`）。
    private static func removingFeaturingSegment(_ text: String) -> String {
        for token in ["feat.", "feat", "ft.", "ft"] {
            guard let range = text.range(of: token, options: [.caseInsensitive]) else { continue }
            let prefix = text[text.startIndex ..< range.lowerBound]
            let boundaryBefore = prefix.isEmpty || prefix.last?.isWhitespace == true
            let boundaryAfter = range.upperBound == text.endIndex
                || text[range.upperBound].isWhitespace
                || text[range.upperBound] == "."
            guard boundaryBefore, boundaryAfter else { continue }
            return String(prefix)
        }
        return text
    }

    /// 去掉 ` - Remastered 2011` / ` - Live` / ` - 中文版` 这类版本后缀。
    private static func removingVersionSuffix(_ text: String) -> String {
        guard let separator = text.range(of: " - ", options: .backwards) else { return text }
        let prefix = text[text.startIndex ..< separator.lowerBound]
        let suffix = text[separator.upperBound...].lowercased()
        let keywords = [
            "remaster", "live", "version", "mix", "edit", "mono", "stereo",
            "demo", "bonus", "acoustic", "instrumental", "deluxe", "remix",
            "版本", "现场", "重制", "伴奏", "混音", "版",
        ]
        guard keywords.contains(where: { suffix.contains($0) }) else { return text }
        return String(prefix)
    }

    /// 在第一个多艺人分隔符处截断（`/`、`&`、`、`、`,`、`;`、`×`）。
    private static func truncatingAtFirstSeparator(_ text: String) -> String {
        let separators: Set<Character> = ["/", "&", "、", ",", "，", ";", "；", "×"]
        if let index = text.firstIndex(where: { separators.contains($0) }) {
            return String(text[text.startIndex ..< index])
        }
        return text
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - 年代标签

/// 年代标签的**唯一**解析口径：请求层 / 计划层（消费端）/ 结果过滤层共用，禁止第二份实现。
///
/// 只认「整串就是年代」的标签（允许前后空白与包裹括号）：
/// `1990s` / `1990's` / `1990S` / `(1990s)` / `1990年代` / `90s` / `90年代` / `1990` / `1990 年`。
/// 标题中段含年代（`1990s Love Song` / `夏日1990`）一律返回 nil——那里是歌名，不是年代标签。
enum RecommendationDecadeLabel {
    /// 4 位年份的合法区间（与请求解析层的年代校验保持一致）。
    static let validYears = 1900 ... 2030

    /// 标签 → 十年桶起点（`1997` / `1990s` / `90s` → 1990）；不是纯年代标签 → nil。
    static func parse(_ raw: String) -> Int? {
        var text = raw.precomposedStringWithCompatibilityMapping.lowercased()
        // 弯引号归一到直引号后再去掉 `'`：`1990's` 与 `1990s` 同一口径。
        text = text.replacingOccurrences(of: "\u{2019}", with: "'")
        text = text.replacingOccurrences(of: "\u{2018}", with: "'")
        text = text.replacingOccurrences(of: "'", with: "")
        // 纯标签不依赖空白（`1990 年` / `1990 s` 都归一成紧凑文本）。
        text = text.split(whereSeparator: \.isWhitespace).joined()
        text = strippingWrappingBrackets(text)
        guard !text.isEmpty else { return nil }

        var digits = Substring(text)
        var hasSuffix = false
        // 「年代」优先于单字后缀，避免 `1990年代` 只吃掉 `代`。
        for suffix in ["年代", "s", "年"] where digits.hasSuffix(suffix) {
            digits = digits.dropLast(suffix.count)
            hasSuffix = true
            break
        }
        guard digits.allSatisfy({ ("0" ... "9").contains($0) }), let value = Int(digits) else { return nil }

        switch digits.count {
        case 4:
            // 纯四位年份（`1990` / `1995`）按十年取整；超出合法区间不算年代标签。
            return decadeStart(forYear: value)
        case 2:
            // 两位年代必须带后缀（`90s` / `90年代`）；裸 `90` 这类数字不算。
            guard hasSuffix else { return nil }
            let year = value >= 30 ? 1900 + value : 2000 + value
            return validYears.contains(year) ? decadeStart(forYear: year) : nil
        default:
            return nil
        }
    }

    /// 年份 → 十年桶起点；超出合法区间 → nil（不编造年代）。
    static func decadeStart(forYear year: Int) -> Int? {
        guard validYears.contains(year) else { return nil }
        return (year / 10) * 10
    }

    /// 去掉最多两层包裹括号（`(1990s)` / `【1990s】`），其余字符原样保留。
    private static func strippingWrappingBrackets(_ text: String) -> String {
        let pairs: [Character: Character] = [
            "(": ")", "[": "]", "【": "】", "（": "）", "《": "》", "\"": "\"",
        ]
        var current = text
        for _ in 0 ..< 2 {
            guard let first = current.first, let last = current.last, first != last else { return current }
            guard pairs[first] == last else { return current }
            current = String(current.dropFirst().dropLast())
        }
        return current
    }
}

// MARK: - 候选

/// 一条推荐候选（召回 → 去重 → 打分后的展示模型）。
struct RecommendedCandidate: Identifiable, Codable, Equatable, Sendable {
    var title: String
    var artist: String
    var album: String?
    /// 专辑 / 单曲年份（来源给不出时为 nil，打分按中性处理，不编造）。
    var year: Int?
    var source: RecommendationSource
    var score: Double = 0
    /// 推荐理由（已本地化的成品文案；P1 由规则产出，P3 由模型产出）。
    var reasons: [String] = []
    /// 召回意图里的曲风（仅 `kind == .genre` 的意图给得出；缺省 = 不参与批次曲风上限）。
    var genre: String?
    /// 相似补位来源（nil = 本人匹配行；非 nil = 该点名艺人的相关艺人）。
    var relatedTo: String?
    /// v3 召回通道（nil = 旧引擎 / 缓存老数据）。
    var channel: RecommendationChannel?
    /// v3 召回用的种子艺人（B 通道 = 被相似的种子）。
    var seedArtist: String?
    /// v3 语种标签（nil = 未判定）。
    var language: RecommendationLanguage?

    var id: String {
        "\(RecommendationKey.normalize(title: title, artist: artist))#\(source.rawValue)"
    }
}

// MARK: - 打分

/// 打分输入（只放候选侧可观测的事实，画像侧统一从 `TasteProfile` 读）。
struct RecommendationScoreInput: Sendable, Equatable {
    var artist: String
    var year: Int?
    var source: RecommendationSource
    /// 是否已在本曲库 / 播放历史里（引擎已过滤库内，这里只影响 novelty 权重）。
    var isKnownTrack: Bool = false
    /// 榜单热度（0.5 = 中性 / 未上榜；1.0 = 榜一）。默认值保持旧调用兼容。
    var popularity: Double = 0.5
}

/// 打分结果（分量留档便于 P2 对照模型输出）。
struct RecommendationScore: Sendable, Equatable {
    var total: Double
    var reasons: [String]
    var artistAffinity: Double
    var eraMatch: Double
    var freshness: Double
    var sourceReliability: Double
    var novelty: Double
    /// 榜单热度分量（无榜单时恒为 0.5）。
    var popularity: Double
}

// MARK: - 检索意图

/// 召回意图：只描述「去哪儿找歌」，不承担打分。
///
/// `kind` 决定召回策略与理由文案；`artist` / `decade` / `genre` 是产生它的画像依据。
/// 禁止再用「1990年代」「流行」这类泛词直接搜歌（泛词只会召回歌单 / 合辑）。
struct RecommendationIntent: Sendable, Equatable {
    enum Kind: String, Sendable {
        /// 同艺人热歌。
        case artist
        /// 与种子歌曲相似（在线源支持时才用）。
        case similar
        /// 曲库里该年代的高权重艺人。
        case decade
        /// 曲库里该曲风的高权重艺人。
        case genre
        /// 指令输入里的关键词 / 情绪词（直接在线搜索）。
        case keyword
    }

    var query: String
    var kind: Kind
    var artist: String?
    var decade: Int?
    var genre: String?

    /// 意图稳定标识（kind + query 小写）：去重与「显式优先」匹配共用同一口径。
    var priorityKey: String {
        "\(kind.rawValue)|\(query.lowercased())"
    }

    init(query: String, kind: Kind, artist: String? = nil, decade: Int? = nil, genre: String? = nil) {
        self.query = query
        self.kind = kind
        self.artist = artist
        self.decade = decade
        self.genre = genre
    }
}

/// 意图生成（纯函数）：top 艺人 ≤ 8 + 年代代表艺人 + 曲风代表艺人，总数 ≤ 12。
///
/// 所有意图最终都落到「艺人名 → 热歌」这一条召回路径上：
/// 年代 / 曲风只用来挑**用户自己曲库里**的高权重艺人，不再直接搜泛词。
enum RecommendationIntentBuilder {
    static let maxArtistIntents = 8
    static let maxDecadeIntents = 2
    static let maxGenreIntents = 2
    static let maxTotalIntents = 12
    /// 年代桶占比低于该值不生成意图（避免长尾噪声）。
    static let minimumDecadeShare = 0.2
    /// 每个年代 / 曲风最多取几个代表艺人。
    static let maxArtistsPerBucket = 2

    static func intents(from profile: TasteProfile) -> [RecommendationIntent] {
        var intents: [RecommendationIntent] = []
        var seenQueries = Set<String>()

        func append(_ intent: RecommendationIntent) {
            let key = intent.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, seenQueries.insert(key).inserted else { return }
            intents.append(intent)
        }

        for artist in profile.topArtists.prefix(maxArtistIntents) {
            let name = artist.artist.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            append(RecommendationIntent(query: name, kind: .artist, artist: name))
        }

        let decades = profile.decadeShare
            .filter { $0.value >= minimumDecadeShare }
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(maxDecadeIntents)

        for (decade, _) in decades {
            let artists = profile.decadeArtists[decade] ?? []
            for name in artists.prefix(maxArtistsPerBucket) {
                append(RecommendationIntent(query: name, kind: .decade, artist: name, decade: decade))
            }
        }

        for genre in profile.topGenres.prefix(maxGenreIntents) {
            let artists = profile.genreArtists[genre] ?? []
            for name in artists.prefix(maxArtistsPerBucket) {
                append(RecommendationIntent(query: name, kind: .genre, artist: name, genre: genre))
            }
        }

        return Array(intents.prefix(maxTotalIntents))
    }

    /// 召回前统一解析意图（纯函数）：纯年代标签（任何 kind）一律展开为画像里该年代的
    /// 代表艺人；画像没有该年代艺人就丢弃，**绝不**把 `1990s` 这类标签送进在线搜索。
    ///
    /// 计划层（本地模型）仍按 kind=decade + `1990s` 输出，解析只在消费端做，prompt 契约不变。
    static func resolved(_ intents: [RecommendationIntent], profile: TasteProfile) -> [RecommendationIntent] {
        var resolved: [RecommendationIntent] = []
        var seen = Set<String>()

        func append(_ intent: RecommendationIntent) {
            guard seen.insert(intent.priorityKey).inserted else { return }
            resolved.append(intent)
        }

        for intent in intents {
            // 相似召回只借 query 做标签、用歌曲 id 召回，不参与年代展开。
            guard intent.kind != .similar, let decade = RecommendationDecadeLabel.parse(intent.query) else {
                append(intent)
                continue
            }
            let artists = profile.decadeArtists[decade] ?? []
            for name in artists.prefix(maxArtistsPerBucket) {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                append(RecommendationIntent(query: trimmed, kind: .decade, artist: trimmed, decade: decade))
            }
        }
        return resolved
    }
}

// MARK: - 非单曲过滤

/// 准入闸的拒绝原因（P1 观测口径：每道闸的 in/out 与命中原因都要能计数）。
///
/// rawValue 进日志，**一经发布不得改动**（改 = 历史日志无法对照）。
enum RecommendationAdmissionRejection: String, CaseIterable, Sendable {
    /// 歌曲 ID 为空。**只计数不拒绝**（2026-11-12 口径更正）：
    /// 歌曲海源全量无 id、领域模型里 id 本就可选；它的用途是相似召回与去重，
    /// 不是「是不是单曲」的判据 → 只作为 flagged 计数进 summary。
    case missingSongID = "missing_song_id"
    /// 时长不在 30s…10min 窗口内（缺失不算）。
    case durationOutOfRange = "duration_out_of_range"
    /// 艺人是泛称（群星 / Various Artists / 未知 …）。
    case genericArtist = "generic_artist"
    /// 标题为空。
    case emptyTitle = "empty_title"
    /// 标题带歌单 / 合辑 / 串烧 / 榜单标记。
    case playlistMarker = "playlist_marker"
    /// 标题整串就是年代 / 年份标签。
    case decadeOnlyTitle = "decade_only_title"
    /// 标题与专辑名相同（榜单 / 合辑占位行）。
    case titleEqualsAlbum = "title_equals_album"
}

/// 歌单 / 合辑 / 串烧识别（搜索结果是网页索引，混进歌单是常态）。
///
/// 依据（按序判定，见 `admissionRejection(for:)`）：时长窗口 30s…10min + 艺人非泛称
/// + 标题非空/非标记/非纯年代 + 标题 ≠ 专辑名。歌曲 ID 缺失**不拒绝**，只在 gather 记 flagged。
/// 取值从「宁放过」收紧为「宁严」：可疑条目剔掉，宁可少推也不错推（设计定稿 §4）。
enum RecommendationCandidateFilter {
    static let playlistMarkers: [String] = [
        "歌单", "精选", "合辑", "合集", "串烧", "榜单", "排行", "循环",
        "playlist", "collection", "compilation", "greatest hits", "best of",
        "hits", "decade", "top 100", "top100", "100首", "medley", "non-stop", "nonstop",
        "dj mix", "megamix",
    ]

    static let genericArtists: Set<String> = [
        "群星", "various artists", "various", "va", "未知", "未知艺术家", "unknown", "unknown artist", "佚名",
    ]

    /// 单曲时长上限（毫秒）：超过 10 分钟基本是串烧 / 合辑。
    static let maxDurationMs = 10 * 60 * 1000

    /// 单曲时长下限（毫秒）：短于 30 秒基本是试听片段 / 提示音，不是完整单曲。
    static let minDurationMs = 30 * 1000

    /// **唯一对外入口**：候选是否需要被准入闸剔除。
    ///
    /// 内部改为条件式顺序判定，逐条给出可枚举原因（供观测打点计数），
    /// 但只允许从这里进闸——不允许再写第二个判断入口。
    static func isLikelyNonSong(_ song: RecommendationRemoteSong) -> Bool {
        admissionRejection(for: song) != nil
    }

    /// 顺序判定并返回**第一个**不满足的准入条件（nil = 通过）。
    ///
    /// 仅供打点计数与单测使用；生产判定入口仍是 `isLikelyNonSong`。
    /// 条件全部只能收紧：原有「泛称艺人 / 超长 / 纯年代 / 歌单标记 / 空标题」规则逐条保留。
    /// 注意：**歌曲 ID 缺失不是拒绝条件**（见 `RecommendationAdmissionRejection.missingSongID` 说明），
    /// 只在 gather 里记 flagged；「标题 / 艺人为空」由 fields 闸拒绝。
    static func admissionRejection(for song: RecommendationRemoteSong) -> RecommendationAdmissionRejection? {
        // 1. 时长窗口 30s ≤ 时长 ≤ 10min；时长缺失沿用既有语义（不拦）。
        if let duration = song.durationMs, duration < minDurationMs || duration > maxDurationMs {
            return .durationOutOfRange
        }

        // 2. 艺人非泛称（群星 / Various Artists / 未知 …）。
        let rawArtist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if genericArtists.contains(rawArtist) { return .genericArtist }
        let primary = RecommendationKey.primaryArtist(song.artist).lowercased()
        if genericArtists.contains(primary) { return .genericArtist }

        // 3. 标题非空、非歌单 / 合辑 / 串烧标记。
        let title = song.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !title.isEmpty else { return .emptyTitle }
        if playlistMarkers.contains(where: { title.contains($0) }) { return .playlistMarker }
        // 标题整串就是年代 / 年份（`1990s` / `2000s` / `90年代` / `1990`）：在线源会把年代
        // 标签当歌名返回，专辑字段往往也填成 `1990s`——与专辑是否为空无关，一律剔除。
        if isDecadeOnlyTitle(song.title) { return .decadeOnlyTitle }

        // 4. 标题 ≠ 专辑名（同串 = 榜单 / 合辑占位行；比较走归一化口径，不做字符串硬比）。
        if let album = song.album, !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let titleToken = RecommendationKey.comparisonToken(song.title)
            let albumToken = RecommendationKey.comparisonToken(album)
            if !titleToken.isEmpty, titleToken == albumToken { return .titleEqualsAlbum }
        }
        return nil
    }

    /// 标题整串是否为纯年代标签（判定口径见 `RecommendationDecadeLabel`，不误杀标题中段含年代的歌）。
    static func isDecadeOnlyTitle(_ title: String) -> Bool {
        RecommendationDecadeLabel.parse(title) != nil
    }
}
