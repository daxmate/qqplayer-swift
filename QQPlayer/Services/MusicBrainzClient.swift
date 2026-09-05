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

    /// MB recording 搜索 + 候选构造（含 year/genre/track/album_artist）。S2 实现。
    func searchMusicBrainz(title: String, artist: String) async throws -> [ScrapeCandidate] {
        fatalError("S2 实现：降级链 + artist 排序加分 + 字段提取（web _mb_search/_scrape_musicbrainz 语义）")
    }

    /// iTunes Search fallback 封面（web _itunes_cover 语义）。S2 实现。
    func itunesCoverURL(title: String, artist: String) async throws -> URL? {
        fatalError("S2 实现")
    }

    /// Cover Art Archive 封面（含 MBID 缓存；web _musicbrainz_release_mbid/_coverartarchive_front）。S2 实现。
    func coverArtArchiveFront(title: String, artist: String) async throws -> URL? {
        fatalError("S2 实现")
    }

    /// 封面 fallback 链（网易云 cover 由调用方先取；iTunes → CAA → nil）。S2 实现。
    func fallbackCoverURL(title: String, artist: String) async throws -> URL? {
        fatalError("S2 实现")
    }

    /// artist 归一化匹配（web _artist_matches：小写 + 去标点空白下划线，相等/互相包含）
    static func artistMatches(_ a: String, _ b: String) -> Bool {
        fatalError("S2 实现")
    }
}
