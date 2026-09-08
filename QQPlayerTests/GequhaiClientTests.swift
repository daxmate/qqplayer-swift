//
//  GequhaiClientTests.swift
//  QQPlayerTests
//
//  歌曲海客户端（web backend/gequhai_provider.py 移植，E2 下载批）防回归测试：
//  ① GequhaiLogic 纯逻辑：HTML 清理/unescape（命名+数字实体）、搜索表格解析
//     （myTables 行：歌名 /play/<id> + color:#666 歌手 td）、播放页 JS 变量解析、
//     mp3_extra_url 解码（'#'→'H' '%'→'S' + base64 + http 校验）、limit 归一化/
//     翻页计算、百分号编码（quote safe="/"）、表单编码（quote_plus）、响应字节解码
//     （charset → UTF-8 → GB18030 兜底）
//  ② 搜索网络路径（GequhaiMockURLProtocol 注入）：apiReady POST /api/s（字段/UA/
//     X-Requested-With/Referer）、GET /s/<kw> 翻页（?page=N 凑 limit）、预检不可用
//     → []（web 语义）、页面 500/无表格 → []、空 keyword → [] 不发请求
//  ③ 播放信息网络路径：GET /play/<id> → shareURL 解码 + playID；无分享/失败 →
//     shareURL nil（web 语义）
//  ④ 下载编排（组合 QuarkClient，quark 端点 mock 在同一 mock 内按 host 路由）：
//     playInfo → resolveShare → pickFile(quality) → getDownloadURL 全链路；无分享/
//     分享空/无音频/未登录各业务错误；quality=flac 挑 flac；请求顺序与字段断言
//
//  隔离说明：自带 GequhaiMockURLProtocol（独立 URLProtocol 类，静态状态只属于自己，
//  与 QuarkClientTests 的 QuarkMockURLProtocol 互不串，跨 suite 可并行）；suite 内
//  .serialized（静态 handler/receivedRequests 是进程级状态）。下载编排测试里 quark
//  client 注入同一个 GequhaiMockURLProtocol（handler 按 host 路由 gequhai/quark 端点），
//  cookie 文件指向临时目录，绝不碰真实 App Support 文件。全程不发真实网络。
//

import Foundation
import Testing

@testable import QQPlayer

/// 歌曲海测试专用 URLProtocol mock（实现同 QuarkMockURLProtocol，静态状态独立）
final class GequhaiMockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var handler: Handler?
    nonisolated(unsafe) static var receivedRequests: [URLRequest] = []

    static func reset() {
        handler = nil
        receivedRequests = []
    }

    static func response(
        _ body: String,
        status: Int = 200,
        headers: [String: String] = [:],
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        return (response, Data(body.utf8))
    }

    // MARK: - URLProtocol

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // iOS 26 起 URLSession 会把 POST httpBody 转成 httpBodyStream 传给
        // URLProtocol（httpBody=nil）——真实服务器收到的仍是 body 内容，这里读流
        // 还原 httpBody 供 handler 路由与断言使用（mock 层环境适配，不改生产语义）
        let capturedRequest: URLRequest
        if request.httpBody == nil, let stream = request.httpBodyStream {
            var mutable = request
            var body = Data()
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(buffer, count: read)
            }
            stream.close()
            mutable.httpBody = body
            capturedRequest = mutable
        } else {
            capturedRequest = request
        }
        GequhaiMockURLProtocol.receivedRequests.append(capturedRequest)
        guard let handler = GequhaiMockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (response, data) = try handler(capturedRequest)
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
struct GequhaiClientTests {
    // MARK: - 基建

    /// 注入 GequhaiMockURLProtocol 的 client（gequhai 端点 + quark 端点都走同一 mock，
    /// handler 按 host 路由）；quark cookie 指向临时目录
    private static func makeClient(cookieFile: URL = tempCookieURL()) -> GequhaiClient {
        let quark = QuarkClient(
            sleep: { _ in },
            cookieFileURL: cookieFile,
            protocolClasses: [GequhaiMockURLProtocol.self]
        )
        return GequhaiClient(
            quark: quark,
            protocolClasses: [GequhaiMockURLProtocol.self]
        )
    }

    /// 测试专用 quark cookie 文件（临时目录，测试结束清理）
    private static func tempCookieURL(_ name: String = "gequhai") -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("gequhai-tests-\(UUID().uuidString)-\(name)", isDirectory: true)
            .appendingPathComponent("quark_cookies.json")
    }

    private static func removeFileIfExists(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// 写 quark 测试 cookie 文件（模拟已登录；自动建目录）
    private static func writeCookieFile(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{\"pan_us\":\"abc123\"}".utf8).write(to: url)
    }

    private static func queryValue(_ name: String, in request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == name }?.value
    }

    private static func bodyString(of request: URLRequest) -> String? {
        guard let body = request.httpBody else { return nil }
        return String(bytes: body, encoding: .utf8)
    }

    private static func bodyDict(of request: URLRequest) -> [String: Any]? {
        guard let body = request.httpBody,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func requests(pathContaining fragment: String) -> [URLRequest] {
        GequhaiMockURLProtocol.receivedRequests.filter {
            $0.url?.path.contains(fragment) == true
        }
    }

    private static func requests(host: String) -> [URLRequest] {
        GequhaiMockURLProtocol.receivedRequests.filter {
            $0.url?.host == host
        }
    }

    /// fixture：搜索页 HTML（web 结构：myTables 表格，行 = 排名/歌名 a/歌手 td）
    private static let searchHTMLFixture = """
    <html><head><title>搜索</title></head><body>
    <div id="wrapper"><table id="myTables" class="table">
    <tr><th>排名</th><th>歌曲</th><th>歌手</th></tr>
    <tr>
      <td>1</td>
      <td><a href="/play/111111" target="_blank">晴天 &amp; 阴天</a></td>
      <td style="text-align:center;color: #666;font-size: 15px;">周杰伦</td>
    </tr>
    <tr>
      <td>2</td>
      <td><a href="/play/222222">七里香&#39;07</a></td>
      <td style="color:#666">Jay &amp; 周董</td>
    </tr>
    <tr><td>3</td><td><a href="/other/333">不是播放链接</a></td><td style="color: #666">无关</td></tr>
    <tr><td>4</td><td><a href="/play/444444">只有歌名无歌手</a></td></tr>
    <tr>
      <td>5</td>
      <td><a href="/play/555555">歌手留空</a></td>
      <td style="color: #666;"></td>
    </tr>
    </table></div>
    <table><tr><td>表格外的表不该被解析</td></tr></table>
    </body></html>
    """

    /// fixture：播放页 HTML（双引号 JS 变量 + mangled extra_url）
    private static func playHTMLFixture(
        playID: String = "123456",
        extraURL: String = "a#R0c#M6Ly9wYW4ucXVhcmsuY24vcy9IQVNhbXBsZVNoYXJl%2V5"
    ) -> String {
        """
        <html><head><script>
        window.play_id = "\(playID)";
        window.mp3_extra_url = "\(extraURL)";
        </script></head><body>歌曲播放页</body></html>
        """
    }

    // MARK: - GequhaiLogic：cleanText / unescapeHTML

    @Test("cleanText：解实体 + 折叠空白 + 去首尾（web _clean_text 顺序：sub→unescape→strip）")
    func cleanTextCollapseAndUnescape() {
        #expect(GequhaiLogic.cleanText("  晴天\n\t &amp; 阴天  ") == "晴天 & 阴天")
        #expect(GequhaiLogic.cleanText("A &lt;b&gt; C") == "A <b> C")
        #expect(GequhaiLogic.cleanText("  ").isEmpty)
        #expect(GequhaiLogic.cleanText(nil).isEmpty)
        #expect(GequhaiLogic.cleanText("").isEmpty)
        // 空白折叠在 unescape 之前（web 同序）——实体解码不产生空格折叠
        #expect(GequhaiLogic.cleanText("a&nbsp;b") == "a\u{00A0}b")
    }

    @Test("unescapeHTML：命名实体 + 数字实体（十进制/hex）+ 未知保留")
    func unescapeHTMLNamedAndNumeric() {
        #expect(GequhaiLogic.unescapeHTML("&amp;&lt;&gt;&quot;&apos;") == "&<>\"'")
        #expect(GequhaiLogic.unescapeHTML("&#39;07") == "'07")
        #expect(GequhaiLogic.unescapeHTML("&#x4E2D;&#x6587;") == "中文")
        #expect(GequhaiLogic.unescapeHTML("&copy; 2026") == "\u{00A9} 2026")
        // 未知命名实体 / 无分号 / 非法数字 → 保留原文
        #expect(GequhaiLogic.unescapeHTML("a &bogus; c") == "a &bogus; c")
        #expect(GequhaiLogic.unescapeHTML("no entities") == "no entities")
        #expect(GequhaiLogic.unescapeHTML("&#x110000;") == "&#x110000;")
        #expect(GequhaiLogic.unescapeHTML("&#;") == "&#;")
    }

    // MARK: - GequhaiLogic：parseSearchHTML

    @Test("parseSearchHTML：myTables 表格行映射（id/title/artist/page_url 逐字段）")
    func parseSearchHTMLRows() {
        let items = GequhaiLogic.parseSearchHTML(
            Self.searchHTMLFixture, playBaseURL: "https://www.gequhai.com/play"
        )
        #expect(items.count == 3)
        #expect(items[0].id == "111111")
        #expect(items[0].title == "晴天 & 阴天")
        #expect(items[0].artist == "周杰伦")
        #expect(items[0].pageURL == "https://www.gequhai.com/play/111111")
        #expect(items[1].id == "222222")
        #expect(items[1].title == "七里香'07")
        #expect(items[1].artist == "Jay & 周董")
        // 歌手 td 存在但内容空 → "未知歌手"（web or "未知歌手" 对齐）
        #expect(items[2].id == "555555")
        #expect(items[2].artist == "未知歌手")
    }

    @Test("parseSearchHTML：无 myTables 表 / 空 HTML → []；标题空的行跳过")
    func parseSearchHTMLNoTable() {
        #expect(GequhaiLogic.parseSearchHTML("", playBaseURL: "x").isEmpty)
        #expect(GequhaiLogic.parseSearchHTML(nil, playBaseURL: "x").isEmpty)
        #expect(GequhaiLogic.parseSearchHTML("<table id='other'><tr><td>1</td></tr></table>",
                                             playBaseURL: "x").isEmpty)
        // 无 id 的表 + 无关表结构
        #expect(GequhaiLogic.parseSearchHTML(
            "<table><tr><td><a href=\"/play/1\">t</a></td></tr></table>",
            playBaseURL: "x").isEmpty)
        // 歌名链接存在但标题为空（如 <a href="/play/9"></a>）→ 跳过
        let emptyTitle = """
        <table id="myTables"><tr><td><a href="/play/9">   </a></td>\
        <td style="color: #666">歌手</td></tr></table>
        """
        #expect(GequhaiLogic.parseSearchHTML(emptyTitle, playBaseURL: "x").isEmpty)
    }

    @Test("parseSearchHTML：id 无引号写法兼容（web [\"']? 对齐）")
    func parseSearchHTMLUnquotedID() {
        let html = """
        <table id=myTables><tr><td>1</td><td><a href="/play/77">歌</a></td>\
        <td style="color: #666">人</td></tr></table>
        """
        let items = GequhaiLogic.parseSearchHTML(html, playBaseURL: "https://p")
        #expect(items.count == 1)
        #expect(items.first?.id == "77")
    }

    // MARK: - GequhaiLogic：decodeExtraURL / parsePlayHTML

    @Test("decodeExtraURL：标准 base64 → 夸克分享 URL（web b64decode 对齐）")
    func decodeExtraURLStandard() {
        // "https://pan.quark.cn/s/abc123" 的 base64（python 交叉验证：aHR0c…MxMjM=）
        let b64 = Data("https://pan.quark.cn/s/abc123".utf8).base64EncodedString()
        #expect(GequhaiLogic.decodeExtraURL(b64) == "https://pan.quark.cn/s/abc123")
    }

    @Test("decodeExtraURL：'#'→'H'、'%'→'S' 还原后解码（web 替换语义）")
    func decodeExtraURLMangledSubstitution() {
        // 服务端把 base64 里的 H→#、S→% 后放进 URL；解码前换回（python 交叉验证样例）
        #expect(GequhaiLogic.decodeExtraURL(
            "a#R0c#M6Ly9wYW4ucXVhcmsuY24vcy9IQVNhbXBsZVNoYXJl%2V5"
        ) == "https://pan.quark.cn/s/HASampleShareKey")
    }

    @Test("decodeExtraURL：解码失败 / 非 http(s) / 空 → nil（web 语义）")
    func decodeExtraURLInvalid() {
        #expect(GequhaiLogic.decodeExtraURL(nil) == nil)
        #expect(GequhaiLogic.decodeExtraURL("") == nil)
        #expect(GequhaiLogic.decodeExtraURL("not-base64!!") == nil)
        #expect(GequhaiLogic.decodeExtraURL("YQ") == nil) // 缺 padding（python Incorrect padding）
        // base64 合法但解码结果非 http(s)（web _HTTP_URL_RE 检查）
        let notHTTP = Data("pan.quark.cn/s/abc123".utf8).base64EncodedString()
        #expect(GequhaiLogic.decodeExtraURL(notHTTP) == nil)
        let ftp = Data("ftp://pan.quark.cn/s/x".utf8).base64EncodedString()
        #expect(GequhaiLogic.decodeExtraURL(ftp) == nil)
    }

    @Test("decodeExtraURL：http 前缀大小写不敏感（web IGNORECASE 对齐）且返回原文")
    func decodeExtraURLCaseInsensitiveScheme() {
        let upper = Data("HTTPS://PAN.QUARK.CN/S/AbC".utf8).base64EncodedString()
        #expect(GequhaiLogic.decodeExtraURL(upper) == "HTTPS://PAN.QUARK.CN/S/AbC")
        let lower = Data("https://pan.quark.cn/s/AbC".utf8).base64EncodedString()
        #expect(GequhaiLogic.decodeExtraURL(lower) == "https://pan.quark.cn/s/AbC")
    }

    @Test("parsePlayHTML：play_id + mp3_extra_url 提取（双/单引号，web 正则对齐）")
    func parsePlayHTMLVariables() {
        // 双引号（fixture mangled extra）
        let info = GequhaiLogic.parsePlayHTML(Self.playHTMLFixture())
        #expect(info.playID == "123456")
        #expect(info.shareURL == "https://pan.quark.cn/s/HASampleShareKey")

        // 单引号 + 无替换的 standard extra
        let singleQuote = """
        <script>
        window.play_id = 'abc-def';
        window.mp3_extra_url = '\(Data("https://pan.quark.cn/s/zz9".utf8).base64EncodedString())';
        </script>
        """
        let info2 = GequhaiLogic.parsePlayHTML(singleQuote)
        #expect(info2.playID == "abc-def")
        #expect(info2.shareURL == "https://pan.quark.cn/s/zz9")
    }

    @Test("parsePlayHTML：字段缺失 / 空 HTML → 对应 nil（web 语义）")
    func parsePlayHTMLMissing() {
        #expect(GequhaiLogic.parsePlayHTML(nil).shareURL == nil)
        #expect(GequhaiLogic.parsePlayHTML(nil).playID == nil)
        #expect(GequhaiLogic.parsePlayHTML("").shareURL == nil)
        // 无 play_id / 无 extra
        let noPlayID = "<html>window.mp3_extra_url = 'abc';</html>"
        #expect(GequhaiLogic.parsePlayHTML(noPlayID).playID == nil)
        let noExtra = "<html>window.play_id = '9';</html>"
        let info = GequhaiLogic.parsePlayHTML(noExtra)
        #expect(info.playID == "9")
        #expect(info.shareURL == nil)
        // extra 存在但解码失败 → shareURL nil、playID 保留
        let badExtra = "<html>window.play_id = '9';window.mp3_extra_url = '%%%';</html>"
        let info2 = GequhaiLogic.parsePlayHTML(badExtra)
        #expect(info2.playID == "9")
        #expect(info2.shareURL == nil)
    }

    // MARK: - GequhaiLogic：limit / 翻页 / 编码

    @Test("normalizeLimit：收敛 [1,50]；pages：每页 10 条上限 5 页（web 公式对齐）")
    func limitAndPages() {
        #expect(GequhaiLogic.normalizeLimit(20) == 20)
        #expect(GequhaiLogic.normalizeLimit(0) == 1)
        #expect(GequhaiLogic.normalizeLimit(-5) == 1)
        #expect(GequhaiLogic.normalizeLimit(99) == 50)

        #expect(GequhaiLogic.pages(forLimit: 1) == 1)
        #expect(GequhaiLogic.pages(forLimit: 10) == 1)
        #expect(GequhaiLogic.pages(forLimit: 11) == 2)
        #expect(GequhaiLogic.pages(forLimit: 50) == 5)
        #expect(GequhaiLogic.pages(forLimit: 51) == 5) // 上限 50 → 5 页封顶
    }

    @Test("percentEncodePath：urllib quote(keyword) 语义（保留字母数字 _ . - ~ /）")
    func percentEncodePathQuoteSemantics() {
        // python 交叉验证：quote('中文 歌曲') = %E4%B8%AD%E6%96%87%20%E6%AD%8C%E6%9B%B2
        #expect(GequhaiLogic.percentEncodePath("中文 歌曲")
            == "%E4%B8%AD%E6%96%87%20%E6%AD%8C%E6%9B%B2")
        // safe 字符原样
        #expect(GequhaiLogic.percentEncodePath("abc-_.~/def") == "abc-_.~/def")
        #expect(GequhaiLogic.percentEncodePath("A&B?") == "A%26B%3F")
        #expect(GequhaiLogic.percentEncodePath("").isEmpty)
    }

    @Test("formEncoded：quote_plus 语义（空格→'+'，中文 UTF-8 编码）")
    func formEncodedQuotePlus() {
        // python 交叉验证：quote_plus('中文 歌曲') = %E4%B8%AD%E6%96%87+%E6%AD%8C%E6%9B%B2
        #expect(GequhaiLogic.formEncoded("中文 歌曲")
            == "%E4%B8%AD%E6%96%87+%E6%AD%8C%E6%9B%B2")
        #expect(GequhaiLogic.formEncoded("hello world") == "hello+world")
        #expect(GequhaiLogic.formEncoded("a/b&c") == "a%2Fb%26c")
    }

    @Test("decodeHTMLBytes：charset 指定 / UTF-8 / GB18030 兜底 / lossy")
    func decodeHTMLBytesEncodings() throws {
        // UTF-8
        let utf8 = Data("晴天".utf8)
        #expect(GequhaiLogic.decodeHTMLBytes(utf8, contentType: nil) == "晴天")
        #expect(GequhaiLogic.decodeHTMLBytes(utf8, contentType: "text/html; charset=utf-8")
            == "晴天")
        // GB18030 字节（无 charset 时兜底——中文站 GBK 场景）
        let gbkData = try #require(
            NSString(string: "七里香").data(using: GequhaiLogic.gb18030Encoding)
        )
        #expect(GequhaiLogic.decodeHTMLBytes(gbkData, contentType: nil) == "七里香")
        // 显式 charset=gbk 走 GB18030
        #expect(GequhaiLogic.decodeHTMLBytes(gbkData, contentType: "text/html; charset=gbk")
            == "七里香")
        // lossy：非法 UTF-8 字节不崩（httpx errors=replace 语义近似）
        let lossy = GequhaiLogic.decodeHTMLBytes(Data([0xFF, 0xFE, 0x41]), contentType: nil)
        #expect(lossy?.contains("A") == true)
    }

    // MARK: - 搜索：请求路径与字段

    @Test("search：单页成功——apiReady POST /api/s + GET /s/<kw> 的 URL/UA/Referer/解析")
    func searchSinglePage() async {
        GequhaiMockURLProtocol.reset()
        let client = Self.makeClient()
        GequhaiMockURLProtocol.handler = { request in
            if request.url?.host == "www.gequhai.com", request.url?.path == "/api/s" {
                return GequhaiMockURLProtocol.response(#"{"code":1}"#, for: request)
            }
            if request.url?.host == "www.gequhai.com", request.url?.path == "/s/晴天" {
                return GequhaiMockURLProtocol.response(Self.searchHTMLFixture, for: request)
            }
            throw URLError(.unsupportedURL)
        }

        let items = await client.search(query: "晴天", limit: 10)

        #expect(items.count == 3)
        #expect(items.first?.id == "111111")

        let requests = GequhaiMockURLProtocol.receivedRequests
        #expect(requests.count == 2)

        // 预检：POST /api/s，表单 keyword（quote_plus），X-Requested-With，Referer=根
        let ready = requests[0]
        #expect(ready.httpMethod == "POST")
        #expect(ready.value(forHTTPHeaderField: "User-Agent") == GequhaiClient.defaultUA)
        #expect(ready.value(forHTTPHeaderField: "X-Requested-With") == "XMLHttpRequest")
        #expect(ready.value(forHTTPHeaderField: "Referer") == "https://www.gequhai.com/")
        #expect(ready.value(forHTTPHeaderField: "Content-Type")
            == "application/x-www-form-urlencoded")
        #expect(Self.bodyString(of: ready) == "keyword=%E6%99%B4%E5%A4%A9")

        // 页面：GET /s/<quote(kw)>（中文路径直接可读；percent 编码在 URL 层），
        // Referer=搜索目录
        let page = requests[1]
        #expect(page.httpMethod == "GET")
        #expect(page.url?.path == "/s/晴天")
        #expect(page.value(forHTTPHeaderField: "User-Agent") == GequhaiClient.defaultUA)
        #expect(page.value(forHTTPHeaderField: "Referer") == "https://www.gequhai.com/s/")
    }

    @Test("search：keyword URL 百分号编码（quote 语义，路径含 %XX）")
    func searchKeywordPercentEncoded() async {
        GequhaiMockURLProtocol.reset()
        let client = Self.makeClient()
        GequhaiMockURLProtocol.handler = { request in
            // URL.path 是解码形态，编码断言用 absoluteString（保留 %XX）
            let absolute = request.url?.absoluteString ?? ""
            if absolute.contains("/api/s") {
                return GequhaiMockURLProtocol.response(#"{"code":1}"#, for: request)
            }
            if absolute.contains("/s/%E6%99%B4%E5%A4%A9%20%E6%AD%8C%E6%9B%B2") {
                return GequhaiMockURLProtocol.response(Self.searchHTMLFixture, for: request)
            }
            if absolute.contains("/s/ab%26cd") {
                return GequhaiMockURLProtocol.response(Self.searchHTMLFixture, for: request)
            }
            throw URLError(.unsupportedURL)
        }

        // handler 在 reset 后已重设；两次搜索共用（receivedRequests 累积，按 last 断言）
        _ = await client.search(query: "晴天 歌曲")
        let page = GequhaiMockURLProtocol.receivedRequests.last
        // python 交叉验证：quote('晴天 歌曲') → /s/%E6%99%B4%E5%A4%A9%20%E6%AD%8C%E6%9B%B2
        #expect(page?.url?.absoluteString.contains("/s/%E6%99%B4%E5%A4%A9%20%E6%AD%8C%E6%9B%B2") == true)

        _ = await client.search(query: "ab&cd")
        let page2 = GequhaiMockURLProtocol.receivedRequests.last
        // quote('ab&cd') → ab%26cd（& 编码，/ 保留）
        #expect(page2?.url?.absoluteString.contains("/s/ab%26cd") == true)
        #expect(page2?.url?.absoluteString.contains("/s/ab&cd") == false)
    }

    @Test("search：空 keyword → [] 不发任何请求（web 语义）")
    func searchEmptyKeyword() async {
        GequhaiMockURLProtocol.reset()
        let client = Self.makeClient()
        GequhaiMockURLProtocol.handler = { _ in
            throw URLError(.unsupportedURL)
        }
        #expect(await client.search(query: "   ").isEmpty)
        #expect(await client.search(query: "").isEmpty)
        #expect(GequhaiMockURLProtocol.receivedRequests.isEmpty)
    }

    @Test("search：apiReady code != 1 → [] 不发页面请求（web 预检语义）")
    func searchAPINotReady() async {
        GequhaiMockURLProtocol.reset()
        let client = Self.makeClient()
        GequhaiMockURLProtocol.handler = { request in
            GequhaiMockURLProtocol.response(#"{"code":0,"msg":"验证码"}"#, for: request)
        }
        let items = await client.search(query: "晴天")
        #expect(items.isEmpty)
        #expect(GequhaiMockURLProtocol.receivedRequests.count == 1)
        #expect(GequhaiMockURLProtocol.receivedRequests[0].url?.path == "/api/s")
    }

    @Test("search：apiReady 非 JSON / HTTP 500 / 网络错误 → []（web 不可用语义）")
    func searchAPIReadyFailures() async {
        // 非 JSON
        GequhaiMockURLProtocol.reset()
        GequhaiMockURLProtocol.handler = { request in
            GequhaiMockURLProtocol.response("<html>captcha</html>", for: request)
        }
        #expect(await Self.makeClient().search(query: "晴天").isEmpty)

        // HTTP 500
        GequhaiMockURLProtocol.reset()
        GequhaiMockURLProtocol.handler = { request in
            GequhaiMockURLProtocol.response("boom", status: 500, for: request)
        }
        #expect(await Self.makeClient().search(query: "晴天").isEmpty)

        // 传输层错误
        GequhaiMockURLProtocol.reset()
        GequhaiMockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(await Self.makeClient().search(query: "晴天").isEmpty)
    }

    @Test("search：limit>10 翻页（?page=N）凑够；超过 50 截断上限")
    func searchPagination() async {
        GequhaiMockURLProtocol.reset()
        let client = Self.makeClient()
        GequhaiMockURLProtocol.handler = { request in
            if request.url?.path == "/api/s" {
                return GequhaiMockURLProtocol.response(#"{"code":1}"#, for: request)
            }
            let page = Int(Self.queryValue("page", in: request) ?? "1") ?? 1
            // 每页 10 首（page 1/2 各 10 → 恰好 20）
            var rows = ""
            for i in 1 ... 10 {
                let n = (page - 1) * 10 + i
                rows += """
                <tr><td>\(n)</td><td><a href="/play/\(1000 + n)">歌曲\(n)</a></td>\
                <td style="color: #666">歌手</td></tr>
                """
            }
            return GequhaiMockURLProtocol.response(
                "<table id=\"myTables\">\(rows)</table>", for: request
            )
        }

        let items = await client.search(query: "周杰伦", limit: 20)

        #expect(items.count == 20)
        // page1 无 ?page；page2 有 ?page=2（web f-string 语义）
        let pageRequests = Self.requests(pathContaining: "/s/周杰伦")
        #expect(pageRequests.count == 2)
        #expect(Self.queryValue("page", in: pageRequests[0]) == nil)
        #expect(Self.queryValue("page", in: pageRequests[1]) == "2")
        #expect(items.first?.id == "1001")
        #expect(items.last?.id == "1020")

        // limit=50 → 5 页后截断 50 条（每页 10 × 5）
        GequhaiMockURLProtocol.reset()
        GequhaiMockURLProtocol.handler = { request in
            if request.url?.path == "/api/s" {
                return GequhaiMockURLProtocol.response(#"{"code":1}"#, for: request)
            }
            let page = Int(Self.queryValue("page", in: request) ?? "1") ?? 1
            var rows = ""
            for i in 1 ... 10 {
                let n = (page - 1) * 10 + i
                rows += """
                <tr><td>\(n)</td><td><a href="/play/\(n)">歌\(n)</a></td>\
                <td style="color: #666">人</td></tr>
                """
            }
            return GequhaiMockURLProtocol.response(
                "<table id=\"myTables\">\(rows)</table>", for: request
            )
        }
        let capped = await client.search(query: "周杰伦", limit: 99)
        #expect(capped.count == 50)
        #expect(Self.requests(pathContaining: "/s/周杰伦").count == 5)
    }

    @Test("search：中间页无结果提前停（web if not page_items: break）")
    func searchStopsOnEmptyPage() async {
        GequhaiMockURLProtocol.reset()
        let client = Self.makeClient()
        GequhaiMockURLProtocol.handler = { request in
            if request.url?.path == "/api/s" {
                return GequhaiMockURLProtocol.response(#"{"code":1}"#, for: request)
            }
            let page = Int(Self.queryValue("page", in: request) ?? "1") ?? 1
            if page >= 2 {
                return GequhaiMockURLProtocol.response("<html>无更多结果</html>", for: request)
            }
            return GequhaiMockURLProtocol.response(Self.searchHTMLFixture, for: request)
        }

        let items = await client.search(query: "晴天", limit: 50)
        #expect(items.count == 3)   // 第一页 3 条后第二页空 → 停
        #expect(Self.requests(pathContaining: "/s/晴天").count == 2)
    }

    @Test("search：页面 GET 非 2xx → []（web 顶层 except 对齐）")
    func searchPageHTTPErrorReturnsEmpty() async {
        GequhaiMockURLProtocol.reset()
        let client = Self.makeClient()
        GequhaiMockURLProtocol.handler = { request in
            if request.url?.path == "/api/s" {
                return GequhaiMockURLProtocol.response(#"{"code":1}"#, for: request)
            }
            return GequhaiMockURLProtocol.response("boom", status: 500, for: request)
        }
        #expect(await client.search(query: "晴天").isEmpty)
    }

    // MARK: - 播放信息

    @Test("playInfo：GET /play/<id> → shareURL 解码 + playID（UA/Referer 逐字段）")
    func playInfoSuccess() async {
        GequhaiMockURLProtocol.reset()
        let client = Self.makeClient()
        GequhaiMockURLProtocol.handler = { request in
            GequhaiMockURLProtocol.response(Self.playHTMLFixture(), for: request)
        }

        let info = await client.playInfo(songID: "123456")

        #expect(info.playID == "123456")
        #expect(info.shareURL == "https://pan.quark.cn/s/HASampleShareKey")
        let request = GequhaiMockURLProtocol.receivedRequests.first
        #expect(request?.httpMethod == "GET")
        #expect(request?.url?.path == "/play/123456")
        #expect(request?.url?.host == "www.gequhai.com")
        #expect(request?.value(forHTTPHeaderField: "User-Agent") == GequhaiClient.defaultUA)
        #expect(request?.value(forHTTPHeaderField: "Referer") == "https://www.gequhai.com/s/")
    }

    @Test("playInfo：songID 首尾空白容忍（web str().strip() 对齐）")
    func playInfoTrimsSongID() async {
        GequhaiMockURLProtocol.reset()
        let client = Self.makeClient()
        GequhaiMockURLProtocol.handler = { request in
            GequhaiMockURLProtocol.response(Self.playHTMLFixture(), for: request)
        }
        let info = await client.playInfo(songID: "  123456\n")
        #expect(info.playID == "123456")
        #expect(GequhaiMockURLProtocol.receivedRequests.first?.url?.path == "/play/123456")
    }

    @Test("playInfo：页面无 mp3_extra_url / 无分享 → shareURL nil（web 语义）")
    func playInfoNoShareURL() async {
        GequhaiMockURLProtocol.reset()
        let client = Self.makeClient()
        GequhaiMockURLProtocol.handler = { request in
            GequhaiMockURLProtocol.response(
                "<html>window.play_id = '9';</html>", for: request
            )
        }
        let info = await client.playInfo(songID: "9")
        #expect(info.playID == "9")
        #expect(info.shareURL == nil)
    }

    @Test("playInfo：HTTP 500 / 网络错误 / 空 id → {nil, nil}（web get_share_url 语义）")
    func playInfoFailure() async {
        // HTTP 500
        GequhaiMockURLProtocol.reset()
        GequhaiMockURLProtocol.handler = { request in
            GequhaiMockURLProtocol.response("boom", status: 500, for: request)
        }
        let info = await Self.makeClient().playInfo(songID: "1")
        #expect(info.shareURL == nil)
        #expect(info.playID == nil)

        // 网络错误
        GequhaiMockURLProtocol.reset()
        GequhaiMockURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let info2 = await Self.makeClient().playInfo(songID: "1")
        #expect(info2.shareURL == nil)

        // 空 id → 不发请求
        GequhaiMockURLProtocol.reset()
        let info3 = await Self.makeClient().playInfo(songID: "  ")
        #expect(info3.shareURL == nil)
        #expect(GequhaiMockURLProtocol.receivedRequests.isEmpty)
    }

    // MARK: - 下载编排（playInfo → resolveShare → pickFile → getDownloadURL）

    /// 安装「gequhai play + quark 分享解析 + 直链」全链路 handler；默认 mp3 分享文件
    private static func installFullChainHandler(
        shareFiles: [[String: Any]] = [
            [
                "fid": "f-mp3", "file_name": "晴天.mp3", "size": 4_200_000,
                "format_type": "file", "share_fid_token": "tok-mp3",
            ],
        ],
        downloadURL: String = "https://dl.quark.cn/x/song.mp3?sign=xyz"
    ) {
        let filesJSON = shareFiles
        GequhaiMockURLProtocol.handler = { request in
            guard let host = request.url?.host, let path = request.url?.path else {
                throw URLError(.unsupportedURL)
            }
            switch host {
            case "www.gequhai.com":
                // gequhai play 页 → 分享 URL https://pan.quark.cn/s/abc123
                if path == "/play/123456" {
                    let b64 = Data("https://pan.quark.cn/s/abc123".utf8).base64EncodedString()
                    return GequhaiMockURLProtocol.response(
                        Self.playHTMLFixture(extraURL: b64), for: request
                    )
                }
            case "drive-pc.quark.cn":
                if path.contains("/share/sharepage/token") {
                    return GequhaiMockURLProtocol.response(
                        #"{"code":0,"data":{"stoken":"sTok-1"}}"#, for: request
                    )
                }
                if path.contains("/share/sharepage/detail") {
                    let body: [String: Any] = [
                        "code": 0,
                        "data": ["list": filesJSON],
                        "metadata": ["_total": filesJSON.count],
                    ]
                    let data = try JSONSerialization.data(withJSONObject: body)
                    return (
                        HTTPURLResponse(
                            url: request.url!, statusCode: 200, httpVersion: nil,
                            headerFields: ["Content-Type": "application/json"]
                        )!,
                        data
                    )
                }
                if path.contains("/file/download") {
                    return GequhaiMockURLProtocol.response(
                        #"{"status":200,"code":0,"data":[{"download_url":"\#(downloadURL)"}]}"#,
                        for: request
                    )
                }
            default:
                break
            }
            throw URLError(.unsupportedURL)
        }
    }

    @Test("downloadInfo：songID 全链路成功——直链+元信息+请求顺序与字段")
    func downloadInfoFullChain() async throws {
        GequhaiMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("chain")
        try Self.writeCookieFile(cookieFile)
        let client = Self.makeClient(cookieFile: cookieFile)
        Self.installFullChainHandler()

        let info = try await client.downloadInfo(songID: "123456")

        // 产物（直链 + 下载头快照 + 元信息）
        #expect(info.urlString == "https://dl.quark.cn/x/song.mp3?sign=xyz")
        #expect(info.headers["User-Agent"] == QuarkClient.quarkClientUA)
        #expect(info.headers["Cookie"] == "pan_us=abc123")
        #expect(info.fileName == "晴天.mp3")
        #expect(info.size == 4_200_000)
        #expect(info.ext == ".mp3")

        // 请求顺序：gequhai play → quark token → detail → config（取直链前 __puus 保活）
        // → download（5 个；config 为 2026-09-08 getDownloadURL 前 refreshPUUS 接入）
        let urls = GequhaiMockURLProtocol.receivedRequests.compactMap { $0.url?.absoluteString }
        #expect(urls.count == 5)
        #expect(urls[0].contains("www.gequhai.com/play/123456"))
        #expect(urls[1].contains("drive-pc.quark.cn"))
        #expect(urls[1].contains("/share/sharepage/token"))
        #expect(urls[2].contains("/share/sharepage/detail"))
        #expect(urls[3].contains("/1/clouddrive/config"))
        #expect(urls[4].contains("/file/download"))

        // download 请求字段（fids/fids_token/pwd_id/stoken——web 逐字）
        let downloadRequest = GequhaiMockURLProtocol.receivedRequests[4]
        let body = Self.bodyDict(of: downloadRequest)
        #expect(body?["fids"] as? [String] == ["f-mp3"])
        #expect(body?["fids_token"] as? [String] == ["tok-mp3"])
        #expect(body?["pwd_id"] as? String == "abc123")
        #expect(body?["stoken"] as? String == "sTok-1")
        Self.removeFileIfExists(cookieFile)
    }

    @Test("downloadInfo：shareURL 直链入口（跳过 playInfo）")
    func downloadInfoFromShareURL() async throws {
        GequhaiMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("share-entry")
        try Self.writeCookieFile(cookieFile)
        let client = Self.makeClient(cookieFile: cookieFile)
        Self.installFullChainHandler()

        let info = try await client.downloadInfo(
            shareURL: "https://pan.quark.cn/s/abc123", quality: "mp3"
        )

        #expect(info.urlString == "https://dl.quark.cn/x/song.mp3?sign=xyz")
        #expect(info.ext == ".mp3")
        // 不经过 gequhai play 页
        let firstURL = GequhaiMockURLProtocol.receivedRequests[0].url?.absoluteString ?? ""
        #expect(firstURL.contains("drive-pc.quark.cn"))
        // token → detail → config（取直链前 __puus 保活）→ download
        #expect(GequhaiMockURLProtocol.receivedRequests.count == 4)
        Self.removeFileIfExists(cookieFile)
    }

    @Test("downloadInfo：quality=flac 挑 flac（同享多格式，fids_token 指向 flac）")
    func downloadInfoPrefersFlac() async throws {
        GequhaiMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("flac")
        try Self.writeCookieFile(cookieFile)
        let client = Self.makeClient(cookieFile: cookieFile)
        Self.installFullChainHandler(shareFiles: [
            [
                "fid": "f-mp3", "file_name": "晴天.mp3", "size": 4_000_000,
                "format_type": "file", "share_fid_token": "tok-mp3",
            ],
            [
                "fid": "f-flac", "file_name": "晴天.flac", "size": 30_000_000,
                "format_type": "file", "share_fid_token": "tok-flac",
            ],
        ])

        let info = try await client.downloadInfo(songID: "123456", quality: "flac")

        #expect(info.ext == ".flac")
        #expect(info.fileName == "晴天.flac")
        let body = Self.bodyDict(of: GequhaiMockURLProtocol.receivedRequests[4])
        #expect(body?["fids_token"] as? [String] == ["tok-flac"])
        Self.removeFileIfExists(cookieFile)
    }

    @Test("downloadInfo：播放页无分享 URL → noShareURL（web 404 文案）")
    func downloadInfoNoShareURL() async {
        GequhaiMockURLProtocol.reset()
        let client = Self.makeClient()
        GequhaiMockURLProtocol.handler = { request in
            GequhaiMockURLProtocol.response(
                "<html>window.play_id = '9';</html>", for: request
            )
        }
        do {
            _ = try await client.downloadInfo(songID: "9")
            Issue.record("应抛 noShareURL")
        } catch let error as GequhaiDownloadError {
            #expect(error == .noShareURL)
            #expect(error.errorDescription == "该歌曲没有夸克网盘分享链接")
        } catch {
            Issue.record("期望 GequhaiDownloadError，实际 \(error)")
        }
    }

    @Test("downloadInfo：夸克分享解析失败（token 业务错）→ shareEmptyOrExpired")
    func downloadInfoShareEmpty() async {
        GequhaiMockURLProtocol.reset()
        let client = Self.makeClient()
        Self.installFullChainHandler()   // 先装正常链路拿到 play URL……
        // ……但 quark 端点一律 token 失败 → resolve 空
        GequhaiMockURLProtocol.handler = { request in
            if request.url?.host == "www.gequhai.com" {
                let b64 = Data("https://pan.quark.cn/s/abc123".utf8).base64EncodedString()
                return GequhaiMockURLProtocol.response(
                    Self.playHTMLFixture(extraURL: b64), for: request
                )
            }
            return GequhaiMockURLProtocol.response(
                #"{"code":40101,"message":"需要提取码"}"#, for: request
            )
        }
        do {
            _ = try await client.downloadInfo(songID: "123456")
            Issue.record("应抛 shareEmptyOrExpired")
        } catch let error as GequhaiDownloadError {
            #expect(error == .shareEmptyOrExpired)
            #expect(error.errorDescription == "夸克分享链接为空或已失效")
        } catch {
            Issue.record("期望 GequhaiDownloadError，实际 \(error)")
        }
    }

    @Test("downloadInfo：分享列表无音频 → noAudioFile（web 404 文案）")
    func downloadInfoNoAudioFile() async {
        GequhaiMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("noaudio")
        try? Self.writeCookieFile(cookieFile)
        let client = Self.makeClient(cookieFile: cookieFile)
        Self.installFullChainHandler(shareFiles: [
            [
                "fid": "f-txt", "file_name": "说明.txt", "size": 100,
                "format_type": "file", "share_fid_token": "tok-txt",
            ],
        ])
        do {
            _ = try await client.downloadInfo(songID: "123456")
            Issue.record("应抛 noAudioFile")
        } catch let error as GequhaiDownloadError {
            #expect(error == .noAudioFile)
            #expect(error.errorDescription == "分享中没有可下载的音频文件")
        } catch {
            Issue.record("期望 GequhaiDownloadError，实际 \(error)")
        }
        Self.removeFileIfExists(cookieFile)
    }

    @Test("downloadInfo：未登录（无 quark cookie 文件）→ quarkLoginRequired（web 401）")
    func downloadInfoLoginRequired() async {
        GequhaiMockURLProtocol.reset()
        // 不写 cookie 文件 → quark getDownloadURL 前置检查抛 loginRequired
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("nologin"))
        Self.installFullChainHandler()
        do {
            _ = try await client.downloadInfo(songID: "123456")
            Issue.record("应抛 quarkLoginRequired")
        } catch let error as GequhaiDownloadError {
            #expect(error == .quarkLoginRequired)
            #expect(error.errorDescription == "需要登录夸克网盘")
        } catch {
            Issue.record("期望 GequhaiDownloadError，实际 \(error)")
        }
        // resolve 两个请求已发出，download 未发出（登录前置检查在先）
        let quarkRequests = Self.requests(host: "drive-pc.quark.cn")
        #expect(quarkRequests.count == 2)
    }

    @Test("downloadInfo：quark 直链业务失败 → quarkFailed 透传文案")
    func downloadInfoQuarkFailed() async {
        GequhaiMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("quarkfail")
        try? Self.writeCookieFile(cookieFile)
        let client = Self.makeClient(cookieFile: cookieFile)
        GequhaiMockURLProtocol.handler = { request in
            guard let host = request.url?.host, let path = request.url?.path else {
                throw URLError(.unsupportedURL)
            }
            if host == "www.gequhai.com" {
                let b64 = Data("https://pan.quark.cn/s/abc123".utf8).base64EncodedString()
                return GequhaiMockURLProtocol.response(
                    Self.playHTMLFixture(extraURL: b64), for: request
                )
            }
            if path.contains("/share/sharepage/token") {
                return GequhaiMockURLProtocol.response(
                    #"{"code":0,"data":{"stoken":"sTok-1"}}"#, for: request
                )
            }
            if path.contains("/share/sharepage/detail") {
                let filesJSON: [[String: Any]] = [[
                    "fid": "f-mp3", "file_name": "a.mp3", "size": 1,
                    "format_type": "file", "share_fid_token": "tok",
                ]]
                let body: [String: Any] = [
                    "code": 0, "data": ["list": filesJSON], "metadata": ["_total": 1],
                ]
                let data = try JSONSerialization.data(withJSONObject: body)
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )!,
                    data
                )
            }
            // /file/download 业务失败（status != 200 && code != 0）
            return GequhaiMockURLProtocol.response(
                #"{"status":400,"code":41020,"message":"转存文件token校验异常"}"#,
                for: request
            )
        }
        do {
            _ = try await client.downloadInfo(songID: "123456")
            Issue.record("应抛 quarkFailed")
        } catch let error as GequhaiDownloadError {
            guard case .quarkFailed(let reason) = error else {
                Issue.record("期望 quarkFailed，实际 \(error)")
                return
            }
            #expect(reason.contains("转存文件token校验异常"))
        } catch {
            Issue.record("期望 GequhaiDownloadError，实际 \(error)")
        }
        Self.removeFileIfExists(cookieFile)
    }
}
