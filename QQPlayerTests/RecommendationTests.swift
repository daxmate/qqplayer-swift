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
