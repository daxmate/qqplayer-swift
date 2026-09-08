//
//  MacAria2ClientTests.swift
//  QQPlayerTests
//
//  aria2 JSON-RPC 客户端（web backend/app/services/download.py _aria2_rpc_call +
//  _download_with_engine aria2 分支移植，2026-09 B1 下载引擎批）防回归测试：
//  ① MacAria2Logic 纯函数：addUri options 组装（dir/out 恒在、限速 >0 才加
//     max-download-limit、headers 非空才加 header 数组）、header 数组格式化、
//     JSON-RPC 请求体结构、响应解析（error code=1 → unauthorized / 其余 →
//     rpcError(message)；非 JSON/无 result → invalidResponse）
//  ② Aria2Status 容错映射：length/speed 字符串数字与 NSNumber 双兼容、缺字段
//     默认 0、非 dict → 全默认、errorMessage 读取
//  ③ addUri 网络层（Aria2MockURLProtocol 注入）：POST JSON-RPC 请求体逐字段断言
//     （token 首位 / params [[url], opts] / dir / out / header / max-download-limit）、
//     响应 gid 返回、无 gid → invalidResponse
//  ④ tellStatus 网络层：complete 状态完整解析 / RPC error 冒泡
//  ⑤ 失败语义：RPC error → rpcError/unauthorized；连接失败（handler 抛 URLError）
//     → unreachable；非 2xx HTTP → unreachable
//
//  隔离说明：自带 Aria2MockURLProtocol（独立 URLProtocol 类，静态状态只属于自己，
//  与共享 MockURLProtocol 互不干扰），跨 suite 可并行；suite 内 .serialized。
//  全程不发真实网络。
//

import Foundation
import Testing

@testable import QQPlayer

/// aria2 测试专用 URLProtocol mock（实现同 MockURLProtocol，静态状态独立）
final class Aria2MockURLProtocol: URLProtocol {
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
        for request: URLRequest
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
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
        Aria2MockURLProtocol.receivedRequests.append(request)

        guard let handler = Aria2MockURLProtocol.handler else {
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

// MARK: - 纯逻辑边界

@Suite(.serialized)
struct MacAria2ClientTests {
    private func makeClient() -> MacAria2Client {
        MacAria2Client(
            rpcURL: URL(string: "http://localhost:6800/jsonrpc")!,
            secret: "dax",
            protocolClasses: [Aria2MockURLProtocol.self]
        )
    }

    /// async 错误断言 helper（#expect(throws:) 不支持 async 闭包，项目惯例用
    /// do/catch + Issue.record，见 DiscogsAPITests.expectDiscogsHTTPError）
    private func expectAria2Error(
        _ expected: Aria2ClientError,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            Issue.record("应抛 \(expected)，但成功返回")
        } catch let error as Aria2ClientError {
            #expect(error == expected)
        } catch {
            Issue.record("期望 Aria2ClientError，实际 \(error)")
        }
    }

    /// 读请求体：URLSession 在自定义 URLProtocol 下会把 httpBody 转成
    /// httpBodyStream（httpBody 变 nil，CI 实测）——双兼容（2026-09-08 B1 CI 修复）
    private func requestBodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
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
        return data
    }

    // MARK: MacAria2Logic.addUriOptions

    @Test("opts：dir/out 恒在；限速 0 不加 max-download-limit；headers 空不加 header")
    func addUriOptionsBaseShape() {
        let opts = MacAria2Logic.addUriOptions(
            dir: "/tmp/dl", out: "歌.mp3.part",
            headers: [:], maxSpeedMbps: 0
        )
        #expect(opts["dir"] as? String == "/tmp/dl")
        #expect(opts["out"] as? String == "歌.mp3.part")
        #expect(opts["max-download-limit"] == nil)
        #expect(opts["header"] == nil)
    }

    @Test("opts：限速 >0 → max-download-limit Int 取整 M；headers 非空 → header 数组 k: v")
    func addUriOptionsWithLimitAndHeaders() {
        let opts = MacAria2Logic.addUriOptions(
            dir: "/tmp/dl", out: "x.flac.part",
            headers: ["User-Agent": "QQPlayer/1.0", "Referer": "https://a.b"],
            maxSpeedMbps: 2.9
        )
        #expect(opts["max-download-limit"] as? String == "2M")
        let header = opts["header"] as? [String]
        #expect(header?.count == 2)
        #expect(header?.contains("User-Agent: QQPlayer/1.0") == true)
        #expect(header?.contains("Referer: https://a.b") == true)
    }

    @Test("header 数组格式化：k: v 原样拼接（web f'{k}: {v}' 逐字）")
    func headerArrayFormatsPairs() {
        let array = MacAria2Logic.headerArray(from: ["K": "V", "A": "B C"])
        #expect(array.count == 2)
        #expect(array.contains("K: V"))
        #expect(array.contains("A: B C"))
    }

    @Test("JSON-RPC 请求体：jsonrpc 2.0 + id + method + params（token 在首位由调用方加）")
    func requestBodyStructure() {
        let body = MacAria2Logic.requestBody(id: 7, method: "aria2.addUri", params: [["token:dax"], [[], [:]]])
        #expect(body["jsonrpc"] as? String == "2.0")
        #expect(body["id"] as? Int == 7)
        #expect(body["method"] as? String == "aria2.addUri")
        #expect(body["params"] != nil)
    }

    // MARK: MacAria2Logic.responseResult

    @Test("响应解析：result 原样返回（gid 字符串）")
    func responseResultReturnsGID() throws {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"result":"2089b05ecca3d829"}"#.utf8)
        let result = try MacAria2Logic.responseResult(from: data)
        #expect(result as? String == "2089b05ecca3d829")
    }

    @Test("响应解析：error code=1 → unauthorized（aria2 secret 错误）")
    func responseResultUnauthorizedThrows() {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":1,"message":"Unauthorized"}}"#.utf8)
        #expect(throws: Aria2ClientError.unauthorized) {
            _ = try MacAria2Logic.responseResult(from: data)
        }
    }

    @Test("响应解析：error code≠1 → rpcError 携带服务端 message")
    func responseResultRPCErrorThrows() {
        let data = Data(#"{"jsonrpc":"2.0","id":1,"error":{"code":5,"message":"gid not exist"}}"#.utf8)
        #expect(throws: Aria2ClientError.rpcError("gid not exist")) {
            _ = try MacAria2Logic.responseResult(from: data)
        }
    }

    @Test("响应解析：非 JSON / 无 result 无 error → invalidResponse")
    func responseResultInvalidThrows() {
        #expect(throws: Aria2ClientError.invalidResponse) {
            _ = try MacAria2Logic.responseResult(from: Data("not json".utf8))
        }
        #expect(throws: Aria2ClientError.invalidResponse) {
            _ = try MacAria2Logic.responseResult(from: Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
        }
    }

    // MARK: MacAria2Logic.tellStatus 容错

    @Test("tellStatus 容错：length/speed 字符串数字解析；errorMessage 读取")
    func tellStatusParsesStringNumbers() {
        let result: [String: Any] = [
            "status": "complete",
            "completedLength": "12345",
            "totalLength": "98765",
            "downloadSpeed": "1024",
            "errorMessage": "err",
        ]
        let status = MacAria2Logic.tellStatus(from: result)
        #expect(status.status == "complete")
        #expect(status.completedLength == 12345)
        #expect(status.totalLength == 98765)
        #expect(status.downloadSpeed == 1024)
        #expect(status.errorMessage == "err")
    }

    @Test("tellStatus 容错：NSNumber 值兼容；缺字段默认 0；非数字串 → 0")
    func tellStatusAcceptsNSNumberAndDefaults() {
        let result: [String: Any] = [
            "status": "active",
            "completedLength": NSNumber(value: 42),
        ]
        let status = MacAria2Logic.tellStatus(from: result)
        #expect(status.status == "active")
        #expect(status.completedLength == 42)
        #expect(status.totalLength == 0)
        #expect(status.downloadSpeed == 0)
        #expect(status.errorMessage == nil)
    }

    @Test("tellStatus 容错：result 非 dict → 全默认（不崩）")
    func tellStatusNonDictResult() {
        let status = MacAria2Logic.tellStatus(from: "just-a-string")
        #expect(status.status.isEmpty)
        #expect(status.completedLength == 0)
        #expect(status.totalLength == 0)
        #expect(status.downloadSpeed == 0)
        #expect(status.errorMessage == nil)
    }

    // MARK: addUri 网络层

    @Test("addUri：请求体逐字段断言（JSON-RPC/token/[[url], opts] dir/out/header/限速）")
    func addUriRequestPayload() async throws {
        Aria2MockURLProtocol.reset()
        Aria2MockURLProtocol.handler = { request in
            Aria2MockURLProtocol.response(#"{"jsonrpc":"2.0","id":1,"result":"gid-abc"}"#, for: request)
        }

        let gid = try await makeClient().addUri(
            url: "https://cdn.example/歌.mp3?token=1",
            headers: ["User-Agent": "QQPlayer/1.0"],
            dir: "/tmp/dl",
            out: "歌.mp3.part",
            maxSpeedMbps: 3
        )
        #expect(gid == "gid-abc")

        let request = try #require(Aria2MockURLProtocol.receivedRequests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://localhost:6800/jsonrpc")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(requestBodyData(request))
        let json = try JSONSerialization.jsonObject(with: body)
        let object = try #require(json as? [String: Any])
        #expect(object["jsonrpc"] as? String == "2.0")
        #expect(object["method"] as? String == "aria2.addUri")
        let params = try #require(object["params"] as? [Any])
        #expect(params.count == 2)
        #expect(params[0] as? String == "token:dax") // token 首位（web 逐字）
        let inner = try #require(params[1] as? [Any])
        #expect(inner.count == 2)
        let urls = try #require(inner[0] as? [String])
        #expect(urls == ["https://cdn.example/歌.mp3?token=1"])
        let opts = try #require(inner[1] as? [String: Any])
        #expect(opts["dir"] as? String == "/tmp/dl")
        #expect(opts["out"] as? String == "歌.mp3.part")
        #expect(opts["max-download-limit"] as? String == "3M")
        let header = try #require(opts["header"] as? [String])
        #expect(header == ["User-Agent: QQPlayer/1.0"])
    }

    @Test("addUri：opts 无 header/无限速时不带多余键（空 headers + 0 限速）")
    func addUriOmitsOptionalOpts() async throws {
        Aria2MockURLProtocol.reset()
        Aria2MockURLProtocol.handler = { request in
            Aria2MockURLProtocol.response(#"{"jsonrpc":"2.0","id":1,"result":"gid-x"}"#, for: request)
        }

        _ = try await makeClient().addUri(
            url: "https://cdn.example/a.flac",
            headers: [:],
            dir: "/tmp",
            out: "a.flac.part",
            maxSpeedMbps: 0
        )

        let request = try #require(Aria2MockURLProtocol.receivedRequests.first)
        let body = try #require(requestBodyData(request))
        let json = try JSONSerialization.jsonObject(with: body)
        let object = try #require(json as? [String: Any])
        let params = try #require(object["params"] as? [Any])
        let inner = try #require(params[1] as? [Any])
        let opts = try #require(inner[1] as? [String: Any])
        #expect(opts["header"] == nil)
        #expect(opts["max-download-limit"] == nil)
        #expect(opts["dir"] as? String == "/tmp")
        #expect(opts["out"] as? String == "a.flac.part")
    }

    @Test("addUri：响应 result 非字符串/空 → invalidResponse")
    func addUriMissingGIDThrows() async throws {
        Aria2MockURLProtocol.reset()
        Aria2MockURLProtocol.handler = { request in
            Aria2MockURLProtocol.response(#"{"jsonrpc":"2.0","id":1,"result":""}"#, for: request)
        }
        await expectAria2Error(.invalidResponse) {
            _ = try await makeClient().addUri(
                url: "https://cdn.example/a.mp3",
                headers: [:], dir: "/tmp", out: "a.mp3.part", maxSpeedMbps: 0
            )
        }
    }

    @Test("addUri：RPC error code=1 → unauthorized（secret 错误抛给服务层降级）")
    func addUriUnauthorizedThrows() async throws {
        Aria2MockURLProtocol.reset()
        Aria2MockURLProtocol.handler = { request in
            Aria2MockURLProtocol.response(
                #"{"jsonrpc":"2.0","id":1,"error":{"code":1,"message":"Unauthorized"}}"#,
                for: request
            )
        }
        await expectAria2Error(.unauthorized) {
            _ = try await makeClient().addUri(
                url: "https://cdn.example/a.mp3",
                headers: [:], dir: "/tmp", out: "a.mp3.part", maxSpeedMbps: 0
            )
        }
    }

    @Test("addUri：连接失败（handler 抛 URLError）→ unreachable")
    func addUriConnectionFailureThrowsUnreachable() async throws {
        Aria2MockURLProtocol.reset()
        Aria2MockURLProtocol.handler = { _ in
            throw URLError(.cannotConnectToHost)
        }
        await expectAria2Error(.unreachable) {
            _ = try await makeClient().addUri(
                url: "https://cdn.example/a.mp3",
                headers: [:], dir: "/tmp", out: "a.mp3.part", maxSpeedMbps: 0
            )
        }
    }

    @Test("addUri：非 2xx HTTP → unreachable（daemon 未启动/地址不对）")
    func addUriHTTPErrorThrowsUnreachable() async throws {
        Aria2MockURLProtocol.reset()
        Aria2MockURLProtocol.handler = { request in
            Aria2MockURLProtocol.response("Internal Server Error", status: 500, for: request)
        }
        await expectAria2Error(.unreachable) {
            _ = try await makeClient().addUri(
                url: "https://cdn.example/a.mp3",
                headers: [:], dir: "/tmp", out: "a.mp3.part", maxSpeedMbps: 0
            )
        }
    }

    // MARK: tellStatus 网络层

    @Test("tellStatus：complete 状态完整解析（长度字符串数字）")
    func tellStatusCompleteMapping() async throws {
        Aria2MockURLProtocol.reset()
        Aria2MockURLProtocol.handler = { request in
            Aria2MockURLProtocol.response(
                #"{"jsonrpc":"2.0","id":1,"result":{"status":"complete","completedLength":"999","totalLength":"999","downloadSpeed":"0"}}"#,
                for: request
            )
        }
        let status = try await makeClient().tellStatus(gid: "gid-1")
        #expect(status.status == "complete")
        #expect(status.completedLength == 999)
        #expect(status.totalLength == 999)
        #expect(status.downloadSpeed == 0)
        #expect(status.errorMessage == nil)
    }

    @Test("tellStatus：error 状态带 errorMessage")
    func tellStatusErrorMapping() async throws {
        Aria2MockURLProtocol.reset()
        Aria2MockURLProtocol.handler = { request in
            Aria2MockURLProtocol.response(
                #"{"jsonrpc":"2.0","id":1,"result":{"status":"error","errorMessage":"Could not parse metalink file"}}"#,
                for: request
            )
        }
        let status = try await makeClient().tellStatus(gid: "gid-2")
        #expect(status.status == "error")
        #expect(status.errorMessage == "Could not parse metalink file")
    }

    @Test("tellStatus：RPC error（gid 不存在）→ rpcError 冒泡")
    func tellStatusRPCErrorThrows() async throws {
        Aria2MockURLProtocol.reset()
        Aria2MockURLProtocol.handler = { request in
            Aria2MockURLProtocol.response(
                #"{"jsonrpc":"2.0","id":1,"error":{"code":5,"message":"gid not exist"}}"#,
                for: request
            )
        }
        await expectAria2Error(.rpcError("gid not exist")) {
            _ = try await makeClient().tellStatus(gid: "no-such-gid")
        }
    }

    @Test("remove：成功不抛（服务层超时兜底路径）")
    func removeSucceeds() async throws {
        Aria2MockURLProtocol.reset()
        Aria2MockURLProtocol.handler = { request in
            Aria2MockURLProtocol.response(#"{"jsonrpc":"2.0","id":1,"result":"gid-removed"}"#, for: request)
        }
        // 服务层 try? 调用，客户端不应抛
        try await makeClient().remove(gid: "gid-1")
        let request = try #require(Aria2MockURLProtocol.receivedRequests.first)
        let body = try #require(requestBodyData(request))
        let json = try JSONSerialization.jsonObject(with: body)
        let object = try #require(json as? [String: Any])
        #expect(object["method"] as? String == "aria2.remove")
        let params = try #require(object["params"] as? [Any])
        #expect(params[0] as? String == "token:dax")
        #expect(params[1] as? String == "gid-1")
    }
}
