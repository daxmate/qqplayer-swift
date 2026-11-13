//
//  RecommendationArtistMixTests.swift
//  QQPlayerTests
//
//  点名艺人推荐 = 本人为主 + 相似补位（来源明示，比例可设定）。
//
//  覆盖口径：画像意图丢弃 / 固定比例配额（10:5）/ 相似段上限 / 来源理由 key /
//  不足提示数字 / 批次配额 / 比例设置默认与归一 / 非点名请求回归。
//  全部纯逻辑 + 桩 provider，不联网、不依赖 UI。
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

/// MB 关系查询调用记录（验证 share=0 时「不召回相似」）。
private final class MixCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []

    func record(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        items.append(value)
    }

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

private struct MixRelationSource: ArtistRelatedArtistProviding {
    var names: [String]
    var log: MixCallLog?

    func relatedArtists(for artistName: String, limit: Int) async throws -> [String] {
        log?.record(artistName)
        return Array(names.prefix(limit))
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
    relatedByArtist: [String: [RecommendationRemoteSong]] = [:],
    share: Double = DeleteSettings.defaultRelatedArtistShare,
    log: MixCallLog? = nil
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
    engine.relatedArtistShare = share
    if !relatedByArtist.isEmpty {
        engine.artistRelation = RecommendationArtistRelation(
            client: MixRelationSource(names: Array(relatedByArtist.keys).sorted(), log: log),
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
    @Test("两段池子都够：target 15、share 0.30 → 本人 10 + 相似 5（固定比例）")
    func mixedBatchIsExactlyTenFive() async {
        let engine = mixEngine(
            direct: sunyanzi(20),
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
            #expect(direct == 10)
            #expect(list.count - direct == 5)
            #expect(list.count == 15)
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("本人过多也按比例截断：12 首本人只取 10，相似补 5")
    func directCappedByQuota() async {
        let engine = mixEngine(
            direct: sunyanzi(12),
            relatedByArtist: ["方大同": relatedSongs(8, "方大同")]
        )
        let result = await engine.recommend(
            request: mixRequest(artists: ["孙燕姿"], rawText: "推荐一些孙燕姿的歌"),
            profile: TasteProfile(),
            count: 15
        )
        switch result {
        case let .success(list):
            let direct = RecommendationArtistMix.directCount(in: list)
            #expect(direct == 10)
            #expect(list.count - direct == 5)
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("本人不足 10：相似仍 ≤5，总数 = 实际可得（不凑数）")
    func relatedCapWhenDirectShort() async {
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
            #expect(list.count - direct == 5)
            #expect(list.count == 8)
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("相似不足：由本人补满 target（本人优先补位）")
    func directBackfillsWhenRelatedShort() async {
        let engine = mixEngine(
            direct: sunyanzi(20),
            relatedByArtist: ["方大同": relatedSongs(2, "方大同")]
        )
        let result = await engine.recommend(
            request: mixRequest(artists: ["孙燕姿"], rawText: "推荐一些孙燕姿的歌"),
            profile: TasteProfile(),
            count: 15
        )
        switch result {
        case let .success(list):
            let direct = RecommendationArtistMix.directCount(in: list)
            #expect(list.count == 15)
            #expect(direct == 13)
            #expect(list.count - direct == 2)
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("名额换算：round(target × share)，share=0 纯本人、0.5 为 7/8")
    func quotaMath() {
        let defaultQuota = RecommendationArtistMix.quota(displayTarget: 15, share: 0.30)
        #expect(defaultQuota.direct == 10)
        #expect(defaultQuota.related == 5)

        let zero = RecommendationArtistMix.quota(displayTarget: 15, share: 0)
        #expect(zero.direct == 15)
        #expect(zero.related == 0)

        let half = RecommendationArtistMix.quota(displayTarget: 15, share: 0.50)
        #expect(half.direct == 7)
        #expect(half.related == 8)

        let pool = RecommendationArtistMix.quota(displayTarget: 60, share: 0.30)
        #expect(pool.direct == 42)
        #expect(pool.related == 18)

        let twenty = RecommendationArtistMix.quota(displayTarget: 20, share: 0.30)
        #expect(twenty.direct == 14)
        #expect(twenty.related == 6)

        let zeroTarget = RecommendationArtistMix.quota(displayTarget: 0, share: 0.30)
        #expect(zeroTarget.direct == 0)
        #expect(zeroTarget.related == 0)
    }

    @Test("share=0：不召回相似（连 MB 关系查询都不发）")
    func shareZeroSkipsRelatedRecall() async {
        let log = MixCallLog()
        let engine = mixEngine(
            direct: sunyanzi(20),
            relatedByArtist: ["方大同": relatedSongs(8, "方大同")],
            share: 0,
            log: log
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
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
        #expect(log.calls.isEmpty)
    }

    @Test("share=0.5：同一请求改成 50% → 本人 7 + 相似 8（比例随设置变）")
    func shareHalfSplitsSevenEight() async {
        let engine = mixEngine(
            direct: sunyanzi(20),
            relatedByArtist: ["方大同": relatedSongs(10, "方大同")],
            share: 0.5
        )
        let result = await engine.recommend(
            request: mixRequest(artists: ["孙燕姿"], rawText: "推荐一些孙燕姿的歌"),
            profile: TasteProfile(),
            count: 15
        )
        switch result {
        case let .success(list):
            let direct = RecommendationArtistMix.directCount(in: list)
            #expect(direct == 7)
            #expect(list.count - direct == 8)
            #expect(list.count == 15)
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("批次比例随设置变化：30% → 10/5，50% → 7/8")
    func batchRatioFollowsShare() {
        let direct = (1 ... 20).map { mixCandidate(String(format: "S%02d", $0), "孙燕姿") }
        let related = (1 ... 12).map { mixCandidate("R\($0)", "方大同", relatedTo: "孙燕姿") }
        let pool = direct + related

        func split(_ share: Double) -> (direct: Int, related: Int) {
            let quota = RecommendationArtistMix.quota(
                displayTarget: RecommendationBatchPolicy.batchSize,
                share: share
            )
            var session = RecallSession(
                pool: pool,
                maxPerArtist: RecommendationArtistMix.batchMaxPerArtist(namedArtist: true),
                minDistinctArtists: RecommendationArtistMix.batchMinDistinctArtists(namedArtist: true),
                quota: RecallSession.Quota(direct: quota.direct, related: quota.related)
            )
            let batch = session.nextBatch()
            let directCount = batch.filter { $0.relatedTo == nil }.count
            return (directCount, batch.count - directCount)
        }

        let thirty = split(0.30)
        #expect(thirty.direct == 10)
        #expect(thirty.related == 5)

        let fifty = split(0.50)
        #expect(fifty.direct == 7)
        #expect(fifty.related == 8)
    }

    @Test("share=0：引擎产出纯本人（相似段名额 0）")
    func shareZeroIsPureDirect() async {
        let engine = mixEngine(
            direct: sunyanzi(20),
            relatedByArtist: ["方大同": relatedSongs(8, "方大同")],
            share: 0
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
        case let .failure(error):
            Issue.record("不应失败：\(error)")
        }
    }

    @Test("批次：两段都够 → 正好 10 本人 + 5 相似")
    func batchQuotaSplitsTenFive() {
        let direct = (1 ... 20).map { mixCandidate(String(format: "S%02d", $0), "孙燕姿") }
        let related = (1 ... 8).map { mixCandidate("R\($0)", "方大同", relatedTo: "孙燕姿") }
        var session = RecallSession(
            pool: direct + related,
            maxPerArtist: RecommendationArtistMix.batchMaxPerArtist(namedArtist: true),
            minDistinctArtists: RecommendationArtistMix.batchMinDistinctArtists(namedArtist: true),
            quota: RecallSession.Quota(direct: 10, related: 5)
        )
        let batch = session.nextBatch()
        #expect(batch.count == 15)
        #expect(batch.filter { $0.relatedTo == nil }.count == 10)
        #expect(batch.filter { $0.relatedTo != nil }.count == 5)
    }

    @Test("批次：相似不足 → 本人补满 15（整批同艺人不标多样性放宽）")
    func batchBackfillsDirect() {
        let pool = (1 ... 20).map { mixCandidate(String(format: "S%02d", $0), "孙燕姿") }
        var session = RecallSession(
            pool: pool,
            maxPerArtist: RecommendationArtistMix.batchMaxPerArtist(namedArtist: true),
            minDistinctArtists: RecommendationArtistMix.batchMinDistinctArtists(namedArtist: true),
            quota: RecallSession.Quota(direct: 10, related: 5)
        )
        let batch = session.nextBatch()
        #expect(batch.count == 15)
        #expect(batch.allSatisfy { $0.artist == "孙燕姿" })
        #expect(!session.lastBatchDiversity.relaxed.contains(.artists))
    }

    @Test("非点名批次：无配额时同艺人上限仍是 4（行为回归不变）")
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
            direct: sunyanzi(10),
            relatedByArtist: ["方大同": relatedSongs(5, "方大同")]
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
            direct: sunyanzi(10),
            relatedByArtist: ["方大同": relatedSongs(5, "方大同")]
        )
        let result = await engine.recommend(
            request: mixRequest(artists: ["孙燕姿"], rawText: "推荐一些孙燕姿的歌"),
            profile: TasteProfile(),
            count: 15
        )
        switch result {
        case let .success(list):
            let related = list.filter { $0.relatedTo != nil }
            #expect(!related.isEmpty)
            #expect(related.allSatisfy { $0.relatedTo == "孙燕姿" })
            #expect(related.allSatisfy { $0.artist == "方大同" })
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

// MARK: - 比例设置

@Suite("点名艺人混合：比例设置")
struct RecommendationArtistMixSettingsTests {
    @Test("默认 30%（与引擎默认值同一口径）")
    func defaultShare() {
        #expect(DeleteSettings.defaultRelatedArtistShare == 0.30)
        #expect(DeleteSettings().relatedArtistShare == 0.30)
        #expect(RecommendationEngine(providers: []).relatedArtistShare == 0.30)
    }

    @Test("归一：夹 0...0.5 且按 5% 步进取整")
    func clampShare() {
        #expect(DeleteSettings.clampRelatedArtistShare(-1) == 0)
        #expect(DeleteSettings.clampRelatedArtistShare(0.9) == 0.5)
        #expect(DeleteSettings.clampRelatedArtistShare(0.33) == 0.35)
        #expect(DeleteSettings.clampRelatedArtistShare(0.02) == 0)
        #expect(DeleteSettings.clampRelatedArtistShare(.nan) == 0.30)
    }

    @Test("旧设置缺 key → 0.30；越界值读取即归一")
    func decodeFallback() throws {
        let legacy = try JSONDecoder().decode(DeleteSettings.self, from: Data("{}".utf8))
        #expect(legacy.relatedArtistShare == 0.30)

        let decoded = try JSONDecoder().decode(
            DeleteSettings.self,
            from: Data(#"{"relatedArtistShare":0.9}"#.utf8)
        )
        #expect(decoded.relatedArtistShare == 0.5)
    }
}
