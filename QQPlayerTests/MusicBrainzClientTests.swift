//
//  MusicBrainzClientTests.swift
//  QQPlayerTests
//
//  MusicBrainzClient（web backend/tag_scraper.py 移植，E1-S2）防回归测试：
//  - recording 降级链：精确 → fuzzy → title 关键词，任一步有结果即停；每阶段前 sleep
//  - artist 排序加分（稳定序）；候选字段提取（year/genre/track/album_artist/joinphrase）
//  - 容错：MB 挂掉（500/网络错）→ 空数组不 throw；坏 recording 跳过不炸整批
//  - CAA：3xx → URL、404 → nil、同 MBID 缓存（请求计数 1）
//  - iTunes fallback：artworkUrl100 → 600x600
//  - artistMatches 归一化（大小写/标点/空白/feat. 部分/繁简）
//
//  隔离说明：本文件自带 MBMockURLProtocol（独立 URLProtocol 类，静态状态只属于自己），
//  与其他 suite 共用的 MockURLProtocol 互不干扰，跨 suite 可并行；suite 内 .serialized
//  （MBMockURLProtocol 静态 handler/receivedRequests 是进程级状态）。
//

import Foundation
import Testing

@testable import QQPlayer

/// MB/iTunes/CAA 测试专用 URLProtocol mock（实现同 MockURLProtocol，静态状态独立）
final class MBMockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?
    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []

    static func reset() {
        handler = nil
        receivedRequests = []
    }

    static func response(
        status: Int,
        headers: [String: String] = [:],
        data: Data = Data(),
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        return (response, data)
    }

    static func jsonResponse(_ body: Data, status: Int = 200, for request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, body)
    }

    // MARK: - URLProtocol

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        MBMockURLProtocol.receivedRequests.append(request)
        guard let handler = MBMockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// sleep 次数计数（注入 sleep 闭包）
private final class SleepCounter: @unchecked Sendable {
    var value = 0
    init() {}
}

@Suite(.serialized)
struct MusicBrainzClientTests {
    // MARK: - 基建

    /// 注入 MBMockURLProtocol 的 client；sleep 默认 no-op（禁真实等待）
    private static func makeClient(sleep: ((TimeInterval) async throws -> Void)? = nil) -> MusicBrainzClient {
        MusicBrainzClient(sleep: sleep ?? { _ in }, protocolClasses: [MBMockURLProtocol.self])
    }

    private static let caaBase = "https://coverartarchive.org/release"

    private static func caaURL(_ mbid: String) -> String {
        "\(caaBase)/\(mbid)/front"
    }

    /// CAA 常规响应：3xx 重定向到 archive.org（表示有封面）
    private static func caaRedirect(_ mbid: String, for request: URLRequest) -> (HTTPURLResponse, Data) {
        MBMockURLProtocol.response(
            status: 302,
            headers: ["Location": "https://archive.org/download/\(mbid)/cover.jpg"],
            for: request
        )
    }

    // MARK: - 请求过滤

    private static func hostRequests(_ host: String) -> [URLRequest] {
        MBMockURLProtocol.receivedRequests.filter { $0.url?.host == host }
    }

    private static func mbRequests() -> [URLRequest] {
        hostRequests("musicbrainz.org")
    }

    private static func caaRequests() -> [URLRequest] {
        hostRequests("coverartarchive.org")
    }

    private static func itunesRequests() -> [URLRequest] {
        hostRequests("itunes.apple.com")
    }

    /// 取 MB ws/2 query 参数（解码后，如 recording:"Love Story"）
    private static func mbQuery(_ request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "query" })?.value
    }

    // MARK: - JSON fixture

    private static func recordingsData(_ recordings: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["recordings": recordings])
    }

    /// 基础 recording（无 releases → 不触发 CAA 请求）
    private static func baseRecording(
        id: String = "rec-1",
        title: String = "Love Story",
        artistCredit: [[String: Any]] = [["name": "Taylor Swift"]]
    ) -> [String: Any] {
        var dict: [String: Any] = ["id": id, "title": title]
        if !artistCredit.isEmpty {
            dict["artist-credit"] = artistCredit
        }
        return dict
    }

    /// 全字段 recording：track 取 releases[0].media（无需 id 的 Decoy），
    /// album/year/cover/album_artist 取首个有 id 的 release（Fearless）
    private static func richRecording() -> [String: Any] {
        [
            "id": "rec-1",
            "title": "Love Story",
            "first-release-date": "2008-07-15",
            "artist-credit": [
                ["name": "Artist A", "joinphrase": " feat. "],
                ["name": "Artist B"],
            ],
            "tags": [
                ["count": 1, "name": "pop"],
                ["count": 3, "name": "rock"],
                ["count": 2, "name": "indie"],
            ],
            "releases": [
                [
                    "title": "Decoy Album",
                    "media": [
                        [
                            "position": 1,
                            "format": "CD",
                            "track": [
                                ["number": " 7", "recording": ["id": "rec-1", "title": "Love Story"]],
                                ["number": "2", "recording": ["id": "other-rec"]],
                            ],
                        ],
                    ],
                ],
                [
                    "id": "rel-1",
                    "title": "Fearless",
                    "date": "2009-03-03",
                    "artist-credit": [["name": "Artist A"]],
                    "media": [],
                ],
            ],
        ]
    }

    // MARK: - 降级链阶段

    @Test("降级链：精确阶段命中 → 只发阶段 1（不再 fuzzy/keyword），sleep 1 次")
    func searchStopsAtExactHit() async throws {
        MBMockURLProtocol.reset()
        let sleeps = SleepCounter()
        let client = Self.makeClient(sleep: { _ in sleeps.value += 1 })
        MBMockURLProtocol.handler = { request in
            guard let host = request.url?.host else { throw URLError(.badURL) }
            switch host {
            case "musicbrainz.org":
                return MBMockURLProtocol.jsonResponse(Self.recordingsData([Self.baseRecording()]), for: request)
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let candidates = try await client.searchMusicBrainz(title: "Love Story", artist: "")

        #expect(candidates.count == 1)
        let requests = Self.mbRequests()
        #expect(requests.count == 1)
        #expect(Self.mbQuery(requests[0]) == "recording:\"Love Story\"")
        #expect(sleeps.value == 1)
    }

    @Test("降级链：阶段 1 空 → 阶段 2 fuzzy 命中 → 不再请求阶段 3")
    func searchFallsBackToFuzzy() async throws {
        MBMockURLProtocol.reset()
        let sleeps = SleepCounter()
        let client = Self.makeClient(sleep: { _ in sleeps.value += 1 })
        MBMockURLProtocol.handler = { request in
            guard request.url?.host == "musicbrainz.org" else { throw URLError(.unsupportedURL) }
            let query = Self.mbQuery(request) ?? ""
            // 只有 fuzzy（~ 结尾）阶段有结果
            if query.hasSuffix("~") {
                return MBMockURLProtocol.jsonResponse(Self.recordingsData([Self.baseRecording()]), for: request)
            }
            return MBMockURLProtocol.jsonResponse(Self.recordingsData([]), for: request)
        }

        let candidates = try await client.searchMusicBrainz(title: "Love Story", artist: "")

        #expect(candidates.count == 1)
        let requests = Self.mbRequests()
        #expect(requests.count == 2)
        #expect(Self.mbQuery(requests[0]) == "recording:\"Love Story\"")
        #expect(Self.mbQuery(requests[1]) == "recording:\"Love Story\"~")
        #expect(sleeps.value == 2)
    }

    @Test("降级链：阶段 1、2 空 → 阶段 3 title 关键词兜底")
    func searchFallsBackToKeyword() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard request.url?.host == "musicbrainz.org" else { throw URLError(.unsupportedURL) }
            let query = Self.mbQuery(request) ?? ""
            if query.hasPrefix("title:") {
                return MBMockURLProtocol.jsonResponse(Self.recordingsData([Self.baseRecording()]), for: request)
            }
            return MBMockURLProtocol.jsonResponse(Self.recordingsData([]), for: request)
        }

        let candidates = try await client.searchMusicBrainz(title: "Love Story", artist: "")

        #expect(candidates.count == 1)
        let requests = Self.mbRequests()
        #expect(requests.count == 3)
        #expect(Self.mbQuery(requests[2]) == "title:Love Story")
    }

    @Test("降级链：三个阶段都空 → 空数组（3 次请求）")
    func searchAllStagesEmpty() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard request.url?.host == "musicbrainz.org" else { throw URLError(.unsupportedURL) }
            return MBMockURLProtocol.jsonResponse(Self.recordingsData([]), for: request)
        }

        let candidates = try await client.searchMusicBrainz(title: "Nothing Here", artist: "")

        #expect(candidates.isEmpty)
        #expect(Self.mbRequests().count == 3)
    }

    @Test("降级链：空/空白 title → 不发请求直接空数组")
    func searchEmptyTitleReturnsEmpty() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            Issue.record("不应发出请求: \(request.url?.absoluteString ?? "")")
            throw URLError(.unsupportedURL)
        }
        let candidates = try await client.searchMusicBrainz(title: "   ", artist: "")
        #expect(candidates.isEmpty)
        #expect(Self.mbRequests().isEmpty)
    }

    // MARK: - 容错

    @Test("MB 500：返回空数组，不再打后续阶段（1 次请求）")
    func searchMB500ReturnsEmpty() async throws {
        MBMockURLProtocol.reset()
        let sleeps = SleepCounter()
        let client = Self.makeClient(sleep: { _ in sleeps.value += 1 })
        MBMockURLProtocol.handler = { request in
            guard request.url?.host == "musicbrainz.org" else { throw URLError(.unsupportedURL) }
            return MBMockURLProtocol.response(status: 500, for: request)
        }

        let candidates = try await client.searchMusicBrainz(title: "Love Story", artist: "")

        #expect(candidates.isEmpty)
        #expect(Self.mbRequests().count == 1)
        #expect(sleeps.value == 1)
    }

    @Test("MB 网络错误：返回空数组不 throw")
    func searchNetworkErrorReturnsEmpty() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard request.url?.host == "musicbrainz.org" else { throw URLError(.unsupportedURL) }
            throw URLError(.timedOut)
        }

        let candidates = try await client.searchMusicBrainz(title: "Love Story", artist: "")

        #expect(candidates.isEmpty)
    }

    // MARK: - artist 排序加分

    @Test("artist 排序：artist 匹配的 recording 排前面，其余保持 MB 原序（稳定）")
    func searchRanksArtistMatchFirst() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard request.url?.host == "musicbrainz.org" else { throw URLError(.unsupportedURL) }
            let recordings = [
                Self.baseRecording(id: "rec-b", artistCredit: [["name": "Katy Perry"]]),
                Self.baseRecording(id: "rec-a", artistCredit: [["name": "Taylor Swift"]]),
                Self.baseRecording(id: "rec-c", artistCredit: [["name": "Katy Perry"]]),
                Self.baseRecording(id: "rec-d", artistCredit: [["name": "Ed Sheeran"]]),
            ]
            return MBMockURLProtocol.jsonResponse(Self.recordingsData(recordings), for: request)
        }

        let candidates = try await client.searchMusicBrainz(title: "Love Story", artist: "taylor swift")

        #expect(candidates.map { $0.id } == ["rec-a", "rec-b", "rec-c", "rec-d"])
    }

    @Test("artist 排序：artist 为空 → 保持 MB 返回原序")
    func searchWithoutArtistKeepsOriginalOrder() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard request.url?.host == "musicbrainz.org" else { throw URLError(.unsupportedURL) }
            let recordings = [
                Self.baseRecording(id: "rec-b", artistCredit: [["name": "Katy Perry"]]),
                Self.baseRecording(id: "rec-a", artistCredit: [["name": "Taylor Swift"]]),
            ]
            return MBMockURLProtocol.jsonResponse(Self.recordingsData(recordings), for: request)
        }

        let candidates = try await client.searchMusicBrainz(title: "Love Story", artist: "")

        #expect(candidates.map { $0.id } == ["rec-b", "rec-a"])
    }

    // MARK: - 候选字段提取

    @Test("候选字段：year(release.date 优先)/genre(tags count 排序)/track(media 匹配)/album_artist/joinphrase/cover")
    func searchExtractsCandidateFields() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard let host = request.url?.host else { throw URLError(.badURL) }
            switch host {
            case "musicbrainz.org":
                return MBMockURLProtocol.jsonResponse(Self.recordingsData([Self.richRecording()]), for: request)
            case "coverartarchive.org":
                return Self.caaRedirect("rel-1", for: request)
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let candidates = try await client.searchMusicBrainz(title: "Love Story", artist: "")

        #expect(candidates.count == 1)
        let candidate = candidates[0]
        #expect(candidate.source == "musicbrainz")
        #expect(candidate.id == "rec-1")
        #expect(candidate.title == "Love Story")
        // artist-credit joinphrase 保留（web "A feat. B" 语义）
        #expect(candidate.artist == "Artist A feat. Artist B")
        // album/album_artist/year 取首个有 id 的 release（release.date 优先于 first-release-date）
        #expect(candidate.album == "Fearless")
        #expect(candidate.albumArtist == "Artist A")
        #expect(candidate.year == 2009)
        // genre：tags 按 count 降序前 3 "/" 连接
        #expect(candidate.genre == "rock/indie/pop")
        // track：releases[0].media[].track[] 按 recording id 匹配取 number 首个数字
        #expect(candidate.track == 7)
        // cover：CAA 3xx → release front URL
        #expect(candidate.coverURL?.absoluteString == Self.caaURL("rel-1"))
        #expect(Self.caaRequests().count == 1)
    }

    @Test("候选字段：year 兜底 first-release-date；无 release → album/cover nil、album_artist 空")
    func searchYearFallbackAndMissingRelease() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard request.url?.host == "musicbrainz.org" else { throw URLError(.unsupportedURL) }
            let recordings = [
                // 无 releases：year 取 first-release-date
                [
                    "id": "rec-f",
                    "title": "Fallback Year",
                    "first-release-date": "2012-06-01",
                ],
                // 无日期：year nil、genre 空
                [
                    "id": "rec-n",
                    "title": "No Year",
                    "artist-credit": [["name": "Nobody"]],
                ],
            ]
            return MBMockURLProtocol.jsonResponse(Self.recordingsData(recordings), for: request)
        }

        let candidates = try await client.searchMusicBrainz(title: "X", artist: "")

        #expect(candidates.count == 2)
        #expect(candidates[0].year == 2012)
        #expect(candidates[0].album == nil)
        #expect(candidates[0].albumArtist?.isEmpty == true)
        #expect(candidates[0].coverURL == nil)
        #expect(candidates[1].year == nil)
        #expect(candidates[1].genre?.isEmpty == true)
        #expect(candidates[1].track == nil)
    }

    @Test("无 id / 无 title 的 recording 跳过（单条坏数据不炸整批）")
    func searchSkipsRecordingsWithoutIdOrTitle() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard request.url?.host == "musicbrainz.org" else { throw URLError(.unsupportedURL) }
            let recordings: [[String: Any]] = [
                ["title": "No ID"],
                ["id": "rec-2"], // 无 title
                ["id": "", "title": "Empty ID"],
                Self.baseRecording(id: "rec-3", title: "Good One", artistCredit: []),
            ]
            return MBMockURLProtocol.jsonResponse(Self.recordingsData(recordings), for: request)
        }

        let candidates = try await client.searchMusicBrainz(title: "X", artist: "")

        #expect(candidates.count == 1)
        #expect(candidates[0].id == "rec-3")
        #expect(candidates[0].artist?.isEmpty == true)
    }

    // MARK: - Lucene 转义

    @Test("Lucene 转义：引号/反斜杠在短语查询里被转义；空 query → 无阶段")
    func mbQueryStagesEscapesLuceneSpecials() {
        #expect(MusicBrainzClient.mbQueryStages("Love Story") == [
            "recording:\"Love Story\"",
            "recording:\"Love Story\"~",
            "title:Love Story",
        ])
        // 引号 → \"；反斜杠 → \\
        #expect(MusicBrainzClient.mbQueryStages("say \"hi\"")[0] == "recording:\"say \\\"hi\\\"\"")
        #expect(MusicBrainzClient.mbQueryStages("a\\b")[0] == "recording:\"a\\\\b\"")
        #expect(MusicBrainzClient.mbQueryStages("").isEmpty)
        #expect(MusicBrainzClient.mbQueryStages("   ").isEmpty)
    }

    // MARK: - CAA（Cover Art Archive）

    @Test("CAA：3xx → 返回 front URL；同 MBID 二次请求走缓存（请求计数 1）")
    func caaRedirectYieldsURLAndCaches() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard request.url?.host == "coverartarchive.org" else { throw URLError(.unsupportedURL) }
            return Self.caaRedirect("rel-1", for: request)
        }

        let first = try await client.coverArtArchiveFront(mbid: "rel-1")
        #expect(first?.absoluteString == Self.caaURL("rel-1"))
        let second = try await client.coverArtArchiveFront(mbid: "rel-1")
        #expect(second?.absoluteString == Self.caaURL("rel-1"))
        #expect(Self.caaRequests().count == 1)
    }

    @Test("CAA：404 → nil（含负缓存，二次请求不再发网络）")
    func caa404ReturnsNilAndCachesNegative() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard request.url?.host == "coverartarchive.org" else { throw URLError(.unsupportedURL) }
            return MBMockURLProtocol.response(status: 404, for: request)
        }

        let first = try await client.coverArtArchiveFront(mbid: "rel-missing")
        #expect(first == nil)
        let second = try await client.coverArtArchiveFront(mbid: "rel-missing")
        #expect(second == nil)
        #expect(Self.caaRequests().count == 1)
    }

    @Test("CAA(title:artist:)：MB 搜 release MBID → CAA front")
    func caaViaTitleArtistSearch() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard let host = request.url?.host else { throw URLError(.badURL) }
            switch host {
            case "musicbrainz.org":
                let recordings: [[String: Any]] = [
                    [
                        "id": "rec-x",
                        "title": "Love Story",
                        "releases": [
                            ["title": "No ID Release"], // 无 id → 必须跳过
                            ["id": "rel-9", "title": "Fearless"],
                        ],
                    ],
                ]
                return MBMockURLProtocol.jsonResponse(Self.recordingsData(recordings), for: request)
            case "coverartarchive.org":
                return Self.caaRedirect("rel-9", for: request)
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let cover = try await client.coverArtArchiveFront(title: "Love Story", artist: "")

        #expect(cover?.absoluteString == Self.caaURL("rel-9"))
        // 首个有 id 的 release 才被采用（rel-9 在无 id 的后面 → 跳过无 id 的）
        #expect(Self.mbRequests().count == 1)
    }

    @Test("CAA(title:artist:)：找不到有 id 的 release → nil")
    func caaViaTitleArtistNoReleaseReturnsNil() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard let host = request.url?.host else { throw URLError(.badURL) }
            switch host {
            case "musicbrainz.org":
                let recordings: [[String: Any]] = [
                    [
                        "id": "rec-y",
                        "title": "No Release",
                        "releases": [["title": "ID-less"]],
                    ],
                ]
                return MBMockURLProtocol.jsonResponse(Self.recordingsData(recordings), for: request)
            case "coverartarchive.org":
                Issue.record("不应请求 CAA")
                throw URLError(.unsupportedURL)
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let cover = try await client.coverArtArchiveFront(title: "No Release", artist: "")
        #expect(cover == nil)
    }

    // MARK: - iTunes fallback

    @Test("iTunes：artworkUrl100 → 600x600 替换；term/media/limit 参数正确")
    func itunesCoverUpgradesArtwork() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard request.url?.host == "itunes.apple.com" else { throw URLError(.unsupportedURL) }
            let body = [
                "results": [
                    ["artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/x/100x100bb.jpg"],
                ],
            ]
            let data = try! JSONSerialization.data(withJSONObject: body)
            return MBMockURLProtocol.jsonResponse(data, for: request)
        }

        let cover = try await client.itunesCoverURL(title: "Love Story", artist: "Taylor Swift")

        #expect(cover?.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/x/600x600bb.jpg")
        let request = Self.itunesRequests()[0]
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first(where: { $0.name == "term" })?.value == "Love Story Taylor Swift")
        #expect(items.first(where: { $0.name == "media" })?.value == "music")
        #expect(items.first(where: { $0.name == "limit" })?.value == "5")
    }

    @Test("iTunes：无 results / 失败 → nil（不 throw）")
    func itunesCoverEmptyOrFailureReturnsNil() async throws {
        MBMockURLProtocol.reset()
        let clientEmpty = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard request.url?.host == "itunes.apple.com" else { throw URLError(.unsupportedURL) }
            return MBMockURLProtocol.jsonResponse(Data(#"{"results":[]}"#.utf8), for: request)
        }
        let emptyCover = try await clientEmpty.itunesCoverURL(title: "X", artist: "Y")
        #expect(emptyCover == nil)

        MBMockURLProtocol.reset()
        let clientFailure = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard request.url?.host == "itunes.apple.com" else { throw URLError(.unsupportedURL) }
            return MBMockURLProtocol.response(status: 500, for: request)
        }
        let failedCover = try await clientFailure.itunesCoverURL(title: "X", artist: "Y")
        #expect(failedCover == nil)
    }

    // MARK: - fallbackCoverURL 链

    @Test("fallbackCoverURL：iTunes 空 → MB release MBID → CAA front")
    func fallbackCoverFallsThroughToCAA() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard let host = request.url?.host else { throw URLError(.badURL) }
            switch host {
            case "itunes.apple.com":
                return MBMockURLProtocol.jsonResponse(Data(#"{"results":[]}"#.utf8), for: request)
            case "musicbrainz.org":
                let recordings: [[String: Any]] = [
                    [
                        "id": "rec-fb",
                        "title": "Love Story",
                        "releases": [["id": "rel-fb", "title": "Fearless"]],
                    ],
                ]
                return MBMockURLProtocol.jsonResponse(Self.recordingsData(recordings), for: request)
            case "coverartarchive.org":
                return Self.caaRedirect("rel-fb", for: request)
            default:
                throw URLError(.unsupportedURL)
            }
        }

        let cover = try await client.fallbackCoverURL(title: "Love Story", artist: "")

        #expect(cover?.absoluteString == Self.caaURL("rel-fb"))
        #expect(Self.itunesRequests().count == 1)
        #expect(Self.mbRequests().count == 1)
        #expect(Self.caaRequests().count == 1)
    }

    @Test("fallbackCoverURL：iTunes 直接命中 → 不再查 MB/CAA")
    func fallbackCoverStopsAtITunesHit() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { request in
            guard let host = request.url?.host else { throw URLError(.badURL) }
            switch host {
            case "itunes.apple.com":
                let body = [
                    "results": [
                        ["artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/x/100x100bb.jpg"],
                    ],
                ]
                let data = try! JSONSerialization.data(withJSONObject: body)
                return MBMockURLProtocol.jsonResponse(data, for: request)
            default:
                Issue.record("iTunes 命中后不应再请求 \(host)")
                throw URLError(.unsupportedURL)
            }
        }

        let cover = try await client.fallbackCoverURL(title: "Love Story", artist: "Taylor Swift")

        #expect(cover?.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/x/600x600bb.jpg")
        #expect(Self.mbRequests().isEmpty)
        #expect(Self.caaRequests().isEmpty)
    }

    @Test("fallbackCoverURL：整条链都失败 → nil（不 throw）")
    func fallbackCoverAllFailReturnsNil() async throws {
        MBMockURLProtocol.reset()
        let client = Self.makeClient()
        MBMockURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let cover = try await client.fallbackCoverURL(title: "X", artist: "Y")
        #expect(cover == nil)
    }

    // MARK: - artistMatches 归一化

    @Test("artistMatches：大小写/标点/空白/下划线归一化后相等")
    func artistMatchesNormalizesEquality() {
        #expect(MusicBrainzClient.artistMatches("Taylor Swift", "taylor swift"))
        #expect(MusicBrainzClient.artistMatches("A. R. Rahman", "ar rahman"))
        #expect(MusicBrainzClient.artistMatches("A_B C", "abc"))
    }

    @Test("artistMatches：互相包含 → 匹配（feat. 部分匹配）")
    func artistMatchesPartialContainment() {
        #expect(MusicBrainzClient.artistMatches("The Beatles", "Beatles"))
        #expect(MusicBrainzClient.artistMatches("Beatles", "The Beatles"))
        #expect(MusicBrainzClient.artistMatches("A feat. B", "A"))
        #expect(MusicBrainzClient.artistMatches("A feat. B", "B"))
    }

    @Test("artistMatches：繁简不同不匹配；空字符串不匹配")
    func artistMatchesRejectsDifferentScriptsAndEmpty() {
        #expect(!MusicBrainzClient.artistMatches("周杰倫", "周杰伦"))
        #expect(!MusicBrainzClient.artistMatches("", "Taylor"))
        #expect(!MusicBrainzClient.artistMatches("Taylor", ""))
        #expect(!MusicBrainzClient.artistMatches("", ""))
        // 归一化后为空（纯标点）→ false
        #expect(!MusicBrainzClient.artistMatches("!!!", "Taylor"))
    }
}
