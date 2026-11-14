//
//  ScrapeBatchServiceTests.swift
//  QQPlayerTests
//
//  ScrapeBatchService.decideWrite（原 web routers/tags.py _process_batch_file 决策段，
//  2026-11-14 按用户新口径改造）防回归测试：纯函数无网络无文件 IO。
//  覆盖：文件缺失/格式不支持/无候选 → skip 原因；**按源优先级合并后的第一个候选
//  直接写**（多候选 / 艺人不匹配都不再跳过）；**两种模式写入字段完全一致**
//  （title/artist/album/albumArtist/year/genre/track + 封面地址透传）；
//  全空候选 → skip；批量恒不改名。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite(.serialized)
struct ScrapeBatchServiceTests {
    /// 构造候选（未指定字段默认带一组可写值）
    private static func candidate(
        source: String = "musicbrainz",
        id: String = "id-1",
        title: String? = "Title",
        artist: String? = "Artist",
        album: String? = "Album",
        albumArtist: String? = "Album Artist",
        year: Int? = nil,
        genre: String? = nil,
        track: Int? = 3,
        coverURL: URL? = nil
    ) -> ScrapeCandidate {
        ScrapeCandidate(
            source: source,
            id: id,
            title: title,
            artist: artist,
            album: album,
            coverURL: coverURL,
            year: year,
            genre: genre,
            track: track,
            albumArtist: albumArtist,
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

    // MARK: - 首候选直接写（无高置信度门槛，全部字段）

    @Test("paths 唯一候选 → 写入全部可用字段（含 track/albumArtist）")
    func pathsSingleCandidateWritesAllFields() {
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
        #expect(values.albumArtist == "Album Artist")
        #expect(values.year == 1999)
        #expect(values.genre == "Rock")
        #expect(values.trackNumber == 3)
    }

    @Test("paths 多候选且首候选 artist 与文件不匹配 → 仍写首候选（不再判高置信度）")
    func pathsMultipleCandidatesStillWriteFirst() {
        let first = Self.candidate(id: "1", title: "First", artist: "Stefanie Sun")
        let second = Self.candidate(id: "2", title: "Second", artist: "Other Artist")
        let decision = ScrapeBatchService.decideWrite(
            libraryMode: false,
            fileExists: true,
            formatSupported: true,
            candidates: [first, second],
            fileArtist: "Someone Else"
        )
        guard case .write(let values) = decision else {
            Issue.record("期望 write（用户口径：第一个候选直接写），实际 \(decision)")
            return
        }
        #expect(values.title == "First")
        #expect(values.artist == "Stefanie Sun")
    }

    @Test("封面地址透传：候选有 coverURL → 写入值带上（下载校验由调用方异步做）")
    func coverURLPassthrough() {
        let cover = URL(string: "https://example.com/front.jpg")
        let decision = ScrapeBatchService.decideWrite(
            libraryMode: false,
            fileExists: true,
            formatSupported: true,
            candidates: [Self.candidate(coverURL: cover)],
            fileArtist: nil
        )
        guard case .write(let values) = decision else {
            Issue.record("期望 write，实际 \(decision)")
            return
        }
        #expect(values.coverURL == cover)
    }

    @Test("首候选全部字段为空（含封面）→ skip 候选无有效字段")
    func candidateWithoutAnyValuesSkips() {
        let candidate = Self.candidate(
            title: nil,
            artist: nil,
            album: nil,
            albumArtist: nil,
            year: nil,
            genre: nil,
            track: nil,
            coverURL: nil
        )
        let decision = ScrapeBatchService.decideWrite(
            libraryMode: false,
            fileExists: true,
            formatSupported: true,
            candidates: [candidate],
            fileArtist: nil
        )
        #expect(decision == .skip(reason: ScrapeBatchService.SkipReason.noWritableFields))
    }

    @Test("字段空白串归一化为不写（trimmed nil）")
    func blankFieldsTrimmedToNil() {
        let candidate = Self.candidate(title: "   ", artist: "  ", album: "Album", albumArtist: " ", year: nil, genre: "")
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
        #expect(values.albumArtist == nil)
        #expect(values.genre == nil)
    }

    // MARK: - library 模式（字段集已与 paths 统一，仅目标集不同）

    @Test("library 模式也写全部字段：候选只带 year → title/artist/album/track 照写")
    func libraryModeWritesAllFieldsToo() {
        let candidate = Self.candidate(title: "Library Title", year: 1999, genre: nil)
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
        #expect(values.title == "Library Title")
        #expect(values.artist == "Artist")
        #expect(values.album == "Album")
        #expect(values.albumArtist == "Album Artist")
        #expect(values.trackNumber == 3)
    }

    @Test("library 模式不判高置信：多候选 artist 不匹配也写首候选")
    func libraryModeIgnoresArtistMismatch() {
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
        #expect(values.artist == "Stefanie Sun")
    }

    // MARK: - 批量恒不改名

    @Test("批量写入请求恒不改名：renameTemplate 为 nil（字段仍照写）")
    func batchWriteRequestNeverRenames() {
        let values = ScrapeFieldValues(
            title: "Title",
            artist: "Artist",
            album: "Album",
            albumArtist: "Album Artist",
            genre: "Rock",
            year: 1999,
            trackNumber: 3,
            coverURL: nil
        )
        let request = ScrapeBatchService.makeBatchWriteRequest(values: values)
        #expect(request.renameTemplate == nil)
        #expect(request.title == "Title")
        #expect(request.trackNumber == 3)
    }
}
