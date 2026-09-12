//
//  MacLibraryFactsStore.swift
//  QQPlayer
//
//  macOS 曲库「卡片事实」缓存（2026-09-12 审计批次 B4 · M2；无 AppKit → 双 target 共享、
//  可在 iOS 测试 target 单测）。
//
//  缺陷（审计 M2）：视图 body/onAppear/通知回调里直接同步调 DatabaseManager——
//  - 专辑网格：每张卡每帧 2 次整表查询（代表曲目 + 曲目数）
//  - 歌手列表：每行每帧 1 次、歌单列表：每行每帧 2–3 次
//  - 歌曲 Table：每个可见行每帧 1 次专辑标题查询
//  - 曲库 reload：四表全量读跑在主线程，且由 7+ 处通知反复触发
//  曲库上千张卡时掉帧明显（Mac 卡顿最可能的一手来源）。
//
//  设计：「事实」按 id 缓存 + 异步预取，body 只做字典查找（零 DB 调用）；
//  - 预取路径：MacLibraryView.reloadLibrary 拿到曲库快照后整体 `preload`，
//    卡片渲染时事已就位 → 不闪现 0；
//  - 兜底路径：预取之外的 id（搜索结果等）首次访问返回默认值并异步补齐，
//    补齐后 `objectWillChange` 触发重绘（`invalidate` 只递增代号，不清空旧值 →
//    重载期间不闪 0）；
//  - 取数口径与修复前逐条一致（同一个 DatabaseManager API），仅执行位置/时机改变；
//  - 取数闭包可注入 → 语义可单测（不需要真 DB）。
//

import Combine
import Foundation

/// 曲库快照（reload 路径一次读四表；跨隔离返回）。
struct MacLibrarySnapshot {
    var tracks: [Track]
    var albums: [Album]
    var artists: [Artist]
    var playlists: [Playlist]
}

/// 曲库读取（nonisolated async → DB 读在全局执行器上，不占主线程）。
enum MacLibraryLoader {
    /// 四表全量读。任一步失败即整体失败（调用方展示失败态，见审计 M6）。
    static func load() async -> Result<MacLibrarySnapshot, Error> {
        do {
            let tracks = try DatabaseManager.shared.getAllTracks()
            let albums = try DatabaseManager.shared.getAllAlbums()
            let artists = try DatabaseManager.shared.getAllArtists()
            let playlists = try DatabaseManager.shared.getAllPlaylists()
            return .success(MacLibrarySnapshot(
                tracks: tracks,
                albums: albums,
                artists: artists,
                playlists: playlists
            ))
        } catch {
            return .failure(error)
        }
    }
}

/// 曲库卡片事实（缓存 + 异步预取）。
@MainActor
final class MacLibraryFactsStore: ObservableObject {
    static let shared = MacLibraryFactsStore()

    /// 专辑卡事实（曲目数 / 代表曲目 / 标题——标题同时供歌曲 Table 的 album 列）。
    struct AlbumFacts: Equatable {
        var title: String = ""
        var trackCount: Int = 0
        var representativeTrack: Track?
    }

    /// 歌单卡事实（条目数 / 代表曲目）。
    struct PlaylistFacts: Equatable {
        var itemCount: Int = 0
        var representativeTrack: Track?
    }

    /// 取数（生产 = DatabaseManager；测试注入假实现）。
    struct Loader {
        var albumFacts: (Int64) async -> AlbumFacts
        var artistTrackCount: (Int64) async -> Int
        var playlistFacts: (Int64) async -> PlaylistFacts

        static var live: Loader {
            Loader(
                albumFacts: { albumId in
                    let tracks = (try? DatabaseManager.shared.getTracksByAlbumId(albumId)) ?? []
                    let title = (try? DatabaseManager.shared.read { db in
                        try Album.fetchOne(db, key: albumId)
                    })?.title ?? ""
                    return AlbumFacts(
                        title: title,
                        trackCount: tracks.count,
                        representativeTrack: tracks.first
                    )
                },
                artistTrackCount: { artistId in
                    (try? DatabaseManager.shared.getTracksByArtistId(artistId).count) ?? 0
                },
                playlistFacts: { playlistId in
                    let items = (try? DatabaseManager.shared.getPlaylistItems(playlistId: playlistId)) ?? []
                    let track = items.first.flatMap {
                        try? DatabaseManager.shared.getTrack(byStableId: $0.trackStableId)
                    }
                    return PlaylistFacts(itemCount: items.count, representativeTrack: track)
                }
            )
        }
    }

    private let loader: Loader
    private var albumFactsById: [Int64: AlbumFacts] = [:]
    private var artistTrackCountById: [Int64: Int] = [:]
    private var playlistFactsById: [Int64: PlaylistFacts] = [:]
    /// 在途补齐的 key（防同一 id 重复调度）
    private var inFlight: Set<String> = []
    /// 代号：`invalidate` 递增 → 失效前发出的在途结果丢弃
    private var generation = 0

    init(loader: Loader = .live) {
        self.loader = loader
    }

    // MARK: - body 侧读（只查缓存，绝不触 DB）

    func albumFacts(for album: Album) -> AlbumFacts {
        guard let id = album.id else { return AlbumFacts() }
        return albumFacts(forAlbumId: id)
    }

    func albumFacts(forAlbumId id: Int64) -> AlbumFacts {
        if let cached = albumFactsById[id] { return cached }
        scheduleAlbumFacts(id)
        return AlbumFacts()
    }

    func artistTrackCount(for artist: Artist) -> Int {
        guard let id = artist.id else { return 0 }
        return artistTrackCount(forArtistId: id)
    }

    func artistTrackCount(forArtistId id: Int64) -> Int {
        if let cached = artistTrackCountById[id] { return cached }
        scheduleArtistTrackCount(id)
        return 0
    }

    func playlistFacts(for playlist: Playlist) -> PlaylistFacts {
        guard let id = playlist.id else { return PlaylistFacts() }
        return playlistFacts(forPlaylistId: id)
    }

    func playlistFacts(forPlaylistId id: Int64) -> PlaylistFacts {
        if let cached = playlistFactsById[id] { return cached }
        schedulePlaylistFacts(id)
        return PlaylistFacts()
    }

    /// 歌曲 Table 的 album 列（修复前每行每帧一次 `Album.fetchOne`）。
    func albumTitle(forTrack track: Track) -> String {
        guard let albumId = track.albumId else { return "" }
        return albumFacts(forAlbumId: albumId).title
    }

    // MARK: - 预取 / 失效

    /// 曲库重载路径调用：整批事实一次算完再整体发布（渲染时已就位，不闪 0）。
    func preload(tracks: [Track], albums: [Album], artists: [Artist], playlists: [Playlist]) async {
        let generation = self.generation
        let albumIds = Set(albums.compactMap(\.id) + tracks.compactMap(\.albumId))
        let artistIds = artists.compactMap(\.id)
        let playlistIds = playlists.compactMap(\.id)
        let loader = self.loader

        var albumFacts: [Int64: AlbumFacts] = [:]
        for id in albumIds {
            albumFacts[id] = await loader.albumFacts(id)
        }
        var artistCounts: [Int64: Int] = [:]
        for id in artistIds {
            artistCounts[id] = await loader.artistTrackCount(id)
        }
        var playlistFacts: [Int64: PlaylistFacts] = [:]
        for id in playlistIds {
            playlistFacts[id] = await loader.playlistFacts(id)
        }

        // 期间又有重载（代号变了）→ 本次结果作废，等新一轮
        guard generation == self.generation else { return }
        albumFactsById = albumFacts
        artistTrackCountById = artistCounts
        playlistFactsById = playlistFacts
        objectWillChange.send()
    }

    /// 曲库数据变化：递增代号并在途结果作废。**不清空已发布值**——
    /// 重载期间沿用旧值（预取完成整体替换），避免计数闪 0。
    func invalidate() {
        generation += 1
        inFlight.removeAll()
    }

    // MARK: - 兜底异步补齐（缓存未命中）

    private func scheduleAlbumFacts(_ id: Int64) {
        guard begin("album-\(id)") else { return }
        let generation = self.generation
        let loader = self.loader
        Task { [weak self] in
            let facts = await loader.albumFacts(id)
            guard let self else { return }
            self.inFlight.remove("album-\(id)")
            guard generation == self.generation else { return }
            self.albumFactsById[id] = facts
            self.objectWillChange.send()
        }
    }

    private func scheduleArtistTrackCount(_ id: Int64) {
        guard begin("artist-\(id)") else { return }
        let generation = self.generation
        let loader = self.loader
        Task { [weak self] in
            let count = await loader.artistTrackCount(id)
            guard let self else { return }
            self.inFlight.remove("artist-\(id)")
            guard generation == self.generation else { return }
            self.artistTrackCountById[id] = count
            self.objectWillChange.send()
        }
    }

    private func schedulePlaylistFacts(_ id: Int64) {
        guard begin("playlist-\(id)") else { return }
        let generation = self.generation
        let loader = self.loader
        Task { [weak self] in
            let facts = await loader.playlistFacts(id)
            guard let self else { return }
            self.inFlight.remove("playlist-\(id)")
            guard generation == self.generation else { return }
            self.playlistFactsById[id] = facts
            self.objectWillChange.send()
        }
    }

    /// 标记在途（已在途/已缓存 → false）
    private func begin(_ key: String) -> Bool {
        inFlight.insert(key).inserted
    }
}
