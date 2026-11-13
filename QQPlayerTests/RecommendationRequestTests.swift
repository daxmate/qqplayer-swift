//
//  RecommendationRequestTests.swift
//  QQPlayerTests
//
//  本地 AI 推荐：指令输入纯逻辑单测（解析 / 历史裁剪 / 设置 clamp / 引擎召回 / 可用性）。
//
//  只测共享层：模型推理不在单测范围（v3 起已无本地模型）。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 桩

private struct KeywordProvider: OnlineSearchProviding {
    let source: RecommendationSource
    var songs: [String: [RecommendationRemoteSong]] = [:]

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        Array((songs[query] ?? []).prefix(limit))
    }
}

private struct SimilarProvider: OnlineSearchProviding, SimilarSongProviding, ArtistAliasProviding {
    let source: RecommendationSource
    var songs: [String: [RecommendationRemoteSong]] = [:]
    var similar: [Int: [RecommendationRemoteSong]] = [:]
    var aliasesByArtist: [String: [String]] = [:]

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        Array((songs[query] ?? []).prefix(limit))
    }

    func similarSongs(songID: Int, limit: Int) async throws -> [RecommendationRemoteSong] {
        Array((similar[songID] ?? []).prefix(limit))
    }

    func aliases(for artist: String) async -> [String] {
        aliasesByArtist[artist] ?? []
    }
}

/// 带别名能力的桩：点名艺人约束测试用（不联网）。
private struct ArtistAliasProvider: OnlineSearchProviding, ArtistAliasProviding {
    let source: RecommendationSource
    var songs: [String: [RecommendationRemoteSong]] = [:]
    var aliasesByArtist: [String: [String]] = [:]

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        Array((songs[query] ?? []).prefix(limit))
    }

    func aliases(for artist: String) async -> [String] {
        aliasesByArtist[artist] ?? []
    }
}

private func remote(
    _ title: String,
    _ artist: String,
    songID: Int? = nil,
    year: Int? = nil
) -> RecommendationRemoteSong {
    RecommendationRemoteSong(title: title, artist: artist, year: year, songID: songID)
}

private func request(
    artists: [String] = [],
    keywords: [String] = [],
    decades: [Int] = [],
    languages: [String] = [],
    moods: [String] = [],
    excludes: [String] = [],
    rawText: String = ""
) -> RecommendationUserRequest {
    RecommendationUserRequest(
        referenceArtists: artists,
        keywords: keywords,
        decades: decades,
        languages: languages,
        moods: moods,
        excludeArtists: excludes,
        rawText: rawText
    )
}

// MARK: - 解析

@Suite("推荐指令：JSON 解析")
struct RecommendationRequestParserTests {
    @Test("正常解析：字段齐全、年代取整、rawText 保留")
    func parsesValidPayload() throws {
        let output = """
        {"referenceArtists":["五月天"],"keywords":["青春"],"decades":[1997],
         "languages":["Chinese"],"moods":["热血"],"excludeArtists":["告五人"]}
        """
        let parsed = try RecommendationRequestParser.parse(output, rawText: "推荐和五月天类似的").get()
        #expect(parsed.referenceArtists == ["五月天"])
        #expect(parsed.keywords == ["青春"])
        #expect(parsed.decades == [1990])
        #expect(parsed.languages == ["Chinese"])
        #expect(parsed.moods == ["热血"])
        #expect(parsed.excludeArtists == ["告五人"])
        #expect(parsed.rawText == "推荐和五月天类似的")
    }

    @Test("字符串年代：\"1990s\" 按十年取整")
    func parsesStringDecade() throws {
        let parsed = try RecommendationRequestParser.parse(
            #"{"referenceArtists":[],"decades":["1990s"]}"#,
            rawText: "90 年代"
        ).get()
        #expect(parsed.decades == [1990])
    }

    @Test("空条件：没有任何正向条件 → emptyRequest")
    func rejectsEmptyRequest() {
        let result = RecommendationRequestParser.parse(
            #"{"referenceArtists":[],"keywords":[],"decades":[],"languages":[],"moods":[],"excludeArtists":["A"]}"#,
            rawText: "别放 A"
        )
        #expect(result == .failure(.emptyRequest))
    }

    @Test("超长字段截断到 64 字符、数组最多 8 条")
    func trimsLongFieldsAndArrays() throws {
        let long = String(repeating: "a", count: 100)
        let many = (1 ... 12).map { "k\($0)" }
        let output = "{\"referenceArtists\":[\"\(long)\"],\"keywords\":[\(many.map { "\"\($0)\"" }.joined(separator: ","))]}"
        let parsed = try RecommendationRequestParser.parse(output, rawText: "x").get()
        #expect(parsed.referenceArtists.first?.count == 64)
        #expect(parsed.keywords.count == 8)
        #expect(parsed.keywords == ["k1", "k2", "k3", "k4", "k5", "k6", "k7", "k8"])
    }

    @Test("重复项去重（忽略大小写与多余空白）")
    func deduplicatesItems() throws {
        let output = #"{"referenceArtists":["五月天"," 五月天 ","MAYDAY","mayday"]}"#
        let parsed = try RecommendationRequestParser.parse(output, rawText: "x").get()
        #expect(parsed.referenceArtists == ["五月天", "MAYDAY"])
    }

    @Test("非法年代丢弃（1800 / 2050），合法值保留")
    func dropsInvalidDecades() throws {
        let parsed = try RecommendationRequestParser.parse(
            #"{"referenceArtists":[],"decades":[1800,2050,1989]}"#,
            rawText: "x"
        ).get()
        #expect(parsed.decades == [1980])
    }

    @Test("截断 JSON → invalidOutput（不静默吞掉）")
    func rejectsTruncatedJSON() {
        let result = RecommendationRequestParser.parse(
            #"{"referenceArtists":["五月天""#,
            rawText: "x"
        )
        #expect(result == .failure(.invalidOutput))
    }
}

// MARK: - 历史

@Suite("推荐指令：后台历史")
struct RecommendationRequestHistoryTests {
    private func entries(_ count: Int) -> [RecommendationRequestHistoryEntry] {
        (1 ... count).map { index in
            RecommendationRequestHistoryEntry(
                requestText: "请求 \(index)",
                results: ["歌 \(index) - 艺人"],
                createdAt: nil
            )
        }
    }

    @Test("裁剪：N = 0 / 3 / 9")
    func trimsToRounds() {
        let history = RecommendationRequestHistory(entries: entries(12))
        #expect(history.trimmed(to: 0).entries.isEmpty)
        #expect(history.trimmed(to: 3).entries.map(\.requestText) == ["请求 10", "请求 11", "请求 12"])
        #expect(history.trimmed(to: 9).entries.count == 9)
    }

    @Test("追加即裁剪：超出上限只留最近 N 轮")
    func appendTrims() {
        var history = RecommendationRequestHistory(entries: entries(3))
        history.append(
            RecommendationRequestHistoryEntry(requestText: "新请求", results: [], createdAt: nil),
            limit: 3
        )
        #expect(history.entries.map(\.requestText) == ["请求 2", "请求 3", "新请求"])
    }

    @Test("写入 / 读取按当前上限裁剪（跨轮读写）")
    func storeRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("recommendation-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var history = RecommendationRequestHistory(entries: entries(5))
        #expect(RecommendationRequestHistoryStore.save(history, to: url, limit: 5))
        #expect(RecommendationRequestHistoryStore.load(from: url, limit: 2).entries.count == 2)

        history.append(
            RecommendationRequestHistoryEntry(requestText: "再来一首", results: ["A - B"], createdAt: nil),
            limit: 5
        )
        #expect(RecommendationRequestHistoryStore.save(history, to: url, limit: 5))
        let reloaded = RecommendationRequestHistoryStore.load(from: url, limit: 5)
        #expect(reloaded.entries.last?.requestText == "再来一首")
    }

    @Test("结果摘要：最多 5 条「歌名 - 主艺人」")
    func resultSummary() {
        let candidates = (1 ... 7).map { index in
            RecommendedCandidate(
                title: "歌 \(index)",
                artist: "艺人 A feat. 艺人 B",
                album: nil,
                year: nil,
                source: .netease
            )
        }
        let summary = RecommendationRequestHistory.results(from: candidates)
        #expect(summary.count == 5)
        #expect(summary.first == "歌 1 - 艺人 A")
    }
}

// MARK: - 设置

@Suite("推荐指令：设置 clamp")
struct RecommendationChatRoundsSettingTests {
    @Test("轮数 clamp：-1 / 0 / 3 / 10")
    func clampsRounds() {
        #expect(DeleteSettings.clampRecommendationChatRounds(-1) == 0)
        #expect(DeleteSettings.clampRecommendationChatRounds(0) == 0)
        #expect(DeleteSettings.clampRecommendationChatRounds(3) == 3)
        #expect(DeleteSettings.clampRecommendationChatRounds(10) == 9)
        #expect(DeleteSettings.defaultRecommendationChatRounds == 3)
    }
}

// MARK: - 引擎

@Suite("推荐指令：引擎召回")
struct RecommendationRequestEngineTests {
    @Test("关键词路径：在线搜索命中的歌进入结果")
    func keywordPath() async {
        let provider = KeywordProvider(
            source: .netease,
            songs: ["city pop": [remote("Plastic Love", "Mariya Takeuchi")]]
        )
        let engine = RecommendationEngine(providers: [provider])
        let result = await engine.recommend(
            request: request(keywords: ["city pop"]),
            profile: TasteProfile(),
            count: 10
        )
        switch result {
        case let .success(list):
            #expect(list.map(\.title) == ["Plastic Love"])
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("纯点名请求：同艺人相似照常追加，异艺人相似被剔除")
    func similarArtistPathUnderExplicitName() async {
        let provider = makeSimilarProvider()
        let engine = RecommendationEngine(providers: [provider])
        let result = await engine.recommend(
            request: request(artists: ["五月天"], rawText: "给我推荐一些五月天的歌"),
            profile: TasteProfile(),
            count: 10
        )
        switch result {
        case let .success(list):
            #expect(list.map(\.title) == ["倔强", "温柔"])
            #expect(!list.contains { $0.artist == "八三夭" })
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("类似语义：不建硬约束，异艺人相似结果保留")
    func similarRequestKeepsOtherArtists() async {
        let provider = makeSimilarProvider()
        let engine = RecommendationEngine(providers: [provider])
        let result = await engine.recommend(
            request: request(artists: ["五月天"], rawText: "推荐和五月天类似的歌"),
            profile: TasteProfile(),
            count: 10
        )
        switch result {
        case let .success(list):
            #expect(list.count == 3)
            #expect(list.contains { $0.title == "想见你想见你想见你" && $0.artist == "八三夭" })
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    private func makeSimilarProvider() -> SimilarProvider {
        SimilarProvider(
            source: .netease,
            songs: ["五月天": [remote("倔强", "五月天", songID: 42)]],
            similar: [42: [
                remote("温柔", "五月天"),
                remote("想见你想见你想见你", "八三夭"),
            ]],
            aliasesByArtist: ["五月天": ["五月天", "Mayday"]]
        )
    }

    @Test("排除艺人：excludeArtists 命中的候选被剔除")
    func excludesArtist() async {
        let provider = KeywordProvider(
            source: .netease,
            songs: ["A": [remote("A 的歌", "A"), remote("B 的歌", "B")]]
        )
        let engine = RecommendationEngine(providers: [provider])
        let result = await engine.recommend(
            request: request(artists: ["A"], excludes: ["A"]),
            profile: TasteProfile(),
            count: 10
        )
        switch result {
        case let .success(list):
            #expect(list.map(\.artist) == ["B"])
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("空条件：直接返回 emptyRequest，不退回画像推荐")
    func emptyRequestFails() async {
        let provider = KeywordProvider(
            source: .netease,
            songs: ["五月天": [remote("倔强", "五月天")]]
        )
        let engine = RecommendationEngine(providers: [provider])
        let result = await engine.recommend(
            request: request(excludes: ["A"]),
            profile: TasteProfile(),
            count: 10
        )
        #expect(result == .failure(.emptyRequest))
    }

    @Test("年代条件：复用曲库该年代高权重艺人")
    func decadePath() async {
        var profile = TasteProfile()
        profile.decadeArtists = [1990: ["王菲"]]
        let provider = KeywordProvider(
            source: .netease,
            songs: ["王菲": [remote("红豆", "王菲", year: 1998)]]
        )
        let engine = RecommendationEngine(providers: [provider])
        let result = await engine.recommend(
            request: request(decades: [1990]),
            profile: profile,
            count: 10
        )
        switch result {
        case let .success(list):
            #expect(list.map(\.title) == ["红豆"])
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }
}

@Suite("推荐指令：显式艺人优先")
struct RecommendationIntentPriorityTests {
    @Test("referenceArtists 对应的 artist intent 前置，其余保持相对顺序")
    func promotesReferenceArtist() {
        let intents = [
            RecommendationIntent(query: "华语流行", kind: .genre, genre: "华语流行"),
            RecommendationIntent(query: "City Pop", kind: .keyword),
            RecommendationIntent(query: "Westlife", kind: .artist, artist: "Westlife"),
        ]
        let ordered = RecommendationIntentBuilder.prioritized(
            intents,
            request: request(artists: ["Westlife"])
        )
        #expect(ordered.map(\.query) == ["Westlife", "华语流行", "City Pop"])
    }

    @Test("模型只给 keywords 时，按 rawText 点名前置")
    func promotesRawTextMention() {
        let intents = [
            RecommendationIntent(query: "华语流行", kind: .genre, genre: "华语流行"),
            RecommendationIntent(query: "西城男孩", kind: .keyword),
        ]
        let ordered = RecommendationIntentBuilder.prioritized(
            intents,
            request: request(rawText: "我想听一些西城男孩的歌曲")
        )
        #expect(ordered.map(\.query) == ["西城男孩", "华语流行"])
    }

    @Test("泛词不算点名：顺序不变")
    func ignoresGenericTerms() {
        let intents = [
            RecommendationIntent(query: "华语流行", kind: .genre, genre: "华语流行"),
            RecommendationIntent(query: "歌曲", kind: .keyword),
        ]
        let ordered = RecommendationIntentBuilder.prioritized(
            intents,
            request: request(rawText: "我想听一些歌曲")
        )
        #expect(ordered.map(\.query) == ["华语流行", "歌曲"])
    }

    @Test("无显式艺人时顺序原样返回（回归）")
    func keepsOrderWithoutExplicitArtist() {
        let intents = [
            RecommendationIntent(query: "华语流行", kind: .genre, genre: "华语流行"),
            RecommendationIntent(query: "City Pop", kind: .keyword),
        ]
        let ordered = RecommendationIntentBuilder.prioritized(intents, request: request())
        #expect(ordered.map(\.query) == ["华语流行", "City Pop"])
    }
}

@Suite("推荐引擎：显式艺人结果前置")
struct RecommendationExplicitArtistOrderTests {
    @Test("画像亲和更高时，点名艺人仍排在最前")
    func explicitArtistFirstDespiteProfileAffinity() async {
        let provider = ArtistAliasProvider(
            source: .netease,
            songs: [
                "华语流行": [remote("十年", "陈奕迅"), remote("浮夸", "陈奕迅")],
                "西城男孩": [remote("My Love", "Westlife"), remote("You Raise Me Up", "Westlife")],
            ],
            aliasesByArtist: ["西城男孩": ["Westlife"]]
        )
        var engine = RecommendationEngine(providers: [provider])
        engine.maxSourceShare = 1
        var profile = TasteProfile()
        profile.topArtists = [ArtistWeight(artist: "陈奕迅", weight: 1)]

        let result = await engine.recommend(
            request: request(
                artists: ["西城男孩"],
                keywords: ["华语流行"],
                rawText: "我想听一些西城男孩的歌曲"
            ),
            profile: profile,
            count: 6
        )
        switch result {
        case let .success(list):
            // 点名艺人 = 硬约束：画像项（陈奕迅）不再补足。
            #expect(list.map(\.artist) == ["Westlife", "Westlife"])
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }
}

// MARK: - 点名艺人硬约束

@Suite("推荐指令：点名艺人硬约束")
struct RecommendationArtistConstraintTests {
    @Test("点名艺人：只出该艺人（含别名），标题命中的其他艺人被剔除")
    func onlyNamedArtist() async {
        let provider = ArtistAliasProvider(
            source: .netease,
            songs: [
                "西城男孩": [
                    remote("My Love", "Westlife"),
                    remote("You Raise Me Up", "Westlife"),
                    remote("此情永不移", "鲸鱼向海_Joy声声"),
                    remote("季候风", "王菲"),
                ],
            ],
            aliasesByArtist: ["西城男孩": ["Westlife", "西城男孩"]]
        )
        let engine = RecommendationEngine(providers: [provider])
        let result = await engine.recommend(
            request: request(artists: ["西城男孩"], rawText: "给我推荐一些西城男孩的歌曲。"),
            profile: TasteProfile(),
            count: 10
        )
        switch result {
        case let .success(list):
            #expect(list.map(\.artist) == ["Westlife", "Westlife"])
            #expect(!list.contains { $0.artist.contains("王菲") })
            #expect(!list.contains { $0.artist.contains("鲸鱼向海") })
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("别名双向：点名英文名也能匹配中文名结果")
    func aliasBothWays() async {
        let provider = ArtistAliasProvider(
            source: .netease,
            songs: ["Westlife": [remote("My Love", "西城男孩")]],
            aliasesByArtist: ["Westlife": ["西城男孩", "Westlife"]]
        )
        let engine = RecommendationEngine(providers: [provider])
        let result = await engine.recommend(
            request: request(artists: ["Westlife"]),
            profile: TasteProfile(),
            count: 5
        )
        switch result {
        case let .success(list):
            #expect(list.map(\.title) == ["My Love"])
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("不足不补足：命中 N 首就返回 N 首，绝不用画像项凑数")
    func noBackfill() async {
        let provider = ArtistAliasProvider(
            source: .netease,
            songs: [
                "西城男孩": [
                    remote("A", "Westlife"),
                    remote("B", "Westlife"),
                    remote("C", "Westlife"),
                    remote("十年", "陈奕迅"),
                    remote("浮夸", "陈奕迅"),
                    remote("处处吻", "杨千嬅"),
                ],
            ],
            aliasesByArtist: ["西城男孩": ["Westlife"]]
        )
        var engine = RecommendationEngine(providers: [provider])
        engine.maxSongsPerArtist = 10
        let result = await engine.recommend(
            request: request(artists: ["西城男孩"]),
            profile: TasteProfile(),
            count: 10
        )
        switch result {
        case let .success(list):
            #expect(list.count == 3)
            #expect(list.allSatisfy { $0.artist == "Westlife" })
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("全半角 / 空白归一后仍匹配点名艺人")
    func normalizedArtistMatch() async {
        let provider = ArtistAliasProvider(
            source: .netease,
            songs: ["西城男孩": [remote("My Love", "ｗｅｓｔ  ｌｉｆｅ")]],
            aliasesByArtist: ["西城男孩": ["Westlife"]]
        )
        let engine = RecommendationEngine(providers: [provider])
        let result = await engine.recommend(
            request: request(artists: ["西城男孩"]),
            profile: TasteProfile(),
            count: 5
        )
        switch result {
        case let .success(list):
            #expect(list.map(\.title) == ["My Love"])
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("理由文案：点名艺人不说「常听 X」")
    func requestedArtistReason() async {
        let provider = ArtistAliasProvider(
            source: .netease,
            songs: ["西城男孩": [remote("My Love", "Westlife"), remote("Seasons in the Sun", "Westlife")]],
            aliasesByArtist: ["西城男孩": ["Westlife"]]
        )
        let engine = RecommendationEngine(providers: [provider])
        let result = await engine.recommend(
            request: request(artists: ["西城男孩"]),
            profile: TasteProfile(),
            count: 5
        )
        switch result {
        case let .success(list):
            let expected = "recommendation_reason_requested_artist".localized
            #expect(list.allSatisfy { $0.reasons.first == expected })
            #expect(!list.contains { $0.reasons.contains { $0.contains("常听") } })
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("无点名艺人时行为不变：关键词结果里不同艺人都保留")
    func unchangedWithoutExplicitArtist() async {
        let provider = KeywordProvider(
            source: .netease,
            songs: ["city pop": [remote("Plastic Love", "Mariya Takeuchi"), remote("Ride On Time", "Tatsuro Yamashita")]]
        )
        let engine = RecommendationEngine(providers: [provider])
        let result = await engine.recommend(
            request: request(keywords: ["city pop"]),
            profile: TasteProfile(),
            count: 10
        )
        switch result {
        case let .success(list):
            #expect(list.count == 2)
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("别名解析器：只收名称/别名与点名相等的艺人，忽略无关搜索结果")
    func aliasResolverFiltersUnrelated() {
        let candidates = [
            RecommendationArtistAliasResolver.Candidate(name: "西城男孩", aliases: ["Westlife"]),
            RecommendationArtistAliasResolver.Candidate(name: "Westlife", aliases: ["西城男孩"]),
            RecommendationArtistAliasResolver.Candidate(name: "西城秀樹", aliases: []),
        ]
        let aliases = RecommendationArtistAliasResolver.aliases(for: "西城男孩", from: candidates)
        #expect(Set(aliases) == Set(["西城男孩", "Westlife"]))
    }

    @Test("别名解析失败/为空：放弃硬约束，回退旧行为（不静默出 0 条）")
    func aliasFailureDisablesConstraint() async {
        let provider = ArtistAliasProvider(
            source: .netease,
            songs: ["西城男孩": [
                remote("My Love", "Westlife"),
                remote("十年", "陈奕迅"),
            ]]
            // aliasesByArtist 为空 = 在线别名解析失败/无结果
        )
        let engine = RecommendationEngine(providers: [provider])
        let result = await engine.recommend(
            request: request(artists: ["西城男孩"], rawText: "给我推荐一些西城男孩的歌曲。"),
            profile: TasteProfile(),
            count: 10
        )
        switch result {
        case let .success(list):
            #expect(list.count == 2)
            #expect(Set(list.map(\.artist)) == Set(["Westlife", "陈奕迅"]))
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("相似语义识别：命中关键词才视为相似请求")
    func similaritySemantics() {
        #expect(RecommendationArtistRequestSemantics.isSimilarityRequest("推荐和五月天类似的歌"))
        #expect(RecommendationArtistRequestSemantics.isSimilarityRequest("来点像周杰伦的歌"))
        #expect(RecommendationArtistRequestSemantics.isSimilarityRequest("风格接近五月天"))
        #expect(!RecommendationArtistRequestSemantics.isSimilarityRequest("给我推荐一些西城男孩的歌曲。"))
        #expect(!RecommendationArtistRequestSemantics.isSimilarityRequest(""))
    }
}
