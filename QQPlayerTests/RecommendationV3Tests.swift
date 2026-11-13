//
//  RecommendationV3Tests.swift
//  QQPlayerTests
//
//  推荐 v3：画像权重 / 配额拆分 / 曲库排除归一化 / 排序稳定性 / 设置默认值 / 五语种文案键。
//

import Foundation
@testable import QQPlayer
import Testing

// MARK: - 画像权重

@Suite("推荐 v3：画像权重")
struct RecommendationProfileWeightsTests {
    @Test("默认权重：0.35 / 0.40 / 0.15 / 0.10，和 = 1")
    func defaults() {
        let weights = RecommendationProfileWeights.defaults
        #expect(abs(weights.library - 0.35) < 0.0001)
        #expect(abs(weights.play - 0.40) < 0.0001)
        #expect(abs(weights.favorite - 0.15) < 0.0001)
        #expect(abs(weights.recency - 0.10) < 0.0001)
        #expect(abs(weights.sum - 1) < 0.0001)
    }

    @Test("任意正权重归一到和 1")
    func normalize() {
        let normalized = RecommendationProfileWeights(library: 0.7, play: 0.7, favorite: 0.7, recency: 0.7).normalized()
        #expect(abs(normalized.library - 0.25) < 0.0001)
        #expect(abs(normalized.play - 0.25) < 0.0001)
        #expect(abs(normalized.favorite - 0.25) < 0.0001)
        #expect(abs(normalized.recency - 0.25) < 0.0001)
        #expect(abs(normalized.sum - 1) < 0.0001)
    }

    @Test("全零 / NaN → 回退默认权重（不崩、不产生 NaN）")
    func degenerate() {
        let zero = RecommendationProfileWeights(library: 0, play: 0, favorite: 0, recency: 0).normalized()
        #expect(abs(zero.sum - 1) < 0.0001)
        let nan = RecommendationProfileWeights(library: .nan, play: -1, favorite: 2, recency: .infinity).normalized()
        #expect(nan.sum.isFinite)
        #expect(abs(nan.sum - 1) < 0.0001)
        #expect(nan.library >= 0 && nan.library <= 1)
    }

    @Test("步进 0.05：0.37 → 0.35，0.98 → 1.0")
    func stepping() {
        #expect(abs(RecommendationProfileWeights.clamp(0.37, fallback: 0.35) - 0.35) < 0.0001)
        #expect(abs(RecommendationProfileWeights.clamp(0.98, fallback: 0.35) - 1.0) < 0.0001)
    }
}

// MARK: - 配额

@Suite("推荐 v3：通道配额")
struct RecommendationChannelQuotasTests {
    @Test("默认配额 0.40 / 0.40 / 0.20，和 = 1")
    func defaults() {
        let quotas = RecommendationChannelQuotas.defaults
        #expect(abs(quotas.seed - 0.40) < 0.0001)
        #expect(abs(quotas.similar - 0.40) < 0.0001)
        #expect(abs(quotas.explore - 0.20) < 0.0001)
        #expect(quotas.isValid)
    }

    @Test("15 首 → 6 / 6 / 3（最大余数法）")
    func allocation15() {
        let allocation = RecommendationChannelQuotas.defaults.allocation(total: 15)
        #expect(allocation.seed == 6)
        #expect(allocation.similar == 6)
        #expect(allocation.explore == 3)
    }

    @Test("任意总数：三者之和恒等于总数，且非负")
    func allocationInvariant() {
        let quotas = RecommendationChannelQuotas(seed: 0.5, similar: 0.3, explore: 0.2)
        for total in 0 ... 60 {
            let allocation = quotas.allocation(total: total)
            #expect(allocation.seed + allocation.similar + allocation.explore == total)
            #expect(allocation.seed >= 0 && allocation.similar >= 0 && allocation.explore >= 0)
        }
    }

    @Test("总数小于通道数：按固定顺序 seed → similar → explore 各 1")
    func allocationSmall() {
        let allocation = RecommendationChannelQuotas.defaults.allocation(total: 2)
        #expect(allocation.seed == 1)
        #expect(allocation.similar == 1)
        #expect(allocation.explore == 0)
    }

    @Test("非法配额（全零 / 越界）归一后仍然合法")
    func normalizeDegenerate() {
        let zero = RecommendationChannelQuotas(seed: 0, similar: 0, explore: 0).normalized()
        #expect(zero.isValid)
        let overflow = RecommendationChannelQuotas(seed: 5, similar: 5, explore: 5).normalized()
        #expect(overflow.isValid)
    }
}

// MARK: - 归一化 / 曲库排除

@Suite("推荐 v3：曲库排除归一化")
struct RecommendationLibraryMatcherTests {
    /// 用例表：同一首歌的不同来源写法必须命中同一个键。
    private static let sameSong: [(String, String)] = [
        ("Love Story", "Taylor Swift"),
        ("Love Story (Live)", "Taylor Swift"),
        ("Love Story [Live]", "Taylor Swift"),
        ("Love Story - Live", "Taylor Swift"),
        ("Love Story - Remastered 2011", "Taylor Swift"),
        ("Love Story (Remastered)", "Taylor Swift"),
        ("Love Story (feat. Ed Sheeran)", "Taylor Swift"),
        ("Love Story feat. Ed Sheeran", "Taylor Swift"),
        ("love story", "taylor swift"),
        ("Ｌｏｖｅ　Ｓｔｏｒｙ", "Taylor Swift"),
        ("Love  Story", "Taylor Swift"),
        ("Love-Story", "Taylor Swift"),
    ]

    @Test("版本后缀 / 大小写 / 全半角 / 标点差异 → 同一个键")
    func sameSongKeys() {
        let keys = Self.sameSong.map { RecommendationLibraryMatcher.key(title: $0.0, artist: $0.1) }
        #expect(Set(keys).count == 1)
        #expect(keys.first == "lovestory#taylorswift")
    }

    @Test("不同歌曲 / 不同艺人 → 不同键")
    func differentKeys() {
        let a = RecommendationLibraryMatcher.key(title: "Love Story", artist: "Taylor Swift")
        let b = RecommendationLibraryMatcher.key(title: "Love Story", artist: "Someone Else")
        let c = RecommendationLibraryMatcher.key(title: "Blank Space", artist: "Taylor Swift")
        #expect(a != b)
        #expect(a != c)
    }

    @Test("多艺人取主艺人；& 不切（保护 Simon & Garfunkel）")
    func primaryArtist() {
        #expect(RecommendationLibraryMatcher.primaryArtist("A feat. B") == "A")
        #expect(RecommendationLibraryMatcher.primaryArtist("A, B") == "A")
        #expect(RecommendationLibraryMatcher.primaryArtist("Simon & Garfunkel") == "Simon & Garfunkel")
    }

    @Test("空输入 → 空键（调用方必须跳过，不进曲库集合）")
    func empty() {
        #expect(RecommendationLibraryMatcher.key(title: "", artist: "").isEmpty)
    }
}

// MARK: - 排序 / 过滤

@Suite("推荐 v3：过滤与排序")
struct RecommendationRankerV3Tests {
    private func song(
        _ title: String,
        _ artist: String,
        album: String? = nil,
        year: Int? = 2000,
        durationMs: Int? = 180_000
    ) -> RecommendationRemoteSong {
        RecommendationRemoteSong(title: title, artist: artist, album: album, year: year, durationMs: durationMs)
    }

    private func candidate(
        _ title: String,
        _ artist: String,
        album: String? = nil,
        channel: RecommendationChannel = .seed,
        affinity: Double? = 1,
        popularity: Double? = 1,
        year: Int? = 2000,
        durationMs: Int? = 180_000
    ) -> RecommendationV3Candidate {
        RecommendationV3Candidate(
            song: song(title, artist, album: album, year: year, durationMs: durationMs),
            context: RecommendationCandidateContext(
                channel: channel,
                seedArtist: artist,
                popularity: popularity,
                language: .latin,
                year: year,
                affinity: affinity
            )
        )
    }

    private func profile(library: Set<String> = [], blacklistTracks: Set<String> = [], blacklistArtists: Set<String> = []) -> RecommendationTasteProfileV3 {
        var profile = RecommendationTasteProfileV3()
        profile.seeds = [RecommendationSeedArtist(artist: "Taylor Swift", affinity: 1, libraryCount: 10, playCount: 100, representativeTitles: [])]
        profile.libraryKeys = library
        profile.blacklistTracks = blacklistTracks
        profile.blacklistArtists = blacklistArtists
        return profile
    }

    @Test("曲库已有的歌必须被排除（含 Live / Remastered 写法差异）")
    func excludesLibrary() {
        let library = Set([RecommendationLibraryMatcher.key(title: "Love Story", artist: "Taylor Swift")])
        let candidates = [
            candidate("Love Story (Live)", "Taylor Swift"),
            candidate("Blank Space", "Taylor Swift"),
        ]
        let admitted = RecommendationRankerV3.admit(candidates, profile: profile(library: library))
        #expect(admitted.count == 1)
        #expect(admitted.first?.song.title == "Blank Space")
    }

    @Test("黑名单曲目 / 艺人被排除")
    func excludesBlacklist() {
        let trackKey = RecommendationLibraryMatcher.key(title: "Song A", artist: "Artist B")
        let candidates = [candidate("Song A", "Artist B"), candidate("Song C", "Artist D")]
        let byTrack = RecommendationRankerV3.admit(candidates, profile: profile(blacklistTracks: [trackKey]))
        #expect(byTrack.count == 1)
        let byArtist = RecommendationRankerV3.admit(candidates, profile: profile(blacklistArtists: ["artist b"]))
        #expect(byArtist.count == 1)
    }

    @Test("时长 30s–10min；缺失时长放行")
    func duration() {
        let candidates = [
            candidate("Too Short", "A", durationMs: 29_000),
            candidate("OK", "B", durationMs: 30_000),
            candidate("Too Long", "C", durationMs: 600_001),
            candidate("Boundary", "D", durationMs: 600_000),
            candidate("Unknown", "E", durationMs: nil),
        ]
        let titles = RecommendationRankerV3.admit(candidates, profile: profile()).map(\.song.title)
        #expect(titles == ["OK", "Boundary", "Unknown"])
    }

    @Test("群星 / 合辑 / 伴奏被排除")
    func compilation() {
        let candidates = [
            candidate("Song", "群星"),
            candidate("Song 2", "Someone", album: "Greatest Hits"),
            candidate("Song 3 (Instrumental)", "Band"),
            candidate("Song 4", "Band"),
        ]
        let titles = RecommendationRankerV3.admit(candidates, profile: profile()).map(\.song.title)
        #expect(titles == ["Song 4"])
    }

    @Test("归一化去重：同曲不同写法只留一条")
    func dedupe() {
        let candidates = [
            candidate("Song (Live)", "Band"),
            candidate("Song", "Band"),
        ]
        let admitted = RecommendationRankerV3.admit(candidates, profile: profile())
        #expect(admitted.count == 1)
    }

    @Test("单艺人 ≤2、单专辑 ≤1")
    func diversity() {
        let candidates = [
            candidate("A1", "Band", album: "Album"),
            candidate("A2", "Band", album: "Album"),
            candidate("A3", "Band", album: "Other"),
            candidate("A4", "Band", album: nil),
        ]
        let ranked = RecommendationRankerV3.rank(candidates, profile: profile())
        #expect(ranked.count == 2)
        #expect(ranked.filter { $0.song.artist == "Band" }.count == 2)
    }

    @Test("排序稳定：同一批候选打乱输入顺序 → 结果顺序一致")
    func stableOrder() {
        let candidates = (0 ..< 12).map { index in
            candidate("Song \(index)", "Artist \(index % 4)", album: "Album \(index)", popularity: 1 - Double(index) / 20)
        }
        let first = RecommendationRankerV3.rank(candidates, profile: profile()).map(\.song.title)
        let second = RecommendationRankerV3.rank(candidates.reversed(), profile: profile()).map(\.song.title)
        #expect(first == second)
    }

    @Test("同分排序确定：按标题归一键升序")
    func tieBreak() {
        let candidates = [
            candidate("Beta", "Artist X", album: "B"),
            candidate("Alpha", "Artist Y", album: "A"),
        ]
        let titles = RecommendationRankerV3.rank(candidates, profile: profile()).map(\.song.title)
        #expect(titles == ["Alpha", "Beta"])
    }

    @Test("新鲜度惩罚：同分下新歌排在很老的歌之前")
    func freshness() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var old = candidate("Old", "Artist A", year: 1970)
        var new = candidate("New", "Artist B", year: 2025)
        old.context.affinity = 1
        new.context.affinity = 1
        let ranked = RecommendationRankerV3.rank([old, new], profile: profile(), now: now)
        #expect(ranked.first?.song.title == "New")
    }
}

// MARK: - 画像

@Suite("推荐 v3：口味画像")
struct RecommendationProfileV3Tests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("空库：返回空画像 + 可读原因")
    func emptyLibrary() {
        let profile = RecommendationProfileV3Builder.build(RecommendationProfileV3Input(now: now))
        #expect(profile.seeds.isEmpty)
        #expect(profile.emptyReason == .emptyLibrary)
    }

    @Test("曲目都缺艺人名：返回 noArtistData")
    func noArtist() {
        let input = RecommendationProfileV3Input(
            tracks: [RecommendationProfileV3Input.Track(title: "Untitled", artist: "")],
            now: now
        )
        let profile = RecommendationProfileV3Builder.build(input)
        #expect(profile.seeds.isEmpty)
        #expect(profile.emptyReason == .noArtistData)
    }

    @Test("曲目数最多的艺人亲和度最高，种子最多 15 个")
    func seeds() {
        var tracks: [RecommendationProfileV3Input.Track] = []
        for index in 0 ..< 20 {
            let count = 20 - index
            for track in 0 ..< count {
                tracks.append(RecommendationProfileV3Input.Track(title: "T\(index)-\(track)", artist: "Artist \(index)", playCount: 0))
            }
        }
        let profile = RecommendationProfileV3Builder.build(RecommendationProfileV3Input(tracks: tracks, now: now))
        #expect(profile.seeds.count == RecommendationProfileV3Builder.maxSeeds)
        #expect(profile.seeds.first?.artist == "Artist 0")
        #expect(profile.seeds.first?.affinity == 1)
        let affinities = profile.seeds.map(\.affinity)
        #expect(affinities == affinities.sorted(by: >))
    }

    @Test("收藏 / 歌单命中提高亲和度")
    func favoriteBoost() {
        let base = [
            RecommendationProfileV3Input.Track(title: "A", artist: "Plain"),
            RecommendationProfileV3Input.Track(title: "B", artist: "Star", isFavorite: true),
        ]
        let profile = RecommendationProfileV3Builder.build(RecommendationProfileV3Input(tracks: base, now: now))
        let star = profile.seeds.first { $0.artist == "Star" }?.affinity ?? 0
        let plain = profile.seeds.first { $0.artist == "Plain" }?.affinity ?? 0
        #expect(star > plain)
    }

    @Test("风格簇：genre × decade × language 占比 Top，最多 5 个")
    func clusters() {
        var tracks: [RecommendationProfileV3Input.Track] = []
        for index in 0 ..< 8 {
            tracks.append(RecommendationProfileV3Input.Track(title: "J\(index)", artist: "J Artist \(index)", genre: "City Pop", year: 1985))
        }
        for index in 0 ..< 2 {
            tracks.append(RecommendationProfileV3Input.Track(title: "R\(index)", artist: "R Artist \(index)", genre: "Rock", year: 1995))
        }
        let profile = RecommendationProfileV3Builder.build(RecommendationProfileV3Input(tracks: tracks, now: now))
        #expect(!profile.clusters.isEmpty)
        #expect(profile.clusters.count <= RecommendationProfileV3Builder.maxClusters)
        #expect(profile.clusters.first?.genre == "city pop")
        #expect(profile.clusters.first?.decade == 1980)
        #expect(abs((profile.clusters.first?.share ?? 0) - 0.8) < 0.0001)
    }

    @Test("没有 genre：簇为空，但种子仍有值")
    func clustersWithoutGenre() {
        let tracks = [RecommendationProfileV3Input.Track(title: "A", artist: "X")]
        let profile = RecommendationProfileV3Builder.build(RecommendationProfileV3Input(tracks: tracks, now: now))
        #expect(profile.clusters.isEmpty)
        #expect(profile.seeds.count == 1)
    }
}

// MARK: - 设置默认值

@Suite("推荐 v3：设置默认值")
struct RecommendationV3SettingsTests {
    @Test("默认权重 / 配额与需求一致")
    func defaults() {
        let settings = DeleteSettings()
        #expect(abs(settings.recommendationProfileWeights.library - 0.35) < 0.0001)
        #expect(abs(settings.recommendationProfileWeights.play - 0.40) < 0.0001)
        #expect(abs(settings.recommendationProfileWeights.favorite - 0.15) < 0.0001)
        #expect(abs(settings.recommendationProfileWeights.recency - 0.10) < 0.0001)
        #expect(abs(settings.recommendationChannelQuotas.seed - 0.40) < 0.0001)
        #expect(abs(settings.recommendationChannelQuotas.similar - 0.40) < 0.0001)
        #expect(abs(settings.recommendationChannelQuotas.explore - 0.20) < 0.0001)
    }

    @Test("归一化落盘：改一项后四项和 = 1")
    func normalizeWrites() {
        var settings = DeleteSettings()
        settings.recommendationV3.weightLibrary = 1
        settings.recommendationV3.weightPlay = 1
        settings.recommendationV3.weightFavorite = 1
        settings.recommendationV3.weightRecency = 1
        settings.normalizeRecommendationWeights()
        let total = settings.recommendationV3.weightLibrary + settings.recommendationV3.weightPlay
            + settings.recommendationV3.weightFavorite + settings.recommendationV3.weightRecency
        #expect(abs(total - 1) < 0.0001)
    }
}

// MARK: - 本地化

@Suite("推荐 v3：五语种文案键")
struct RecommendationV3LocalizationTests {
    private static let languages = ["en", "fr", "ru", "zh-Hans", "zh-Hant"]
    private static let requiredKeys = [
        "recommendation_v3_reason_seed",
        "recommendation_v3_reason_similar",
        "recommendation_v3_reason_explore",
        "recommendation_v3_decade",
        "recommendation_decade_unknown",
        "recommendation_channel_seed",
        "recommendation_channel_similar",
        "recommendation_channel_explore",
        "recommendation_language_zh_hans",
        "recommendation_language_zh_hant",
        "recommendation_language_ja",
        "recommendation_language_ko",
        "recommendation_language_latin",
        "recommendation_language_unknown",
        "recommendation_downloaded_badge",
        "recommendation_weights_title",
        "recommendation_weight_library",
        "recommendation_weight_play",
        "recommendation_weight_favorite",
        "recommendation_weight_recency",
        "recommendation_quotas_title",
        "recommendation_quota_seed",
        "recommendation_quota_similar",
        "recommendation_quota_explore",
        "recommendation_lastfm_title",
        "recommendation_lastfm_footer",
        "recommendation_profile_empty_library",
        "recommendation_profile_no_artist",
        "source_lastfm",
    ]

    @Test("五个语种都包含 v3 必需文案键")
    func allLanguagesHaveKeys() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for language in Self.languages {
            let url = root.appendingPathComponent("QQPlayer/Resources/\(language).lproj/Localizable.strings")
            let text = try String(contentsOf: url, encoding: .utf8)
            for key in Self.requiredKeys {
                #expect(text.contains("\"\(key)\" ="), "\(language) 缺少 \(key)")
            }
        }
    }
}

// MARK: - iTunes 元数据标准化

@Suite("推荐 v3：iTunes 元数据标准化")
struct RecommendationMetadataNormalizerTests {
    /// 记录调用次数的桩 provider（actor 保证并发安全）。
    actor StubProvider: OnlineSearchProviding {
        nonisolated var source: RecommendationSource { .itunes }
        private let results: [RecommendationRemoteSong]
        private var calls = 0

        init(results: [RecommendationRemoteSong]) {
            self.results = results
        }

        func search(query _: String, limit _: Int) async throws -> [RecommendationRemoteSong] {
            calls += 1
            return results
        }

        func callCount() -> Int { calls }
    }

    private func profile() -> RecommendationTasteProfileV3 {
        var profile = RecommendationTasteProfileV3()
        profile.seeds = [RecommendationSeedArtist(artist: "张学友", affinity: 1, libraryCount: 10, playCount: 10, representativeTitles: [])]
        return profile
    }

    private func candidate(_ title: String, _ artist: String) -> RecommendationV3Candidate {
        RecommendationV3Candidate(
            song: RecommendationRemoteSong(title: title, artist: artist, source: .lastfm),
            context: RecommendationCandidateContext(channel: .seed, seedArtist: artist, affinity: 1)
        )
    }

    @Test("错名纠正：归一化键不同 → 用 iTunes 标准曲名，并补齐年份/专辑/时长")
    func correctsDirtyTitle() async {
        let provider = StubProvider(results: [
            RecommendationRemoteSong(
                title: "她来听我的演唱会",
                artist: "张学友",
                album: "走过1999",
                year: 1999,
                durationMs: 260_000
            ),
        ])
        let normalizer = RecommendationMetadataNormalizer(
            provider: provider,
            cache: RecommendationMetadataCache(),
            maxLookups: 5
        )
        let dirty = candidate("Ageless Tale", "张学友")
        let output = await normalizer.normalize([dirty], profile: profile())
        #expect(output.hits == 1)
        #expect(output.candidates.first?.song.title == "她来听我的演唱会")
        #expect(output.candidates.first?.song.year == 1999)
        #expect(output.candidates.first?.song.album == "走过1999")
        #expect(output.candidates.first?.song.durationMs == 260_000)
    }

    @Test("同曲版本差异（Live）不覆盖原曲名")
    func keepsVersionTitle() async {
        let provider = StubProvider(results: [
            RecommendationRemoteSong(title: "慢慢", artist: "张学友", year: 2001),
        ])
        let normalizer = RecommendationMetadataNormalizer(
            provider: provider,
            cache: RecommendationMetadataCache(),
            maxLookups: 5
        )
        let live = candidate("慢慢 (Live)", "张学友")
        let output = await normalizer.normalize([live], profile: profile())
        #expect(output.candidates.first?.song.title == "慢慢 (Live)")
        #expect(output.candidates.first?.song.year == 2001)
    }

    @Test("艺人不一致 → 不采纳（宁缺勿错）")
    func rejectsArtistMismatch() async {
        let provider = StubProvider(results: [
            RecommendationRemoteSong(title: "Ageless Tale", artist: "Someone Else", year: 2020),
        ])
        let normalizer = RecommendationMetadataNormalizer(
            provider: provider,
            cache: RecommendationMetadataCache(),
            maxLookups: 5
        )
        let dirty = candidate("Ageless Tale", "张学友")
        let output = await normalizer.normalize([dirty], profile: profile())
        #expect(output.hits == 0)
        #expect(output.candidates.first?.song.year == nil)
    }

    @Test("maxLookups = 0：完全跳过，不发请求")
    func disabled() async {
        let provider = StubProvider(results: [RecommendationRemoteSong(title: "X", artist: "张学友")])
        let normalizer = RecommendationMetadataNormalizer(
            provider: provider,
            cache: RecommendationMetadataCache(),
            maxLookups: 0
        )
        _ = await normalizer.normalize([candidate("X", "张学友")], profile: profile())
        let calls = await provider.callCount()
        #expect(calls == 0)
    }

    @Test("缓存命中：同曲第二轮不再请求")
    func cacheHit() async {
        let provider = StubProvider(results: [RecommendationRemoteSong(title: "她来听我的演唱会", artist: "张学友", year: 1999)])
        let normalizer = RecommendationMetadataNormalizer(
            provider: provider,
            cache: RecommendationMetadataCache(),
            maxLookups: 5
        )
        _ = await normalizer.normalize([candidate("Ageless Tale", "张学友")], profile: profile())
        let second = await normalizer.normalize([candidate("Ageless Tale", "张学友")], profile: profile())
        let calls = await provider.callCount()
        #expect(calls == 1)
        #expect(second.hits == 1)
    }
}
