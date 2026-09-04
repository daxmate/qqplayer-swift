//  NeteaseOnlineClientTests.swift
//  QQPlayerTests
//
//  在线搜索下载（web 版 /api/online/* 对齐，2026-09 C 组）防回归测试：
//  ① NeteaseOnlineLogic 纯逻辑：音质归一/br 映射/文件名清洗与组合/重名序号/URL 处理
//  ② search 富映射（MockTransport 注入）：album/cover(https)/dt/artist 连接/非法跳过
//  ③ 失败语义：HTTP 非 200 → 抛 httpError
//
//  背景（web netease_provider.py + app/routers/stream.py）：网易云源在线链路 =
//  eapi cloudsearch 搜索 + Meting→cenguigui 直链 + 下载文件名 {title}-{artist}.{ext}。

import Foundation
import Testing

@testable import QQPlayer

// MARK: - MockTransport（测试注入；不发真实网络）

struct MockNetworkTransport: NetworkTransport {
    var dataHandler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    var redirectHandler: @Sendable (URL) throws -> (statusCode: Int, headers: [String: String], body: Data)
    var downloadHandler: @Sendable (URL, URL) throws -> Void

    static func httpResponse(status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.test")!,
                        statusCode: status,
                        httpVersion: nil,
                        headerFields: nil)!
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try dataHandler(request)
    }

    func getWithoutRedirect(url: URL, timeout: TimeInterval) async throws -> (statusCode: Int, headers: [String: String], body: Data) {
        try redirectHandler(url)
    }

    func download(url: URL, to destination: URL, timeout: TimeInterval, headers: [String: String]) async throws {
        try downloadHandler(url, destination)
    }
}

// MARK: - 纯逻辑

struct NeteaseOnlineClientTests {
    // MARK: 音质

    @Test("音质归一：合法值原样返回（大小写不敏感）")
    func normalizeValidLevels() {
        #expect(NeteaseOnlineLogic.normalizeLevel("exhigh") == "exhigh")
        #expect(NeteaseOnlineLogic.normalizeLevel("STANDARD") == "standard")
        #expect(NeteaseOnlineLogic.normalizeLevel(" lossless ") == "lossless")
        #expect(NeteaseOnlineLogic.normalizeLevel("hires") == "hires")
    }

    @Test("音质归一：非法/缺失回落默认 exhigh（web VALID_LEVELS 对齐）")
    func normalizeInvalidLevelsFallBackToDefault() {
        #expect(NeteaseOnlineLogic.normalizeLevel(nil) == "exhigh")
        #expect(NeteaseOnlineLogic.normalizeLevel("") == "exhigh")
        #expect(NeteaseOnlineLogic.normalizeLevel("ultra") == "exhigh")
        #expect(NeteaseOnlineLogic.normalizeLevel("128") == "exhigh")
    }

    @Test("br 映射：standard=128 / exhigh=320 / lossless|hires=2000（web METING_BR_BY_LEVEL 对齐）")
    func brParameterMapping() {
        #expect(NeteaseOnlineLogic.brParameter(forLevel: "standard") == "128")
        #expect(NeteaseOnlineLogic.brParameter(forLevel: "exhigh") == "320")
        #expect(NeteaseOnlineLogic.brParameter(forLevel: "lossless") == "2000")
        #expect(NeteaseOnlineLogic.brParameter(forLevel: "hires") == "2000")
        #expect(NeteaseOnlineLogic.brParameter(forLevel: "bogus") == "320")
    }

    // MARK: 文件名

    @Test("文件名清洗：去掉非法字符（/ \\ : * ? < > |）并去首尾空白（web _sanitize_filename 对齐）")
    func sanitizeFilenameStripsInvalidChars() {
        #expect(NeteaseOnlineLogic.sanitizeFilename(" 爱/你:一万?年  ") == "爱你一万年")
        #expect(NeteaseOnlineLogic.sanitizeFilename("a<b>c|d\\e") == "abcde")
        #expect(NeteaseOnlineLogic.sanitizeFilename("  ").isEmpty)
    }

    @Test("下载文件名：{title}-{artist}.{ext}")
    func downloadFileNameWithArtist() {
        let name = NeteaseOnlineLogic.downloadFileName(
            title: "晴天", artist: "周杰伦", ext: "mp3", songID: 186016
        )
        #expect(name == "晴天-周杰伦.mp3")
    }

    @Test("下载文件名：artist 清洗后为空 → {title}.{ext}")
    func downloadFileNameWithoutArtist() {
        let name = NeteaseOnlineLogic.downloadFileName(
            title: "晴天", artist: "///", ext: "flac", songID: 186016
        )
        #expect(name == "晴天.flac")
    }

    @Test("下载文件名：title 也空 → id 兜底（web /api/online/download 对齐）")
    func downloadFileNameFallsBackToID() {
        let name = NeteaseOnlineLogic.downloadFileName(
            title: "? ", artist: " ", ext: "mp3", songID: 186016
        )
        #expect(name == "186016.mp3")
    }

    @Test("下载文件名：扩展名空 → mp3 兜底")
    func downloadFileNameExtFallback() {
        let name = NeteaseOnlineLogic.downloadFileName(
            title: "歌", artist: "", ext: "", songID: 1
        )
        #expect(name == "歌.mp3")
    }

    @Test("重名序号：name.ext → name (1).ext（web _unique_path 对齐）")
    func uniqueFileNameAppendsNumber() {
        var occupied: Set<String> = ["歌.mp3"]
        let first = NeteaseOnlineLogic.uniqueFileName(base: "歌.mp3") { occupied.contains($0) }
        #expect(first == "歌 (1).mp3")
        occupied.insert(first)
        let second = NeteaseOnlineLogic.uniqueFileName(base: "歌.mp3") { occupied.contains($0) }
        #expect(second == "歌 (2).mp3")
    }

    @Test("重名序号：无冲突原样返回；无扩展名分支也加序号")
    func uniqueFileNameNoCollision() {
        let same = NeteaseOnlineLogic.uniqueFileName(base: "歌.mp3") { _ in false }
        #expect(same == "歌.mp3")
        let noExt = NeteaseOnlineLogic.uniqueFileName(base: "歌") { $0 == "歌" }
        #expect(noExt == "歌 (1)")
    }

    // MARK: URL 处理

    @Test("扩展名推断：路径末段点后缀（去 query），推断不出用 mp3")
    func extractExtensionFromURL() {
        let cases: [(String, String)] = [
            ("https://m701.music.126.net/a/b.mp3?x=1", "mp3"),
            ("https://cdn.example/x/Flac.FLAC", "flac"),
            ("https://cdn.example/x/noext", "mp3"),
            ("https://cdn.example/x/a.bad.ext.too.long123456", "mp3"),
        ]
        for (raw, expected) in cases {
            #expect(NeteaseOnlineLogic.extractExtension(from: URL(string: raw)!) == expected)
        }
        // 自定义 fallback：URL 推断不出扩展名时返回 fallback 参数
        #expect(NeteaseOnlineLogic.extractExtension(from: URL(string: "https://cdn.example/x/song")!, fallback: "m4a") == "m4a")
    }

    @Test("http → https；https 原样；空/非法 → nil（web _to_https 对齐）")
    func toHttpsURLNormalizes() {
        #expect(NeteaseOnlineLogic.toHttpsURL("http://a.com/x.jpg")?.absoluteString == "https://a.com/x.jpg")
        #expect(NeteaseOnlineLogic.toHttpsURL("https://a.com/x.jpg")?.absoluteString == "https://a.com/x.jpg")
        #expect(NeteaseOnlineLogic.toHttpsURL("") == nil)
        #expect(NeteaseOnlineLogic.toHttpsURL("   ") == nil)
    }

    // MARK: 搜索富映射（MockTransport）

    private func cloudsearchJSON(songs: [[String: Any]]) -> Data {
        let wrapper: [String: Any] = ["result": ["songs": songs]]
        return (try! JSONSerialization.data(withJSONObject: wrapper))
    }

    @Test("search 富映射：album/cover(http→https)/dt/artist 逗号连接/level 默认 exhigh")
    func searchMapsRichSongFields() async throws {
        let json = cloudsearchJSON(songs: [
            [
                "id": 186016,
                "name": "晴天",
                "ar": [["name": "周杰伦"], ["name": "费玉清"]],
                "al": ["name": "叶惠美", "picUrl": "http://p1.music.126.net/cover.jpg"],
                "dt": 269000,
            ],
            [
                "id": 999,
                "name": "无专辑歌",
                // ar/al/dt 全缺 → artist 空、album nil、duration nil；仍应收录
            ],
        ])
        let transport = MockNetworkTransport(
            dataHandler: { _ in (json, MockNetworkTransport.httpResponse()) },
            redirectHandler: { _ in (200, [:], Data()) },
            downloadHandler: { _, _ in }
        )
        let client = NeteaseOnlineClient(transport: transport)
        let songs = try await client.search(query: "晴天", limit: 20)

        #expect(songs.count == 2)
        let first = songs[0]
        #expect(first.id == 186016)
        #expect(first.title == "晴天")
        #expect(first.artist == "周杰伦, 费玉清")
        #expect(first.album == "叶惠美")
        #expect(first.coverURL?.absoluteString == "https://p1.music.126.net/cover.jpg")
        #expect(first.durationMs == 269000)
        #expect(first.level == "exhigh")
        #expect(first.durationDisplay == "04:29")
        #expect(songs[1].album == nil)
    }

    @Test("search：无 id 的条目跳过；result/songs 缺失 → 空数组（web 失败返回 [] 语义的解析端）")
    func searchSkipsInvalidAndEmptyResults() async throws {
        let withInvalid = cloudsearchJSON(songs: [
            ["name": "无 id"],
            ["id": 1, "name": "正常"],
        ])
        let transport1 = MockNetworkTransport(
            dataHandler: { _ in (withInvalid, MockNetworkTransport.httpResponse()) },
            redirectHandler: { _ in (200, [:], Data()) },
            downloadHandler: { _, _ in }
        )
        let client1 = NeteaseOnlineClient(transport: transport1)
        let result = try await client1.search(query: "q")
        #expect(result.map { $0.id } == [1])

        let empty = Data(#"{"result":{}}"#.utf8)
        let transport2 = MockNetworkTransport(
            dataHandler: { _ in (empty, MockNetworkTransport.httpResponse()) },
            redirectHandler: { _ in (200, [:], Data()) },
            downloadHandler: { _, _ in }
        )
        let client2 = NeteaseOnlineClient(transport: transport2)
        let result2 = try await client2.search(query: "q")
        #expect(result2.isEmpty)
    }

    @Test("search：query 去空白后为空 → 直接返回空（不发请求）")
    func searchEmptyQueryReturnsEmpty() async throws {
        let transport = MockNetworkTransport(
            dataHandler: { _ in
                Issue.record("不应发出请求")
                return (Data(), MockNetworkTransport.httpResponse())
            },
            redirectHandler: { _ in (200, [:], Data()) },
            downloadHandler: { _, _ in }
        )
        let client = NeteaseOnlineClient(transport: transport)
        let result = try await client.search(query: "   ")
        #expect(result.isEmpty)
    }

    @Test("search：HTTP 非 200 → 抛 httpError")
    func searchHTTPErrorThrows() async {
        let transport = MockNetworkTransport(
            dataHandler: { _ in (Data(), MockNetworkTransport.httpResponse(status: 500)) },
            redirectHandler: { _ in (200, [:], Data()) },
            downloadHandler: { _, _ in }
        )
        let client = NeteaseOnlineClient(transport: transport)
        await #expect(throws: NeteaseOnlineError.self) {
            _ = try await client.search(query: "q")
        }
    }

    // MARK: playInfo（Meting → cenguigui 兜底语义）

    @Test("playInfo：Meting 302 Location → 直链（http→https 归一）")
    func playInfoUsesMetingRedirect() async throws {
        let transport = MockNetworkTransport(
            dataHandler: { _ in (Data(), MockNetworkTransport.httpResponse()) },
            redirectHandler: { url in
                if url.absoluteString.contains("qijieya.cn") {
                    return (302, ["Location": "http://m701.music.126.net/dl.mp3"], Data())
                }
                return (200, [:], Data())
            },
            downloadHandler: { _, _ in }
        )
        let client = NeteaseOnlineClient(transport: transport)
        let info = try await client.playInfo(songID: 1, level: "exhigh")
        #expect(info.url.absoluteString == "https://m701.music.126.net/dl.mp3")
        #expect(info.ext == "mp3")
        #expect(info.bitrate == "320")
    }

    @Test("playInfo：Meting 失败（无直链）→ cenguigui 兜底成功")
    func playInfoFallsBackToCenguigui() async throws {
        let transport = MockNetworkTransport(
            dataHandler: { _ in (Data(), MockNetworkTransport.httpResponse()) },
            redirectHandler: { url in
                if url.absoluteString.contains("qijieya.cn") {
                    return (200, [:], Data()) // Meting 无直链（body 非 URL/JSON）
                }
                // cenguigui
                let payload = try! JSONSerialization.data(withJSONObject: [
                    "code": 200,
                    "data": ["url": "https://cdn.example/x/out.flac", "format": "FLAC"],
                ])
                return (200, [:], payload)
            },
            downloadHandler: { _, _ in }
        )
        let client = NeteaseOnlineClient(transport: transport)
        let info = try await client.playInfo(songID: 1, level: "lossless")
        #expect(info.url.absoluteString == "https://cdn.example/x/out.flac")
        #expect(info.ext == "flac")
        #expect(info.bitrate == "FLAC")
    }

    @Test("playInfo：Meting body 为 JSON 数组形态也能解析（web _extract_meting_url 对齐）")
    func playInfoParsesMetingJSONBody() async throws {
        let transport = MockNetworkTransport(
            dataHandler: { _ in (Data(), MockNetworkTransport.httpResponse()) },
            redirectHandler: { _ in
                let payload = try! JSONSerialization.data(withJSONObject: [
                    ["url": "https://cdn.example/a.mp3"],
                ])
                return (200, [:], payload)
            },
            downloadHandler: { _, _ in }
        )
        let client = NeteaseOnlineClient(transport: transport)
        let info = try await client.playInfo(songID: 7)
        #expect(info.url.absoluteString == "https://cdn.example/a.mp3")
    }

    @Test("playInfo：Meting 与 cenguigui 都失败 → 抛 noPlayURL")
    func playInfoThrowsWhenBothFail() async {
        let transport = MockNetworkTransport(
            dataHandler: { _ in (Data(), MockNetworkTransport.httpResponse()) },
            redirectHandler: { _ in (500, [:], Data()) },
            downloadHandler: { _, _ in }
        )
        let client = NeteaseOnlineClient(transport: transport)
        await #expect(throws: NeteaseOnlineError.self) {
            _ = try await client.playInfo(songID: 1)
        }
    }
}
