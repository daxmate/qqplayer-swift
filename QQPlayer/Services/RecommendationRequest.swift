//
//  RecommendationRequest.swift
//  QQPlayer
//
//  本地 AI 推荐：指令输入（纯逻辑层，iOS / macOS 共享）。
//
//  - `RecommendationUserRequest`：模型解析出的结构化检索条件（单一契约）。
//  - `RecommendationRequestParser`：严格 JSON 解析 + 清洗（空 / 超长 / 重复 / 非法年代）。
//  - `RecommendationRequestHistory`：后台多轮上下文（只留最近 N 轮，界面不显示）。
//  - `RecommendationChatAvailability`：指令输入是否可用（模型未就绪必须禁用，禁止规则回退）。
//
//  ⚠️ 本文件只依赖 Foundation，不引入平台 API。
//

import Foundation

// MARK: - 用户请求

/// 指令输入解析结果：只描述「用户要什么」，不承担召回与打分。
struct RecommendationUserRequest: Sendable, Codable, Equatable {
    /// 「和五月天类似」里的五月天。
    var referenceArtists: [String]
    /// 关键词（歌名 / 专辑 / 具体主题）。
    var keywords: [String]
    /// 年代（十年起点，如 1990）。
    var decades: [Int]
    /// 语言提示（模型能识别就填，不保证召回使用）。
    var languages: [String]
    /// 情绪 / 氛围词。
    var moods: [String]
    /// 明确不想听的艺人。
    var excludeArtists: [String]
    /// 用户原话（不进模型 prompt 的 JSON，只用于展示 / 历史）。
    var rawText: String

    init(
        referenceArtists: [String] = [],
        keywords: [String] = [],
        decades: [Int] = [],
        languages: [String] = [],
        moods: [String] = [],
        excludeArtists: [String] = [],
        rawText: String = ""
    ) {
        self.referenceArtists = referenceArtists
        self.keywords = keywords
        self.decades = decades
        self.languages = languages
        self.moods = moods
        self.excludeArtists = excludeArtists
        self.rawText = rawText
    }

    /// 没有任何**正向**条件（只有排除项不算有效请求）。
    var isEmpty: Bool {
        referenceArtists.isEmpty
            && keywords.isEmpty
            && decades.isEmpty
            && languages.isEmpty
            && moods.isEmpty
    }
}

// MARK: - 规划器契约

/// 指令 → 结构化请求的生成器（只有本地模型实现；不允许规则回退）。
protocol RecommendationRequestPlanning: Sendable {
    func makeRequest(
        text: String,
        history: [RecommendationRequestHistoryEntry],
        profile: TasteProfile
    ) async -> Result<RecommendationUserRequest, RecommendationRequestError>
}

// MARK: - 错误

/// 指令解析 / 生成错误。UI 直接展示 `localizedDescription`。
enum RecommendationRequestError: Error, Equatable, LocalizedError {
    /// 模型未就绪（v3 起规则解析永远可用；该错误仅保留旧缓存 / 旧路径兼容）。
    case modelNotReady
    /// 模型输出不是可解析 JSON，或结构不符。
    case invalidOutput
    /// 模型没有给出任何有效条件（UI 提示「换个说法试试」）。
    case emptyRequest
    /// 生成超时。
    case timedOut

    var errorDescription: String? {
        switch self {
        case .modelNotReady: return "recommendation_chat_model_not_ready".localized
        case .invalidOutput: return "recommendation_chat_invalid_output".localized
        case .emptyRequest: return "recommendation_empty_request".localized
        case .timedOut: return "recommendation_chat_timeout".localized
        }
    }
}

// MARK: - 解析

/// 模型输出解析 + 校验（纯函数，不依赖网络 / 文件系统）。
enum RecommendationRequestParser {
    /// 单个数组最多保留几条。
    static let maxItems = 8
    /// 单个字段最大字符数（超出截断，不整条丢弃）。
    static let maxFieldLength = 64

    struct Payload: Decodable {
        var referenceArtists: [String]?
        var keywords: [String]?
        var decades: [DecadeValue]?
        var languages: [String]?
        var moods: [String]?
        var excludeArtists: [String]?
    }

    /// 模型可能给 `1990` 也可能给 `"1990s"`，两种都收。
    enum DecadeValue: Equatable {
        case number(Int)
        case text(String)
    }

    /// 解析模型输出；JSON 不可读 → `.invalidOutput`，清洗后为空 → `.emptyRequest`。
    static func parse(_ output: String, rawText: String) -> Result<RecommendationUserRequest, RecommendationRequestError> {
        guard let json = RecommendationPlanParser.extractJSON(from: output),
              let data = json.data(using: .utf8)
        else {
            AppLog.warn(.general, "⚠️ 推荐指令解析失败：未找到 JSON 片段")
            return .failure(.invalidOutput)
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            AppLog.warn(.general, "⚠️ 推荐指令解析失败：\(error.localizedDescription)")
            return .failure(.invalidOutput)
        }

        let request = normalize(payload, rawText: rawText)
        guard !request.isEmpty else { return .failure(.emptyRequest) }
        return .success(request)
    }

    /// 清洗：换行压成空格、超长截断、去重（大小写不敏感）、数组截到上限。
    static func normalize(_ payload: Payload, rawText: String) -> RecommendationUserRequest {
        RecommendationUserRequest(
            referenceArtists: cleaned(payload.referenceArtists),
            keywords: cleaned(payload.keywords),
            decades: cleanedDecades(payload.decades),
            languages: cleaned(payload.languages),
            moods: cleaned(payload.moods),
            excludeArtists: cleaned(payload.excludeArtists),
            rawText: rawText
        )
    }

    static func cleaned(_ values: [String]?) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values ?? [] {
            let text = singleLine(raw)
            guard !text.isEmpty else { continue }
            let clipped = String(text.prefix(maxFieldLength))
            guard seen.insert(clipped.lowercased()).inserted else { continue }
            result.append(clipped)
            if result.count >= maxItems { break }
        }
        return result
    }

    static func cleanedDecades(_ values: [DecadeValue]?) -> [Int] {
        var seen = Set<Int>()
        var result: [Int] = []
        for value in values ?? [] {
            guard let decade = decadeStart(of: value) else { continue }
            guard seen.insert(decade).inserted else { continue }
            result.append(decade)
            if result.count >= maxItems { break }
        }
        return result
    }

    /// 单个年代值 → 十年桶起点：文本走共享年代标签解析（`1990s` / `90年代` / `1990 年`
    /// 与结果过滤同一口径），数字走同一套区间校验，不再各写一套前缀截取。
    private static func decadeStart(of value: DecadeValue) -> Int? {
        switch value {
        case let .number(year):
            return RecommendationDecadeLabel.decadeStart(forYear: year)
        case let .text(raw):
            return RecommendationDecadeLabel.parse(raw)
        }
    }

    /// 单行化 + 压连续空白（prompt 与存储都禁止换行）。
    static func singleLine(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension RecommendationRequestParser.DecadeValue: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
            return
        }
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "decade must be an integer or a string"
        )
    }
}

// MARK: - 历史

/// 一轮指令交互：用户原话 + 该轮返回的前 5 条「歌名 - 艺人」。
struct RecommendationRequestHistoryEntry: Codable, Equatable, Sendable {
    var requestText: String
    var results: [String]
    var createdAt: Date?
}

/// 后台多轮上下文（界面不显示；只用于让模型理解追问）。
struct RecommendationRequestHistory: Codable, Equatable, Sendable {
    var entries: [RecommendationRequestHistoryEntry] = []

    static let empty = RecommendationRequestHistory()
    static let maxResultsPerEntry = 5

    /// 纯函数：只保留最近 `rounds` 轮（0 轮 = 清空）。
    func trimmed(to rounds: Int) -> RecommendationRequestHistory {
        let limit = max(0, rounds)
        guard entries.count > limit else { return self }
        return RecommendationRequestHistory(entries: Array(entries.suffix(limit)))
    }

    /// 追加一轮并按上限裁剪。
    mutating func append(_ entry: RecommendationRequestHistoryEntry, limit: Int) {
        entries.append(entry)
        self = trimmed(to: limit)
    }

    /// 结果摘要：最多 `limit` 条「歌名 - 主艺人」。
    static func results(
        from candidates: [RecommendedCandidate],
        limit: Int = maxResultsPerEntry
    ) -> [String] {
        candidates.prefix(max(0, limit)).map { candidate in
            let artist = RecommendationKey.displayPrimaryArtist(candidate.artist)
            return artist.isEmpty ? candidate.title : "\(candidate.title) - \(artist)"
        }
    }
}

/// 历史读写（文件不存在 / 损坏 = 空历史；写失败只记日志，不阻断推荐）。
enum RecommendationRequestHistoryStore {
    static let fileName = "recommendation-request-history.json"

    /// 默认落点：`<Application Support>/QQPlayerMac/recommendation-request-history.json`。
    static func defaultURL(fileManager: FileManager = .default) -> URL? {
        guard let root = LibraryRoot.macAppSupportRootURL(fileManager: fileManager) else { return nil }
        return root.appendingPathComponent(fileName)
    }

    /// 读取并按当前设置裁剪（旧文件轮数可能更大）。
    static func load(from url: URL?, limit: Int) -> RecommendationRequestHistory {
        guard let url, let data = try? Data(contentsOf: url) else { return .empty }
        let decoded = (try? JSONDecoder().decode(RecommendationRequestHistory.self, from: data)) ?? .empty
        return decoded.trimmed(to: limit)
    }

    static func save(_ history: RecommendationRequestHistory, to url: URL?, limit: Int) -> Bool {
        guard let url else { return false }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(history.trimmed(to: limit)).write(to: url, options: .atomic)
            return true
        } catch {
            AppLog.warn(.general, "⚠️ 推荐指令历史写入失败：\(error)")
            return false
        }
    }
}

// MARK: - 意图

/// 指令 → 召回意图（显式条件优先；年代复用曲库高权重艺人，不硬编码代表歌手）。
extension RecommendationIntentBuilder {
    static func intents(
        from request: RecommendationUserRequest,
        profile: TasteProfile
    ) -> [RecommendationIntent] {
        var intents: [RecommendationIntent] = []
        var seen = Set<String>()

        func append(_ intent: RecommendationIntent) {
            guard intents.count < maxTotalIntents else { return }
            guard seen.insert(intent.priorityKey).inserted else { return }
            intents.append(intent)
        }

        for artist in request.referenceArtists.prefix(maxArtistIntents) {
            append(RecommendationIntent(query: artist, kind: .artist, artist: artist))
        }

        // 点名艺人：画像派生的关键词 / 年代意图不再追加（否则点名会被画像稀释）；
        // 用户自己写进原话里的关键词 / 情绪词保留。
        let namedArtist = RecommendationArtistMix.isNamedArtistRequest(request)

        var keywordCount = 0
        for keyword in request.keywords + request.moods {
            guard keywordCount < Self.maxKeywordIntents else { break }
            guard !namedArtist || Self.isUserWritten(keyword, in: request.rawText) else { continue }
            keywordCount += 1
            append(RecommendationIntent(query: keyword, kind: .keyword))
        }

        guard !namedArtist else { return prioritized(intents, request: request) }

        for decade in request.decades.prefix(maxDecadeIntents) {
            let artists = profile.decadeArtists[decade] ?? []
            for name in artists.prefix(maxArtistsPerBucket) {
                append(RecommendationIntent(query: name, kind: .decade, artist: name, decade: decade))
            }
        }

        return prioritized(intents, request: request)
    }

    /// 关键词是否出自用户原话（点名场景只保留用户自己写的词，丢弃画像派生项）。
    static func isUserWritten(_ keyword: String, in rawText: String) -> Bool {
        let word = RecommendationKey.comparisonToken(keyword)
        guard !word.isEmpty else { return false }
        return RecommendationKey.comparisonToken(rawText).contains(word)
    }

    // MARK: 显式艺人优先

    /// 用户请求里被明确点名的艺人（referenceArtists + rawText 中原样出现的搜索词）。
    ///
    /// 只用于排序：不改变 intent 的 kind / query，也不参与打分。
    static func explicitArtistTokens(
        intents: [RecommendationIntent],
        request: RecommendationUserRequest
    ) -> Set<String> {
        var tokens = request.referenceArtists.map(RecommendationKey.comparisonToken)
        let text = RecommendationKey.comparisonToken(request.rawText)
        if !text.isEmpty {
            for intent in intents {
                for candidate in [intent.artist, intent.query].compactMap({ $0 }) {
                    let token = RecommendationKey.comparisonToken(candidate)
                    guard token.count >= 2, !genericRequestTerms.contains(token), text.contains(token) else { continue }
                    tokens.append(token)
                }
            }
        }
        return Set(tokens.filter { !$0.isEmpty })
    }

    /// 稳定重排：显式艺人对应的 intent 前置，其余保持原相对顺序。
    static func prioritized(
        _ intents: [RecommendationIntent],
        request: RecommendationUserRequest
    ) -> [RecommendationIntent] {
        let explicit = explicitArtistTokens(intents: intents, request: request)
        guard !explicit.isEmpty else { return intents }
        var head: [RecommendationIntent] = []
        var tail: [RecommendationIntent] = []
        for intent in intents {
            if isExplicit(intent, artists: explicit) {
                head.append(intent)
            } else {
                tail.append(intent)
            }
        }
        return head + tail
    }

    /// intent 是否指向用户点名的艺人：query / artist 命中，允许关键词短语包含艺人名。
    static func isExplicit(_ intent: RecommendationIntent, artists: Set<String>) -> Bool {
        [intent.artist, intent.query]
            .compactMap { $0 }
            .contains { RecommendationExplicitPriority.matches($0, artists: artists) }
    }

    /// rawText 匹配时不算「点名」的泛词（与 prompt 的 never generic words 同口径）。
    static let genericRequestTerms: Set<String> = [
        "music", "song", "songs", "hits", "pop", "rock", "classics",
        "歌曲", "歌", "音乐", "热歌", "金曲", "流行", "经典", "老歌", "情歌",
    ]

    /// 指令里的关键词 / 情绪词最多生成几条搜索意图（限制请求放大）。
    static let maxKeywordIntents = 4
}

// MARK: - 显式优先排序

/// 最终结果排序：用户点名的艺人优先于画像推断（稳定分区，不改分）。
enum RecommendationExplicitPriority {
    /// 把满足 isPriority 的元素整体前置，组内保持原有顺序。
    static func order<T>(_ items: [T], isPriority: (T) -> Bool) -> [T] {
        var head: [T] = []
        var tail: [T] = []
        for item in items {
            if isPriority(item) {
                head.append(item)
            } else {
                tail.append(item)
            }
        }
        return head + tail
    }

    /// 文本是否命中用户点名的艺人（允许关键词短语 / 候选艺人字段包含艺人名）。
    static func matches(_ value: String, artists: Set<String>) -> Bool {
        guard !artists.isEmpty else { return false }
        let token = RecommendationKey.comparisonToken(value)
        guard token.count >= 2 else { return false }
        return artists.contains { name in
            guard name.count >= 2 else { return false }
            return name == token || token.contains(name) || (token.count >= 3 && name.contains(token))
        }
    }
}
