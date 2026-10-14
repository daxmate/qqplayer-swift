//
//  ITunesScrapeClientTests.swift
//  QQPlayerTests
//
//  ITunesScrapeClient（E2 2026-10「iTunes 备用源」）防回归：
//  - candidates(fromJSON:)：字段映射 + 封面 100x100bb → 600x600bb（唯一转换入口）
//  - 容错：坏 JSON / 无 results / 缺 trackName 条目 → 空/跳过
//  - searchURL：term/entity/country/limit 参数；空 term → nil
//  - candidates(query:)：注入 URLProtocol mock；网络失败 → []（不抛）
//
//  隔离说明：本文件自带 ITunesMockURLProtocol（独立 URLProtocol 类，静态状态只属于自己），
//  与其他 suite 的 mock 互不干扰；suite 内 .serialized。
//

import Foundation
import Testing

@testable import QQPlayer

/// iTunes 测试专用 URLProtocol mock（实现同 MockURLProtocol，静态状态独立）
final class ITunesMockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?

    static func reset() {
        handler = nil
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = ITunesMockURLProtocol.handler else {
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

@Suite(.serialized)
struct ITunesScrapeClientTests {
    private static func sampleResults() -> [[String: Any]] {
        [[
            "trackId": 1440857781,
            "trackName": "Love Story",
            "artistName": "Taylor Swift",
            "collectionName": "Fearless",
            "releaseDate": "2008-11-11T08:00:00Z",
            "primaryGenreName": "Country",
            "trackNumber": 2,
            "trackTimeMillis": 235_000,
            "artworkUrl100": "https://is1-ssl.mzstatic.com/image/thumb/x/100x100bb.jpg",
        ]]
    }

    private static func sampleJSON(_ results: [[String: Any]]? = nil) -> Data {
        try! JSONSerialization.data(withJSONObject: ["resultCount": 1, "results": results ?? sampleResults()])
    }

    // MARK: - 映射（唯一转换入口）

    @Test("candidates(fromJSON:)：字段映射 + 封面 100x100bb → 600x600bb")
    func mapping() {
        let candidates = ITunesScrapeClient.candidates(fromJSON: Self.sampleJSON())
        #expect(candidates.count == 1)
        let candidate = candidates[0]
        #expect(candidate.source == "itunes")
        #expect(candidate.id == "1440857781")
        #expect(candidate.title == "Love Story")
        #expect(candidate.artist == "Taylor Swift")
        #expect(candidate.album == "Fearless")
        #expect(candidate.year == 2008)
        #expect(candidate.genre == "Country")
        #expect(candidate.track == 2)
        #expect(candidate.albumArtist == "Taylor Swift")
        #expect(candidate.durationMs == 235_000)
        #expect(candidate.coverURL?.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/x/600x600bb.jpg")
    }

    @Test("candidates(fromJSON:)：坏 JSON / 无 results / 缺 trackName 条目 → 空或跳过")
    func mappingTolerant() {
        #expect(ITunesScrapeClient.candidates(fromJSON: Data("not json".utf8)).isEmpty)
        #expect(ITunesScrapeClient.candidates(fromJSON: Data(#"{"results":[]}"#.utf8)).isEmpty)
        let missingTitle = try! JSONSerialization.data(withJSONObject: ["results": [["artistName": "X"]]])
        #expect(ITunesScrapeClient.candidates(fromJSON: missingTitle).isEmpty)
        // 缺字段尽力取值：无封面 / 无年份 → nil，其余照填
        let sparse = try! JSONSerialization.data(withJSONObject: ["results": [["trackName": "Only Title"]]])
        let candidates = ITunesScrapeClient.candidates(fromJSON: sparse)
        #expect(candidates.count == 1)
        #expect(candidates[0].title == "Only Title")
        #expect(candidates[0].coverURL == nil)
        #expect(candidates[0].year == nil)
    }

    // MARK: - URL 构造

    @Test("searchURL：term/entity/country/limit 参数；term 去空白；空 term → nil")
    func searchURLParams() {
        let url = ITunesScrapeClient.searchURL(query: "  Love Story ")
        #expect(url?.host == "itunes.apple.com")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first(where: { $0.name == "term" })?.value == "Love Story")
        #expect(items.first(where: { $0.name == "entity" })?.value == "song")
        #expect(items.first(where: { $0.name == "country" })?.value == "cn")
        #expect(items.first(where: { $0.name == "limit" })?.value == "20")
        #expect(ITunesScrapeClient.searchURL(query: "   ") == nil)
    }

    // MARK: - 注入 seam（映射 + 容错）

    @Test("candidates(query:)：注入 mock → 映射；网络错误 → []（不抛）")
    func queryWithInjectedMock() async {
        ITunesMockURLProtocol.reset()
        ITunesMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, Self.sampleJSON())
        }
        let client = ITunesScrapeClient(protocolClasses: [ITunesMockURLProtocol.self])
        let ok = await client.candidates(query: "Love Story")
        #expect(ok.count == 1)
        #expect(ok[0].source == "itunes")

        ITunesMockURLProtocol.reset()
        ITunesMockURLProtocol.handler = { _ in throw URLError(.timedOut) }
        let failed = await client.candidates(query: "X")
        #expect(failed.isEmpty)

        ITunesMockURLProtocol.reset()
        ITunesMockURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let serverError = await client.candidates(query: "X")
        #expect(serverError.isEmpty)
    }
}
