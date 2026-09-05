//
//  MusicBrainzClient.swift
//  QQPlayer
//
//  MusicBrainz recording 搜索 + Cover Art Archive + iTunes Search fallback
//  （web 版 backend/tag_scraper.py 移植，E1 刮削批 2026-09）。web 为唯一事实源。
//
//  语义对齐（web TagScraper）：
//  - recording 查询降级链 3 阶段：recording:"title"（精确）→ recording:"title"~
//    （Lucene fuzzy）→ title:title（关键词兜底）；任一阶段有结果即返回不再降级；
//    阶段调用前必须 sleep 1s（MusicBrainz 限流要求）
//  - artist 不作为查询硬条件（文件 tag 歌手名与 MB 写法不一致——别名/繁简/大小写/
//    标点/feat. 部分——会导致整条查询 0 结果），只参与结果排序加分：
//    归一化（小写+去 \W_ 字符）后相等/互相包含 → 排前面（稳定排序保持 MB score 序）
//  - 候选字段尽力取值，失败 → nil/空串，绝不抛异常：
//    title/artist(artist-credit joinphrase 保留)/album(取 releases 首个有 id)/cover/
//    year(release.date 优先，first-release-date 兜底，正则取 \d{4})/genre(recording.tags
//    按 count 降序前 3 个用 "/" 连接)/track(releases[0].media[].track[] 按 recording id
//    匹配取 number 首个数字)/album_artist(release artist-credit)/mbid(recording id)
//  - 封面 fallback 链：网易云 cover 由调用方先取 → iTunes Search API
//    （term="{title} {artist}"，media=music，results[0].artworkUrl100 换 600x600）→
//    Cover Art Archive（先 MB 搜 recording 取首个有 id 的 release MBID →
//    https://coverartarchive.org/release/{mbid}/front，非 4xx 即认为有封面；
//    同 MBID 结果缓存）
//  - 单源失败返回空数组，整体不抛异常；任何外部源挂掉不影响其他
//  - UA 必须自定义（MusicBrainz 拒绝默认 UA）："QQPlayer/1.0 (https://github.com/daxmate/qqplayer)"
//
//  测试：URLProtocol mock（MockURLProtocol 既有模式）；sleep 注入（protocol 或闭包）

import Foundation

/// MB/iTunes 刮削候选（宽松视图，字段缺省回落）
struct ScrapeCandidate: Sendable {
    var source: String          // "netease" | "musicbrainz"
    var id: String?             // 网易云歌曲 id / MB recording id（mbid）
    var title: String?
    var artist: String?
    var album: String?
    var coverURL: URL?
    var year: Int?
    var genre: String?
    var track: Int?
    var albumArtist: String?
    var durationMs: Int?
}

enum MusicBrainzClientError: Error {
    case badResponse
}

struct MusicBrainzClient {
    static let apiBase = URL(string: "https://musicbrainz.org/ws/2/recording")!
    static let coverArtArchiveFront = "https://coverartarchive.org/release/{mbid}/front"
    static let itunesSearch = URL(string: "https://itunes.apple.com/search")!
    static let userAgent = "QQPlayer/1.0 (https://github.com/daxmate/qqplayer)"

    /// 供测试注入的时钟/休眠
    var sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }

    /// 测试注入：URLProtocol mock 类列表（nil = 真实网络）。网络请求每次临时构造
    /// URLSession（带取消重定向 delegate），无法注入现成 session，故注入 protocolClasses。
    private let protocolClasses: [AnyClass]?

    /// CAA 结果缓存（同 release MBID 只查一次；含负缓存）。class box 引用语义：
    /// struct 值拷贝间共享缓存，且请求方法无需标 mutating。
    private let caaCache = MusicBrainzCAACacheBox()

    init(
        sleep: @escaping (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        },
        protocolClasses: [AnyClass]? = nil
    ) {
        self.sleep = sleep
        self.protocolClasses = protocolClasses
    }

    /// 单次 MB 搜索最大候选数（web SEARCH_LIMIT = 20）
    private static let searchLimit = 20
    /// 封面 fallback 里 MB release 检索用 limit（web _musicbrainz_release_mbid limit=5）
    private static let releaseSearchLimit = 5

    // MARK: - recording 降级链搜索（web _mb_search）

    /// MB recording 降级查询链：精确短语 → fuzzy → title 关键词。
    /// 任一步有结果即返回（不再降级）；异常/非 2xx 直接返回空（不继续打后续阶段，
    /// 避免对不可用 API 反复请求）。每阶段调用前 sleep 1s（限流要求）。
    private func mbSearch(query: String, limit: Int) async -> [[String: Any]] {
        for stage in Self.mbQueryStages(query) {
            do {
                try await sleep(1)
                var components = URLComponents(url: Self.apiBase, resolvingAgainstBaseURL: false)!
                components.queryItems = [
                    URLQueryItem(name: "query", value: stage),
                    URLQueryItem(name: "fmt", value: "json"),
                    URLQueryItem(name: "limit", value: String(limit)),
                ]
                let obj = try await getJSON(
                    url: components.url!,
                    headers: ["User-Agent": Self.userAgent, "Accept": "application/json"]
                )
                let recordings = (obj["recordings"] as? [[String: Any]]) ?? []
                if !recordings.isEmpty {
                    return recordings
                }
            } catch {
                return []
            }
        }
        return []
    }

    /// MB 查询降级链构造（web _mb_query_stages）。空/空白 query → 无阶段。
    /// Lucene 特殊字符转义：短语内容里只可能被引号/反斜杠破坏。
    static func mbQueryStages(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let escaped = q.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return ["recording:\"\(escaped)\"", "recording:\"\(escaped)\"~", "title:\(escaped)"]
    }

    // MARK: - MB recording 搜索 → 候选（web _scrape_musicbrainz）

    /// MB recording 搜索 + 候选构造（year/genre/track/album_artist/封面 fallback 全量）。
    /// artist 仅排序加分（匹配的排前面，MB score 序保持——稳定排序）。
    /// 单条坏数据跳过不炸整批；单源整体失败返回空数组不 throw。
    func searchMusicBrainz(title: String, artist: String) async throws -> [ScrapeCandidate] {
        let recordings = await mbSearch(query: title, limit: Self.searchLimit)
        let ranked = Self.rankByArtist(recordings, artist: artist)
        var results: [ScrapeCandidate] = []
        for recording in ranked {
            guard let mbid = recording["id"] as? String, !mbid.isEmpty,
                  let titleValue = recording["title"] as? String, !titleValue.isEmpty else {
                continue
            }
            // releases 首个有 id 的（web next(r for r if dict and r.get("id"))）
            let release = ((recording["releases"] as? [Any]) ?? [])
                .compactMap { $0 as? [String: Any] }
                .first { ($0["id"] as? String)?.isEmpty == false }
            var cover: URL?
            if let release, let releaseID = release["id"] as? String {
                cover = try? await coverArtArchiveFront(mbid: releaseID)
            }
            let credit = (recording["artist-credit"] as? [Any]) ?? []
            results.append(ScrapeCandidate(
                source: "musicbrainz",
                id: mbid,
                title: titleValue,
                artist: Self.joinArtistCredit(credit),
                album: Self.stringValue(release?["title"]),
                coverURL: cover,
                year: Self.releaseYear(release: release, recording: recording),
                genre: Self.recordingGenre(recording),
                track: Self.recordingTrackNumber(recording),
                albumArtist: release.map { Self.joinArtistCredit(($0["artist-credit"] as? [Any]) ?? []) } ?? "",
                durationMs: nil
            ))
        }
        return results
    }

    /// artist 排序加分：归一化匹配的 recording 排前面，其余保持 MB 返回序（稳定排序）。
    private static func rankByArtist(_ recordings: [[String: Any]], artist: String) -> [[String: Any]] {
        let artistValue = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artistValue.isEmpty else { return recordings }
        return recordings.enumerated().sorted { lhs, rhs in
            let lhsMatched = artistMatches(
                joinArtistCredit((lhs.element["artist-credit"] as? [Any]) ?? []), artistValue
            )
            let rhsMatched = artistMatches(
                joinArtistCredit((rhs.element["artist-credit"] as? [Any]) ?? []), artistValue
            )
            if lhsMatched != rhsMatched {
                return lhsMatched
            }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    // MARK: - 候选字段提取（全部尽力取值，失败 → nil/空串，绝不 throw）

    /// 宽松取字符串：字符串原样；数字 → stringValue（MB 部分字段可能是数字）
    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String {
            return text
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    /// 年份：release.date 优先，recording.first-release-date 兜底；正则取 \d{4}（web _release_year）
    private static func releaseYear(release: [String: Any]?, recording: [String: Any]) -> Int? {
        let candidates = [
            release.flatMap { stringValue($0["date"]) },
            stringValue(recording["first-release-date"]),
        ]
        for candidate in candidates {
            guard let value = candidate else { continue }
            if let match = value.range(of: #"\d{4}"#, options: .regularExpression) {
                guard let year = Int(value[match]) else { return nil }
                return year
            }
        }
        return nil
    }

    /// 流派：recording.tags 按 count 降序取前 3 个 name 用 "/" 连接；无 → ""（web _recording_genre）
    private static func recordingGenre(_ recording: [String: Any]) -> String {
        let tags = (recording["tags"] as? [Any]) ?? []
        var named: [(name: String, count: Int)] = []
        for tag in tags {
            guard let dict = tag as? [String: Any],
                  let name = stringValue(dict["name"]), !name.isEmpty else { continue }
            let count = (dict["count"] as? NSNumber)?.intValue ?? 0
            named.append((name, count))
        }
        // count 降序；同 count 保持 MB 原序（Python sorted 稳定 → 手动稳定化）
        let sorted = named.enumerated().sorted { lhs, rhs in
            if lhs.element.count != rhs.element.count {
                return lhs.element.count > rhs.element.count
            }
            return lhs.offset < rhs.offset
        }
        return sorted.prefix(3).map { $0.element.name }.joined(separator: "/")
    }

    /// 音轨序号：releases 首个 release 的 media 里找本 recording 对应 track.number 首个数字
    /// （web _recording_track_number；找不到 → nil，绝不 throw）
    private static func recordingTrackNumber(_ recording: [String: Any]) -> Int? {
        guard let releases = recording["releases"] as? [Any],
              let first = releases.first(where: { $0 is [String: Any] }) as? [String: Any],
              let recID = recording["id"] as? String else {
            return nil
        }
        for medium in (first["media"] as? [Any]) ?? [] {
            guard let mediumDict = medium as? [String: Any] else { continue }
            for track in (mediumDict["track"] as? [Any]) ?? [] {
                guard let trackDict = track as? [String: Any] else { continue }
                // track.recording 可能是 dict（{id:…}）或直接 id 字符串
                let trackRecording = trackDict["recording"]
                let trackRecID: String?
                if let idString = trackRecording as? String {
                    trackRecID = idString
                } else if let idDict = trackRecording as? [String: Any] {
                    trackRecID = stringValue(idDict["id"])
                } else {
                    trackRecID = nil
                }
                guard let trackRecID, trackRecID == recID else { continue }
                // web 正则 ^\s*(\d+)：去前导空白后取首段连续数字
                guard let numberValue = stringValue(trackDict["number"]) else { continue }
                let digits = numberValue
                    .trimmingCharacters(in: .whitespaces)
                    .prefix(while: { $0.isNumber })
                guard !digits.isEmpty, let number = Int(digits) else { continue }
                return number
            }
        }
        return nil
    }

    /// MusicBrainz artist-credit → 显示名（web _join_artist_credit，保留 joinphrase 如 "A feat. B"）
    static func joinArtistCredit(_ credit: [Any]) -> String {
        var parts: [String] = []
        for entry in credit {
            if let text = entry as? String {
                parts.append(text)
            } else if let dict = entry as? [String: Any],
                      let name = stringValue(dict["name"]), !name.isEmpty {
                parts.append(name)
                if let joinphrase = stringValue(dict["joinphrase"]), !joinphrase.isEmpty {
                    parts.append(joinphrase)
                }
            }
        }
        return parts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// artist 匹配归一化（web _norm）：小写 + 去 \W_（保留字母/数字/CJK）
    private static func normalizedArtist(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// artist 归一化匹配（web _artist_matches(credit, artist)）：归一化后相等/互相包含；
    /// 任一归一化后为空 → false
    static func artistMatches(_ a: String, _ b: String) -> Bool {
        let na = normalizedArtist(a)
        let nb = normalizedArtist(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na == nb || na.contains(nb) || nb.contains(na)
    }

    // MARK: - iTunes Search 封面（web _itunes_cover）

    /// iTunes Search API：results[0].artworkUrl100 → 600x600 高清 URL；失败/无结果 → nil
    func itunesCoverURL(title: String, artist: String) async throws -> URL? {
        let term = "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        var components = URLComponents(url: Self.itunesSearch, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        do {
            let obj = try await getJSON(url: components.url!)
            let results = (obj["results"] as? [Any]) ?? []
            if let first = results.first as? [String: Any],
               let artwork = Self.stringValue(first["artworkUrl100"]) {
                let upgraded = artwork.replacingOccurrences(of: "100x100", with: "600x600")
                return URL(string: upgraded)
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Cover Art Archive（web _musicbrainz_release_mbid / _coverartarchive_front）

    /// 封面 fallback 的 CAA 步：MB 搜 recording 取首个有 id 的 release MBID → CAA front
    /// （web _musicbrainz_release_mbid + _coverartarchive_front）
    func coverArtArchiveFront(title: String, artist: String) async throws -> URL? {
        guard let releaseMBID = await musicbrainzReleaseMBID(title: title, artist: artist) else {
            return nil
        }
        return try await coverArtArchiveFront(mbid: releaseMBID)
    }

    /// CAA release 前封面（web _coverartarchive_front）：2xx/3xx 视为有封面（返回 CAA URL
    /// 本身，非图片数据）；404/异常 → nil（不报错）；同 MBID 结果缓存（含负缓存）。
    func coverArtArchiveFront(mbid: String) async throws -> URL? {
        if let cached = caaCache.url(for: mbid) {
            return cached
        }
        if caaCache.hasConclusion(for: mbid) {
            return nil
        }
        let template = MusicBrainzClient.coverArtArchiveFront
        let url = URL(string: template.replacingOccurrences(of: "{mbid}", with: mbid))!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await send(request)
            // CAA 有封面时返回 3xx 重定向到 archive.org 图片（302/307），404 表示无封面
            let present = (200 ..< 400).contains(response.statusCode)
            caaCache.store(mbid, present ? url : nil)
            return present ? url : nil
        } catch {
            caaCache.store(mbid, nil)
            return nil
        }
    }

    /// MB 搜 recording（limit 5），取第一个有 id 的 release MBID（封面 fallback 用；
    /// 同样走降级链，artist 仅排序加分——web _musicbrainz_release_mbid）
    private func musicbrainzReleaseMBID(title: String, artist: String) async -> String? {
        let recordings = await mbSearch(query: title, limit: Self.releaseSearchLimit)
        let ranked = Self.rankByArtist(recordings, artist: artist)
        for recording in ranked {
            for release in (recording["releases"] as? [Any]) ?? [] {
                guard let releaseDict = release as? [String: Any],
                      let releaseID = Self.stringValue(releaseDict["id"]), !releaseID.isEmpty else {
                    continue
                }
                return releaseID
            }
        }
        return nil
    }

    // MARK: - 封面 fallback 链（web _fallback_cover）

    /// iTunes Search API → CAA → nil（网易云 cover 由调用方先取，不在这里）
    func fallbackCoverURL(title: String, artist: String) async throws -> URL? {
        if let cover = try await itunesCoverURL(title: title, artist: artist) {
            return cover
        }
        return try await coverArtArchiveFront(title: title, artist: artist)
    }

    // MARK: - 网络层

    /// 请求（不跟随重定向）：CAA 3xx 判定需要把 3xx 当终态响应，不能交给 URLSession
    /// 自动跟随。测试通过 protocolClasses 注入 URLProtocol mock（每请求临时 session，
    /// delegate 本地强引用保活，与 URLSessionNetworkTransport.getWithoutRedirect 同款）。
    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let delegate = RedirectCancelDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MusicBrainzClientError.badResponse
        }
        return (data, http)
    }

    /// GET JSON：非 2xx → throw（调用方按 web 语义转空/降级）
    private func getJSON(url: URL, headers: [String: String] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await send(request)
        guard (200 ..< 300).contains(response.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MusicBrainzClientError.badResponse
        }
        return obj
    }
}

/// CAA 结果缓存（同 release MBID 只查一次；含负缓存——404/异常也记住，不再重试）
private final class MusicBrainzCAACacheBox: @unchecked Sendable {
    private let lock = NSLock()
    private var positives: [String: URL] = [:]
    private var negatives: Set<String> = []

    /// 命中正缓存返回 URL；未命中/负缓存返回 nil
    func url(for mbid: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return positives[mbid]
    }

    /// 是否已有结论（正或负）——命中即不再发请求
    func hasConclusion(for mbid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return positives[mbid] != nil || negatives.contains(mbid)
    }

    func store(_ mbid: String, _ url: URL?) {
        lock.lock()
        defer { lock.unlock() }
        if let url {
            positives[mbid] = url
        } else {
            negatives.insert(mbid)
        }
    }
}

/// 重定向取消 delegate：CAA 封面判定需要「不跟随重定向」（3xx 直接视为有封面）
private final class RedirectCancelDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
