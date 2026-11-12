//
//  RecommendationP3Tests.swift
//  QQPlayerTests
//
//  推荐 v2 P3 纯逻辑单测：模型理由校验 / 逐条回落、单批多样性目标、池不足放宽标记。
//  不打网络、不碰 MLX（模型只在 Mac 上跑，这里覆盖它与平台无关的口径）。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 夹具

private func p3Candidate(
    _ title: String,
    _ artist: String,
    album: String? = nil,
    year: Int? = 2020,
    genre: String? = nil,
    reasons: [String] = ["规则理由"]
) -> RecommendedCandidate {
    var item = RecommendedCandidate(
        title: title,
        artist: artist,
        album: album,
        year: year,
        source: .itunes
    )
    item.genre = genre
    item.reasons = reasons
    return item
}

private func p3Items(_ candidates: [RecommendedCandidate]) -> [RecommendationReasonItem] {
    candidates.map { RecommendationReasonItem(candidate: $0) }
}

// MARK: - 多样性

@Suite("推荐 P3 · 批次多样性")
struct RecommendationDiversityTests {
    @Test("15 首至少 8 个不同艺人（前段只有 4 个艺人时用后段补）")
    func minimumDistinctArtists() {
        // 前 15 首只来自 4 个艺人（每人 4 首、各带一张专辑，绕开「同专辑 ≤2」）；
        // 后面的艺人必须靠「不同艺人 ≥8」的替换轮补进来。
        var pool: [RecommendedCandidate] = []
        for artist in ["A", "B", "C", "D"] {
            for index in 1 ... 4 {
                pool.append(
                    p3Candidate("\(artist)-\(index)", artist, album: "\(artist)-Album-\(index)", year: nil)
                )
            }
        }
        for tag in ["E", "F", "G", "H", "I", "J"] {
            for index in 1 ... 3 {
                pool.append(p3Candidate("\(tag)-\(index)", tag, year: 2010 + index))
            }
        }

        let outcome = RecommendationBatchDiversity.select(pool)
        let artists = Set(outcome.candidates.map(\.artist))
        #expect(outcome.candidates.count == 15)
        #expect(artists.count >= 8)
        #expect(outcome.relaxed.isEmpty)
        for artist in artists {
            let count = outcome.candidates.filter { $0.artist == artist }.count
            #expect(count <= RecommendationBatchPolicy.maxSongsPerArtist)
        }
    }

    @Test("同 decade 超过 9 首：放宽并标记 decade（不静默）")
    func decadeRelaxedIsMarked() {
        let pool = (1 ... 20).map { p3Candidate("Song \($0)", "Artist \($0)", year: 2004) }

        let outcome = RecommendationBatchDiversity.select(pool)
        #expect(outcome.candidates.count == 15)
        #expect(outcome.relaxed.contains(.decade))
        #expect(outcome.candidates.allSatisfy { $0.year == 2004 })
    }

    @Test("同 genre 不超过 9 首；缺 genre 的条目不参与该约束")
    func genreCapIgnoresMissingGenre() {
        var pool: [RecommendedCandidate] = []
        for index in 1 ... 20 {
            pool.append(p3Candidate("Rock \(index)", "Rock Artist \(index)", year: 1990, genre: "Rock"))
        }
        for index in 1 ... 10 {
            pool.append(p3Candidate("Plain \(index)", "Plain Artist \(index)", year: 1980))
        }

        let outcome = RecommendationBatchDiversity.select(pool)
        let rock = outcome.candidates.filter { $0.genre == "Rock" }.count
        #expect(outcome.candidates.count == 15)
        #expect(rock <= RecommendationBatchPolicy.maxSongsPerGenre)
        #expect(!outcome.relaxed.contains(.genre))
    }

    @Test("池不足 8 个艺人：放宽并标记 artists")
    func smallPoolMarksArtistsRelaxed() {
        let pool = (1 ... 5).map {
            p3Candidate("Song \($0)", "Only \($0 % 2)", album: "Album \($0)")
        }

        let outcome = RecommendationBatchDiversity.select(pool)
        #expect(outcome.candidates.count == 5)
        #expect(outcome.relaxed.contains(.artists))
    }

    @Test("会话池透传多样性报告：15 首 / 8 艺人 / 无放宽")
    func sessionExposesReport() {
        let pool = (0 ..< 12).flatMap { artist in
            (1 ... 3).map { p3Candidate("S\(artist)-\($0)", "Artist \(artist)", year: nil) }
        }
        var session = RecallSession(pool: pool)
        let batch = session.nextBatch()
        #expect(batch.count == 15)
        #expect(session.lastBatchDiversity.distinctArtists >= 8)
        #expect(!session.lastBatchDiversity.isRelaxed)
    }
}

// MARK: - 理由校验

@Suite("推荐 P3 · 理由校验与回落")
struct RecommendationReasonValidationTests {
    @Test("默认来源原样返回规则理由（两端行为不变）")
    func ruleProviderKeepsRules() async {
        let candidates = [p3Candidate("Title", "Artist", reasons: ["常听 Artist"])]
        let map = await RuleRecommendationReasonProvider().reasons(for: p3Items(candidates), locale: .current)
        #expect(map[RecommendationKey.normalize(title: "Title", artist: "Artist")] == ["常听 Artist"])
    }

    @Test("合法 JSON 一批解析：条目按序映射且不接受多余残片")
    func parsesBatch() {
        let items = p3Items([p3Candidate("Title", "Artist"), p3Candidate("Other", "Band")])
        let text = #"{ "1": "Artist 的作品，与你常听的口味接近", "2": "Band 的新歌" }"#
        let map = RecommendationReasonParser.parse(text, items: items)
        #expect(map.count == 2)
        #expect(map[RecommendationKey.normalize(title: "Title", artist: "Artist")]?.first?.hasPrefix("Artist") == true)
    }

    @Test("超长 / 引号 / JSON 残片被拒")
    func rejectsMarkupAndLongText() {
        let item = p3Items([p3Candidate("Title", "Artist")])[0]
        let allowed = RecommendationReasonParser.allowedNames(in: [item])
        #expect(RecommendationReasonParser.validate(String(repeating: "长", count: 61), item: item, allowedNames: allowed) == nil)
        #expect(RecommendationReasonParser.validate("{\"1\":\"x\"}", item: item, allowedNames: allowed) == nil)
        #expect(RecommendationReasonParser.validate("他说 \"好听\"", item: item, allowedNames: allowed) == nil)
        #expect(RecommendationReasonParser.validate("曲库里的老歌", item: item, allowedNames: allowed) != nil)
    }

    @Test("引用输入之外的名字被拒；引用本批名字通过")
    func rejectsFabricatedNames() {
        let item = p3Items([p3Candidate("Title", "Artist")])[0]
        let allowed = RecommendationReasonParser.allowedNames(in: [item])
        #expect(RecommendationReasonParser.validate("来自「不存在的乐队」", item: item, allowedNames: allowed) == nil)
        #expect(RecommendationReasonParser.validate("「Artist」的早期作品", item: item, allowedNames: allowed) != nil)
    }

    @Test("年份不符 / 缺失年份时编年份被拒")
    func rejectsFabricatedYear() {
        let item = p3Items([p3Candidate("Title", "Artist", year: 1998)])[0]
        let allowed = RecommendationReasonParser.allowedNames(in: [item])
        #expect(RecommendationReasonParser.validate("1998 年的经典", item: item, allowedNames: allowed) != nil)
        #expect(RecommendationReasonParser.validate("1972 年的经典", item: item, allowedNames: allowed) == nil)

        let unknownYear = p3Items([p3Candidate("Title", "Artist", year: nil)])[0]
        let allowedUnknown = RecommendationReasonParser.allowedNames(in: [unknownYear])
        #expect(RecommendationReasonParser.validate("2001 年的作品", item: unknownYear, allowedNames: allowedUnknown) == nil)
    }

    @Test("模型失败 / 空结果 → 逐条回落规则理由（理由不清空）")
    func emptyModelResultKeepsRules() {
        let candidates = [p3Candidate("Title", "Artist", reasons: ["常听 Artist"])]
        let bound = RecommendationReasonBinder.bind([:], to: candidates)
        #expect(bound.replaced == 0)
        #expect(bound.candidates.first?.reasons == ["常听 Artist"])
    }

    @Test("部分合格 → mixed：只替换通过校验的条目")
    func partialReplaceKeepsOthers() {
        let first = p3Candidate("Title", "Artist", reasons: ["规则一"])
        let second = p3Candidate("Other", "Band", reasons: ["规则二"])
        let items = p3Items([first, second])
        let text = #"{ "1": "「Artist」的推荐" }"#
        let map = RecommendationReasonParser.parse(text, items: items)
        let bound = RecommendationReasonBinder.bind(map, to: [first, second])

        #expect(bound.replaced == 1)
        #expect(bound.isPartial)
        #expect(bound.candidates[0].reasons == ["「Artist」的推荐"])
        #expect(bound.candidates[1].reasons == ["规则二"])
    }
}
