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
//  设计：「事实」按 id 缓存 + 显式补齐，body 只做字典查找（零 DB 调用）；
//  - 补齐路径①：MacLibraryView.reloadLibrary 拿到曲库快照后整体 `preload`，
//    卡片渲染时事已就位 → 不闪现 0；
//  - 补齐路径②：快照覆盖不到的 id（搜索结果等）走 `ensureFacts(…)`（非渲染期显式调用）；
//  - 读路径**严格只读**（见下方 ⚠️）；`invalidate` 只递增代号、不清空旧值 →
//    重载期间不闪 0；
//  - 取数口径与修复前逐条一致（同一个 DatabaseManager API），仅执行位置/时机改变；
//  - 取数闭包可注入 → 语义可单测（不需要真 DB）。
//
//  ⚠️ 2026-09-25 修复「渲染期写入 → 表格重入更新 → 主线程 100% CPU 自旋」：
//  两次 `sample` 实锤（栈完全一致、无崩溃报告、stderr 有
//  `reentrant operation in its NSTableView delegate`）——
//  `Update.dispatchActions → AppKitOutlineTableCoordinator.update →
//  enumerateAvailableRowViewsUsingBlock → MacTrackListView album 列 → 本 store`
//  **嵌套两层**。旧实现的 body 侧读路径**不是只读**：缓存未命中就 `schedule…` → `begin` →
//  **同步写被观察的 `inFlight`**，而这个写正落在 SwiftUI/AppKit 的行更新过程中 ⇒
//  观察者失效 ⇒ 再排一轮 update ⇒ 再读 ⇒ 再写 …… 循环无法收敛。
//
//  **本文件的不变量**（形状由 `QQPlayerTests/MacLibraryFactsReadPathContractTests.swift` 守护）：
//  1. `albumFacts(for:)` / `albumFacts(forAlbumId:)` / `artistTrackCount(for:)` /
//     `artistTrackCount(forArtistId:)` / `playlistFacts(for:)` / `playlistFacts(forPlaylistId:)` /
//     `albumTitle(forTrack:)` **只读**：只查缓存，未命中返回默认值，**不调度、不写任何存储属性**
//     （`@Observable` 下 `inFlight` / `generation` 同样是「会被观察的状态」）。
//  2. 补齐只走**显式非渲染期入口**：`preload(…)` / `ensureFacts(…)`，二者共用 `refill(…)`
//     （唯一写缓存处）；**禁止**从 `body` / 行更新回调里调用它们。
//  3. `invalidate()` 之后一定有一轮补齐能落地：唯一调用点 `MacLibraryView.reloadLibrary`
//     在同一函数里紧接着发起新的 `preload`，而 `generation` 守卫只会丢弃**更旧**的一轮。
//

import Foundation
import Observation

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
/// 2026-09-19（视图层单例收口「下降预算」批 3a）：`ObservableObject` → `@Observable`，
/// 不再手工 `objectWillChange.send()`（字典就地写入走 `_modify` 访问器，按属性追踪生效）；
/// 视图侧改由 Mac 组合根 `.environment(...)` 注入 + `@Environment(MacLibraryFactsStore.self)` 取。
@MainActor
@Observable
final class MacLibraryFactsStore {
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
    /// 在途补齐的 key（防同一 id 重复取数）；**只由显式补齐写**，读路径不碰。
    private var inFlight: Set<String> = []
    /// 代号：`invalidate` 递增 → 失效前发出的在途补齐结果丢弃（见 `refill` 的代号收口）
    private var generation = 0

    init(loader: Loader = .live) {
        self.loader = loader
    }

    // MARK: - body 侧读（**严格只读**：只查缓存，绝不调度、绝不写任何存储属性）

    func albumFacts(for album: Album) -> AlbumFacts {
        guard let id = album.id else { return AlbumFacts() }
        return albumFacts(forAlbumId: id)
    }

    func albumFacts(forAlbumId id: Int64) -> AlbumFacts {
        albumFactsById[id] ?? AlbumFacts()
    }

    func artistTrackCount(for artist: Artist) -> Int {
        guard let id = artist.id else { return 0 }
        return artistTrackCount(forArtistId: id)
    }

    func artistTrackCount(forArtistId id: Int64) -> Int {
        artistTrackCountById[id] ?? 0
    }

    func playlistFacts(for playlist: Playlist) -> PlaylistFacts {
        guard let id = playlist.id else { return PlaylistFacts() }
        return playlistFacts(forPlaylistId: id)
    }

    func playlistFacts(forPlaylistId id: Int64) -> PlaylistFacts {
        playlistFactsById[id] ?? PlaylistFacts()
    }

    /// 歌曲 Table 的 album 列（修复前每行每帧一次 `Album.fetchOne`）。
    func albumTitle(forTrack track: Track) -> String {
        guard let albumId = track.albumId else { return "" }
        return albumFacts(forAlbumId: albumId).title
    }

    // MARK: - 显式补齐（**非渲染期唯一入口**；读路径绝不调用）

    /// 曲库重载路径调用：整批事实一次算完再发布（渲染时已就位，不闪 0）。
    /// ⚠️ 只许在非渲染期调用（`.task` / 曲库 reload 完成处 / 变更通知回调）；
    /// `onlyMissing: false` = 整批重取，重载后把旧值刷成新值。
    func preload(tracks: [Track], albums: [Album], artists: [Artist], playlists: [Playlist]) async {
        await refill(
            albumIds: Set(albums.compactMap(\.id) + tracks.compactMap(\.albumId)),
            artistIds: Set(artists.compactMap(\.id)),
            playlistIds: Set(playlists.compactMap(\.id)),
            onlyMissing: false
        )
    }

    /// 单点补齐：曲库快照覆盖不到的 id（搜索结果等）；已命中的 id 不重取。
    /// ⚠️ 只许在非渲染期调用（搜索出结果后 / `.task` / 变更通知回调）。
    func ensureFacts(albumIds: [Int64] = [], artistIds: [Int64] = [], playlistIds: [Int64] = []) async {
        await refill(
            albumIds: Set(albumIds),
            artistIds: Set(artistIds),
            playlistIds: Set(playlistIds),
            onlyMissing: true
        )
    }

    /// 曲库数据变化：递增代号并在途补齐作废。**不清空已发布值**——
    /// 重载期间沿用旧值（随后 `preload` 整体刷新），避免计数闪 0。
    func invalidate() {
        generation += 1
        inFlight.removeAll()
    }

    // MARK: - 补齐实现（**唯一写缓存处**；`preload` / `ensureFacts` 共用，禁止第二份）

    /// - `onlyMissing`：true = 跳过已命中（`ensureFacts`）；false = 整批重取（`preload`）。
    /// - **代号收口（2026-09-25）**：本轮取数期间若发生 `invalidate()`（代号变了），结果基于
    ///   过期快照 → 丢弃（旧值继续被读，不闪 0）。**不会饿死**（活锁已消，依据见下）：
    ///   ① `invalidate()` 的唯一调用点 `MacLibraryView.reloadLibrary` 在同一函数里紧接着
    ///   发起一轮新的 `preload` → **最后一次失效之后总有一轮补齐落地**（该配对由读路径契约
    ///   测试静态守护）；
    ///   ② `invalidate()` 清 `inFlight` ⇒ 旧代号占用的 key 不会挡住新一轮的取数（同代号在途
    ///   的补齐本来就会发布）；
    ///   ③ 读路径不再调度补齐 ⇒ 失效后不存在「每帧重新发起 + 每轮被丢弃」的往复。
    private func refill(
        albumIds: Set<Int64>,
        artistIds: Set<Int64>,
        playlistIds: Set<Int64>,
        onlyMissing: Bool
    ) async {
        var claimedAlbums: [Int64] = []
        var claimedArtists: [Int64] = []
        var claimedPlaylists: [Int64] = []

        // inFlight 去重：只有显式补齐写它（读路径绝不碰）
        for id in albumIds.sorted() {
            if onlyMissing, albumFactsById[id] != nil { continue }
            if inFlight.insert("album-\(id)").inserted { claimedAlbums.append(id) }
        }
        for id in artistIds.sorted() {
            if onlyMissing, artistTrackCountById[id] != nil { continue }
            if inFlight.insert("artist-\(id)").inserted { claimedArtists.append(id) }
        }
        for id in playlistIds.sorted() {
            if onlyMissing, playlistFactsById[id] != nil { continue }
            if inFlight.insert("playlist-\(id)").inserted { claimedPlaylists.append(id) }
        }
        defer {
            claimedAlbums.forEach { inFlight.remove("album-\($0)") }
            claimedArtists.forEach { inFlight.remove("artist-\($0)") }
            claimedPlaylists.forEach { inFlight.remove("playlist-\($0)") }
        }

        let generation = self.generation
        let loader = self.loader

        var albumFacts: [Int64: AlbumFacts] = [:]
        for id in claimedAlbums {
            albumFacts[id] = await loader.albumFacts(id)
        }
        var artistCounts: [Int64: Int] = [:]
        for id in claimedArtists {
            artistCounts[id] = await loader.artistTrackCount(id)
        }
        var playlistFacts: [Int64: PlaylistFacts] = [:]
        for id in claimedPlaylists {
            playlistFacts[id] = await loader.playlistFacts(id)
        }

        // 期间又有重载（代号变了）→ 本轮结果作废，等新一轮补齐落地
        guard generation == self.generation else { return }
        for (id, facts) in albumFacts {
            albumFactsById[id] = facts
        }
        for (id, count) in artistCounts {
            artistTrackCountById[id] = count
        }
        for (id, facts) in playlistFacts {
            playlistFactsById[id] = facts
        }
    }
}
