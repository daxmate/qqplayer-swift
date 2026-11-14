//
//  ScrapeLogicTests.swift
//  QQPlayerTests
//
//  ScrapeLogic（web routers/tags.py + tag_scraper.scrape 纯逻辑移植，E1-S2）防回归测试：
//  - mergedCandidates：按 source_order 保序合并 / 空源跳过 / 未知源忽略
//  - isHighConfidence：空→false、唯一→true、文件无 artist→true、归一化匹配判定
//  - searchQuery：title 优先 / 文件名 stem 回落 / 去扩展名
//  - 字段映射唯一入口（2026-11-14）：fieldValues(from:) 全字段映射 + 空值归一；
//    makeTagWriteRequest 有值才写 + renameTemplate 透传
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

    // MARK: - mergedCandidates（枚举键版）

    @Test("mergedCandidates：按 sourceOrder 保序合并三源候选（含 itunes）")
    func mergedCandidatesKeepsSourceOrder() {
        let sources: [ScrapeSource: [ScrapeCandidate]] = [
            .netease: [
                Self.candidate(source: "netease", id: "n1"),
                Self.candidate(source: "netease", id: "n2"),
            ],
            .itunes: [Self.candidate(source: "itunes", id: "i1")],
            .musicbrainz: [Self.candidate(source: "musicbrainz", id: "m1")],
        ]

        let merged = ScrapeLogic.mergedCandidates(
            sources: sources,
            sourceOrder: [.netease, .itunes, .musicbrainz]
        )

        #expect(merged.map { $0.id } == ["n1", "n2", "i1", "m1"])
    }

    @Test("mergedCandidates：sourceOrder 倒序时结果倒序；候选对象原样透传")
    func mergedCandidatesRespectsCustomOrder() {
        let sources: [ScrapeSource: [ScrapeCandidate]] = [
            .netease: [Self.candidate(source: "netease", id: "n1")],
            .musicbrainz: [
                Self.candidate(source: "musicbrainz", id: "m1", artist: "MB Artist", year: 2001),
                Self.candidate(source: "musicbrainz", id: "m2", genre: "rock"),
            ],
        ]

        let merged = ScrapeLogic.mergedCandidates(
            sources: sources,
            sourceOrder: [.musicbrainz, .netease]
        )

        #expect(merged.map { $0.id } == ["m1", "m2", "n1"])
        #expect(merged[0].artist == "MB Artist")
        #expect(merged[0].year == 2001)
        #expect(merged[1].genre == "rock")
    }

    @Test("mergedCandidates：空源/缺失键跳过（该源候选为空）")
    func mergedCandidatesSkipsEmptySources() {
        let sources: [ScrapeSource: [ScrapeCandidate]] = [
            .musicbrainz: [Self.candidate(source: "musicbrainz", id: "m1")],
        ]

        // netease / itunes 未出现 → 跳过
        let merged = ScrapeLogic.mergedCandidates(
            sources: sources,
            sourceOrder: [.netease, .itunes, .musicbrainz]
        )

        #expect(merged.map { $0.id } == ["m1"])
        #expect(merged.map { $0.source } == ["musicbrainz"])
    }

    @Test("mergedCandidates：全部源缺失/空 → 空数组")
    func mergedCandidatesAllEmpty() {
        let merged = ScrapeLogic.mergedCandidates(
            sources: [:],
            sourceOrder: [.netease, .itunes, .musicbrainz]
        )
        #expect(merged.isEmpty)
    }

    // MARK: - ScrapeSource 注册表（唯一事实源）

    @Test("ScrapeSource：defaultOrder 含全部 case 且顺序 netease → itunes → musicbrainz")
    func scrapeSourceDefaultOrderCoversAllCases() {
        #expect(ScrapeSource.defaultOrder == [.netease, .itunes, .musicbrainz])
        #expect(Set(ScrapeSource.defaultOrder) == Set(ScrapeSource.allCases))
        // 本地化键派生自 rawValue
        #expect(ScrapeSource.itunes.localizationKey == "source_itunes")
    }

    @Test("ScrapeSource.resolvedOrder：过滤未知源 + 补齐缺失源（旧值无 itunes → 追加末尾）")
    func scrapeSourceResolvedOrderCompletesAndFilters() {
        #expect(ScrapeSource.resolvedOrder(from: ["netease", "musicbrainz"]) == [.netease, .musicbrainz, .itunes])
        #expect(ScrapeSource.resolvedOrder(from: ["musicbrainz", "qqmusic", "netease"]) == [.musicbrainz, .netease, .itunes])
        #expect(ScrapeSource.resolvedOrder(from: []) == [.netease, .itunes, .musicbrainz])
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

    // MARK: - 字段映射唯一入口（fieldValues / makeTagWriteRequest，2026-11-14）

    @Test("fieldValues：候选全部可用字段都映射进来（含 albumArtist/track/封面地址）")
    func fieldValuesMapsEveryField() {
        let cover = URL(string: "https://example.com/cover.jpg")
        let candidate = ScrapeCandidate(
            source: "musicbrainz",
            id: "mb-1",
            title: "晴天",
            artist: "周杰伦",
            album: "叶惠美",
            coverURL: cover,
            year: 2003,
            genre: "Pop",
            track: 3,
            albumArtist: "周杰伦",
            durationMs: 269_000
        )

        let values = ScrapeLogic.fieldValues(from: candidate)

        #expect(values.title == "晴天")
        #expect(values.artist == "周杰伦")
        #expect(values.album == "叶惠美")
        #expect(values.albumArtist == "周杰伦")
        #expect(values.genre == "Pop")
        #expect(values.year == 2003)
        #expect(values.trackNumber == 3)
        #expect(values.coverURL == cover)
        #expect(!values.isEmpty)
    }

    @Test("fieldValues：空串 / 纯空白归一为 nil；全空候选 isEmpty")
    func fieldValuesNormalizesBlankStrings() {
        let candidate = ScrapeCandidate(
            source: "netease",
            id: nil,
            title: "   ",
            artist: "",
            album: " \n ",
            coverURL: nil,
            year: nil,
            genre: "",
            track: nil,
            albumArtist: "  ",
            durationMs: nil
        )

        let values = ScrapeLogic.fieldValues(from: candidate)
        #expect(values.title == nil)
        #expect(values.artist == nil)
        #expect(values.album == nil)
        #expect(values.albumArtist == nil)
        #expect(values.genre == nil)
        #expect(values.isEmpty)
    }

    @Test("makeTagWriteRequest：有值才写（nil 字段保持 nil）+ renameTemplate 透传")
    func makeTagWriteRequestCarriesValuesAndTemplate() {
        let values = ScrapeFieldValues(
            title: "Title",
            artist: nil,
            album: "Album",
            albumArtist: nil,
            genre: "Rock",
            year: 1999,
            trackNumber: 2,
            coverURL: nil
        )

        let request = ScrapeLogic.makeTagWriteRequest(values: values, renameTemplate: "{artist} - {title}")
        #expect(request.title == "Title")
        #expect(request.artist == nil)
        #expect(request.album == "Album")
        #expect(request.albumArtist == nil)
        #expect(request.genre == "Rock")
        #expect(request.year == 1999)
        #expect(request.trackNumber == 2)
        // 封面数据由调用方异步补（唯一入口不碰网络）、改名模板原样透传
        #expect(request.coverData == nil)
        #expect(request.renameTemplate == "{artist} - {title}")

        // 批量语义：模板 nil = 不改名
        #expect(ScrapeLogic.makeTagWriteRequest(values: values, renameTemplate: nil).renameTemplate == nil)
    }

    // MARK: - validateCoverData（封面格式唯一判据；B1 2026-10-10）

    @Test("validateCoverData：合法 JPEG / PNG 通过")
    func validateCoverAcceptsJPEGAndPNG() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        #expect(ScrapeLogic.validateCoverData(jpeg))
        #expect(ScrapeLogic.validateCoverData(png))
    }

    @Test("validateCoverData：空 / GIF / 文本 / 截断一律拒")
    func validateCoverRejectsInvalid() {
        #expect(!ScrapeLogic.validateCoverData(Data()))
        // GIF（87a / 89a）
        #expect(!ScrapeLogic.validateCoverData(Data([0x47, 0x49, 0x46, 0x38, 0x39, 0x61])))
        // 普通文本
        #expect(!ScrapeLogic.validateCoverData(Data("not an image".utf8)))
        // 截断：只有前两字节（JPEG 需 3 字节魔数、PNG 需 4 字节）
        #expect(!ScrapeLogic.validateCoverData(Data([0xFF, 0xD8])))
        #expect(!ScrapeLogic.validateCoverData(Data([0x89, 0x50])))
    }
}
