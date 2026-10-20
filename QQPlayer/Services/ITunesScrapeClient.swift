//
//  ITunesScrapeClient.swift
//  QQPlayer
//
//  iTunes / Apple Music Search API 刮削源（E2 2026-10「iTunes 备用源」）。
//
//  §2 核实结论：原生此前只有 MusicBrainzClient 的 iTunes **封面 fallback**
//  （itunesCoverURL：查询 media=music&limit=5，只取 results[0].artworkUrl100，服务封面
//  兜底链），**没有**「按源返回候选」的实现，故本文件新建候选源；端点常量复用
//  MusicBrainzClient.itunesSearch（不重复 itunes.apple.com 字面量）。
//
//  语义：
//  - 请求 https://itunes.apple.com/search?term=<query>&entity=song&country=tw&limit=20
//  - 店区顺序 tw → us：CN 店区 entity=song 恒返回 0 条（2026-10 实测），tw 对中文原唱
//    覆盖最好，空/失败才回退 us；primary 命中即返回，不再发 fallback 请求
//  - 任何失败（超时 / 网络 / 非 2xx / 解析失败）→ 返回 []，绝不抛、不影响其它源
//  - 映射唯一入口 candidates(fromJSON:)（纯函数，可单测）
//  - URLProtocol 注入 seam（照 MusicBrainzClient 写法），便于测试
//

import Foundation

struct ITunesScrapeClient {
    /// 复用既有 iTunes 端点常量（MusicBrainzClient 封面 fallback 用同一常量）
    static let searchBaseURL = MusicBrainzClient.itunesSearch
    /// 与 MusicBrainzClient 同一 UA（Apple 端点无强制 UA 要求，保持一致便于排查）
    static let userAgent = MusicBrainzClient.userAgent

    /// 店区顺序：`tw` 主（中文原唱覆盖最好）、`us` 回退（CN 店区 `entity=song` 恒返回 0 条）
    static let storefronts = ["tw", "us"]
    /// 单次查询候选上限（§3.B：limit=20）
    static let searchLimit = 20
    /// 网络超时（§3.B：10s）
    static let requestTimeout: TimeInterval = 10

    /// 测试注入：URLProtocol mock 类列表（nil = 真实网络）
    private let protocolClasses: [AnyClass]?

    init(protocolClasses: [AnyClass]? = nil) {
        self.protocolClasses = protocolClasses
    }

    /// 查询 → 候选；空 query / 任何失败 → []（不抛、不影响其它源）
    ///
    /// 按 `storefronts` 顺序尝试：某个店区拿到候选即返回（不再请求后续店区）；
    /// 空结果 / 网络失败 / 非 2xx / 解析失败 → 继续下一个店区；全部失败 → []。
    func candidates(query: String) async -> [ScrapeCandidate] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        var merged: [ScrapeCandidate] = []
        for storefront in Self.storefronts {
            guard let url = Self.searchURL(term: term, storefront: storefront) else { return merged }
            let batch: [ScrapeCandidate]
            do {
                batch = Self.candidates(fromJSON: try await fetch(url))
            } catch {
                continue
            }
            guard !batch.isEmpty else { continue }
            merged = Self.merging(merged, with: batch)
            break
        }
        return merged
    }

    /// 构造查询 URL（term 去空白后为空 → nil）；storefront 由调用方按 `storefronts` 传入
    static func searchURL(term rawTerm: String, storefront: String) -> URL? {
        let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return nil }
        var components = URLComponents(url: searchBaseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "country", value: storefront),
            URLQueryItem(name: "limit", value: String(searchLimit)),
        ]
        return components.url
    }

    /// 合并去重：按 `trackId`（候选 `id`）保留首次出现的条目；无 `id` 的候选无法判重，逐条保留。
    static func merging(_ existing: [ScrapeCandidate], with incoming: [ScrapeCandidate]) -> [ScrapeCandidate] {
        var result = existing
        var seen = Set(existing.compactMap(\.id))
        for candidate in incoming {
            guard let id = candidate.id else {
                result.append(candidate)
                continue
            }
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(candidate)
        }
        return result
    }

    /// iTunes search JSON → 候选（**唯一转换入口**，纯函数可单测）
    ///
    /// 字段映射：title=trackName / artist=artistName / album=collectionName /
    /// year=releaseDate 前 4 位 / genre=primaryGenreName / track=trackNumber /
    /// albumArtist=artistName / durationMs=trackTimeMillis /
    /// coverURL=artworkUrl100 的 100x100bb → 600x600bb（id=trackId）。
    /// 缺 trackName 的条目跳过（缺字段尽力取值）。
    static func candidates(fromJSON data: Data) -> [ScrapeCandidate] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = object["results"] as? [Any] else {
            return []
        }
        var candidates: [ScrapeCandidate] = []
        for item in results {
            guard let dict = item as? [String: Any],
                  let title = stringValue(dict["trackName"]), !title.isEmpty else {
                continue
            }
            candidates.append(ScrapeCandidate(
                source: ScrapeSource.itunes.rawValue,
                id: intValue(dict["trackId"]).map(String.init),
                title: title,
                artist: stringValue(dict["artistName"]),
                album: stringValue(dict["collectionName"]),
                coverURL: artworkURL(dict["artworkUrl100"]),
                year: year(from: dict["releaseDate"]),
                genre: stringValue(dict["primaryGenreName"]),
                track: intValue(dict["trackNumber"]),
                albumArtist: stringValue(dict["artistName"]),
                durationMs: intValue(dict["trackTimeMillis"])
            ))
        }
        return candidates
    }

    // MARK: - 字段提取（全部尽力取值，失败 → nil）

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let text = value as? String {
            return Int(text)
        }
        return nil
    }

    /// 年份：releaseDate（ISO8601，如 2008-11-11T08:00:00Z）取首个 4 位数字
    private static func year(from value: Any?) -> Int? {
        guard let text = value as? String,
              let match = text.range(of: #"\d{4}"#, options: .regularExpression),
              let year = Int(text[match]) else {
            return nil
        }
        return year
    }

    /// artworkUrl100（100x100bb）→ 600x600bb 高清
    private static func artworkURL(_ value: Any?) -> URL? {
        guard let text = stringValue(value) else { return nil }
        return URL(string: text.replacingOccurrences(of: "100x100bb", with: "600x600bb"))
    }

    // MARK: - 网络层（照 MusicBrainzClient 的 URLProtocol 注入写法）

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
