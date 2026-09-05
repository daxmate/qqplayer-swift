//
//  ScrapeLogicTests.swift
//  QQPlayerTests
//
//  ScrapeLogic（web routers/tags.py + tag_scraper.scrape 纯逻辑移植，E1-S2）防回归测试：
//  - mergedCandidates：按 source_order 保序合并 / 空源跳过 / 未知源忽略
//  - isHighConfidence：空→false、唯一→true、文件无 artist→true、归一化匹配判定
//  - searchQuery：title 优先 / 文件名 stem 回落 / 去扩展名
//  纯函数，无网络。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite(.serialized)
struct ScrapeLogicTests {
    /// 构造候选（未指定字段默认缺省）
    private static func candidate(
        source: String = "musicbrainz",
        id: String = "id-1",
        title: String = "Title",
        artist: String? = nil,
        year: Int? = nil,
        genre: String? = nil
    ) -> ScrapeCandidate {
        ScrapeCandidate(
            source: source,
            id: id,
            title: title,
            artist: artist,
            album: nil,
            coverURL: nil,
            year: year,
            genre: genre,
            track: nil,
            albumArtist: nil,
            durationMs: nil
        )
    }

    // MARK: - mergedCandidates

    @Test("mergedCandidates：按 source_order 保序合并两源候选")
    func mergedCandidatesKeepsSourceOrder() {
        let netease = [
            Self.candidate(source: "netease", id: "n1"),
            Self.candidate(source: "netease", id: "n2"),
        ]
        let musicbrainz = [Self.candidate(source: "musicbrainz", id: "m1")]

        let merged = ScrapeLogic.mergedCandidates(
            netease: netease,
            musicbrainz: musicbrainz,
            sourceOrder: ["netease", "musicbrainz"]
        )

        #expect(merged.map { $0.id } == ["n1", "n2", "m1"])
    }

    @Test("mergedCandidates：source_order 倒序时结果倒序；候选对象原样透传")
    func mergedCandidatesRespectsCustomOrder() {
        let netease = [Self.candidate(source: "netease", id: "n1")]
        let musicbrainz = [
            Self.candidate(source: "musicbrainz", id: "m1", artist: "MB Artist", year: 2001),
            Self.candidate(source: "musicbrainz", id: "m2", genre: "rock"),
        ]

        let merged = ScrapeLogic.mergedCandidates(
            netease: netease,
            musicbrainz: musicbrainz,
            sourceOrder: ["musicbrainz", "netease"]
        )

        #expect(merged.map { $0.id } == ["m1", "m2", "n1"])
        #expect(merged[0].artist == "MB Artist")
        #expect(merged[0].year == 2001)
        #expect(merged[1].genre == "rock")
    }

    @Test("mergedCandidates：空源跳过；未知源忽略")
    func mergedCandidatesSkipsEmptyAndUnknownSources() {
        let musicbrainz = [Self.candidate(source: "musicbrainz", id: "m1")]

        // netease 空 → 跳过；source_order 带未知源 "qqmusic" → 忽略
        let merged = ScrapeLogic.mergedCandidates(
            netease: [],
            musicbrainz: musicbrainz,
            sourceOrder: ["netease", "qqmusic", "musicbrainz"]
        )

        #expect(merged.map { $0.id } == ["m1"])
        #expect(merged.map { $0.source } == ["musicbrainz"])
    }

    @Test("mergedCandidates：两源皆空 → 空数组")
    func mergedCandidatesAllEmpty() {
        let merged = ScrapeLogic.mergedCandidates(
            netease: [],
            musicbrainz: [],
            sourceOrder: ["netease", "musicbrainz"]
        )
        #expect(merged.isEmpty)
    }

    // MARK: - isHighConfidence

    @Test("isHighConfidence：候选空 → false（无论文件 artist 是否有）")
    func highConfidenceEmptyCandidates() {
        #expect(!ScrapeLogic.isHighConfidence(candidates: [], fileArtist: nil))
        #expect(!ScrapeLogic.isHighConfidence(candidates: [], fileArtist: "Some Artist"))
    }

    @Test("isHighConfidence：候选唯一 → true（即使 artist 与文件不符——唯一候选直接采用）")
    func highConfidenceSingleCandidate() {
        let candidates = [Self.candidate(artist: "Different Artist")]
        #expect(ScrapeLogic.isHighConfidence(candidates: candidates, fileArtist: "File Artist"))
        #expect(ScrapeLogic.isHighConfidence(candidates: candidates, fileArtist: nil))
    }

    @Test("isHighConfidence：多候选但文件 artist 为空 → true（取首候选）")
    func highConfidenceNoFileArtist() {
        let candidates = [
            Self.candidate(artist: "Taylor Swift"),
            Self.candidate(id: "id-2", artist: "Katy Perry"),
        ]
        #expect(ScrapeLogic.isHighConfidence(candidates: candidates, fileArtist: nil))
        #expect(ScrapeLogic.isHighConfidence(candidates: candidates, fileArtist: ""))
    }

    @Test("isHighConfidence：多候选 → 首候选 artist 与文件 artist 归一化匹配判定")
    func highConfidenceArtistMatchDecides() {
        let matched = [
            Self.candidate(artist: "Taylor Swift"),
            Self.candidate(id: "id-2", artist: "Katy Perry"),
        ]
        #expect(ScrapeLogic.isHighConfidence(candidates: matched, fileArtist: "taylor swift"))

        let mismatched = [
            Self.candidate(artist: "Ed Sheeran"),
            Self.candidate(id: "id-2", artist: "Katy Perry"),
        ]
        #expect(!ScrapeLogic.isHighConfidence(candidates: mismatched, fileArtist: "Taylor Swift"))

        // 首候选 artist 缺失（nil）→ 归一化空 → 不匹配
        let missingArtist = [
            Self.candidate(artist: nil),
            Self.candidate(id: "id-2", artist: "Katy Perry"),
        ]
        #expect(!ScrapeLogic.isHighConfidence(candidates: missingArtist, fileArtist: "Taylor Swift"))
    }

    // MARK: - searchQuery

    @Test("searchQuery：title 非空 → 直接使用 title")
    func searchQueryUsesTitle() {
        #expect(ScrapeLogic.searchQuery(title: "晴天", fileName: "song.mp3") == "晴天")
        #expect(ScrapeLogic.searchQuery(title: "Hello World", fileName: "song.mp3") == "Hello World")
    }

    @Test("searchQuery：title 空/nil → 文件名去扩展名取末段")
    func searchQueryFallsBackToFileStem() {
        #expect(ScrapeLogic.searchQuery(title: nil, fileName: "song.mp3") == "song")
        #expect(ScrapeLogic.searchQuery(title: "", fileName: "song.mp3") == "song")
        #expect(ScrapeLogic.searchQuery(title: nil, fileName: "/music/album/01 intro.flac") == "01 intro")
        #expect(ScrapeLogic.searchQuery(title: nil, fileName: "noext") == "noext")
        #expect(ScrapeLogic.searchQuery(title: nil, fileName: "archive.tar.gz") == "archive.tar")
    }
}
