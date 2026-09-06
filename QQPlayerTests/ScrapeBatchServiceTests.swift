//
//  ScrapeBatchServiceTests.swift
//  QQPlayerTests
//
//  ScrapeBatchService.decideWrite（web routers/tags.py _process_batch_file 决策段
//  移植，E1-S4）防回归测试：纯函数无网络无文件 IO。
//  覆盖：文件缺失/格式不支持/无候选/非高置信 → skip 原因；paths 模式写入字段集
//  （title/artist/album/year/genre，不含 cover/track/album_artist）；library 模式
//  只补 year/genre 且不判高置信；首候选字段全空 → skip。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite(.serialized)
struct ScrapeBatchServiceTests {
    /// 构造候选（未指定字段默认缺省）
    private static func candidate(
        source: String = "musicbrainz",
        id: String = "id-1",
        title: String? = "Title",
        artist: String? = "Artist",
        album: String? = "Album",
        year: Int? = nil,
        genre: String? = nil
    ) -> ScrapeCandidate {
        ScrapeCandidate(
            source: source,
            id: id,
            title: title,
            artist: artist,
            album: album,
            coverURL: nil,
            year: year,
            genre: genre,
            track: 3,
            albumArtist: "Album Artist",
            durationMs: 200_000
        )
    }

    // MARK: - 前置预检

    @Test("文件不存在 → skip 文件不存在（paths 与 library 同源判定）")
    func missingFileSkips() {
        let decision = ScrapeBatchService.decideWrite(
            libraryMode: false,
            fileExists: false,
            formatSupported: true,
            candidates: [Self.candidate()],
            fileArtist: nil
        )
        #expect(decision == .skip(reason: ScrapeBatchService.SkipReason.fileMissing))
    }

    @Test("格式不支持 → skip 格式不支持（不进写流程）")
    func unsupportedFormatSkips() {
        let decision = ScrapeBatchService.decideWrite(
            libraryMode: false,
            fileExists: true,
            formatSupported: false,
            candidates: [Self.candidate()],
            fileArtist: nil
        )
        #expect(decision == .skip(reason: ScrapeBatchService.SkipReason.unsupportedFormat))
    }

    @Test("无候选 → skip 无候选（两种模式一致）")
    func noCandidatesSkips() {
        for libraryMode in [false, true] {
            let decision = ScrapeBatchService.decideWrite(
                libraryMode: libraryMode,
                fileExists: true,
                formatSupported: true,
                candidates: [],
                fileArtist: nil
            )
            #expect(decision == .skip(reason: ScrapeBatchService.SkipReason.noCandidates))
        }
    }

    // MARK: - paths 模式（高置信门禁 + BATCH_WRITABLE_FIELDS）

    @Test("paths 唯一候选 → 写入 title/artist/album/year/genre，不含 track/album_artist/封面")
    func pathsSingleCandidateWritesWritableFields() {
        let candidate = Self.candidate(year: 1999, genre: "Rock")
        let decision = ScrapeBatchService.decideWrite(
            libraryMode: false,
            fileExists: true,
            formatSupported: true,
            candidates: [candidate],
            fileArtist: nil
        )
        guard case .write(let values) = decision else {
            Issue.record("期望 write，实际 \(decision)")
            return
        }
        #expect(values.title == "Title")
        #expect(values.artist == "Artist")
        #expect(values.album == "Album")
        #expect(values.year == 1999)
        #expect(values.genre == "Rock")
    }

    @Test("paths 多候选且首候选 artist 与文件不匹配 → skip 候选不唯一")
    func pathsMultipleCandidatesNotHighConfidenceSkips() {
        let first = Self.candidate(id: "1", artist: "Stefanie Sun")
        let second = Self.candidate(id: "2", artist: "Other Artist")
        let decision = ScrapeBatchService.decideWrite(
            libraryMode: false,
            fileExists: true,
            formatSupported: true,
            candidates: [first, second],
            fileArtist: "Someone Else"
        )
        #expect(decision == .skip(reason: ScrapeBatchService.SkipReason.notHighConfidence))
    }

    @Test("paths 多候选但首候选 artist 与文件归一化匹配 → 写入")
    func pathsMultipleCandidatesMatchingArtistWrites() {
        let first = Self.candidate(id: "1", artist: "Stefanie Sun")
        let second = Self.candidate(id: "2", artist: "Other Artist")
        let decision = ScrapeBatchService.decideWrite(
            libraryMode: false,
            fileExists: true,
            formatSupported: true,
            candidates: [first, second],
            fileArtist: "stefanie sun"
        )
        guard case .write = decision else {
            Issue.record("期望 write，实际 \(decision)")
            return
        }
    }

    @Test("paths 首候选在可写字段内全无有效值 → skip 候选无有效字段")
    func pathsCandidateWithoutWritableValuesSkips() {
        // 候选只带 track/albumArtist（不在 BATCH_WRITABLE_FIELDS）→ 无可写内容
        let candidate = Self.candidate(title: nil, artist: nil, album: nil, year: nil, genre: nil)
        let decision = ScrapeBatchService.decideWrite(
            libraryMode: false,
            fileExists: true,
            formatSupported: true,
            candidates: [candidate],
            fileArtist: nil
        )
        #expect(decision == .skip(reason: ScrapeBatchService.SkipReason.noWritableFields))
    }

    @Test("paths 字段空白串归一化为不写（trimmed nil）")
    func pathsBlankFieldsTrimmedToNil() {
        let candidate = Self.candidate(title: "   ", artist: "  ", album: "Album", year: nil, genre: "")
        let decision = ScrapeBatchService.decideWrite(
            libraryMode: false,
            fileExists: true,
            formatSupported: true,
            candidates: [candidate],
            fileArtist: nil
        )
        guard case .write(let values) = decision else {
            Issue.record("期望 write，实际 \(decision)")
            return
        }
        #expect(values.title == nil)
        #expect(values.artist == nil)
        #expect(values.album == "Album")
        #expect(values.genre == nil)
    }

    // MARK: - library 模式（只补 year/genre、不判高置信）

    @Test("library 候选只带 year → 只写 year，title/artist/album/genre 不写")
    func libraryModeWritesYearOnly() {
        let candidate = Self.candidate(title: "Should Not Write", year: 1999, genre: nil)
        let decision = ScrapeBatchService.decideWrite(
            libraryMode: true,
            fileExists: true,
            formatSupported: true,
            candidates: [candidate],
            fileArtist: nil
        )
        guard case .write(let values) = decision else {
            Issue.record("期望 write，实际 \(decision)")
            return
        }
        #expect(values.year == 1999)
        #expect(values.genre == nil)
        #expect(values.title == nil)
        #expect(values.artist == nil)
        #expect(values.album == nil)
    }

    @Test("library 候选只带 genre → 只写 genre")
    func libraryModeWritesGenreOnly() {
        let candidate = Self.candidate(year: nil, genre: "Jazz")
        let decision = ScrapeBatchService.decideWrite(
            libraryMode: true,
            fileExists: true,
            formatSupported: true,
            candidates: [candidate],
            fileArtist: nil
        )
        guard case .write(let values) = decision else {
            Issue.record("期望 write，实际 \(decision)")
            return
        }
        #expect(values.year == nil)
        #expect(values.genre == "Jazz")
    }

    @Test("library 候选无 year 也无 genre → skip 候选无 year/genre")
    func libraryModeCandidateWithoutYearGenreSkips() {
        let candidate = Self.candidate(title: "Title", artist: "Artist", year: nil, genre: nil)
        let decision = ScrapeBatchService.decideWrite(
            libraryMode: true,
            fileExists: true,
            formatSupported: true,
            candidates: [candidate],
            fileArtist: nil
        )
        #expect(decision == .skip(reason: ScrapeBatchService.SkipReason.noYearGenre))
    }

    @Test("library 模式不判高置信：多候选 artist 不匹配也写首候选 year")
    func libraryModeIgnoresHighConfidenceGate() {
        let first = Self.candidate(id: "1", artist: "Stefanie Sun", year: 2000)
        let second = Self.candidate(id: "2", artist: "Other", year: 2001)
        let decision = ScrapeBatchService.decideWrite(
            libraryMode: true,
            fileExists: true,
            formatSupported: true,
            candidates: [first, second],
            fileArtist: "Someone Else"
        )
        guard case .write(let values) = decision else {
            Issue.record("期望 write，实际 \(decision)")
            return
        }
        #expect(values.year == 2000)
    }
}
