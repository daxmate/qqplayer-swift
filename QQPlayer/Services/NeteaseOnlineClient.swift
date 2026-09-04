//
//  NeteaseOnlineClient.swift
//  QQPlayer
//
//  网易云在线搜索/直链/下载客户端（web 版 /api/online/* + backend/netease_provider.py
//  对齐，2026-09 C 组「在线搜索下载」）。QQPlayer 共享层：iOS folder-sync 自动含，
//  QQPlayerMac target 走 B1A 白名单（pbxproj membershipExceptions）。
//
//  语义对齐（web 后端为唯一事实源，此处逐条注释）：
//  - search：eapi POST /api/cloudsearch/pc（复用 NeteaseEAPI 加密/解密 + OrderedJSON）
//  - 播放直链：Meting（api.qijieya.cn，302 → Location）优先 → cenguigui 兜底
//  - 下载文件名：{title}-{artist}.{ext}（artist 清洗后空 → {title}.{ext}，title 也空用 id）
//  - 音质：standard=128 / exhigh=320（默认）/ lossless=2000 / hires=2000
//  纯逻辑抽到 NeteaseOnlineLogic（防回归单测）；网络层抽象 NetworkTransport（测试注入）。
//

import Foundation

// MARK: - 模型

/// 网易云在线搜索结果条目（web /api/online/search items 结构对齐）
struct NeteaseOnlineSong: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let title: String
    let artist: String          // 多歌手逗号连接
    let album: String?          // 专辑名
    let coverURL: URL?          // https 化封面（ATS：web _to_https 对齐）
    let durationMs: Int?
    let level: String           // 音质等级（web DEFAULT_LEVEL "exhigh"）

    /// 展示用 mm:ss 时长
    var durationDisplay: String? {
        guard let durationMs, durationMs > 0 else { return nil }
        let totalSeconds = durationMs / 1000
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

/// 播放直链信息（web netease_provider.get_play_info 结构对齐）
struct NeteasePlayInfo: Sendable {
    let url: URL
    let ext: String       // URL 推断：mp3/flac/…
    let bitrate: String   // 实际比特率标注
}

// MARK: - 纯逻辑（web 语义对齐，可单测）

enum NeteaseOnlineLogic {
    static let validLevels = ["standard", "exhigh", "lossless", "hires"]
    static let defaultLevel = "exhigh"

    /// 非法/缺失音质 → 默认 exhigh（web VALID_LEVELS 检查同语义）
    static func normalizeLevel(_ level: String?) -> String {
        guard let level = level?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              validLevels.contains(level) else {
            return defaultLevel
        }
        return level
    }

    /// 音质等级 → Meting br 参数（web METING_BR_BY_LEVEL 对齐）
    static func brParameter(forLevel level: String) -> String {
        switch normalizeLevel(level) {
        case "standard": return "128"
        case "exhigh": return "320"
        case "lossless", "hires": return "2000"
        default: return "320"
        }
    }

    /// 文件名清洗：去掉 / \\ : * ? " < > | 与首尾空白（web download._sanitize_filename 对齐）
    static func sanitizeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: invalid).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 从 URL 推断扩展名（去 query，取路径末段点后缀；推断不出用 fallback）。
    /// web _extract_ext：后缀须字母数字且 ≤5 字符。
    static func extractExtension(from url: URL, fallback: String = "mp3") -> String {
        let name = url.path.components(separatedBy: "/").last ?? ""
        guard let dot = name.lastIndex(of: ".") else { return fallback }
        let candidate = String(name[name.index(after: dot)...]).lowercased()
        guard !candidate.isEmpty, candidate.count <= 5,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return fallback
        }
        return candidate
    }

    /// http:// → https://（CDN 同路径支持 https；web _to_https 对齐）
    static func toHttpsURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var candidate = trimmed
        if candidate.lowercased().hasPrefix("http://") {
            candidate = "https://" + String(candidate.dropFirst("http://".count))
        }
        return URL(string: candidate)
    }

    /// 下载文件名：{title}-{artist}.{ext}；artist 清洗后空 → {title}.{ext}；
    /// title 清洗后也空 → id 兜底（web /api/online/download 对齐）
    static func downloadFileName(title: String, artist: String, ext: String, songID: Int) -> String {
        let cleanExt = ext.isEmpty ? "mp3" : ext
        let cleanTitle = sanitizeFilename(title)
        let cleanArtist = sanitizeFilename(artist)
        let titlePart = cleanTitle.isEmpty ? String(songID) : cleanTitle
        let base = cleanArtist.isEmpty ? titlePart : "\(titlePart)-\(cleanArtist)"
        return "\(base).\(cleanExt)"
    }

    /// 重名加序号：name.ext → name (1).ext（web download._unique_path 对齐；exists 由调用方注入）
    static func uniqueFileName(base: String, exists: (String) -> Bool) -> String {
        guard exists(base) else { return base }
        guard let dot = base.lastIndex(of: ".") else {
            for i in 1 ..< 1000 {
                let cand = "\(base) (\(i))"
                if !exists(cand) { return cand }
            }
            return base
        }
        let stem = String(base[..<dot])
        let ext = String(base[dot...])
        for i in 1 ..< 1000 {
            let cand = "\(stem) (\(i))\(ext)"
            if !exists(cand) { return cand }
        }
        return base
    }
}

// MARK: - 错误

enum NeteaseOnlineError: Error, LocalizedError {
    case httpError(Int)
    case invalidResponse
    case noPlayURL
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "HTTP \(code)"
        case .invalidResponse: return "invalid response"
        case .noPlayURL: return "no play URL"
        case .downloadFailed(let reason): return reason
        }
    }
}

// MARK: - 网络传输抽象（测试注入）

protocol NetworkTransport: Sendable {
    /// 普通请求（自动跟随重定向；POST/GET 通用）
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// GET 且不跟随重定向：302 时返回响应头 Location（Meting 直链语义）
    func getWithoutRedirect(url: URL, timeout: TimeInterval) async throws -> (statusCode: Int, headers: [String: String], body: Data)
    /// 流式下载到文件（跟随重定向）
    func download(url: URL, to destination: URL, timeout: TimeInterval, headers: [String: String]) async throws
}

/// 重定向捕获 delegate：302 时记录 Location 并取消跟随（Meting 直链）
private final class RedirectCapturingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _redirectLocation: String?

    var redirectLocation: String? {
        lock.lock()
        defer { lock.unlock() }
        return _redirectLocation
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        _redirectLocation = request.url?.absoluteString
        lock.unlock()
        completionHandler(nil) // 取消跟随
    }
}

/// URLSession 实现（macOS 13+/iOS 均可用）
struct URLSessionNetworkTransport: NetworkTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NeteaseOnlineError.invalidResponse
        }
        return (data, http)
    }

    func getWithoutRedirect(
        url: URL,
        timeout: TimeInterval
    ) async throws -> (statusCode: Int, headers: [String: String], body: Data) {
        let delegate = RedirectCapturingDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 10
        // delegate 被 session 弱引用：整个请求期间持有强引用
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NeteaseOnlineError.invalidResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        if let redirect = delegate.redirectLocation, headers["Location"] == nil {
            headers["Location"] = redirect
        }
        return (http.statusCode, headers, data)
    }

    func download(
        url: URL,
        to destination: URL,
        timeout: TimeInterval,
        headers: [String: String]
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw NeteaseOnlineError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        try FileManager.default.removeItem(at: destination) // 覆盖旧文件（临时同名残留）
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }
}

// MARK: - 客户端

/// 网易云在线搜索/直链/下载（web netease_provider + /api/online/* 对齐）。
/// 每实例独立随机 deviceId（与 NeteaseLyricsProvider 同款防风控策略）。
struct NeteaseOnlineClient: Sendable {
    static let shared = NeteaseOnlineClient()

    private let transport: any NetworkTransport
    private let deviceID: String

    private let apiDomain = "https://interface.music.163.com"
    private let metingURL = URL(string: "https://api.qijieya.cn/meting/")!
    private let cenguiguiURL = URL(string: "https://api-v2.cenguigui.cn/api/netease/music_v1.php")!
    private let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 "
            + "NeteasyMusicDesktop/3.1.19.204510"

    init(transport: (any NetworkTransport)? = nil) {
        self.transport = transport ?? URLSessionNetworkTransport()
        self.deviceID = NeteaseOnlineClient.randomHex(length: 16)
    }

    // MARK: 搜索（eapi /api/cloudsearch/pc）

    /// 在线搜索歌曲；query 去空白后为空返回 []；网络/解析失败抛 NeteaseOnlineError。
    func search(query: String, limit: Int = 20) async throws -> [NeteaseOnlineSong] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let bounded = max(1, min(50, limit))

        let payload = OrderedJSON {
            OrderedJSONEntry("header", requestHeader())
            OrderedJSONEntry("e_r", true)
            OrderedJSONEntry("s", q)
            OrderedJSONEntry("type", 1)
            OrderedJSONEntry("limit", bounded)
            OrderedJSONEntry("offset", 0)
            OrderedJSONEntry("total", true)
        }
        let body = try eapiBody(uri: "/api/cloudsearch/pc", payload: payload)
        let url = URL(string: "\(apiDomain)/eapi/cloudsearch/pc")!
        let data = try await post(url: url, body: body)
        let obj = try NeteaseEAPI.decrypt(data, contentType: "application/json")

        guard let result = obj["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            return []
        }
        return songs.compactMap { mapSong($0) }
    }

    // MARK: 播放直链（Meting → cenguigui 兜底）

    /// 取播放直链；Meting 失败自动 cenguigui 兜底，两者皆失败抛 noPlayURL。
    func playInfo(songID: Int, level: String? = nil) async throws -> NeteasePlayInfo {
        let normalized = NeteaseOnlineLogic.normalizeLevel(level)
        if let url = try? await fetchViaMeting(songID: songID, level: normalized) {
            return NeteasePlayInfo(
                url: url,
                ext: NeteaseOnlineLogic.extractExtension(from: url),
                bitrate: NeteaseOnlineLogic.brParameter(forLevel: normalized)
            )
        }
        return try await fetchViaCenguigui(songID: songID, level: normalized)
    }

    // MARK: - 内部

    private func requestHeaderItems() -> [(key: String, value: String)] {
        [
            ("os", "pc"),
            ("appver", "3.1.19.204510"),
            ("requestId", "0"),
            ("osver", "Microsoft-Windows-11-Home-China-build-22631-64bit"),
            ("deviceId", deviceID),
            ("MUSIC_U", ""),
        ]
    }

    private func requestHeader() -> OrderedJSON {
        OrderedJSON {
            for (key, value) in requestHeaderItems() {
                OrderedJSONEntry(key, value)
            }
        }
    }

    private func cookieHeader() -> String {
        requestHeaderItems().map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private func eapiBody(uri: String, payload: OrderedJSON) throws -> Data {
        let jsonString = payload.stringValue()
        let params = NeteaseEAPI.encrypt(uri: uri, payloadJSON: jsonString)
        return Data("params=\(params)".utf8)
    }

    private func post(url: URL, body: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let (data, http) = try await transport.data(for: request)
        guard http.statusCode == 200 else {
            throw NeteaseOnlineError.httpError(http.statusCode)
        }
        return data
    }

    /// Meting：GET 不跟随重定向；302 → Location 直链；200 → body 解析（web _get_by_meting 对齐）
    private func fetchViaMeting(songID: Int, level: String) async throws -> URL {
        let br = NeteaseOnlineLogic.brParameter(forLevel: level)
        var components = URLComponents(url: metingURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "server", value: "netease"),
            URLQueryItem(name: "type", value: "url"),
            URLQueryItem(name: "id", value: String(songID)),
            URLQueryItem(name: "br", value: br),
        ]
        let result = try await transport.getWithoutRedirect(url: components.url!, timeout: 20)

        if result.statusCode == 302 {
            if let location = result.headers["Location"] ?? result.headers["location"],
               let url = NeteaseOnlineLogic.toHttpsURL(location) {
                return url
            }
            throw NeteaseOnlineError.noPlayURL
        }
        guard result.statusCode == 200 else {
            throw NeteaseOnlineError.httpError(result.statusCode)
        }
        if let url = extractMetingBodyURL(result.body) {
            return url
        }
        throw NeteaseOnlineError.noPlayURL
    }

    /// Meting body 解析：裸 URL / JSON 数组 [{"url":…}] / JSON 对象 url|data{url}
    private func extractMetingBodyURL(_ data: Data) -> URL? {
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let url = NeteaseOnlineLogic.toHttpsURL(raw), url.scheme != nil {
            return url
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let array = json as? [[String: Any]], let first = array.first,
           let urlString = first["url"] as? String {
            return NeteaseOnlineLogic.toHttpsURL(urlString)
        }
        if let dict = json as? [String: Any] {
            if let urlString = dict["url"] as? String {
                return NeteaseOnlineLogic.toHttpsURL(urlString)
            }
            if let nested = dict["data"] as? [String: Any],
               let urlString = nested["url"] as? String {
                return NeteaseOnlineLogic.toHttpsURL(urlString)
            }
        }
        return nil
    }

    /// cenguigui 兜底：data.code==200 且 data.data.url 为 http(s)（web _get_by_cenguigui 对齐）
    private func fetchViaCenguigui(songID: Int, level: String) async throws -> NeteasePlayInfo {
        var components = URLComponents(url: cenguiguiURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "id", value: String(songID)),
            URLQueryItem(name: "type", value: "json"),
            URLQueryItem(name: "level", value: level),
        ]
        let result = try await transport.getWithoutRedirect(url: components.url!, timeout: 20)
        guard result.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: result.body) as? [String: Any],
              (obj["code"] as? Int) == 200,
              let data = obj["data"] as? [String: Any],
              let urlString = data["url"] as? String,
              let url = NeteaseOnlineLogic.toHttpsURL(urlString) else {
            throw NeteaseOnlineError.noPlayURL
        }
        let format = (data["format"] as? String) ?? ""
        let bitrate = format.isEmpty ? level : format
        return NeteasePlayInfo(
            url: url,
            ext: NeteaseOnlineLogic.extractExtension(from: url),
            bitrate: bitrate
        )
    }

    private func mapSong(_ song: [String: Any]) -> NeteaseOnlineSong? {
        guard let id = song["id"] as? Int else { return nil }
        let title = song["name"] as? String ?? ""
        let artist = joinArtists(song["ar"] as? [[String: Any]])
        let albumDict = (song["al"] as? [String: Any]) ?? (song["album"] as? [String: Any])
        let album = albumDict?["name"] as? String
        let cover = NeteaseOnlineLogic.toHttpsURL((albumDict?["picUrl"] as? String) ?? "")
        let durationMs = song["dt"] as? Int
        return NeteaseOnlineSong(
            id: id,
            title: title,
            artist: artist,
            album: album,
            coverURL: cover,
            durationMs: durationMs,
            level: NeteaseOnlineLogic.defaultLevel
        )
    }

    private func joinArtists(_ artists: [[String: Any]]?) -> String {
        guard let artists else { return "" }
        return artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
    }

    private static func randomHex(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
