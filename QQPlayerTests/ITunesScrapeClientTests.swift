//
//  ITunesScrapeClientTests.swift
//  QQPlayerTests
//
//  ITunesScrapeClient（E2 2026-10「iTunes 备用源」）防回归：
//  - candidates(fromJSON:)：字段映射 + 封面 100x100bb → 600x600bb（唯一转换入口）
//  - 容错：坏 JSON / 无 results / 缺 trackName 条目 → 空/跳过
//  - searchURL：term/entity/country/limit 参数；空 term → nil
//  - 店区顺序 tw → us：primary 命中只发一次请求；空/失败回退 us；两轮都失败 → []
//  - 合并去重：同一 trackId 只保留首条
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
    /// 实际发生的请求店区（按发生顺序），用于断言回退顺序与请求次数
    nonisolated(unsafe) static var requestedStorefronts: [String] = []

    static func reset() {
        handler = nil
        requestedStorefronts = []
    }

    /// 从请求 URL 取 country 参数（`term` 之外的店区标识）
    static func storefront(of request: URLRequest) -> String? {
        guard let url = request.url,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return nil
        }
        return items.first(where: { $0.name == "country" })?.value
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let storefront = Self.storefront(of: request) {
            Self.requestedStorefronts.append(storefront)
        }
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

    @Test("searchURL：term/entity/country/limit 参数；term 去空白；空 term → nil；店区顺序 tw → us")
    func searchURLParams() {
        #expect(ITunesScrapeClient.storefronts == ["tw", "us"])
        let url = ITunesScrapeClient.searchURL(term: "  Love Story ", storefront: ITunesScrapeClient.storefronts[0])
        #expect(url?.host == "itunes.apple.com")
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first(where: { $0.name == "term" })?.value == "Love Story")
        #expect(items.first(where: { $0.name == "entity" })?.value == "song")
        #expect(items.first(where: { $0.name == "country" })?.value == "tw")
        #expect(items.first(where: { $0.name == "limit" })?.value == "20")
        #expect(ITunesScrapeClient.searchURL(term: "   ", storefront: "tw") == nil)
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

    // MARK: - 店区回退（tw → us）

    private static func emptyJSON() -> Data {
        try! JSONSerialization.data(withJSONObject: ["resultCount": 0, "results": [Any]()])
    }

    private static func jsonResponse(for request: URLRequest, statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
    }

    @Test("candidates(query:)：tw 空 → 自动请求 us，返回 us 结果（两个请求都发生）")
    func fallbackToUSWhenPrimaryEmpty() async {
        ITunesMockURLProtocol.reset()
        ITunesMockURLProtocol.handler = { request in
            let body = ITunesMockURLProtocol.storefront(of: request) == "tw" ? Self.emptyJSON() : Self.sampleJSON()
            return (Self.jsonResponse(for: request), body)
        }
        let client = ITunesScrapeClient(protocolClasses: [ITunesMockURLProtocol.self])
        let candidates = await client.candidates(query: "Love Story")
        #expect(candidates.count == 1)
        #expect(candidates.first?.id == "1440857781")
        #expect(ITunesMockURLProtocol.requestedStorefronts == ["tw", "us"])
    }

    @Test("candidates(query:)：tw 有候选 → 只发一次请求（不再查 us）")
    func primaryHitSkipsFallback() async {
        ITunesMockURLProtocol.reset()
        ITunesMockURLProtocol.handler = { request in
            (Self.jsonResponse(for: request), Self.sampleJSON())
        }
        let client = ITunesScrapeClient(protocolClasses: [ITunesMockURLProtocol.self])
        let candidates = await client.candidates(query: "Love Story")
        #expect(candidates.count == 1)
        #expect(ITunesMockURLProtocol.requestedStorefronts == ["tw"])
    }

    @Test("candidates(query:)：tw 500 → 回退 us 成功，返回 us 结果")
    func fallbackOnPrimaryServerError() async {
        ITunesMockURLProtocol.reset()
        ITunesMockURLProtocol.handler = { request in
            if ITunesMockURLProtocol.storefront(of: request) == "tw" {
                return (Self.jsonResponse(for: request, statusCode: 500), Data())
            }
            return (Self.jsonResponse(for: request), Self.sampleJSON())
        }
        let client = ITunesScrapeClient(protocolClasses: [ITunesMockURLProtocol.self])
        let candidates = await client.candidates(query: "Love Story")
        #expect(candidates.count == 1)
        #expect(ITunesMockURLProtocol.requestedStorefronts == ["tw", "us"])
    }

    @Test("candidates(query:)：tw 与 us 都空/失败 → []（不抛）")
    func bothStorefrontsFail() async {
        ITunesMockURLProtocol.reset()
        ITunesMockURLProtocol.handler = { request in
            if ITunesMockURLProtocol.storefront(of: request) == "tw" {
                return (Self.jsonResponse(for: request, statusCode: 500), Data())
            }
            throw URLError(.cannotConnectToHost)
        }
        let client = ITunesScrapeClient(protocolClasses: [ITunesMockURLProtocol.self])
        let candidates = await client.candidates(query: "Love Story")
        #expect(candidates.isEmpty)
        #expect(ITunesMockURLProtocol.requestedStorefronts == ["tw", "us"])
    }

    @Test("candidates(query:)：同一 trackId 重复出现 → 去重只留首条")
    func duplicateTrackIDInResponse() async {
        ITunesMockURLProtocol.reset()
        ITunesMockURLProtocol.handler = { request in
            let duplicated = Self.sampleResults() + Self.sampleResults()
            return (Self.jsonResponse(for: request), Self.sampleJSON(duplicated))
        }
        let client = ITunesScrapeClient(protocolClasses: [ITunesMockURLProtocol.self])
        let candidates = await client.candidates(query: "Love Story")
        #expect(candidates.count == 1)
        #expect(candidates.first?.id == "1440857781")
        #expect(ITunesMockURLProtocol.requestedStorefronts == ["tw"])
    }

    @Test("merging：跨店区结果按 trackId 去重并保留首条")
    func mergingDeduplicatesByTrackID() {
        let first = ITunesScrapeClient.candidates(fromJSON: Self.sampleJSON())
        #expect(first.count == 1)
        var duplicate = first[0]
        duplicate.title = "Love Story (Live)"
        let merged = ITunesScrapeClient.merging(first, with: [duplicate])
        #expect(merged.count == 1)
        #expect(merged[0].title == "Love Story")
    }
}
