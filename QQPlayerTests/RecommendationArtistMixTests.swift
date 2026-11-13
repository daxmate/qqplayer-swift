//
//  RecommendationArtistMixTests.swift
//  QQPlayerTests
//
//  点名艺人推荐 = 本人为主 + 相似补位（来源明示）。
//
//  覆盖口径：画像意图丢弃 / 15 首批次配额 / 相似补位上限 / 来源理由 key / 不足提示数字 /
//  非点名请求回归。全部纯逻辑 + 桩 provider，不联网、不依赖 UI。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 桩

private struct MixProvider: OnlineSearchProviding, ArtistAliasProviding {
    let source: RecommendationSource = .netease
    var songs: [String: [RecommendationRemoteSong]] = [:]

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        Array((songs[query] ?? []).prefix(limit))
    }

    func aliases(for artist: String) async -> [String] {
        [artist]
    }
}

private struct MixRelationSource: ArtistRelatedArtistProviding {
    var names: [String]

    func relatedArtists(for artistName: String, limit: Int) async throws -> [String] {
        Array(names.prefix(limit))
    }
}

private struct MixRelatedRecall: RelatedArtistRecallProviding {
    var songsByArtist: [String: [RecommendationRemoteSong]] = [:]

    func songsForRelatedArtist(_ name: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        Array((songsByArtist[name] ?? []).prefix(limit))
    }
}

private func mixSong(_ title: String, _ artist: String) -> RecommendationRemoteSong {
    RecommendationRemoteSong(title: title, artist: artist, year: 2004, songID: nil)
}

private func mixCandidate(_ title: String, _ artist: String, relatedTo: String? = nil) -> RecommendedCandidate {
    RecommendedCandidate(
        title: title,
        artist: artist,
        album: "专辑-\(title)",
        year: nil,
        source: .netease,
        relatedTo: relatedTo
    )
}

private func mixRequest(
    artists: [String] = [],
    keywords: [String] = [],
    moods: [String] = [],
    decades: [Int] = [],
    rawText: String = ""
) -> RecommendationUserRequest {
    RecommendationUserRequest(
        referenceArtists: artists,
        keywords: keywords,
        decades: decades,
        moods: moods,
        rawText: rawText
    )
}

/// 点名场景引擎：与 Mac 池构建同口径（不限单艺人 / 单专辑 / 单意图 / 单来源）。
private func mixEngine(
    direct: [RecommendationRemoteSong],
    relatedByArtist: [String: [RecommendationRemoteSong]] = [:]
) -> RecommendationEngine {
    var provider = MixProvider()
    provider.songs = ["孙燕姿": direct]
    var engine = RecommendationEngine(
        providers: [provider],
        perIntentLimit: 40,
        maxSongsPerArtist: 10_000,
        maxSongsPerAlbum: nil
    )
    engine.maxSongsPerIntent = 40
    engine.maxSourceShare = 1
    engine.similarRecallEnabled = false
    if !relatedByArtist.isEmpty {
        engine.artistRelation = RecommendationArtistRelation(
            client: MixRelationSource(names: Array(relatedByArtist.keys).sorted()),
            recall: MixRelatedRecall(songsByArtist: relatedByArtist),
            budget: RecommendationArtistRelationBudget()
        )
    }
    return engine
}

private func sunyanzi(_ count: Int) -> [RecommendationRemoteSong] {
    (1 ... count).map { mixSong(String(format: "S%02d", $0), "孙燕姿") }
}

private func relatedSongs(_ count: Int, _ artist: String) -> [RecommendationRemoteSong] {
    (1 ... count).map { mixSong("\(artist)-R\($0)", artist) }
}

// MARK: - 意图

@Suite("点名艺人混合：意图口径")
struct RecommendationArtistMixIntentTests {
    @Test("点名请求：丢弃画像派生的关键词 / 年代意图，用户原话里的词保留")
    func namedArtistDropsProfileIntents() {
        var profile = TasteProfile()
        profile.decadeArtists = [1990: ["张学友"], 2000: ["周杰伦"]]

        let request = mixRequest(
            artists: ["孙燕姿"],
            keywords: ["抒情"],
            moods: ["安静"],
            decades: [1990],
            rawText: "给我推荐一些孙燕姿的抒情歌曲"
        )
        let intents = RecommendationIntentBuilder.intents(from: request, profile: profile)

        #expect(!intents.contains { $0.kind == .decade })
        #expect(intents.contains { $0.kind == .keyword && $0.query == "抒情" })
        #expect(!intents.contains { $0.kind == .keyword && $0.query == "安静" })
        #expect(intents.contains { $0.kind == .artist && $0.query == "孙燕姿" })
    }

    @Test("非点名请求：画像关键词 / 年代意图照旧追加（行为回归不变）")
    func nonNamedRequestKeepsProfileIntents() {
        var profile = TasteProfile()
        profile.decadeArtists = [1990: ["张学友"]]

        let request = mixRequest(keywords: ["抒情"], decades: [1990], rawText: "来点抒情的老歌")
        let intents = RecommendationIntentBuilder.intents(from: request, profile: profile)

        #expect(intents.contains { $0.kind == .keyword && $0.query == "抒情" })
        #expect(intents.contains { $0.kind == .decade && $0.query == "张学友" })
    }

    @Test("相似语义不算点名：画像意图保留（与硬约束同一判定）")
    func similarityRequestIsNotNamedArtist() {
        var profile = TasteProfile()
        profile.decadeArtists = [1990: ["张学友"]]

        let request = mixRequest(artists: ["孙燕姿"], decades: [1990], rawText: "来点像孙燕姿的歌")
        #expect(!RecommendationArtistMix.isNamedArtistRequest(request))
        let intents = RecommendationIntentBuilder.intents(from: request, profile: profile)
        #expect(intents.contains { $0.kind == .decade })
    }
}

// MARK: - 配额

@Suite("点名艺人混合：配额")
struct RecommendationArtistMixQuotaTests {
    @Test("池子够：15 首全是本人（相似补位 0）")
    func directFillsTarget() async {
        let engine = mixEngine(
            direct: sunyanzi(20),
            relatedByArtist: ["方大同": relatedSongs(6, "方大同")]
        )
        let result = await engine.recommend(
            request: mixRequest(artists: ["孙燕姿"], rawText: "推荐一些孙燕姿的歌"),
            profile: TasteProfile(),
            count: 15
        )
        switch result {
        case let .success(list):
            #expect(list.count == 15)
            #expect(RecommendationArtistMix.directCount(in: list) == 15)
            #expect(RecommendationArtistMix.directCount(in: list) >= 10)
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("本人 12 首：补 3 首相似凑满 15，相似 ≤ 5")
    func relatedTopsUpWithinCap() async {
        let engine = mixEngine(
            direct: sunyanzi(12),
            relatedByArtist: [
                "方大同": relatedSongs(4, "方大同"),
                "王力宏": relatedSongs(4, "王力宏"),
            ]
        )
        let result = await engine.recommend(
            request: mixRequest(artists: ["孙燕姿"], rawText: "推荐一些孙燕姿的歌"),
            profile: TasteProfile(),
            count: 15
        )
        switch result {
        case let .success(list):
            let direct = RecommendationArtistMix.directCount(in: list)
            let related = list.count - direct
            #expect(direct == 12)
            #expect(related == 3)
            #expect(related <= 5)
            #expect(list.count == 15)
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("本人不足：相似最多补 5，总数 = 实际找到数（不凑数）")
    func relatedCapIsBatchThird() async {
        let engine = mixEngine(
            direct: sunyanzi(3),
            relatedByArtist: ["方大同": relatedSongs(10, "方大同")]
        )
        let result = await engine.recommend(
            request: mixRequest(artists: ["孙燕姿"], rawText: "推荐一些孙燕姿的歌"),
            profile: TasteProfile(),
            count: 15
        )
        switch result {
        case let .success(list):
            let direct = RecommendationArtistMix.directCount(in: list)
            #expect(direct == 3)
            #expect(list.count == 8)
            #expect(list.count - direct == 5)
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("相似补位额度按用户可见批次（15 → 5），池容量 60 不放宽")
    func relatedCapUsesDisplayBatch() {
        #expect(RecommendationArtistMix.relatedCap(displayTarget: 15) == 5)
        #expect(RecommendationArtistMix.relatedCap(displayTarget: 60) == 5)
        #expect(RecommendationArtistMix.relatedCap(displayTarget: 2) == 0)
    }

    @Test("点名批次：同一艺人可占满整批（15 首全本人），不标多样性放宽")
    func namedArtistBatchAllowsSingleArtist() {
        let pool = (1 ... 20).map { mixCandidate(String(format: "S%02d", $0), "孙燕姿") }
        var session = RecallSession(
            pool: pool,
            maxPerArtist: RecommendationArtistMix.batchMaxPerArtist(namedArtist: true),
            minDistinctArtists: RecommendationArtistMix.batchMinDistinctArtists(namedArtist: true)
        )
        let batch = session.nextBatch()
        #expect(batch.count == 15)
        #expect(batch.allSatisfy { $0.artist == "孙燕姿" })
        #expect(!session.lastBatchDiversity.relaxed.contains(.artists))
    }

    @Test("非点名批次：同艺人上限仍是 4（行为回归不变）")
    func regularBatchKeepsArtistCap() {
        let pool = (1 ... 20).map { mixCandidate(String(format: "S%02d", $0), "孙燕姿") }
        var session = RecallSession(
            pool: pool,
            maxPerArtist: RecommendationArtistMix.batchMaxPerArtist(namedArtist: false)
        )
        let batch = session.nextBatch()
        #expect(batch.count == RecommendationBatchPolicy.maxSongsPerArtist)
    }
}

// MARK: - 来源明示

@Suite("点名艺人混合：来源明示")
struct RecommendationArtistMixReasonTests {
    @Test("相似行用「相似艺人」理由，本人行用「点名艺人」理由，两者 key 不同")
    func relatedRowsCarryOwnReason() async {
        let engine = mixEngine(
            direct: sunyanzi(3),
            relatedByArtist: ["方大同": relatedSongs(3, "方大同")]
        )
        let result = await engine.recommend(
            request: mixRequest(artists: ["孙燕姿"], rawText: "推荐一些孙燕姿的歌"),
            profile: TasteProfile(),
            count: 15
        )
        switch result {
        case let .success(list):
            let direct = list.filter { $0.relatedTo == nil }
            let related = list.filter { $0.relatedTo != nil }
            #expect(!related.isEmpty)
            let directReason = "recommendation_reason_requested_artist".localized
            #expect(direct.allSatisfy { $0.reasons.contains(directReason) })
            for row in related {
                #expect(!row.reasons.contains(directReason))
                let relatedReason = "recommendation_reason_related_artist".localized(with: row.artist)
                #expect(row.reasons.contains(relatedReason))
                #expect(relatedReason != directReason)
            }
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("相似行的 relatedTo = 点名艺人")
    func relatedRowsMarkNamedArtist() async {
        let engine = mixEngine(
            direct: sunyanzi(1),
            relatedByArtist: ["方大同": relatedSongs(2, "方大同")]
        )
        let result = await engine.recommend(
            request: mixRequest(artists: ["孙燕姿"], rawText: "推荐一些孙燕姿的歌"),
            profile: TasteProfile(),
            count: 15
        )
        switch result {
        case let .success(list):
            #expect(list.filter { $0.relatedTo != nil }.allSatisfy { $0.relatedTo == "孙燕姿" })
            #expect(list.filter { $0.relatedTo != nil }.allSatisfy { $0.artist == "方大同" })
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }
}

// MARK: - 不足提示

@Suite("点名艺人混合：不足提示")
struct RecommendationArtistMixNoticeTests {
    @Test("数字用本人匹配数（不是整批数量）")
    func noticeUsesDirectCount() {
        let filled = RecommendationArtistMix.shortfallNotice(
            artist: "孙燕姿", directCount: 3, relatedCount: 5, target: 15
        )
        #expect(filled == "recommendation_artist_shortfall_filled".localized(with: "孙燕姿", 3, 5))
        #expect(filled?.contains("15") == false)

        let plain = RecommendationArtistMix.shortfallNotice(
            artist: "孙燕姿", directCount: 3, relatedCount: 0, target: 15
        )
        #expect(plain == "recommendation_artist_shortfall".localized(with: 3, "孙燕姿"))
    }

    @Test("本人已达标：不打扰（nil）")
    func noticeHiddenWhenEnough() {
        #expect(RecommendationArtistMix.shortfallNotice(
            artist: "孙燕姿", directCount: 15, relatedCount: 0, target: 15
        ) == nil)
    }
}
