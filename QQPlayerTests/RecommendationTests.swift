//
//  RecommendationTests.swift
//  QQPlayerTests
//
//  本地 AI 推荐 P1 纯逻辑单测：归一化 / 去重 / 打分 / 画像 / 引擎守卫。
//
//  只测共享层（`QQPlayer/Services/Recommendation*.swift`）——iOS 单测 target 编不到
//  `QQPlayer/Mac/**`，视图层由真机验收。
//  守卫自证：同一批用例在「去掉同艺人上限 / 去掉黑名单过滤 / 去掉库内过滤」的注入下会变红。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 夹具

private struct MockProvider: OnlineSearchProviding {
    let source: RecommendationSource
    /// 查询词 → 返回歌曲（未命中的查询返回空）。
    var songs: [String: [RecommendationRemoteSong]] = [:]
    var fails = false

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        if fails { throw MockError.offline }
        return Array((songs[query] ?? []).prefix(limit))
    }

    enum MockError: Error { case offline }
}

private func makeProfile(
    artists: [(String, Double)] = [],
    library: [String] = [],
    played: [String] = [],
    blacklistTracks: [String] = [],
    blacklistArtists: [String] = [],
    decades: [Int: Double] = [:],
    drift: [String: Double] = [:]
) -> TasteProfile {
    var profile = TasteProfile()
    profile.topArtists = artists.map { ArtistWeight(artist: $0.0, weight: $0.1) }
    profile.libraryKeys = Set(library)
    profile.playedKeys = Set(played)
    profile.blacklistTracks = Set(blacklistTracks)
    profile.blacklistArtists = Set(blacklistArtists)
    profile.decadeShare = decades
    profile.recentArtistDrift = drift
    return profile
}

private func remote(_ title: String, _ artist: String, album: String? = nil, year: Int? = nil) -> RecommendationRemoteSong {
    RecommendationRemoteSong(title: title, artist: artist, album: album, year: year)
}

// MARK: - 归一化

@Suite("推荐归一化")
struct RecommendationNormalizationTests {
    @Test("括号 / feat / 版本后缀 / 全角")
    func normalizeTitleVariants() {
        #expect(RecommendationKey.normalizeTitle("晴天（Live）") == "晴天")
        #expect(RecommendationKey.normalizeTitle("Song (Live)") == "song")
        #expect(RecommendationKey.normalizeTitle("Song [Remix]") == "song")
        #expect(RecommendationKey.normalizeTitle("Song feat. X") == "song")
        #expect(RecommendationKey.normalizeTitle("Song ft. Y") == "song")
        #expect(RecommendationKey.normalizeTitle("Song - Remastered 2011") == "song")
        #expect(RecommendationKey.normalizeTitle("Song - 中文版") == "song")
        #expect(RecommendationKey.normalizeTitle("Ｓｏｎｇ　（Ｌｉｖｅ）") == "song")
    }

    @Test("多艺人取主艺人 + 大小写归并")
    func primaryArtistVariants() {
        #expect(RecommendationKey.primaryArtist("A/B & C") == "a")
        #expect(RecommendationKey.primaryArtist("周杰伦、方文山") == "周杰伦")
        #expect(RecommendationKey.primaryArtist("A feat. B") == "a")
        #expect(RecommendationKey.primaryArtist("  The  Band  ") == "the band")
        #expect(RecommendationKey.displayPrimaryArtist("周杰伦、方文山") == "周杰伦")
    }

    @Test("单曲键：同曲不同写法必须相等")
    func normalizeKeyEquality() {
        let key = RecommendationKey.normalize(title: "Song (Live)", artist: "A feat. B")
        #expect(key == RecommendationKey.normalize(title: "Song - Remastered", artist: "A"))
        #expect(key == "song|a")
    }
}

// MARK: - 打分

@Suite("推荐打分与守卫")
struct RecommendationScoringTests {
    @Test("同艺人优先级：权重高的艺人分数更高")
    func artistAffinityOrdering() {
        let profile = makeProfile(artists: [("a", 10), ("b", 1)])
        let a = RecommendationScorer.score(
            RecommendationScoreInput(artist: "A", source: .netease), profile: profile
        )
        let b = RecommendationScorer.score(
            RecommendationScoreInput(artist: "B", source: .netease), profile: profile
        )
        #expect(a.total > b.total)
        #expect(a.artistAffinity > b.artistAffinity)
    }

    @Test("源可靠度：网易云 > 歌曲海")
    func sourceReliabilityOrdering() {
        let profile = makeProfile(artists: [("a", 1)])
        let netease = RecommendationScorer.score(
            RecommendationScoreInput(artist: "A", source: .netease), profile: profile
        )
        let gequhai = RecommendationScorer.score(
            RecommendationScoreInput(artist: "A", source: .gequhai), profile: profile
        )
        #expect(netease.total > gequhai.total)
    }

    @Test("年代：无年份给中性 0.5，命中年代桶加分")
    func eraScoring() {
        let profile = makeProfile(artists: [("a", 1)], decades: [1990: 0.8, 2000: 0.2])
        let noYear = RecommendationScorer.score(
            RecommendationScoreInput(artist: "Z", source: .netease), profile: profile
        )
        #expect(noYear.eraMatch == RecommendationWeights.neutral)
        let hit = RecommendationScorer.score(
            RecommendationScoreInput(artist: "Z", year: 1995, source: .netease), profile: profile
        )
        let miss = RecommendationScorer.score(
            RecommendationScoreInput(artist: "Z", year: 2015, source: .netease), profile: profile
        )
        #expect(hit.eraMatch == 1.0)
        #expect(miss.eraMatch == 0)
    }

    @Test("同艺人上限 2 首（engine）")
    func artistCap() async {
        let songs = (1 ... 4).map { remote("Song \($0)", "A") } + [remote("Other", "B")]
        let engine = RecommendationEngine(providers: [MockProvider(source: .netease, songs: ["a": songs])])
        let profile = makeProfile(artists: [("a", 10), ("b", 5)])
        let result = await engine.recommend(profile: profile, count: 10)
        guard case let .success(candidates) = result else {
            Issue.record("引擎应成功返回")
            return
        }
        let byA = candidates.filter { RecommendationKey.primaryArtist($0.artist) == "a" }
        #expect(byA.count == 2)
        #expect(candidates.contains { $0.title == "Other" })
    }

    @Test("黑名单：单曲与艺人直接剔除（engine）")
    func blacklistFiltering() async {
        let songs = [remote("Keep", "A"), remote("Blocked", "A"), remote("Solo", "B")]
        let engine = RecommendationEngine(providers: [MockProvider(source: .netease, songs: ["a": songs])])
        let blockedKey = RecommendationKey.normalize(title: "Blocked", artist: "A")
        let profile = makeProfile(
            artists: [("a", 10)],
            blacklistTracks: [blockedKey],
            blacklistArtists: ["b"]
        )
        let result = await engine.recommend(profile: profile, count: 10)
        guard case let .success(candidates) = result else {
            Issue.record("引擎应成功返回")
            return
        }
        #expect(candidates.map(\.title).sorted() == ["Keep"])
    }

    @Test("库内去重：同曲不同写法不进推荐（engine）")
    func libraryDeduplication() async {
        let songs = [remote("Song", "A"), remote("Fresh", "A")]
        let engine = RecommendationEngine(providers: [MockProvider(source: .netease, songs: ["a": songs])])
        let libraryKey = RecommendationKey.normalize(title: "Song (Live)", artist: "A feat. B")
        let profile = makeProfile(artists: [("a", 10)], library: [libraryKey])
        let result = await engine.recommend(profile: profile, count: 10)
        guard case let .success(candidates) = result else {
            Issue.record("引擎应成功返回")
            return
        }
        #expect(candidates.map(\.title) == ["Fresh"])
    }

    @Test("单源失败不影响另一源；全失败报错")
    func failureSemantics() async {
        let ok = MockProvider(source: .netease, songs: ["a": [remote("Song", "A")]])
        let bad = MockProvider(source: .gequhai, fails: true)
        let profile = makeProfile(artists: [("a", 10)])

        let mixed = await RecommendationEngine(providers: [ok, bad]).recommend(profile: profile, count: 10)
        guard case let .success(candidates) = mixed else {
            Issue.record("单源失败不应整体失败")
            return
        }
        #expect(candidates.count == 1)

        let allBad = await RecommendationEngine(providers: [bad]).recommend(profile: profile, count: 10)
        #expect(allBad == .failure(.allSourcesFailed))
    }
}

// MARK: - 画像

@Suite("推荐画像")
struct RecommendationProfileTests {
    @Test("半衰期衰减：近期播放权重更高")
    func halfLifeMonotonic() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let input = RecommendationProfileInput(
            plays: [
                .init(trackStableId: "recent", playedAt: now.addingTimeInterval(-86400), playDurationMs: 200_000),
                .init(trackStableId: "old", playedAt: now.addingTimeInterval(-60 * 86400), playDurationMs: 200_000),
            ],
            tracks: [
                .init(stableId: "recent", title: "R", artist: "Recent", album: nil, year: nil, durationMs: 200_000, genre: "Pop"),
                .init(stableId: "old", title: "O", artist: "Old", album: nil, year: nil, durationMs: 200_000, genre: "Pop"),
            ],
            now: now
        )
        let profile = RecommendationProfileBuilder.build(input)
        #expect(profile.weight(forArtist: "recent") > profile.weight(forArtist: "old"))
        #expect(profile.topArtists.first?.artist == "recent")
    }

    @Test("完成率只统计 duration > 15s 且有进度的记录")
    func completionRateFiltering() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let input = RecommendationProfileInput(
            plays: [
                // 10s 曲目：不算完成率
                .init(trackStableId: "short", playedAt: now, playDurationMs: 10_000),
                // 200s 曲目听到 100s → 0.5
                .init(trackStableId: "long", playedAt: now, playDurationMs: 100_000),
                // 有进度但为 0 → 不算
                .init(trackStableId: "zero", playedAt: now, playDurationMs: 0),
            ],
            tracks: [
                .init(stableId: "short", title: "S", artist: "A", album: nil, year: nil, durationMs: 10_000, genre: nil),
                .init(stableId: "long", title: "L", artist: "A", album: nil, year: nil, durationMs: 200_000, genre: nil),
                .init(stableId: "zero", title: "Z", artist: "A", album: nil, year: nil, durationMs: 200_000, genre: nil),
            ],
            now: now
        )
        let profile = RecommendationProfileBuilder.build(input)
        #expect(abs(profile.completionRate - 0.5) < 0.0001)
    }

    @Test("空数据不崩、年代不编造、脏 genre 被过滤")
    func emptyInput() {
        let profile = RecommendationProfileBuilder.build(RecommendationProfileInput())
        #expect(profile.topArtists.isEmpty)
        #expect(profile.decadeShare.isEmpty)
        #expect(profile.completionRate == 0)
        #expect(profile.topGenres.isEmpty)

        #expect(RecommendationProfileBuilder.cleanedGenre("http://example.com/x") == nil)
        #expect(RecommendationProfileBuilder.cleanedGenre("a/very/long/genre/value/exceeding") == nil)
        #expect(RecommendationProfileBuilder.cleanedGenre("Jazz") == "Jazz")
    }

    @Test("黑名单 JSON 往返（排序输出，跨写法命中）")
    func blacklistRoundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("recommendation-blacklist-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var blacklist = RecommendationBlacklist()
        blacklist.add(title: "Song (Live)", artist: "A feat. B")
        #expect(RecommendationBlacklistStore.save(blacklist, to: url))
        let loaded = RecommendationBlacklistStore.load(from: url)
        #expect(loaded == blacklist)
        #expect(loaded.contains(title: "Song - Remastered", artist: "A"))
    }
}

// MARK: - 推荐质量（A–D）

private actor SimilarCallRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

private struct MockSimilarProvider: OnlineSearchProviding, SimilarSongProviding, Sendable {
    var source: RecommendationSource = .netease
    var songs: [String: [RecommendationRemoteSong]] = [:]
    var similar: [RecommendationRemoteSong] = []
    var similarFails = false
    let recorder = SimilarCallRecorder()

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        Array((songs[query] ?? []).prefix(limit))
    }

    func similarSongs(songID: Int, limit: Int) async throws -> [RecommendationRemoteSong] {
        await recorder.record()
        if similarFails { throw MockError.offline }
        return Array(similar.prefix(limit))
    }

    enum MockError: Error { case offline }
}

@Suite("推荐质量：召回意图")
struct RecommendationIntentQualityTests {
    @Test("年代意图改成曲库里该年代的高权重艺人，不再搜泛词")
    func decadeUsesLibraryArtists() {
        // 代表艺人不在 topArtists 里，避免被「同一艺人只搜一次」的意图去重吃掉。
        var profile = makeProfile(artists: [("someone", 10)], decades: [1990: 0.7])
        profile.decadeArtists = [1990: ["Jay"]]
        let intents = RecommendationIntentBuilder.intents(from: profile)
        #expect(intents.contains { $0.kind == .decade && $0.query == "Jay" && $0.decade == 1990 })
        #expect(!intents.contains { $0.query.contains("年代") || $0.query.contains("1990") })
    }

    @Test("没有代表艺人时不为年代 / 曲风生成泛词意图")
    func noGenericFallback() {
        var profile = makeProfile(artists: [("a", 10)], decades: [1990: 0.9])
        profile.topGenres = ["流行"]
        let intents = RecommendationIntentBuilder.intents(from: profile)
        #expect(intents.allSatisfy { $0.kind == .artist })
        #expect(intents.allSatisfy { !$0.query.contains("1990") && $0.query != "流行" })
    }

    @Test("曲风意图用曲风下的高权重艺人")
    func genreUsesLibraryArtists() {
        var profile = makeProfile(artists: [("a", 10)])
        profile.topGenres = ["流行"]
        profile.genreArtists = ["流行": ["David Tao"]]
        let intents = RecommendationIntentBuilder.intents(from: profile)
        #expect(intents.contains { $0.kind == .genre && $0.query == "David Tao" && $0.genre == "流行" })
        #expect(!intents.contains { $0.query == "流行" })
    }
}

@Suite("推荐质量：非单曲过滤")
struct RecommendationFilterTests {
    @Test("歌单 / 合辑 / 群星 / 超长条目被过滤")
    func filtersPlaylistEntries() {
        #expect(RecommendationCandidateFilter.isLikelyNonSong(remote("1990s Golden Decade", "Playlist Co")))
        #expect(RecommendationCandidateFilter.isLikelyNonSong(remote("华语精选100首", "群星")))
        #expect(RecommendationCandidateFilter.isLikelyNonSong(remote("Greatest Hits", "Queen")))
        #expect(RecommendationCandidateFilter.isLikelyNonSong(remote("Night Mix", "Various Artists")))
        var long = remote("Long Set", "DJ")
        long.durationMs = 15 * 60 * 1000
        #expect(RecommendationCandidateFilter.isLikelyNonSong(long))
        #expect(RecommendationCandidateFilter.isLikelyNonSong(remote("1990s", "Somebody")))
    }

    @Test("正常单曲不被误杀")
    func keepsNormalSongs() {
        let creep = remote("Creep", "Radiohead", album: "Pablo Honey", year: 1993)
        #expect(!RecommendationCandidateFilter.isLikelyNonSong(creep))
        var song = remote("晴天", "周杰伦", album: "叶惠美", year: 2003)
        song.durationMs = 269_000
        #expect(!RecommendationCandidateFilter.isLikelyNonSong(song))
    }

    @Test("引擎归一化阶段丢弃歌单条目")
    func engineDropsPlaylists() async {
        let songs = [
            remote("1990s Golden Decade", "Playlist Co"),
            remote("Real Song", "Somebody"),
        ]
        let engine = RecommendationEngine(
            providers: [MockProvider(source: .netease, songs: ["a": songs])]
        )
        let profile = makeProfile(artists: [("a", 10)])
        guard case let .success(list) = await engine.recommend(profile: profile, count: 5) else {
            Issue.record("推荐应成功")
            return
        }
        #expect(list.map(\.title) == ["Real Song"])
    }
}

// MARK: - 年代标签（解析 / 标题判定 / 召回接线）

/// 记录查询词的桩：证明「年代标签绝不进在线搜索」（actor 收口，避免并发召回下的数据竞争）。
private actor QueryRecorder {
    private(set) var queries: [String] = []

    func record(_ query: String) {
        queries.append(query)
    }
}

private final class QueryRecordingProvider: OnlineSearchProviding, @unchecked Sendable {
    let source: RecommendationSource
    private let recorder = QueryRecorder()
    private let songs: [String: [RecommendationRemoteSong]]

    init(source: RecommendationSource = .netease, songs: [String: [RecommendationRemoteSong]] = [:]) {
        self.source = source
        self.songs = songs
    }

    func recordedQueries() async -> [String] {
        await recorder.queries
    }

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        await recorder.record(query)
        return Array((songs[query] ?? []).prefix(limit))
    }
}

@Suite("推荐质量：年代标签")
struct RecommendationDecadeLabelTests {
    @Test("年代标签解析：整串匹配，不误杀标题中段")
    func parsesDecadeLabels() {
        #expect(RecommendationDecadeLabel.parse("1990s") == 1990)
        #expect(RecommendationDecadeLabel.parse("1990年代") == 1990)
        #expect(RecommendationDecadeLabel.parse("90s") == 1990)
        #expect(RecommendationDecadeLabel.parse("1990") == 1990)
        #expect(RecommendationDecadeLabel.parse(" 1990S ") == 1990)
        #expect(RecommendationDecadeLabel.parse("1990's") == 1990)
        #expect(RecommendationDecadeLabel.parse("(1990s)") == 1990)
        #expect(RecommendationDecadeLabel.parse("【1990s】") == 1990)
        #expect(RecommendationDecadeLabel.parse("2000s") == 2000)
        #expect(RecommendationDecadeLabel.parse("2020s") == 2020)
        #expect(RecommendationDecadeLabel.parse("80s") == 1980)
        #expect(RecommendationDecadeLabel.parse("90年代") == 1990)
        #expect(RecommendationDecadeLabel.parse("1990 年") == 1990)

        #expect(RecommendationDecadeLabel.parse("1990s Love Song") == nil)
        #expect(RecommendationDecadeLabel.parse("Summer of 1990s") == nil)
        #expect(RecommendationDecadeLabel.parse("夏日1990") == nil)
        #expect(RecommendationDecadeLabel.parse("90") == nil)
        #expect(RecommendationDecadeLabel.parse("Creep") == nil)
        #expect(RecommendationDecadeLabel.parse("") == nil)
        #expect(RecommendationDecadeLabel.parse("1800s") == nil)
    }

    @Test("纯年代标题判定：年代/年份整串 → true，正常歌名 → false")
    func flagsDecadeOnlyTitles() {
        let decadeTitles = [
            "1990s", "1990's", "1990S", "2000s", "2020s", "1990", "2000",
            "90s", "80s", "1990年代", "90年代", "1990 年", " (1990s) ",
        ]
        for title in decadeTitles {
            #expect(RecommendationCandidateFilter.isDecadeOnlyTitle(title), "应判定为年代标题：\(title)")
            // 截图里的脏结果：专辑也等于年代（非空），旧规则因此漏网。
            #expect(
                RecommendationCandidateFilter.isLikelyNonSong(remote(title, "Axis Neptune", album: title)),
                "应剔除年代结果：\(title)"
            )
        }
        for title in ["1990s Love Song", "Summer of 1990s", "夏日1990", "晴天", "Creep"] {
            #expect(!RecommendationCandidateFilter.isDecadeOnlyTitle(title), "不应判定为年代标题：\(title)")
        }
    }

    @Test("年代意图展开为画像艺人，画像没有艺人则丢弃")
    func resolvesDecadeIntentToProfileArtists() {
        var profile = makeProfile(artists: [("someone", 10)])
        profile.decadeArtists = [1990: ["Jay", "Faye", "Third"]]

        let resolved = RecommendationIntentBuilder.resolved(
            [RecommendationIntent(query: "1990s", kind: .decade)],
            profile: profile
        )
        #expect(resolved.map(\.query) == ["Jay", "Faye"])
        #expect(resolved.allSatisfy { $0.kind == .decade && $0.decade == 1990 })
        #expect(!resolved.contains { RecommendationDecadeLabel.parse($0.query) != nil })

        let empty = RecommendationIntentBuilder.resolved(
            [RecommendationIntent(query: "1990s", kind: .decade)],
            profile: makeProfile()
        )
        #expect(empty.isEmpty)
    }

    @Test("kind 缺失/为 artist 的年代 query 同样按年代处理")
    func resolvesDecadeQueryRegardlessOfKind() {
        var profile = makeProfile()
        profile.decadeArtists = [2000: ["Jay"]]
        let artistKind = RecommendationIntentBuilder.resolved(
            [RecommendationIntent(query: "2000s", kind: .artist, artist: "2000s")],
            profile: profile
        )
        #expect(artistKind == [RecommendationIntent(query: "Jay", kind: .decade, artist: "Jay", decade: 2000)])

        let keywordKind = RecommendationIntentBuilder.resolved(
            [RecommendationIntent(query: "90年代", kind: .keyword)],
            profile: makeProfile()
        )
        #expect(keywordKind.isEmpty)
    }

    @Test("引擎召回：年代意图只搜画像艺人，结果里没有年代数字")
    func engineNeverSearchesDecadeLabel() async {
        var profile = makeProfile(artists: [("someone", 10)])
        profile.decadeArtists = [1990: ["Axis Neptune"]]
        let provider = QueryRecordingProvider(
            songs: [
                "Axis Neptune": [remote("Real Song", "Axis Neptune", album: "Album")],
                "1990s": [remote("1990s", "Axis Neptune", album: "1990s")],
            ]
        )
        let engine = RecommendationEngine(providers: [provider])
        let result = await engine.recommend(
            profile: profile,
            count: 5,
            intents: [RecommendationIntent(query: "1990s", kind: .decade)]
        )
        guard case let .success(list) = result else {
            Issue.record("推荐应成功")
            return
        }
        #expect(await provider.recordedQueries() == ["Axis Neptune"])
        #expect(list.map(\.title) == ["Real Song"])
    }
}

@Suite("推荐质量：重排与多样性")
struct RecommendationRankingQualityTests {
    @Test("相关性重排：高亲和艺人排到前面，而不是来源顺序")
    func rankingBeatsSourceOrder() async {
        let songs = [
            remote("Weak", "B", year: 2001),
            remote("Strong", "A", year: 2001),
        ]
        let engine = RecommendationEngine(
            providers: [MockProvider(source: .netease, songs: ["a": songs, "b": songs])]
        )
        let profile = makeProfile(artists: [("a", 10), ("b", 1)])
        guard case let .success(list) = await engine.recommend(profile: profile, count: 5) else {
            Issue.record("推荐应成功")
            return
        }
        #expect(list.first?.title == "Strong")
    }

    @Test("来源多样性：单意图不霸占整份列表")
    func intentDiversity() async {
        let aSongs = (1 ... 6).map { remote("Alpha \($0)", "ArtistA\($0)") }
        let bSongs = [remote("Beta 1", "ArtistB1"), remote("Beta 2", "ArtistB2")]
        let engine = RecommendationEngine(
            providers: [MockProvider(source: .netease, songs: ["a": aSongs, "b": bSongs])]
        )
        let profile = makeProfile(artists: [("a", 10), ("b", 2)])
        guard case let .success(list) = await engine.recommend(profile: profile, count: 4) else {
            Issue.record("推荐应成功")
            return
        }
        #expect(list.contains { $0.title.hasPrefix("Beta") })
    }
}

@Suite("推荐质量：逐曲理由")
struct RecommendationReasonTests {
    @Test("理由来自产生它的意图，相邻行不同")
    func perIntentReasons() async {
        let aSongs = [remote("S1", "ArtistA1"), remote("S2", "ArtistA2")]
        let bSongs = [remote("S3", "ArtistB1")]
        let engine = RecommendationEngine(
            providers: [MockProvider(source: .netease, songs: ["a": aSongs, "b": bSongs])]
        )
        let profile = makeProfile(artists: [("a", 10), ("b", 5)])
        guard case let .success(list) = await engine.recommend(profile: profile, count: 4), list.count >= 2 else {
            Issue.record("推荐应成功且至少两条")
            return
        }
        #expect(list.allSatisfy { !$0.reasons.isEmpty })
        #expect(list.allSatisfy { $0.reasons.count <= 2 })
        #expect(list[0].reasons.first != list[1].reasons.first)
        #expect(list[0].reasons.first?.lowercased().contains("a") == true)
    }

    @Test("年代意图的理由带年代数字")
    func decadeReason() async {
        let engine = RecommendationEngine(
            providers: [MockProvider(source: .netease, songs: ["Jay": [remote("Nunchucks", "Jay")]])]
        )
        let profile = makeProfile(artists: [("jay", 10)], decades: [1990: 0.8])
        let intents = [RecommendationIntent(query: "Jay", kind: .decade, artist: "Jay", decade: 1990)]
        guard case let .success(list) = await engine.recommend(profile: profile, count: 3, intents: intents) else {
            Issue.record("推荐应成功")
            return
        }
        #expect(list.first?.reasons.contains { $0.contains("1990") } == true)
    }
}

@Suite("推荐质量：相似召回回退")
struct RecommendationSimilarFallbackTests {
    private func seed(_ title: String, _ artist: String, id: Int) -> RecommendationRemoteSong {
        RecommendationRemoteSong(title: title, artist: artist, album: nil, year: nil, songID: id)
    }

    @Test("相似接口失败 → 回退同艺人热歌，且只探测一次")
    func similarFailureFallsBack() async {
        var provider = MockSimilarProvider()
        provider.songs = [
            "a": [seed("SeedA", "a", id: 1)],
            "b": [seed("SeedB", "b", id: 2)],
            "c": [seed("SeedC", "c", id: 3)],
        ]
        provider.similarFails = true
        let engine = RecommendationEngine(providers: [provider])
        let profile = makeProfile(artists: [("a", 10), ("b", 9), ("c", 8)])
        guard case let .success(list) = await engine.recommend(profile: profile, count: 6) else {
            Issue.record("回退后仍应有结果")
            return
        }
        #expect(list.count == 3)
        let calls = await provider.recorder.count
        #expect(calls == 1)
    }

    @Test("相似接口可用 → 追加相似候选")
    func similarAddsCandidates() async {
        var provider = MockSimilarProvider()
        provider.songs = ["a": [seed("SeedA", "a", id: 1)]]
        provider.similar = [RecommendationRemoteSong(title: "Sim", artist: "Someone", album: nil, year: nil)]
        let engine = RecommendationEngine(providers: [provider])
        let profile = makeProfile(artists: [("a", 10)])
        guard case let .success(list) = await engine.recommend(profile: profile, count: 5) else {
            Issue.record("推荐应成功")
            return
        }
        #expect(list.contains { $0.title == "Sim" })
    }
}
