//
//  QuarkClientTests.swift
//  QQPlayerTests
//
//  夸克网盘客户端（web backend/quark_provider.py 移植，E2 下载批）防回归测试：
//  ① QuarkLogic 纯逻辑：share token 提取（正则/大小写/前后缀）、扩展名、目录判定、
//     pick_file 降级决策（mp3 默认/flac 可选/兜底音频/同 size 取先）、Set-Cookie 解析
//     （多条合并 + Expires 日期逗号）、cookie 序列化/反序列化（含损坏兜底）
//  ② 扫码登录状态机（QuarkMockURLProtocol 注入）：qr 生成（请求路径/参数/UA）、
//     waiting/expired/ok 全链路（ticket 交换 + Set-Cookie 持久化）、error 状态、
//     login_state 冒烟语义（200 success/非 200 清文件/网络错保留）
//  ③ 分享解析 mock：token/detail 请求路径与字段、目录递归（深度 ≤3）、翻页、
//     fid 去重、失败 → 空数组（web 语义）
//  ④ 下载直链 mock：登录前置检查、401/403 不删 cookie、成功头快照（UA/Cookie/
//     Referer/Origin）、业务码失败
//  ⑤ refreshPUUS：不带 __puus 请求 → 服务端重发才持久化；失败静默
//  ⑥ cookie 文件：round-trip、0600 权限、.tmp 原子写残留清理、损坏文件兜底
//
//  隔离说明：自带 QuarkMockURLProtocol（独立 URLProtocol 类，静态状态只属于自己，
//  行为与共享 MockURLProtocol 一致），与其他 suite 共用互不干扰，跨 suite 可并行；
//  suite 内 .serialized（静态 handler/receivedRequests 是进程级状态）。所有用例
//  cookieFileURL 指向临时目录，绝不碰真实 App Support 文件。全程不发真实网络。
//

import Foundation
import Testing

@testable import QQPlayer

/// 夸克测试专用 URLProtocol mock（实现同 MockURLProtocol，静态状态独立）
final class QuarkMockURLProtocol: URLProtocol {
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
        QuarkMockURLProtocol.receivedRequests.append(request)
        guard let handler = QuarkMockURLProtocol.handler else {
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
struct QuarkClientTests {
    // MARK: - 基建

    /// 注入 QuarkMockURLProtocol 的 client；sleep no-op（quark 无内部 sleep，纯骨架）
    private static func makeClient(cookieFile: URL) -> QuarkClient {
        QuarkClient(
            sleep: { _ in },
            cookieFileURL: cookieFile,
            protocolClasses: [QuarkMockURLProtocol.self]
        )
    }

    /// 测试专用 cookie 文件（临时目录，测试结束清理）
    private static func tempCookieURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("quark-tests-\(UUID().uuidString)-\(name)", isDirectory: true)
            .appendingPathComponent("quark_cookies.json")
    }

    private static func removeFileIfExists(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// 写测试 cookie 文件（自动建目录）
    private static func writeCookieFile(_ url: URL, _ cookies: [String: String]) throws {
        guard let data = QuarkLogic.cookiesData(cookies) else {
            throw QuarkClientError.invalidResponse
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url)
    }

    private static func queryItems(of request: URLRequest) -> [URLQueryItem] {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    }

    private static func queryValue(_ name: String, in request: URLRequest) -> String? {
        queryItems(of: request).first { $0.name == name }?.value
    }

    private static func requests(pathContaining fragment: String) -> [URLRequest] {
        QuarkMockURLProtocol.receivedRequests.filter {
            $0.url?.path.contains(fragment) == true
        }
    }

    private static func bodyDict(of request: URLRequest) -> [String: Any]? {
        // URLSession 会把 httpBody 转成 httpBodyStream 再交给 URLProtocol——
        // 直接读 httpBody 恒为 nil；这里兜底从 stream 重建
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufferSize = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: bufferSize)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            body = data
        }
        guard let body,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return obj
    }

    /// 目录项 JSON（web sharepage/detail list 元素）
    private static func dirItem(fid: String, name: String) -> [String: Any] {
        [
            "fid": fid, "file_name": name, "size": 0, "format_type": "folder",
            "share_fid_token": "tok-\(fid)",
        ]
    }

    private static func fileItem(
        fid: String, name: String, size: Int = 100, token: String? = nil
    ) -> [String: Any] {
        [
            "fid": fid, "file_name": name, "size": size, "format_type": "file",
            "share_fid_token": token ?? "tok-\(fid)",
        ]
    }

    // MARK: - QuarkLogic：share token 提取

    @Test("shareToken：标准夸克分享 URL 提取 pwd_id")
    func shareTokenStandard() {
        #expect(QuarkLogic.shareToken(from: "https://pan.quark.cn/s/AbC123xyz") == "AbC123xyz")
        #expect(QuarkLogic.shareToken(from: "pan.quark.cn/s/9zz8") == "9zz8")
    }

    @Test("shareToken：容忍首尾空白与前后缀（规范化语义）")
    func shareTokenNormalization() {
        #expect(QuarkLogic.shareToken(from: "   https://pan.quark.cn/s/abc123\n") == "abc123")
        #expect(QuarkLogic.shareToken(from: "歌曲分享：https://pan.quark.cn/s/xyz789 请查收") == "xyz789")
        #expect(QuarkLogic.shareToken(from: "https://pan.quark.cn/s/abc123?pwd=1#top") == "abc123")
    }

    @Test("shareToken：host/路径大小写不敏感（web IGNORECASE 对齐）")
    func shareTokenCaseInsensitive() {
        #expect(QuarkLogic.shareToken(from: "https://PAN.QUARK.CN/S/ABC123") == "ABC123")
        #expect(QuarkLogic.shareToken(from: "https://Pan.Quark.Cn/S/a1b2") == "a1b2")
    }

    @Test("shareToken：非夸克/无 token → nil")
    func shareTokenInvalid() {
        #expect(QuarkLogic.shareToken(from: "https://pan.baidu.com/s/1abc") == nil)
        #expect(QuarkLogic.shareToken(from: "https://pan.quark.cn/list") == nil)
        #expect(QuarkLogic.shareToken(from: "https://pan.quark.cn/s/") == nil)
        #expect(QuarkLogic.shareToken(from: "") == nil)
        #expect(QuarkLogic.shareToken(from: "   \n  ") == nil)
        #expect(QuarkLogic.shareToken(from: "https://quark.cn/s/abc") == nil)
    }

    // MARK: - QuarkLogic：扩展名 / 目录判定

    @Test("extensionOf：小写带点扩展名，无扩展名空串")
    func extensionOf() {
        #expect(QuarkLogic.extensionOf(fileName: "song.mp3") == ".mp3")
        #expect(QuarkLogic.extensionOf(fileName: "SONG.FLAC") == ".flac")
        #expect(QuarkLogic.extensionOf(fileName: "archive.tar.gz") == ".gz")
        #expect(QuarkLogic.extensionOf(fileName: "noext").isEmpty)
        #expect(QuarkLogic.extensionOf(fileName: "").isEmpty)
    }

    @Test("rawIsDirectory：dir 布尔字段优先")
    func rawIsDirectoryBool() {
        #expect(QuarkLogic.rawIsDirectory(["dir": true]) == true)
        #expect(QuarkLogic.rawIsDirectory(["dir": false]) == false)
    }

    @Test("rawIsDirectory：format_type/file_type 字符串兜底，数字不作判据")
    func rawIsDirectoryStringFallback() {
        #expect(QuarkLogic.rawIsDirectory(["format_type": "folder"]) == true)
        #expect(QuarkLogic.rawIsDirectory(["format_type": "DIR"]) == true)
        #expect(QuarkLogic.rawIsDirectory(["format_type": "file"]) == false)
        #expect(QuarkLogic.rawIsDirectory(["file_type": "folder"]) == true)
        #expect(QuarkLogic.rawIsDirectory(["file_type": "dir"]) == true)
        // file_type 数字语义不稳定（实测文件=1），web 明确不作为判据
        #expect(QuarkLogic.rawIsDirectory(["file_type": 1]) == false)
        #expect(QuarkLogic.rawIsDirectory(["file_type": "1"]) == false)
        #expect(QuarkLogic.rawIsDirectory([:]) == false)
        #expect(QuarkLogic.rawIsDirectory(["dir": "true"]) == false)
    }

    // MARK: - QuarkLogic：pick_file 降级决策

    private static func audioFile(fid: String, ext: String, size: Int, fileName: String? = nil) -> QuarkShareFile {
        QuarkShareFile(
            fid: fid,
            fileName: fileName ?? "song.\(ext)",
            size: Int64(size),
            formatType: "file",
            shareFidToken: "tok",
            ext: QuarkLogic.extensionOf(fileName: fileName ?? "song.\(ext)")
        )
    }

    @Test("pickFile：默认 mp3 优先（flac 更大也不降级——web primary 存在即返回）")
    func pickFileDefaultPrefersMp3() {
        let files = [
            Self.audioFile(fid: "flac", ext: "flac", size: 500),
            Self.audioFile(fid: "mp3", ext: "mp3", size: 10),
        ]
        let picked = QuarkLogic.pickFile(files, quality: nil)
        #expect(picked?.fid == "mp3")
        #expect(QuarkLogic.pickFile(files, quality: "mp3")?.fid == "mp3")
    }

    @Test("pickFile：quality=flac 优先 flac（大小写/空白容忍）")
    func pickFilePrefersFlac() {
        let files = [
            Self.audioFile(fid: "flac", ext: "flac", size: 5),
            Self.audioFile(fid: "mp3", ext: "mp3", size: 900),
        ]
        #expect(QuarkLogic.pickFile(files, quality: "flac")?.fid == "flac")
        #expect(QuarkLogic.pickFile(files, quality: " FLAC ")?.fid == "flac")
    }

    @Test("pickFile：偏好缺失自动降级另一格式")
    func pickFileDowngrade() {
        let onlyFlac = [Self.audioFile(fid: "f1", ext: "flac", size: 42)]
        #expect(QuarkLogic.pickFile(onlyFlac, quality: "mp3")?.fid == "f1")
        #expect(QuarkLogic.pickFile(onlyFlac, quality: nil)?.fid == "f1")
        let onlyMp3 = [Self.audioFile(fid: "m1", ext: "mp3", size: 42)]
        #expect(QuarkLogic.pickFile(onlyMp3, quality: "flac")?.fid == "m1")
    }

    @Test("pickFile：非偏好也非另一格式 → 兜底任何音频扩展（m4a/wav…）")
    func pickFileAudioExtFallback() {
        let files = [
            Self.audioFile(fid: "m4a", ext: "m4a", size: 7),
            Self.audioFile(fid: "wav", ext: "wav", size: 80),
        ]
        #expect(QuarkLogic.pickFile(files, quality: nil)?.fid == "wav")   // size 最大
        let onlyM4a = [Self.audioFile(fid: "m4a", ext: "m4a", size: 7)]
        #expect(QuarkLogic.pickFile(onlyM4a, quality: "flac")?.fid == "m4a")
    }

    @Test("pickFile：无音频 → nil；空数组 → nil")
    func pickFileNoAudio() {
        let txt = QuarkShareFile(
            fid: "t1", fileName: "a.txt", size: 1, formatType: "file",
            shareFidToken: "tok", ext: ".txt"
        )
        #expect(QuarkLogic.pickFile([txt], quality: nil) == nil)
        #expect(QuarkLogic.pickFile([], quality: "flac") == nil)
    }

    @Test("pickFile：同格式多个取 size 最大；并列取先出现（Python max 语义）")
    func pickFileMaxBySizeFirstOnTie() {
        let files = [
            Self.audioFile(fid: "small", ext: "mp3", size: 10),
            Self.audioFile(fid: "big", ext: "mp3", size: 999),
        ]
        #expect(QuarkLogic.pickFile(files, quality: nil)?.fid == "big")

        let tied = [
            Self.audioFile(fid: "first", ext: "flac", size: 50),
            Self.audioFile(fid: "second", ext: "flac", size: 50),
        ]
        #expect(QuarkLogic.pickFile(tied, quality: "flac")?.fid == "first")
    }

    @Test("pickFile：ext 缺失时用文件名后缀兜底（web 内层 _ext 对齐）")
    func pickFileExtFromFileName() {
        let file = QuarkShareFile(
            fid: "f1", fileName: "现场录音.FLAC", size: 10, formatType: "file",
            shareFidToken: "tok", ext: ""
        )
        #expect(QuarkLogic.pickFile([file], quality: "flac")?.fid == "f1")
    }

    // MARK: - QuarkLogic：Set-Cookie 解析

    @Test("parseSetCookieHeaders：单条带属性头")
    func parseSetCookieSingle() {
        let jar = QuarkLogic.parseSetCookieHeaders([
            "pan_us=abc123; Path=/; HttpOnly",
        ])
        #expect(jar == ["pan_us": "abc123"])
    }

    @Test("parseSetCookieHeaders：多条合并字符串 + Expires 日期逗号不误切")
    func parseSetCookieCombinedWithExpires() {
        // URLSession 把同名多个 Set-Cookie 拼成一条：逗号后紧跟 name= 才切分，
        // "Wed, 21 Oct 2026" 日期里的逗号后不是 name=，不会误切
        let header = "pan_us=abc; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/; HttpOnly, "
            + "__puus=new2; Path=/"
        let jar = QuarkLogic.parseSetCookieHeaders([header])
        #expect(jar["pan_us"] == "abc")
        #expect(jar["__puus"] == "new2")
    }

    @Test("parseSetCookieHeaders：value 含 = 与多段数组输入")
    func parseSetCookieValueWithEquals() {
        let jar = QuarkLogic.parseSetCookieHeaders([
            "st=abc=def==; Path=/",
            "token=xyz",
            "",
        ])
        #expect(jar["st"] == "abc=def==")
        #expect(jar["token"] == "xyz")
    }

    @Test("parseSetCookieHeaders：无 name= 的垃圾段跳过")
    func parseSetCookieGarbage() {
        let jar = QuarkLogic.parseSetCookieHeaders(["not-a-cookie", "; Path=/", "=novalue"])
        #expect(jar.isEmpty)
    }

    // MARK: - QuarkLogic：cookie 序列化 round-trip / 损坏兜底

    @Test("cookiesData/cookies：round-trip 相等；空字典可持久化")
    func cookiesRoundTrip() {
        let cookies = ["pan_us": "abc", "__puus": "xyz"]
        let data = QuarkLogic.cookiesData(cookies)
        #expect(data != nil)
        #expect(QuarkLogic.cookies(from: data!) == cookies)

        let emptyData = QuarkLogic.cookiesData([:])
        #expect(emptyData != nil)
        #expect(QuarkLogic.cookies(from: emptyData!) == [:])
    }

    @Test("cookies(from:)：损坏 JSON / 非 dict / 非字符串值 → nil（兜底为空）")
    func cookiesCorrupted() {
        #expect(QuarkLogic.cookies(from: Data("{{{{ not json".utf8)) == nil)
        #expect(QuarkLogic.cookies(from: Data("[1,2,3]".utf8)) == nil)
        #expect(QuarkLogic.cookies(from: Data("{\"a\": 1}".utf8)) == nil)
        #expect(QuarkLogic.cookies(from: Data("null".utf8)) == nil)
        #expect(QuarkLogic.cookies(from: Data()) == nil)
    }

    @Test("cookieHeader：k=v; 连接，空字典 → 空串")
    func cookieHeaderJoin() {
        #expect(QuarkLogic.cookieHeader(["a": "1", "b": "2"]) == "a=1; b=2")
        #expect(QuarkLogic.cookieHeader([:]).isEmpty)
    }

    // MARK: - 扫码登录：二维码生成

    @Test("loginQRCode：请求参数/UA 与响应结构（web login_qrcode 对齐）")
    func loginQRCodeSuccess() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("qr")
        let client = Self.makeClient(cookieFile: cookieFile)
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"data":{"members":{"token":"tok-abc"}}}"#,
                for: request
            )
        }

        let qr = try await client.loginQRCode()

        let requests = QuarkMockURLProtocol.receivedRequests
        #expect(requests.count == 1)
        let request = requests[0]
        #expect(request.url?.path == "/cas/ajax/getTokenForQrcodeLogin")
        #expect(request.url?.host == "uop.quark.cn")
        #expect(request.httpMethod == "GET")
        #expect(Self.queryValue("client_id", in: request) == "532")
        #expect(Self.queryValue("v", in: request) == "1.2")
        let requestID = Self.queryValue("request_id", in: request)
        #expect(requestID?.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil)
        #expect(request.value(forHTTPHeaderField: "User-Agent") == QuarkClient.browserUA)

        #expect(qr.qrID.isEmpty == false)
        #expect(qr.expiresIn == 170)
        #expect(qr.contentURL == "https://su.quark.cn/4_eMHBJ?token=tok-abc&client_id=532"
            + "&ssb=weblogin&uc_param_str=&uc_biz_str=S%3Acustom%7COPT%3ASAREA%400"
            + "%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400")
    }

    @Test("loginQRCode：token 缺失 → serverMessage（web RuntimeError 对齐）")
    func loginQRCodeMissingToken() async {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("qr-notoken"))
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(#"{"message":"服务繁忙"}"#, for: request)
        }
        await Self.expectServerMessage(containing: "获取扫码 token 失败: 服务繁忙") {
            _ = try await client.loginQRCode()
        }
    }

    @Test("loginQRCode：HTTP 500 → httpStatus")
    func loginQRCodeHTTPError() async {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("qr-500"))
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response("boom", status: 500, for: request)
        }
        await Self.expectQuarkError(.httpStatus(500)) {
            _ = try await client.loginQRCode()
        }
    }

    // MARK: - 扫码登录：状态机

    @Test("loginStatus：未知 qr_id → error「登录会话已失效」（web token 缺失语义）")
    func loginStatusUnknownQRID() async throws {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("unknown"))

        let status = try await client.loginStatus(qrID: "no-such-id")

        #expect(status.state == .error)
        #expect(status.message == "登录会话已失效，请重新扫码")
        #expect(QuarkMockURLProtocol.receivedRequests.isEmpty)   // 不发请求
    }

    @Test("loginStatus：waiting（50004001）；请求带 token/参数与浏览器 UA")
    func loginStatusWaiting() async throws {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("waiting"))
        // 先拿 token（web 流程：loginQRCode 生成 → loginStatus 轮询）
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"data":{"members":{"token":"tok-1"}}}"#,
                for: request
            )
        }
        let qr = try await client.loginQRCode()

        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(#"{"status":50004001}"#, for: request)
        }
        let status = try await client.loginStatus(qrID: qr.qrID)

        #expect(status.state == .waiting)
        #expect(status.nickname == nil)
        let pollRequest = QuarkMockURLProtocol.receivedRequests.last!
        #expect(pollRequest.url?.path == "/cas/ajax/getServiceTicketByQrcodeToken")
        #expect(pollRequest.url?.host == "uop.quark.cn")
        #expect(Self.queryValue("token", in: pollRequest) == "tok-1")
        #expect(Self.queryValue("client_id", in: pollRequest) == "532")
        #expect(Self.queryValue("v", in: pollRequest) == "1.2")
        #expect(pollRequest.value(forHTTPHeaderField: "User-Agent") == QuarkClient.browserUA)
    }

    @Test("loginStatus：expired（50004002）→ token 弹出，再查报会话失效")
    func loginStatusExpiredPopsToken() async throws {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("expired"))
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"data":{"members":{"token":"tok-2"}}}"#,
                for: request
            )
        }
        let qr = try await client.loginQRCode()

        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(#"{"status":50004002}"#, for: request)
        }
        let status = try await client.loginStatus(qrID: qr.qrID)
        #expect(status.state == .expired)
        #expect(status.message == "二维码已过期，请重新扫码")

        // token 已弹出（web _QR_TOKENS.pop 对齐）→ 再次查询直接 error
        let again = try await client.loginStatus(qrID: qr.qrID)
        #expect(again.state == .error)
        #expect(again.message == "登录会话已失效，请重新扫码")
    }

    @Test("loginStatus：ok 全链路——ticket 交换收 Set-Cookie 持久化 + nickname")
    func loginStatusOkPersistsCookies() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("login-ok")
        let client = Self.makeClient(cookieFile: cookieFile)
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"data":{"members":{"token":"tok-3"}}}"#,
                for: request
            )
        }
        let qr = try await client.loginQRCode()

        QuarkMockURLProtocol.handler = { request in
            if request.url?.path == "/cas/ajax/getServiceTicketByQrcodeToken" {
                return QuarkMockURLProtocol.response(
                    #"{"status":2000000,"data":{"members":{"service_ticket":"st-9"}}}"#,
                    for: request
                )
            }
            if request.url?.path == "/account/info" {
                return QuarkMockURLProtocol.response(
                    #"{"success":true,"data":{"nickname":"小明"}}"#,
                    status: 200,
                    headers: ["Set-Cookie": "pan_us=abc123; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/; HttpOnly"],
                    for: request
                )
            }
            throw URLError(.unsupportedURL)
        }

        let status = try await client.loginStatus(qrID: qr.qrID)

        #expect(status.state == .ok)
        #expect(status.nickname == "小明")
        #expect(status.message == nil)

        // 交换请求：pan.quark.cn/account/info?st=st-9&lw=scan，匿名 UA 无 Referer
        let exchangeRequest = Self.requests(pathContaining: "/account/info").first
        #expect(exchangeRequest != nil)
        #expect(Self.queryValue("st", in: exchangeRequest!) == "st-9")
        #expect(Self.queryValue("lw", in: exchangeRequest!) == "scan")
        #expect(exchangeRequest?.url?.host == "pan.quark.cn")
        #expect(exchangeRequest?.value(forHTTPHeaderField: "User-Agent") == QuarkClient.browserUA)

        // Cookie 已持久化（只含本次响应 Set-Cookie——web 全新 client 语义）
        let saved = try? Data(contentsOf: cookieFile)
        #expect(saved != nil)
        #expect(QuarkLogic.cookies(from: saved!) == ["pan_us": "abc123"])
        // 0600 权限
        let attrs = try? FileManager.default.attributesOfItem(atPath: cookieFile.path)
        let perms = (attrs?[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o600)
        Self.removeFileIfExists(cookieFile)
    }

    @Test("loginStatus：exchange success=false → error 且不落盘 cookie")
    func loginStatusExchangeFailure() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("login-fail")
        let client = Self.makeClient(cookieFile: cookieFile)
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"data":{"members":{"token":"tok-4"}}}"#,
                for: request
            )
        }
        let qr = try await client.loginQRCode()

        QuarkMockURLProtocol.handler = { request in
            if request.url?.path == "/cas/ajax/getServiceTicketByQrcodeToken" {
                return QuarkMockURLProtocol.response(
                    #"{"status":2000000,"data":{"members":{"service_ticket":"st-9"}}}"#,
                    for: request
                )
            }
            return QuarkMockURLProtocol.response(
                #"{"success":false,"message":"凭证无效"}"#,
                headers: ["Set-Cookie": "pan_us=should-not-persist"],
                for: request
            )
        }

        let status = try await client.loginStatus(qrID: qr.qrID)
        #expect(status.state == .error)
        #expect(status.message == "凭证无效")
        #expect(FileManager.default.fileExists(atPath: cookieFile.path) == false)
    }

    @Test("loginStatus：2000000 但缺 service_ticket → error")
    func loginStatusMissingTicket() async throws {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("no-ticket"))
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"data":{"members":{"token":"tok-5"}}}"#,
                for: request
            )
        }
        let qr = try await client.loginQRCode()

        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"status":2000000,"data":{"members":{}}}"#,
                for: request
            )
        }
        let status = try await client.loginStatus(qrID: qr.qrID)
        #expect(status.state == .error)
        #expect(status.message == "登录响应缺少 service_ticket")
    }

    @Test("loginStatus：轮询 HTTP 500 → error 状态（web except HTTPError 对齐）")
    func loginStatusPollHTTPError() async throws {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("poll-500"))
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"data":{"members":{"token":"tok-6"}}}"#,
                for: request
            )
        }
        let qr = try await client.loginQRCode()

        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response("boom", status: 500, for: request)
        }
        let status = try await client.loginStatus(qrID: qr.qrID)
        #expect(status.state == .error)
        #expect(status.message?.hasPrefix("轮询扫码状态失败: HTTP 500") == true)
    }

    @Test("loginStatus：轮询传输层错误 → error 状态")
    func loginStatusPollTransportError() async throws {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("poll-net"))
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"data":{"members":{"token":"tok-7"}}}"#,
                for: request
            )
        }
        let qr = try await client.loginQRCode()

        QuarkMockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let status = try await client.loginStatus(qrID: qr.qrID)
        #expect(status.state == .error)
        #expect(status.message?.hasPrefix("轮询扫码状态失败:") == true)
    }

    @Test("loginStatus：轮询响应非 JSON → 抛出 invalidResponse（web ValueError 冒泡对齐）")
    func loginStatusPollInvalidJSON() async throws {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("poll-json"))
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"data":{"members":{"token":"tok-8"}}}"#,
                for: request
            )
        }
        let qr = try await client.loginQRCode()

        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response("<html>not json</html>", for: request)
        }
        await Self.expectQuarkError(.invalidResponse) {
            _ = try await client.loginStatus(qrID: qr.qrID)
        }
    }

    @Test("loginStatus：未知 status → error「未知状态」")
    func loginStatusUnknownStatus() async throws {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("unknown-status"))
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"data":{"members":{"token":"tok-9"}}}"#,
                for: request
            )
        }
        let qr = try await client.loginQRCode()

        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(#"{"status":99999}"#, for: request)
        }
        let status = try await client.loginStatus(qrID: qr.qrID)
        #expect(status.state == .error)
        #expect(status.message == "未知状态: 99999")
    }

    @Test("loginStatus：exchange 阶段传输错误抛出（web _exchange_ticket 在 try 外对齐）")
    func loginStatusExchangeTransportErrorThrows() async throws {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("exchange-net"))
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"data":{"members":{"token":"tok-10"}}}"#,
                for: request
            )
        }
        let qr = try await client.loginQRCode()

        QuarkMockURLProtocol.handler = { request in
            if request.url?.path == "/cas/ajax/getServiceTicketByQrcodeToken" {
                return QuarkMockURLProtocol.response(
                    #"{"status":2000000,"data":{"members":{"service_ticket":"st-1"}}}"#,
                    for: request
                )
            }
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await client.loginStatus(qrID: qr.qrID)
            Issue.record("exchange 网络错误应抛出，但成功返回")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        } catch {
            Issue.record("期望 URLError，实际 \(error)")
        }
    }

    // MARK: - loginState / logout

    @Test("loginState：cookie 文件不存在 → (false, nil)，不发请求")
    func loginStateNoFile() async {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("state-nofile"))

        let state = await client.loginState()

        #expect(state.loggedIn == false)
        #expect(state.nickname == nil)
        #expect(QuarkMockURLProtocol.receivedRequests.isEmpty)
    }

    @Test("loginState：200 + success → logged_in；请求带夸克 UA/Referer/Cookie")
    func loginStateLoggedIn() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("state-ok")
        try Self.writeCookieFile(cookieFile, ["pan_us": "abc123"])
        let client = Self.makeClient(cookieFile: cookieFile)
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"success":true,"data":{"nickname":"多多"}}"#,
                for: request
            )
        }

        let state = await client.loginState()

        #expect(state.loggedIn == true)
        #expect(state.nickname == "多多")
        let request = QuarkMockURLProtocol.receivedRequests.first
        #expect(request?.url?.path == "/account/info")
        #expect(request?.url?.host == "pan.quark.cn")
        #expect(request?.value(forHTTPHeaderField: "User-Agent") == QuarkClient.quarkClientUA)
        #expect(request?.value(forHTTPHeaderField: "Referer") == QuarkClient.referer)
        #expect(request?.value(forHTTPHeaderField: "Cookie") == "pan_us=abc123")
        Self.removeFileIfExists(cookieFile)
    }

    @Test("loginState：200 + success=false → (false, nil) 且清 cookie 文件")
    func loginStateExpiredClearsFile() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("state-expired")
        try Self.writeCookieFile(cookieFile, ["pan_us": "dead"])
        let client = Self.makeClient(cookieFile: cookieFile)
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(#"{"success":false}"#, for: request)
        }

        let state = await client.loginState()

        #expect(state.loggedIn == false)
        #expect(state.nickname == nil)
        #expect(FileManager.default.fileExists(atPath: cookieFile.path) == false)
        Self.removeFileIfExists(cookieFile)
    }

    @Test("loginState：HTTP 401 → (false, nil) 且清 cookie 文件（web 手动状态码检查）")
    func loginStateHTTP401ClearsFile() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("state-401")
        try Self.writeCookieFile(cookieFile, ["pan_us": "dead"])
        let client = Self.makeClient(cookieFile: cookieFile)
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(#"{"success":false}"#, status: 401, for: request)
        }

        let state = await client.loginState()

        #expect(state.loggedIn == false)
        #expect(FileManager.default.fileExists(atPath: cookieFile.path) == false)
        Self.removeFileIfExists(cookieFile)
    }

    @Test("loginState：网络抖动 → (false, nil) 但保留 cookie 文件（下次再试）")
    func loginStateNetworkErrorKeepsFile() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("state-net")
        try Self.writeCookieFile(cookieFile, ["pan_us": "still-valid"])
        let client = Self.makeClient(cookieFile: cookieFile)
        QuarkMockURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }

        let state = await client.loginState()

        #expect(state.loggedIn == false)
        #expect(state.nickname == nil)
        #expect(FileManager.default.fileExists(atPath: cookieFile.path) == true)
        Self.removeFileIfExists(cookieFile)
    }

    @Test("loginState：cookie 文件损坏（非 JSON）→ 请求不带 Cookie、不崩")
    func loginStateCorruptedCookieFile() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("state-corrupt")
        try FileManager.default.createDirectory(
            at: cookieFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{{{{ not json".utf8).write(to: cookieFile)
        let client = Self.makeClient(cookieFile: cookieFile)
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(#"{"success":false}"#, for: request)
        }

        let state = await client.loginState()

        #expect(state.loggedIn == false)
        #expect(QuarkMockURLProtocol.receivedRequests.first?.value(forHTTPHeaderField: "Cookie") == nil)
        // success=false → 损坏文件被清掉（web 语义：失效即清）
        #expect(FileManager.default.fileExists(atPath: cookieFile.path) == false)
        Self.removeFileIfExists(cookieFile)
    }

    @Test("logout：删除 cookie 文件")
    func logoutRemovesFile() async throws {
        let cookieFile = Self.tempCookieURL("logout")
        try FileManager.default.createDirectory(
            at: cookieFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{\"a\":\"1\"}".utf8).write(to: cookieFile)
        let client = Self.makeClient(cookieFile: cookieFile)

        client.logout()

        #expect(FileManager.default.fileExists(atPath: cookieFile.path) == false)
        Self.removeFileIfExists(cookieFile)
    }

    // MARK: - 分享解析（匿名 mock）

    /// 安装「分享解析成功」handler：root 返回 list，metadata 总量一致
    private static func installShareHandler(list: [[String: Any]], total: Int? = nil) {
        let itemsJSON = list
        QuarkMockURLProtocol.handler = { request in
            if request.url?.path == "/1/clouddrive/share/sharepage/token" {
                return QuarkMockURLProtocol.response(
                    #"{"code":0,"data":{"stoken":"sTok-1"}}"#,
                    for: request
                )
            }
            if request.url?.path == "/1/clouddrive/share/sharepage/detail" {
                let body: [String: Any] = [
                    "code": 0,
                    "data": ["list": itemsJSON],
                    "metadata": ["_total": total ?? itemsJSON.count],
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
            throw URLError(.unsupportedURL)
        }
    }

    @Test("resolveShareVerbose：token POST 字段 + detail GET 参数 + 文件字段映射")
    func resolveShareFlatFiles() async {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("share-flat"))
        Self.installShareHandler(list: [
            Self.fileItem(fid: "f1", name: "song.mp3", size: 10, token: "tok-f1"),
            Self.fileItem(fid: "f2", name: "loss.FLAC", size: 20, token: "tok-f2"),
            Self.dirItem(fid: "d1", name: "专辑文件夹"),
        ])

        let (files, stoken) = await client.resolveShareVerbose("https://pan.quark.cn/s/abc123")

        #expect(stoken == "sTok-1")
        #expect(files.count == 3)

        // token 请求断言
        let tokenRequests = Self.requests(pathContaining: "/1/clouddrive/share/sharepage/token")
        #expect(tokenRequests.count == 1)
        let tokenRequest = tokenRequests[0]
        #expect(tokenRequest.httpMethod == "POST")
        #expect(tokenRequest.url?.host == "drive-pc.quark.cn")
        #expect(Self.queryValue("pr", in: tokenRequest) == "ucpro")
        #expect(Self.queryValue("fr", in: tokenRequest) == "pc")
        #expect(tokenRequest.value(forHTTPHeaderField: "User-Agent") == QuarkClient.quarkClientUA)
        #expect(tokenRequest.value(forHTTPHeaderField: "Referer") == QuarkClient.referer)
        #expect(tokenRequest.value(forHTTPHeaderField: "Origin") == "https://pan.quark.cn")
        #expect(tokenRequest.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let tokenBody = Self.bodyDict(of: tokenRequest)
        #expect(tokenBody?["pwd_id"] as? String == "abc123")
        #expect((tokenBody?["passcode"] as? String)?.isEmpty == true)
        #expect(tokenBody?["support_visit_limit_private_share"] as? Bool == true)

        // detail 请求断言（root pdir_fid=0；root 含目录 d1 → 递归多一次 detail 请求）
        let detailRequests = Self.requests(pathContaining: "/1/clouddrive/share/sharepage/detail")
        #expect(detailRequests.count == 2)
        let detailRequest = detailRequests[0]
        #expect(detailRequest.httpMethod == "GET")
        #expect(Self.queryValue("ver", in: detailRequest) == "2")
        #expect(Self.queryValue("pwd_id", in: detailRequest) == "abc123")
        #expect(Self.queryValue("stoken", in: detailRequest) == "sTok-1")
        #expect(Self.queryValue("pdir_fid", in: detailRequest) == "0")
        #expect(Self.queryValue("force", in: detailRequest) == "0")
        #expect(Self.queryValue("_page", in: detailRequest) == "1")
        #expect(Self.queryValue("_size", in: detailRequest) == "50")
        #expect(Self.queryValue("_fetch_total", in: detailRequest) == "1")
        #expect(Self.queryValue("_sort", in: detailRequest) == "file_type:asc,updated_at:desc")
        #expect(Self.queryValue("pr", in: detailRequest) == "ucpro")
        #expect(Self.queryValue("fr", in: detailRequest) == "pc")

        // 文件字段映射（web dict 构造逐字段）
        let flac = files.first { $0.fid == "f2" }
        #expect(flac?.fileName == "loss.FLAC")
        #expect(flac?.size == 20)
        #expect(flac?.formatType == "file")
        #expect(flac?.shareFidToken == "tok-f2")
        #expect(flac?.ext == ".flac")
        let dir = files.first { $0.fid == "d1" }
        #expect(dir?.formatType == "folder")
        #expect(dir?.shareFidToken == "tok-d1")
    }

    @Test("resolveShareVerbose：目录递归（≤3 层）+ fid 去重 + 目录项也进列表")
    func resolveShareRecursiveDedupeDepth() async {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("share-rec"))
        // 按 pdir_fid 分发各层目录内容
        QuarkMockURLProtocol.handler = { request in
            if request.url?.path == "/1/clouddrive/share/sharepage/token" {
                return QuarkMockURLProtocol.response(
                    #"{"code":0,"data":{"stoken":"sTok"}}"#,
                    for: request
                )
            }
            if request.url?.path == "/1/clouddrive/share/sharepage/detail" {
                let pdirFid = Self.queryValue("pdir_fid", in: request) ?? ""
                let list: [[String: Any]]
                switch pdirFid {
                case "0":
                    // root：重复 fid f1 出现两次 → 去重；另含目录 d1
                    list = [
                        Self.fileItem(fid: "f1", name: "a.mp3"),
                        Self.fileItem(fid: "f1", name: "a-dupe.mp3"),
                        Self.dirItem(fid: "d1", name: "dir1"),
                    ]
                case "d1":
                    list = [Self.dirItem(fid: "d2", name: "dir2")]
                case "d2":
                    // 深度 3 可列；其子目录不再进入（depth 4 guard）
                    list = [
                        Self.dirItem(fid: "d3", name: "dir3"),
                        Self.fileItem(fid: "deep", name: "deep.flac"),
                    ]
                default:
                    list = []
                }
                let body: [String: Any] = [
                    "code": 0, "data": ["list": list], "metadata": ["_total": list.count],
                ]
                let data = try JSONSerialization.data(withJSONObject: body)
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )!,
                    data
                )
            }
            throw URLError(.unsupportedURL)
        }

        let (files, _) = await client.resolveShareVerbose("https://pan.quark.cn/s/abc")

        // 去重：fid f1 只进一次；目录项自身进列表（含深度 3 层列出的 d3——
        // 深度 guard 只限制递归，不限制已列出目录进列表）
        #expect(files.filter { $0.fid == "f1" }.count == 1)
        let fids = files.map(\.fid)
        #expect(fids == ["f1", "d1", "d2", "d3", "deep"])

        // detail 请求恰好 3 次（root/d1/d2），深度 4 不发请求
        let detailRequests = Self.requests(pathContaining: "/1/clouddrive/share/sharepage/detail")
        #expect(detailRequests.count == 3)
        let pdirFids = detailRequests.compactMap { Self.queryValue("pdir_fid", in: $0) }
        #expect(pdirFids == ["0", "d1", "d2"])
    }

    @Test("resolveShareVerbose：翻页（>50 条）按 _page 递增拉全量")
    func resolveSharePagination() async {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("share-page"))
        QuarkMockURLProtocol.handler = { request in
            if request.url?.path == "/1/clouddrive/share/sharepage/token" {
                return QuarkMockURLProtocol.response(
                    #"{"code":0,"data":{"stoken":"sTok"}}"#,
                    for: request
                )
            }
            if request.url?.path == "/1/clouddrive/share/sharepage/detail" {
                let page = Int(Self.queryValue("_page", in: request) ?? "1") ?? 1
                // page1 满 50 条（total 55 → 需翻页）；page2 余 5 条（batch<50 → 停）
                let start = (page - 1) * 50
                let count = page == 1 ? 50 : 5
                var list: [[String: Any]] = []
                for i in 0 ..< count {
                    let fid = String(format: "f%03d", start + i)
                    list.append(Self.fileItem(fid: fid, name: "song\(fid).mp3", size: i))
                }
                let body: [String: Any] = [
                    "code": 0, "data": ["list": list], "metadata": ["_total": 55],
                ]
                let data = try JSONSerialization.data(withJSONObject: body)
                return (
                    HTTPURLResponse(
                        url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
                    )!,
                    data
                )
            }
            throw URLError(.unsupportedURL)
        }

        let (files, _) = await client.resolveShareVerbose("https://pan.quark.cn/s/abc")

        #expect(files.count == 55)
        let detailRequests = Self.requests(pathContaining: "/1/clouddrive/share/sharepage/detail")
        #expect(detailRequests.count == 2)
        #expect(Self.queryValue("_page", in: detailRequests[0]) == "1")
        #expect(Self.queryValue("_page", in: detailRequests[1]) == "2")
        #expect(files.first?.fid == "f000")
        #expect(files.last?.fid == "f054")
    }

    @Test("resolveShare：失败 → 空数组不抛（web 语义）")
    func resolveShareFailuresReturnEmpty() async {
        // 1) 非法分享 URL（不发请求）
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("share-invalid"))
        let (files, stoken) = await client.resolveShareVerbose("https://example.com/nope")
        #expect(files.isEmpty)
        #expect(stoken.isEmpty)
        #expect(QuarkMockURLProtocol.receivedRequests.isEmpty)

        // 2) token 接口业务失败（code != 0）
        QuarkMockURLProtocol.reset()
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"code":40101,"message":"需要提取码"}"#,
                for: request
            )
        }
        let (files2, stoken2) = await client.resolveShareVerbose("https://pan.quark.cn/s/abc")
        #expect(files2.isEmpty)
        #expect(stoken2.isEmpty)

        // 3) detail 接口 HTTP 500
        QuarkMockURLProtocol.reset()
        QuarkMockURLProtocol.handler = { request in
            if request.url?.path == "/1/clouddrive/share/sharepage/token" {
                return QuarkMockURLProtocol.response(
                    #"{"code":0,"data":{"stoken":"sTok"}}"#,
                    for: request
                )
            }
            return QuarkMockURLProtocol.response("boom", status: 500, for: request)
        }
        let (files3, stoken3) = await client.resolveShareVerbose("https://pan.quark.cn/s/abc")
        #expect(files3.isEmpty)
        #expect(stoken3.isEmpty)

        // 4) 传输层错误
        QuarkMockURLProtocol.reset()
        QuarkMockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let (files4, stoken4) = await client.resolveShareVerbose("https://pan.quark.cn/s/abc")
        #expect(files4.isEmpty)
        #expect(stoken4.isEmpty)
    }

    @Test("resolveShare：损坏 cookie 文件不阻塞匿名分享解析（loadCookies 兜底为空）")
    func resolveShareWithCorruptedCookieFile() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("share-corrupt")
        try FileManager.default.createDirectory(
            at: cookieFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{{{{ not json".utf8).write(to: cookieFile)
        let client = Self.makeClient(cookieFile: cookieFile)
        Self.installShareHandler(list: [Self.fileItem(fid: "f1", name: "a.mp3")])

        let (files, _) = await client.resolveShareVerbose("https://pan.quark.cn/s/abc")

        #expect(files.count == 1)
        #expect(files.first?.fid == "f1")
        // 空 jar → 请求不带 Cookie 头
        for request in QuarkMockURLProtocol.receivedRequests {
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        }
        Self.removeFileIfExists(cookieFile)
    }

    // MARK: - 下载直链（登录后 mock）

    @Test("getDownloadURL：无 cookie 文件 → loginRequired（先于 URL 检查，web 顺序）")
    func getDownloadURLRequiresLogin() async {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("dl-nologin"))

        do {
            _ = try await client.getDownloadURL(
                shareURL: "garbage-url", fid: "f1", shareFidToken: "t", stoken: "s"
            )
            Issue.record("应抛 loginRequired，但成功返回")
        } catch let error as QuarkClientError {
            #expect(error == .loginRequired)
            #expect(error.errorDescription == "quark login required")
        } catch {
            Issue.record("期望 QuarkClientError，实际 \(error)")
        }
        #expect(QuarkMockURLProtocol.receivedRequests.isEmpty)
    }

    @Test("getDownloadURL：成功——请求字段 + 响应直链与下载头快照")
    func getDownloadURLSuccess() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("dl-ok")
        try Self.writeCookieFile(cookieFile, ["pan_us": "abc123"])
        let client = Self.makeClient(cookieFile: cookieFile)
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"status":200,"code":0,"data":[{"download_url":"https://dl.quark.cn/x/song.mp3?sign=xyz"}]}"#,
                for: request
            )
        }

        let download = try await client.getDownloadURL(
            shareURL: "https://pan.quark.cn/s/abc123",
            fid: "f1",
            shareFidToken: "tok-f1",
            stoken: "sTok-1"
        )

        #expect(download.urlString == "https://dl.quark.cn/x/song.mp3?sign=xyz")
        #expect(download.headers["User-Agent"] == QuarkClient.quarkClientUA)
        #expect(download.headers["Referer"] == QuarkClient.referer)
        #expect(download.headers["Origin"] == "https://pan.quark.cn")
        #expect(download.headers["Cookie"] == "pan_us=abc123")

        // 请求序列：config（取直链前 __puus 保活）→ file/download
        let requests = QuarkMockURLProtocol.receivedRequests
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].url?.path == "/1/clouddrive/config")
        let request = requests[1]
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/1/clouddrive/file/download")
        #expect(Self.queryValue("entry", in: request) == "ft")
        #expect(Self.queryValue("fr", in: request) == "pc")
        #expect(Self.queryValue("pr", in: request) == "ucpro")
        let body = Self.bodyDict(of: request)
        #expect(body?["fids"] as? [String] == ["f1"])
        #expect(body?["fids_token"] as? [String] == ["tok-f1"])
        #expect(body?["pwd_id"] as? String == "abc123")
        #expect(body?["stoken"] as? String == "sTok-1")
        Self.removeFileIfExists(cookieFile)
    }

    @Test("getDownloadURL：401/403 → loginRequired 且不删 cookie 文件（保留现场）")
    func getDownloadURL401KeepsCookieFile() async throws {
        for code in [401, 403] {
            QuarkMockURLProtocol.reset()
            let cookieFile = Self.tempCookieURL("dl-\(code)")
            try Self.writeCookieFile(cookieFile, ["pan_us": "abc"])
            let client = Self.makeClient(cookieFile: cookieFile)
            QuarkMockURLProtocol.handler = { request in
                QuarkMockURLProtocol.response("unauthorized", status: code, for: request)
            }

            do {
                _ = try await client.getDownloadURL(
                    shareURL: "https://pan.quark.cn/s/abc", fid: "f1",
                    shareFidToken: "t", stoken: "s"
                )
                Issue.record("HTTP \(code) 应抛 loginRequired")
            } catch let error as QuarkClientError {
                #expect(error == .loginRequired)
            } catch {
                Issue.record("期望 QuarkClientError，实际 \(error)")
            }
            // ⚠️ 不删 cookie（web 注释：删文件会导致扫码-下载-重扫死循环）
            #expect(FileManager.default.fileExists(atPath: cookieFile.path) == true)
            Self.removeFileIfExists(cookieFile)
        }
    }

    @Test("getDownloadURL：业务失败（status!=200 且 code!=0）→ serverMessage 带 message")
    func getDownloadURLBusinessError() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("dl-biz")
        try Self.writeCookieFile(cookieFile, ["pan_us": "abc"])
        let client = Self.makeClient(cookieFile: cookieFile)
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"status":400,"code":40211,"message":"链接失效或已取消"}"#,
                for: request
            )
        }
        await Self.expectServerMessage(containing: "获取下载直链失败: 链接失效或已取消") {
            _ = try await client.getDownloadURL(
                shareURL: "https://pan.quark.cn/s/abc", fid: "f1",
                shareFidToken: "t", stoken: "s"
            )
        }
        Self.removeFileIfExists(cookieFile)
    }

    @Test("getDownloadURL：data 缺 download_url → serverMessage")
    func getDownloadURLMissingURL() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("dl-nourl")
        try Self.writeCookieFile(cookieFile, ["pan_us": "abc"])
        let client = Self.makeClient(cookieFile: cookieFile)
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(#"{"status":200,"code":0,"data":[]}"#, for: request)
        }
        await Self.expectServerMessage(containing: "下载直链响应缺少 download_url") {
            _ = try await client.getDownloadURL(
                shareURL: "https://pan.quark.cn/s/abc", fid: "f1",
                shareFidToken: "t", stoken: "s"
            )
        }
        Self.removeFileIfExists(cookieFile)
    }

    @Test("getDownloadURL：非法分享 URL（有 cookie）→ invalidShareURL")
    func getDownloadURLInvalidShareURL() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("dl-badurl")
        try Self.writeCookieFile(cookieFile, ["pan_us": "abc"])
        let client = Self.makeClient(cookieFile: cookieFile)
        await Self.expectQuarkError(.invalidShareURL("https://example.com/x")) {
            _ = try await client.getDownloadURL(
                shareURL: "https://example.com/x", fid: "f1",
                shareFidToken: "t", stoken: "s"
            )
        }
        #expect(QuarkMockURLProtocol.receivedRequests.isEmpty)
        Self.removeFileIfExists(cookieFile)
    }

    // MARK: - refreshPUUS

    @Test("refreshPUUS：cookie 文件不存在 → 静默不发请求")
    func refreshPUUSNoFile() async {
        QuarkMockURLProtocol.reset()
        let client = Self.makeClient(cookieFile: Self.tempCookieURL("puus-nofile"))

        await client.refreshPUUS()

        #expect(QuarkMockURLProtocol.receivedRequests.isEmpty)
    }

    @Test("refreshPUUS：请求不带 __puus；服务端重发 → 合并持久化")
    func refreshPUUSRenews() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("puus-renew")
        try Self.writeCookieFile(cookieFile, ["pan_us": "abc", "__puus": "old"])
        let client = Self.makeClient(cookieFile: cookieFile)
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"code":0}"#,
                headers: ["Set-Cookie": "__puus=new-value; Path=/"],
                for: request
            )
        }

        await client.refreshPUUS()

        let request = QuarkMockURLProtocol.receivedRequests.first
        #expect(request?.url?.path == "/1/clouddrive/config")
        #expect(Self.queryValue("pr", in: request!) == "ucpro")
        #expect(Self.queryValue("fr", in: request!) == "pc")
        #expect(request?.url?.host == "drive-pc.quark.cn")
        let cookieHeader = request?.value(forHTTPHeaderField: "Cookie")
        #expect(cookieHeader == "pan_us=abc")   // 已剥掉 __puus
        // 新 __puus 已合并持久化，pan_us 保留
        let saved = try? Data(contentsOf: cookieFile)
        #expect(QuarkLogic.cookies(from: saved!) == ["pan_us": "abc", "__puus": "new-value"])
        Self.removeFileIfExists(cookieFile)
    }

    @Test("refreshPUUS：200 但无 __puus Set-Cookie → 文件不变")
    func refreshPUUSNoRenewal() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("puus-nonew")
        try Self.writeCookieFile(cookieFile, ["__puus": "old"])
        let client = Self.makeClient(cookieFile: cookieFile)
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(#"{"code":0}"#, for: request)
        }

        await client.refreshPUUS()

        let saved = try? Data(contentsOf: cookieFile)
        #expect(QuarkLogic.cookies(from: saved!) == ["__puus": "old"])
        Self.removeFileIfExists(cookieFile)
    }

    @Test("refreshPUUS：HTTP 500 / 传输错误 → 静默且文件不变")
    func refreshPUUSFailureSilent() async throws {
        for mode in ["http500", "network"] {
            QuarkMockURLProtocol.reset()
            let cookieFile = Self.tempCookieURL("puus-fail-\(mode)")
            try Self.writeCookieFile(cookieFile, ["__puus": "old"])
            let client = Self.makeClient(cookieFile: cookieFile)
            QuarkMockURLProtocol.handler = { request in
                if mode == "http500" {
                    return QuarkMockURLProtocol.response("boom", status: 500, for: request)
                }
                throw URLError(.notConnectedToInternet)
            }

            await client.refreshPUUS()

            let saved = try? Data(contentsOf: cookieFile)
            #expect(QuarkLogic.cookies(from: saved!) == ["__puus": "old"])
            Self.removeFileIfExists(cookieFile)
        }
    }

    @Test("refreshPUUS：文件只有 __puus → 请求不带 Cookie 头（剥掉后为空）")
    func refreshPUUSOnlyPuus() async throws {
        QuarkMockURLProtocol.reset()
        let cookieFile = Self.tempCookieURL("puus-only")
        try Self.writeCookieFile(cookieFile, ["__puus": "old"])
        let client = Self.makeClient(cookieFile: cookieFile)
        QuarkMockURLProtocol.handler = { request in
            QuarkMockURLProtocol.response(
                #"{"code":0}"#,
                headers: ["Set-Cookie": "__puus=new; Path=/"],
                for: request
            )
        }

        await client.refreshPUUS()

        #expect(QuarkMockURLProtocol.receivedRequests.first?.value(forHTTPHeaderField: "Cookie") == nil)
        let saved = try? Data(contentsOf: cookieFile)
        #expect(QuarkLogic.cookies(from: saved!) == ["__puus": "new"])
        Self.removeFileIfExists(cookieFile)
    }

    // MARK: - 错误断言 helpers

    private static func expectQuarkError(
        _ expected: QuarkClientError,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("应抛 \(expected)，但成功返回")
        } catch let error as QuarkClientError {
            #expect(error == expected)
        } catch {
            Issue.record("期望 QuarkClientError.\(expected)，实际 \(error)")
        }
    }

    private static func expectServerMessage(
        containing fragment: String,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("应抛 serverMessage 含「\(fragment)」，但成功返回")
        } catch let error as QuarkClientError {
            guard case .serverMessage(let message) = error else {
                Issue.record("期望 serverMessage，实际 \(error)")
                return
            }
            #expect(message.contains(fragment))
        } catch {
            Issue.record("期望 QuarkClientError.serverMessage，实际 \(error)")
        }
    }
}
