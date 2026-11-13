//
//  RecommendationProviders.swift
//  QQPlayer
//
//  在线召回契约 + 两个适配器（网易云 / 歌曲海）。
//  从 RecommendationEngine.swift 原样拆出：加观测后文件触及 600 行结构预算，本次只搬家、不改行为。
//

import Foundation

// MARK: - 在线召回契约

/// 在线源返回的歌曲（两源归一后的最小字段；年份/专辑给不出就是 nil，不编造）。
struct RecommendationRemoteSong: Sendable, Equatable {
    var title: String
    var artist: String
    var album: String?
    var year: Int?
    /// 在线源歌曲 ID（相似歌曲召回用；给不出就是 nil）。
    var songID: Int?
    /// 时长（毫秒；歌单 / 串烧过滤用；给不出就是 nil）。
    var durationMs: Int?
    /// 试听地址（iTunes 30s preview；其他源给不出就是 nil）。**不下载**，只做下载衔接的线索。
    var previewURL: URL?
    /// 实际来源（降级链 / 聚合源用）：nil = 由 provider 的 `source` 归属。
    var source: RecommendationSource?
    /// 来源质量降级原因（如网易云兜底）；nil = 原级来源。
    var degradedReason: String?
    /// 来源热度（0…1；网易云 `pop`/100 等；给不出 = nil，排序按名次兜底）。
    var popularity: Double?

    init(
        title: String,
        artist: String,
        album: String? = nil,
        year: Int? = nil,
        songID: Int? = nil,
        durationMs: Int? = nil,
        previewURL: URL? = nil,
        source: RecommendationSource? = nil,
        degradedReason: String? = nil,
        popularity: Double? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.year = year
        self.songID = songID
        self.durationMs = durationMs
        self.previewURL = previewURL
        self.source = source
        self.degradedReason = degradedReason
        self.popularity = popularity
    }
}

/// 在线搜索 seam（生产适配既有客户端，测试注入桩；不新增第二套搜索实现）。
protocol OnlineSearchProviding: Sendable {
    var source: RecommendationSource { get }
    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong]
}

/// 网易云适配器（复用 `NeteaseOnlineClient.search`，不改客户端）。
struct NeteaseSearchProvider: OnlineSearchProviding, SimilarSongProviding {
    var client: NeteaseOnlineClient = .shared

    var source: RecommendationSource { .netease }

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        let songs = try await client.search(query: query, limit: limit)
        return songs.map {
            RecommendationRemoteSong(
                title: $0.title, artist: $0.artist, album: $0.album, year: nil,
                songID: $0.id, durationMs: $0.durationMs
            )
        }
    }

    /// 相似歌曲（网易云 eapi）；不可用时抛错，由引擎降级到同艺人热歌。
    func similarSongs(songID: Int, limit: Int) async throws -> [RecommendationRemoteSong] {
        let songs = try await client.similarSongs(songID: songID, limit: limit)
        return songs.map {
            RecommendationRemoteSong(
                title: $0.title, artist: $0.artist, album: $0.album, year: nil,
                songID: $0.id, durationMs: $0.durationMs
            )
        }
    }
}

/// 歌曲海适配器。
///
/// `GequhaiClient.search` 的既有语义是「失败返回 [] 不抛」，这里保持原语义；
/// `@unchecked Sendable` 的理由：客户端是值类型 + URLSession，搜索路径无共享可变状态，
/// 下载/扫码路径（Quark cookie）不经过本适配器。
final class GequhaiSearchProvider: OnlineSearchProviding, @unchecked Sendable {
    private let client: GequhaiClient

    init(client: GequhaiClient = GequhaiClient()) {
        self.client = client
    }

    var source: RecommendationSource { .gequhai }

    func search(query: String, limit: Int) async throws -> [RecommendationRemoteSong] {
        let songs = await client.search(query: query, limit: limit)
        return songs.map {
            RecommendationRemoteSong(title: $0.title, artist: $0.artist, album: nil, year: nil)
        }
    }
}

// MARK: - 错误

enum RecommendationError: LocalizedError, Equatable {
    /// 所有在线源都失败（网络断 / 双源同时不可用）。
    case allSourcesFailed
    /// 指令输入没有解析出任何有效条件（提示用户换个说法，不退回画像推荐）。
    case emptyRequest

    var errorDescription: String? {
        switch self {
        case .allSourcesFailed:
            return "recommendation_error_all_sources".localized
        case .emptyRequest:
            return "recommendation_empty_request".localized
        }
    }
}

// MARK: - 艺人路径契约

/// 可选能力：按**艺人名**召回（iTunes 走 artistId → lookup；关键词意图不经过这里）。
///
/// 引擎只在 `intent.kind == .artist` 时优先调用；未实现该协议或调用失败时回落到普通 `search`。
protocol ArtistSearchProviding: Sendable {
    func searchArtist(_ name: String, limit: Int) async throws -> [RecommendationRemoteSong]
}

// MARK: - 相似歌曲召回契约

/// 可选能力：支持「相似歌曲」的在线源（当前只有网易云）。
///
/// 接口不可用（匿名态未登录 / 改版）时必须抛错或返回空；引擎运行时探测后整轮降级，
/// 绝不阻塞主召回链路。
protocol SimilarSongProviding: Sendable {
    func similarSongs(songID: Int, limit: Int) async throws -> [RecommendationRemoteSong]
}
