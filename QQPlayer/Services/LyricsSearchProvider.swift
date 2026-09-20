//
//  LyricsSearchProvider.swift
//  QQPlayer
//
//  多源歌词搜索（网易云 + lrclib），供用户手动挑选歌词。
//  协议与桌面版 QQPlayer 后端 /api/lyric/search 一致：
//  - 网易云：eapi 搜索候选（前 5 个）逐个拉取歌词全文 + 中文翻译
//  - lrclib：/api/search 结果直接携带 syncedLyrics（无翻译）
//  两个源并发搜索，netease 在前、lrclib 在后（桌面版同顺序）。
//  搜索结果按搜索词缓存（LyricsSearchCache，7 天 TTL），命中直接返回。
//

import Foundation

/// 歌词搜索候选（统一两个源的返回结构；text 为 LRC 全文，tlyric 为中文翻译）
struct LyricsSearchCandidate: Codable, Equatable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable {
        case netease
        case lrclib

        /// 界面显示名
        var displayName: String {
            switch self {
            case .netease: return "网易云"
            case .lrclib: return "lrclib"
            }
        }
    }

    let id: UUID
    let source: Source
    let title: String
    let artist: String
    let duration: Double?
    /// LRC 全文（netease 搜索时已拉取；lrclib 直接带 syncedLyrics）
    let text: String
    /// 中文翻译 LRC（仅网易云）
    let tlyric: String?
    /// 罗马音 LRC（仅网易云，且仅部分曲目有；旧缓存无此键 = nil）
    let romalrc: String?

    init(
        id: UUID = UUID(),
        source: Source,
        title: String,
        artist: String,
        duration: Double?,
        text: String,
        tlyric: String?,
        romalrc: String? = nil
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.artist = artist
        self.duration = duration
        self.text = text
        self.tlyric = tlyric
        self.romalrc = romalrc
    }
}

struct LyricsSearchProvider: Sendable {
    static let shared = LyricsSearchProvider()

    private let netease = NeteaseLyricsProvider.shared
    private let lrclibBaseURL = "https://lrclib.net/api"
    /// 测试注入：默认共享会话（MockURLProtocol 通过它拦截 lrclib 请求）
    var urlSession: URLSession = .shared

    /// 双源并发搜索：netease 在前、lrclib 在后；全部失败返回 []。
    /// 缓存优先：相同搜索词命中未过期缓存时直接返回，不重复请求网络（见 LyricsSearchCache）。
    func search(title: String, artist: String) async -> [LyricsSearchCandidate] {
        let query = "\(title) \(artist)".trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }

        if let cached = LyricsSearchCache.shared.load(title: title, artist: artist) {
            return cached
        }

        async let neteaseCandidates = searchNetease(query: query)
        async let lrclibCandidates = searchLRCLib(title: title, artist: artist)
        let results = await neteaseCandidates + lrclibCandidates

        // 非空结果才写缓存：避免把"没搜到"缓存住，搜索词修正后仍能重试
        if !results.isEmpty {
            LyricsSearchCache.shared.save(results, title: title, artist: artist)
        }
        return results
    }

    // MARK: - 网易云

    /// eapi 搜索候选（前 5 个）逐个并发拉取歌词全文 + 中文翻译；结果按搜索相关度排序
    private func searchNetease(query: String) async -> [LyricsSearchCandidate] {
        guard let songs = try? await netease.search(query: query, limit: 8) else {
            return []
        }

        let top = Array(songs.prefix(5))
        // 并发拉歌词；用字典收集后按候选顺序重排（相关度排序稳定，与桌面版一致）
        let fetched = await withTaskGroup(
            of: (index: Int, candidate: LyricsSearchCandidate?)?.self,
            returning: [Int: LyricsSearchCandidate].self
        ) { group in
            for (index, song) in top.enumerated() {
                group.addTask {
                    guard let result = try? await self.netease.getLyric(songID: song.id),
                          !result.lrc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return nil
                    }
                    return (
                        index,
                        LyricsSearchCandidate(
                            source: .netease,
                            title: song.title,
                            artist: song.artist,
                            duration: song.duration,
                            text: result.lrc,
                            tlyric: result.tlyric,
                            romalrc: result.romalrc
                        )
                    )
                }
            }
            var collected: [Int: LyricsSearchCandidate] = [:]
            for await item in group {
                if let item {
                    collected[item.index] = item.candidate
                }
            }
            return collected
        }

        return top.indices.compactMap { fetched[$0] }
    }

    // MARK: - lrclib

    /// lrclib /api/search：只保留带时间戳的 syncedLyrics（纯文本歌词对播放器无用）
    /// 简繁双查询：lrclib 收录多为繁体标题（如「電台情歌」），简体查询词会漏；
    /// 用系统 ICU 转换生成繁体查询词补搜一次，按歌曲 id 去重合并。
    /// 兑底：带 artist 双查仍 0 条时只按歌名（简/繁）重搜——lrclib 中文歌 artist
    /// 多为拉丁拼写（「孙燕姿」→ Stefanie Sun），中文 artist 匹配不上。
    /// 两个查询 async let 并发（各 10s 超时）：串行会放大最坏等待到 20s。
    /// internal：供测试直接验证 lrclib 路径（不经 search()，避免触发网易云/缓存）。
    func searchLRCLib(title: String, artist: String) async -> [LyricsSearchCandidate] {
        // swiftlint:disable todo
        // TODO(搜索页分批展示)：双源结果当前等齐才返回（netease+lrclib 并发 ≈ max(10s,10s)）；
        // 若要做「先出 netease 再出 lrclib」的分批展示，需把 search 改为流式/回调式 API。
        // swiftlint:enable todo
        let queries = [
            (trackName: title, artistName: artist),
            (trackName: traditionalChinese(title), artistName: traditionalChinese(artist)),
        ]
        async let simplifiedHits = fetchLRCLibHits(
            trackName: queries[0].trackName, artistName: queries[0].artistName
        )
        async let traditionalHits = fetchLRCLibHits(
            trackName: queries[1].trackName, artistName: queries[1].artistName
        )
        var hits = await simplifiedHits + traditionalHits

        if hits.isEmpty {
            AppLog.warn(.scrape, "⚠️ lrclib search with artist returned 0, retrying by track name only")
            async let fallbackSimplified = fetchLRCLibHits(
                trackName: queries[0].trackName, artistName: nil
            )
            async let fallbackTraditional = fetchLRCLibHits(
                trackName: queries[1].trackName, artistName: nil
            )
            hits = await fallbackSimplified + fallbackTraditional
        }

        var seenIDs = Set<Int>()
        var out: [LyricsSearchCandidate] = []
        for hit in hits {
            guard !hit.instrumental,
                  let synced = hit.syncedLyrics,
                  !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !seenIDs.contains(hit.id) else {
                continue
            }
            seenIDs.insert(hit.id)
            out.append(
                LyricsSearchCandidate(
                    source: .lrclib,
                    title: hit.trackName,
                    artist: hit.artistName,
                    duration: hit.duration,
                    text: synced,
                    tlyric: nil
                )
            )
        }
        return out
    }

    private func fetchLRCLibHits(trackName: String, artistName: String?) async -> [LRCLibSearchHit] {
        var components = URLComponents(string: "\(lrclibBaseURL)/search")
        var queryItems = [URLQueryItem(name: "track_name", value: trackName)]
        if let artistName, !artistName.isEmpty {
            queryItems.append(URLQueryItem(name: "artist_name", value: artistName))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue(
            "QQPlayer/1.0 (https://github.com/daxmate/qqplayer-ios)",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 10

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return []
            }
            return (try? JSONDecoder().decode([LRCLibSearchHit].self, from: data)) ?? []
        } catch {
            AppLog.error(.scrape, "❌ Failed to search lrclib.net: \(error)")
            return []
        }
    }
}

// MARK: - 简繁转换

/// 简体 → 繁体（内置 OpenCC 单字映射表，见 SimplifiedTraditionalMap.swift；
/// 简繁同形/未收录的字原样返回）。用于 lrclib 等以繁体标题为主的源补搜。
func traditionalChinese(_ text: String) -> String {
    guard !text.isEmpty else { return text }
    var out = ""
    out.reserveCapacity(text.count)
    for char in text {
        out.append(simplifiedToTraditionalMap[char] ?? char)
    }
    return out
}

// MARK: - API 模型

private struct LRCLibSearchHit: Codable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: Double
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
}
