//
//  MusicBrainzClient+ArtistRelation.swift
//  QQPlayer
//
//  推荐 v2 P4：MusicBrainz 艺人关系查询（MB artist → artist-rels → 相关艺人名）。
//  从 MusicBrainzClient 主体拆出：主体已 531 行（结构预算 600），P4 只做扩展、不改既有行为。
//
//  只在线查询：不建 MB 本地镜像、不做关系图谱持久化（设计 §3.4 不做项）。
//  - 1 req/s 由注入的 sleep 保证；UA 必填（MusicBrainzClient.userAgent）。
//  - 24h 进程内缓存（MusicBrainzRelationCache.shared；含空结果负缓存）。
//

import Foundation

extension MusicBrainzClient {
    // MARK: - 艺人关系（P4；只在线查询，无调用方 = 零请求）

    /// Lucene 短语转义（只可能被引号 / 反斜杠破坏）。
    static func luceneEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 艺人 → 相关艺人名（MB artist-rels）。
    ///
    /// 两次请求：artist?query= 定位 MBID → artist/{mbid}?inc=artist-rels 取关系；
    /// 每次请求前 sleep 1s（MB 限流），UA 必填。结果（含空）进 24h 进程内缓存。
    /// 失败直接抛出——调用方（推荐引擎）按「静默跳过」处理，不影响主链。
    func relatedArtists(for artistName: String, limit: Int = 3) async throws -> [String] {
        let name = artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = max(0, limit)
        guard !name.isEmpty, capped > 0 else { return [] }
        let key = Self.normalizedArtist(name)
        guard !key.isEmpty else { return [] }
        if let cached = relationCache.artists(for: key, now: now()) {
            return cached
        }

        // ① 定位 artist MBID（查询词用 artist:"名字"，与 searchRecordings 同款 Lucene 形态）。
        try await sleep(Self.requestInterval)
        var searchComponents = URLComponents(url: Self.artistBase, resolvingAgainstBaseURL: false)!
        searchComponents.queryItems = [
            URLQueryItem(name: "query", value: "artist:\"\(Self.luceneEscaped(name))\""),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "1"),
        ]
        let searchResult = try await getJSON(url: searchComponents.url!, headers: Self.jsonHeaders)
        let first = ((searchResult["artists"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.first
        guard let mbid = first.flatMap({ Self.stringValue($0["id"]) }), !mbid.isEmpty else {
            relationCache.store([], for: key, now: now())
            return []
        }

        // ② 取 artist-to-artist 关系（inc=artist-rels 只返回关系，不含录音）。
        try await sleep(Self.requestInterval)
        var detailComponents = URLComponents(
            url: Self.artistBase.appendingPathComponent(mbid),
            resolvingAgainstBaseURL: false
        )!
        detailComponents.queryItems = [
            URLQueryItem(name: "inc", value: "artist-rels"),
            URLQueryItem(name: "fmt", value: "json"),
        ]
        let detail = try await getJSON(url: detailComponents.url!, headers: Self.jsonHeaders)
        let names = Self.relatedArtistNames(from: detail, seed: name, limit: capped)
        relationCache.store(names, for: key, now: now())
        return names
    }

    /// MB artist detail JSON → 相关艺人名（纯函数）。
    ///
    /// 只取 artist-to-artist 关系（关系另一头有 artist 对象；url / work 等关系没有该字段）。
    /// 过滤：空名、归一化后重复、归一化后与种子相同。
    static func relatedArtistNames(from detail: [String: Any], seed: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var names: [String] = []
        var seen: Set<String> = [normalizedArtist(seed)]
        for relation in (detail["relations"] as? [Any]) ?? [] {
            guard let dict = relation as? [String: Any],
                  let target = dict["artist"] as? [String: Any],
                  let raw = stringValue(target["name"]) else {
                continue
            }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let normalized = normalizedArtist(name)
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            names.append(name)
            if names.count >= limit { break }
        }
        return names
    }
}
