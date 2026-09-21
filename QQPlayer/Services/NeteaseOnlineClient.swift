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
//  2026-09-21 拆分（纯搬家，无逻辑变更）：`NeteaseOnlineLogic` / `NeteaseOnlineError`
//  搬到 NeteaseOnlineClient+Logic.swift；`NetworkTransport` 协议 + 两个文件级 private
//  URLSession 委托（302 捕获 / 下载进度）+ `URLSessionNetworkTransport` 搬到
//  NeteaseOnlineClient+Transport.swift。本文件保留模型（NeteaseOnlineSong /
//  NeteasePlayInfo）与 `NeteaseOnlineClient` 客户端（搜索 / 直链 / 专辑年份）。
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

// MARK: - 专辑发行年份（web netease_provider.get_album_year / POST /eapi/song/detail）

extension NeteaseOnlineClient {
    /// 网易云歌曲详情 → 专辑发行年份（毫秒时间戳 → 年，UTC）。
    ///
    /// web 语义（netease_provider.get_album_year + /api/tags/album-year 路由）：
    /// 查询失败/无数据/字段缺失 → 返回 null（不报错），只有参数缺失才 400；
    /// Swift 侧参数恒有（Int），故任何失败都返回 nil，调用方不感知、不抛错。
    /// 请求体：eapi POST /api/song/detail，payload = {header, e_r, ids}，
    /// ids = json.dumps([song_id]) 的字符串形态（web 双编码，须逐字节对齐）。
    func albumYear(songID: Int) async -> Int? {
        do {
            // web: json.dumps([str(song_id)]) → "[\"186016\"]"（payload 里是带转义的字符串值）
            let idsJSON = "[\"\(songID)\"]"
            let payload = OrderedJSON {
                OrderedJSONEntry("header", requestHeader())
                OrderedJSONEntry("e_r", true)
                OrderedJSONEntry("ids", idsJSON)
            }
            let body = try eapiBody(uri: "/api/song/detail", payload: payload)
            let url = URL(string: "\(apiDomain)/eapi/song/detail")!
            let data = try await post(url: url, body: body)
            let obj = try NeteaseEAPI.decrypt(data, contentType: "application/json")

            guard let songs = obj["songs"] as? [[String: Any]],
                  let first = songs.first,
                  let album = first["album"] as? [String: Any] else {
                return nil
            }
            // web 语义：publishTime 为数字且 > 0；bool 排除（isinstance(ts, bool)）
            guard let tsNumber = album["publishTime"] as? NSNumber,
                  CFGetTypeID(tsNumber) != CFBooleanGetTypeID() else {
                return nil
            }
            let milliseconds = tsNumber.doubleValue
            guard milliseconds > 0, milliseconds.isFinite else {
                return nil
            }
            return Self.utcYear(fromMilliseconds: milliseconds)
        } catch {
            return nil
        }
    }

    /// 毫秒时间戳 → UTC 年（web datetime.fromtimestamp(ts / 1000, timezone.utc).year 对齐）
    private static func utcYear(fromMilliseconds milliseconds: Double) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar.component(.year, from: Date(timeIntervalSince1970: milliseconds / 1000))
    }
}
