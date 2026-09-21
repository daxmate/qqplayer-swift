//
//  QuarkClient+CookieHTTP.swift
//  QQPlayer
//
//  夸克会话 cookie 存取（读取 / 持久化 / 删除）+ 请求头组装 + 网络原语（ephemeral
//  URLSession、JSON 编解码、表单编码 URL 构造）——web _load_cookies_into /
//  _persist_cookies / _clear_cookie_file / _new_anon_client / _new_drive_client 语义。
//  本片是全类共用的「工具箱」（主片扫码登录、分享片解析/直链都调用它），
//  故其成员按分片需要放宽为 internal，逐个带「分片：跨文件可见」标记。
//
//  2026-09-21 从 QuarkClient.swift 原样搬出（纯搬家，无逻辑变更）：函数体逐字未改，
//  只去掉 14 个成员的 private（跨片调用点见批内报告）。结构体声明、注入缝、
//  扫码登录、旧明文文件迁移在 QuarkClient.swift；分享解析与直链在
//  QuarkClient+Share.swift。改语义时一起看。
//

import Foundation

extension QuarkClient {
    // MARK: - Cookie 存取（web _load_cookies_into / _persist_cookies / _clear_cookie_file）

    /// 分片：跨文件可见（原 private）
    var hasStoredCookies: Bool {
        if (try? cookieStore.loadCookiesData()) != nil { return true }
        // 除級：钥匙串失败时看旧明文文件（迁移失败会保留该文件）
        guard let legacy = legacyCookieFileURL else { return false }
        return FileManager.default.fileExists(atPath: legacy.path)
    }

    /// 从安全存储重载（web 每次请求都重载，登录态变更立即可见）；
    /// 条目缺失/损坏/非字符串值 → 空字典（web except (OSError, ValueError) return 对齐）。
    /// 除級顺序：钥匙串 → 旧明文文件（迁移失败时保留的可读副本）→ 空。
    /// 分片：跨文件可见（原 private）
    func loadCookies() -> [String: String] {
        migrateLegacyCookieFileIfNeeded()
        if let data = try? cookieStore.loadCookiesData(), let jar = QuarkLogic.cookies(from: data) {
            return jar
        }
        if let legacy = legacyCookieFileURL,
           let data = try? Data(contentsOf: legacy),
           let jar = QuarkLogic.cookies(from: data) {
            return jar
        }
        return [:]
    }

    /// 持久化 cookie（写入钥匙串；web _persist_cookies 语义：整体替换）。
    /// 写失败不降级为明文盘写入（凭据不落明文）——记日志后上抛，由调用方决定。
    /// 分片：跨文件可见（原 private）
    func saveCookies(_ cookies: [String: String]) throws {
        guard let data = QuarkLogic.cookiesData(cookies) else {
            throw QuarkClientError.invalidResponse
        }
        do {
            try cookieStore.saveCookiesData(data)
        } catch {
            AppLog.error(.scrape, "❌ [夸克会话] 写入钥匙串失败（不落明文降级）: \(error)")
            throw error
        }
    }

    /// 删除已存 cookie（web _clear_cookie_file，missing_ok）
    /// 分片：跨文件可见（原 private）
    func deleteCookieFile() {
        do {
            try cookieStore.deleteCookies()
        } catch {
            AppLog.warn(.scrape, "⚠️ [夸克会话] 删除钥匙串条目失败: \(error)")
        }
        // 旧明文文件存在时一并清掉（已失效凭据不应继续留在盘上）
        if let legacy = legacyCookieFileURL {
            QuarkCookieMigration.removeFileSecurely(legacy)
        }
    }

    // MARK: - 请求头（web 逐字段）

    /// 匿名客户端头（web _new_anon_client：浏览器 UA，无 Referer）
    /// 分片：跨文件可见（原 private）
    static func anonHeaders() -> [String: String] {
        ["User-Agent": browserUA]
    }

    /// drive 客户端头（web _new_drive_client：夸克客户端 UA + Referer），
    /// cookie 非空时附加 Cookie 头（httpx 只在有 cookie 时带头）。
    /// 分片：跨文件可见（原 private）
    func driveHeaders(cookies: [String: String]? = nil) -> [String: String] {
        let jar = cookies ?? loadCookies()
        var headers: [String: String] = [
            "User-Agent": Self.quarkClientUA,
            "Referer": Self.referer,
        ]
        if !jar.isEmpty {
            headers["Cookie"] = QuarkLogic.cookieHeader(jar)
        }
        return headers
    }

    /// 从 HTTPURLResponse 收集全部 Set-Cookie 头值（allHeaderFields 键大小写不定、
    /// 值可能是 String 或 [String]——不同 OS 版本行为不同，两种都兼容）
    /// 分片：跨文件可见（原 private）
    static func setCookieHeaderValues(from response: HTTPURLResponse) -> [String] {
        var values: [String] = []
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String, key.caseInsensitiveCompare("Set-Cookie") == .orderedSame else {
                continue
            }
            if let text = value as? String {
                values.append(text)
            } else if let array = value as? [String] {
                values.append(contentsOf: array)
            }
        }
        return values
    }

    // MARK: - 网络层

    /// 单次请求（ephemeral session，手动 Cookie 管理——禁 URLSession 自动 cookie
    /// 存储/附加，web httpx 语义全手动）。测试经 protocolClasses 注入 URLProtocol mock。
    /// 分片：跨文件可见（原 private）
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.poolTimeout
        configuration.timeoutIntervalForResource = Self.poolTimeout + 10
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw QuarkClientError.invalidResponse
        }
        return (data, http)
    }

    /// GET JSON：非 2xx → httpStatus；JSON 非法 → invalidResponse（都不静默）
    /// 分片：跨文件可见（原 private）
    func getJSON(url: URL, headers: [String: String]) async throws -> [String: Any] {
        let (data, http) = try await perform(makeRequest(url: url, headers: headers))
        guard (200 ..< 300).contains(http.statusCode) else {
            // 诊断打点（2026-09-08）：400/401 响应体带服务端真实原因（参数缺失提示等）
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            AppLog.error(.scrape, "❌ [夸克 GET] HTTP \(http.statusCode) url=\(url.absoluteString) body=\(bodyPreview)")
            throw QuarkClientError.httpStatus(http.statusCode)
        }
        return try Self.decode(data)
    }

    /// POST JSON：非 2xx → httpStatus；JSON 非法 → invalidResponse
    /// 分片：跨文件可见（原 private）
    func postJSON(
        url: URL, headers: [String: String], body: [String: Any]
    ) async throws -> [String: Any] {
        var request = makeRequest(url: url, headers: headers)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, http) = try await perform(request)
        guard (200 ..< 300).contains(http.statusCode) else {
            // 诊断打点（2026-09-08）：400/401 响应体带服务端真实原因（参数缺失提示等）
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            AppLog.error(.scrape, "❌ [夸克 POST] HTTP \(http.statusCode) url=\(url.absoluteString) body=\(bodyPreview)")
            throw QuarkClientError.httpStatus(http.statusCode)
        }
        return try Self.decode(data)
    }

    /// 分片：跨文件可见（原 private）
    func makeRequest(url: URL, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.poolTimeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    // MARK: - 工具

    /// base + path + query → URL（query 值按 web urllib.parse.urlencode 的
    /// quote_plus 语义编码）。
    ///
    /// ⚠️ 不能用 URLComponents.queryItems / URLQueryItem：它按 RFC 3986 把
    /// '+' 与 '/' 视为 query 合法字符不编码，而夸克服务端按
    /// x-www-form-urlencoded 解码（'+' → 空格），stoken 等 base64 值会被篡改
    /// → HTTP 400「非法 token」→ resolve 空 → shareEmptyOrExpired
    /// （2026-09-08 歌曲海下载全挂根因；web 端 httpx params 用 quote_plus
    /// 无此问题，纯 Swift 移植差异）。
    /// 分片：跨文件可见（原 private）
    static func url(_ base: String, _ path: String, query: [String: String]) -> URL {
        var components = URLComponents(string: base + path)!
        if !query.isEmpty {
            let encoded = query
                .map { key, value in
                    "\(QuarkLogic.formQueryValue(key))=\(QuarkLogic.formQueryValue(value))"
                }
                .joined(separator: "&")
            components.percentEncodedQuery = encoded
        }
        return components.url!
    }

    /// JSON Data → dict；非法 → invalidResponse（web .json() ValueError 冒泡对齐）
    /// 分片：跨文件可见（原 private）
    static func decode(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuarkClientError.invalidResponse
        }
        return object
    }

    /// 32 位小写 hex（web uuid.uuid4().hex）
    /// 分片：跨文件可见（原 private）
    static func randomHex32() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
