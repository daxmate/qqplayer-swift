//
//  MacLibraryFactsStoreTests.swift
//  QQPlayerTests
//
//  曲库卡片事实缓存（MacLibraryFactsStore）语义回归用例
//  —— 2026-09-12 审计批次 B4 · M2；2026-09-25 渲染期写入死循环修复后重写。
//
//  修复前视图 body 里直接同步调 DatabaseManager（专辑网格每卡每帧 2 次整表查询、
//  歌手/歌单行每行每帧 1–3 次、歌曲 Table 每可见行每帧 1 次）——这些调用直连 DB
//  单例、没有任何缝，只能靠读代码。本文件用注入的假取数器锁定新契约：
//  1) **读路径严格只读**：未命中回默认值，**零取数、零可观察状态写**
//     （旧实现的读路径会 `schedule…` → 同步写被观察的 `inFlight`，落在表格行更新里
//     就变成「失效 → 重排 update → 再读 → 再写」的主线程自旋死循环）；
//  2) 补齐只走显式非渲染期入口（`ensureFacts(…)` / `preload(…)`），已命中的 id 不重取；
//  3) `invalidate()` 保留已发布旧值（重载期间不闪 0），但作废在途的过期补齐；
//  4) 失效之后**一定**有一轮补齐能落地（`invalidate` 的唯一调用点 `reloadLibrary`
//     在同一函数里紧接着发起新的 `preload`）——「缓存永远补不上」的活锁已消。
//
//  形状（读路径不得出现 schedule / begin( / 写 inFlight·generation）另由
//  `MacLibraryFactsReadPathContractTests.swift` 静态守护。
//

import Foundation
import Observation
import Testing

@testable import QQPlayer

/// 假取数器（记录调用 + 可开门挂起，模拟慢查询）。
@MainActor
private final class FakeFactsLoader {
    private(set) var albumCalls: [Int64] = []
    private(set) var artistCalls: [Int64] = []
    private(set) var playlistCalls: [Int64] = []

    private var albumValues: [Int64: MacLibraryFactsStore.AlbumFacts] = [:]
    private var artistValues: [Int64: Int] = [:]
    private var playlistValues: [Int64: MacLibraryFactsStore.PlaylistFacts] = [:]

    /// 开着门：取数会挂起，直到 `openGate()`（用于「作废在途结果」用例）
    private var gateOpen = false
    private var gateContinuations: [CheckedContinuation<Void, Never>] = []

    func setAlbumFacts(_ facts: MacLibraryFactsStore.AlbumFacts, for id: Int64) {
        albumValues[id] = facts
    }

    func setArtistCount(_ count: Int, for id: Int64) {
        artistValues[id] = count
    }

    func setPlaylistFacts(_ facts: MacLibraryFactsStore.PlaylistFacts, for id: Int64) {
        playlistValues[id] = facts
    }

    func setGateOpen(_ open: Bool) {
        gateOpen = open
    }

    func openGate() {
        gateOpen = false
        let waiting = gateContinuations
        gateContinuations = []
        waiting.forEach { $0.resume() }
    }

    func loader() -> MacLibraryFactsStore.Loader {
        MacLibraryFactsStore.Loader(
            albumFacts: { [self] id in
                await noteAlbumCall(id)
                return await albumValue(id)
            },
            artistTrackCount: { [self] id in
                await noteArtistCall(id)
                return await artistValue(id)
            },
            playlistFacts: { [self] id in
                await notePlaylistCall(id)
                return await playlistValue(id)
            }
        )
    }

    private func noteAlbumCall(_ id: Int64) async {
        albumCalls.append(id)
        await waitAtGate()
    }

    private func noteArtistCall(_ id: Int64) async {
        artistCalls.append(id)
        await waitAtGate()
    }

    private func notePlaylistCall(_ id: Int64) async {
        playlistCalls.append(id)
        await waitAtGate()
    }

    private func waitAtGate() async {
        guard gateOpen else { return }
        await withCheckedContinuation { continuation in
            gateContinuations.append(continuation)
        }
    }

    private func albumValue(_ id: Int64) async -> MacLibraryFactsStore.AlbumFacts {
        albumValues[id] ?? MacLibraryFactsStore.AlbumFacts()
    }

    private func artistValue(_ id: Int64) async -> Int {
        artistValues[id] ?? 0
    }

    private func playlistValue(_ id: Int64) async -> MacLibraryFactsStore.PlaylistFacts {
        playlistValues[id] ?? MacLibraryFactsStore.PlaylistFacts()
    }
}

// MARK: - 测试数据构造（模型字段多，集中在这里）

private func makeAlbum(_ id: Int64, title: String = "专辑") -> Album {
    Album(id: id, artistId: nil, title: title, year: nil, albumArtist: nil)
}

private func makeArtist(_ id: Int64, name: String = "歌手") -> Artist {
    Artist(id: id, name: name)
}

private func makePlaylist(_ id: Int64, title: String = "歌单") -> Playlist {
    Playlist(
        id: id,
        slug: "p-\(id)",
        title: title,
        createdAt: 0,
        updatedAt: 0,
        lastPlayedAt: 0,
        folderPath: nil,
        isFolderSynced: false,
        lastFolderSync: nil,
        customCoverImagePath: nil
    )
}

private func makeTrack(_ stableId: String, albumId: Int64?, artistId: Int64? = nil) -> Track {
    Track(
        id: nil,
        stableId: stableId,
        albumId: albumId,
        artistId: artistId,
        title: "曲目 \(stableId)",
        genre: nil,
        trackNo: nil,
        discNo: nil,
        durationMs: nil,
        sampleRate: nil,
        bitDepth: nil,
        channels: nil,
        path: "/tmp/\(stableId).mp3",
        fileSize: nil,
        modificationDate: nil,
        contentHash: nil,
        replaygainTrackGain: nil,
        replaygainAlbumGain: nil,
        replaygainTrackPeak: nil,
        replaygainAlbumPeak: nil,
        hasEmbeddedArt: false
    )
}

/// 让主 actor 上的补齐任务跑完（Task.yield 若干轮；给足轮次防 CI 抖动）。
@MainActor
private func settle(_ rounds: Int = 50) async {
    for _ in 0 ..< rounds {
        await Task.yield()
    }
}

/// 轮询等待条件成立（超时即返回末次结果）。
/// CI 慢机上「固定轮次 yield」不足以保证异步补齐已落库 → 用超时轮询替代，
/// 语义仍是「等到补齐完成」，不引入 sleep 猜测。
/// 轮询间隙用 5ms 休眠（不是紧贴 Task.yield 自旋）：这是测试主 actor 上的等待，
/// 自旋会把主 actor 饿死，连带把同套件其它计时敏感用例拖红（run 34702157359 实例）。
@MainActor
private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

@MainActor
struct MacLibraryFactsStoreTests {
    @Test("★ 读路径严格只读：未命中连读多次 → 零取数 + 零可观察状态写")
    func readPathHasNoSideEffectsOnCacheMiss() async {
        let fake = FakeFactsLoader()
        fake.setAlbumFacts(MacLibraryFactsStore.AlbumFacts(title: "Album X", trackCount: 12), for: 5)
        fake.setArtistCount(42, for: 7)
        fake.setPlaylistFacts(MacLibraryFactsStore.PlaylistFacts(itemCount: 4), for: 2)
        let store = MacLibraryFactsStore(loader: fake.loader())
        let track = makeTrack("t1", albumId: 5)

        // 旧实现的读路径会写 `inFlight`（@Observable 存储属性）→ 在表格行更新期间
        // 就是「观察者失效 → 重排 update → 再读 → 再写」的燃料。此处必须一次都不写。
        var observableMutations = 0
        withObservationTracking {
            for _ in 0 ..< 5 {
                _ = store.albumFacts(forAlbumId: 5)
                _ = store.artistTrackCount(forArtistId: 7)
                _ = store.playlistFacts(forPlaylistId: 2)
                _ = store.albumTitle(forTrack: track)
                _ = store.albumFacts(for: makeAlbum(5))
                _ = store.artistTrackCount(for: makeArtist(7))
                _ = store.playlistFacts(for: makePlaylist(2))
            }
        } onChange: {
            observableMutations += 1
        }
        #expect(observableMutations == 0, "读路径写了被观察状态（渲染期写入 = 重排 update 的源头）")

        // 也不许「回默认值 + 后台补一轮取数」（旧实现未命中会 schedule → 异步打 DB）
        await settle()
        #expect(fake.albumCalls.isEmpty, "读路径不得触发取数")
        #expect(fake.artistCalls.isEmpty, "读路径不得触发取数")
        #expect(fake.playlistCalls.isEmpty, "读路径不得触发取数")

        // 未命中 → 默认值（不闪真值、不写状态）
        #expect(store.albumFacts(forAlbumId: 5) == MacLibraryFactsStore.AlbumFacts())
        #expect(store.albumFacts(forAlbumId: 5).title.isEmpty)
        #expect(store.artistTrackCount(forArtistId: 7) == 0)
        #expect(store.playlistFacts(forPlaylistId: 2) == MacLibraryFactsStore.PlaylistFacts())
        #expect(store.albumTitle(forTrack: track).isEmpty)
        #expect(store.albumFacts(for: makeAlbum(5, title: "忽略模型字段")).title.isEmpty)
    }

    @Test("显式补齐（ensureFacts）：取数一次 → 再读命中 → 已命中 id 不重取")
    func ensureFactsFillsOnceThenReadsHitCache() async {
        let fake = FakeFactsLoader()
        fake.setAlbumFacts(MacLibraryFactsStore.AlbumFacts(title: "Album X", trackCount: 12), for: 5)
        fake.setArtistCount(42, for: 7)
        fake.setPlaylistFacts(MacLibraryFactsStore.PlaylistFacts(itemCount: 4), for: 2)
        let store = MacLibraryFactsStore(loader: fake.loader())

        await store.ensureFacts(albumIds: [5], artistIds: [7], playlistIds: [2])

        #expect(fake.albumCalls == [5])
        #expect(fake.artistCalls == [7])
        #expect(fake.playlistCalls == [2])

        // 补齐后读到真值
        #expect(store.albumFacts(forAlbumId: 5).title == "Album X")
        #expect(store.albumFacts(forAlbumId: 5).trackCount == 12)
        #expect(store.albumTitle(forTrack: makeTrack("t1", albumId: 5)) == "Album X")
        #expect(store.artistTrackCount(forArtistId: 7) == 42)
        #expect(store.playlistFacts(forPlaylistId: 2).itemCount == 4)

        // 再读 + 重复补齐：命中缓存，零额外取数
        _ = store.albumFacts(forAlbumId: 5)
        _ = store.artistTrackCount(forArtistId: 7)
        await store.ensureFacts(albumIds: [5], artistIds: [7], playlistIds: [2])
        #expect(fake.albumCalls == [5])
        #expect(fake.artistCalls == [7])
        #expect(fake.playlistCalls == [2])
    }

    @Test("preload：曲库快照整批补齐（含 track.albumId），重载后整批刷新旧值")
    func preloadFillsSnapshotAndRefreshesValues() async {
        let fake = FakeFactsLoader()
        fake.setAlbumFacts(MacLibraryFactsStore.AlbumFacts(title: "旧标题", trackCount: 1), for: 5)
        fake.setAlbumFacts(MacLibraryFactsStore.AlbumFacts(title: "悬空专辑", trackCount: 1), for: 9)
        fake.setArtistCount(3, for: 7)
        fake.setPlaylistFacts(MacLibraryFactsStore.PlaylistFacts(itemCount: 2), for: 2)
        let store = MacLibraryFactsStore(loader: fake.loader())

        // 曲库快照：专辑 5（表里有）、曲目挂在专辑 9 上（表里没有 → 也要补）
        await store.preload(
            tracks: [makeTrack("t1", albumId: 5), makeTrack("t2", albumId: 9)],
            albums: [makeAlbum(5)],
            artists: [makeArtist(7)],
            playlists: [makePlaylist(2)]
        )

        #expect(fake.albumCalls == [5, 9])
        #expect(fake.artistCalls == [7])
        #expect(fake.playlistCalls == [2])
        #expect(store.albumFacts(forAlbumId: 5).title == "旧标题")
        #expect(store.albumFacts(forAlbumId: 9).title == "悬空专辑")
        #expect(store.artistTrackCount(forArtistId: 7) == 3)
        #expect(store.playlistFacts(forPlaylistId: 2).itemCount == 2)

        // 曲库变了：invalidate + preload 重载 → 旧值被整批刷新（不闪 0 的旧值→新值）
        fake.setAlbumFacts(MacLibraryFactsStore.AlbumFacts(title: "新标题", trackCount: 8), for: 5)
        store.invalidate()
        #expect(store.albumFacts(forAlbumId: 5).title == "旧标题") // 重载期间沿用旧值
        await store.preload(
            tracks: [makeTrack("t1", albumId: 5)],
            albums: [makeAlbum(5)],
            artists: [makeArtist(7)],
            playlists: [makePlaylist(2)]
        )
        #expect(store.albumFacts(forAlbumId: 5).title == "新标题")
        #expect(store.albumFacts(forAlbumId: 5).trackCount == 8)
    }

    @Test("invalidate 保留已发布旧值（重载期间不闪 0）")
    func invalidateKeepsPublishedValues() async {
        let fake = FakeFactsLoader()
        fake.setArtistCount(5, for: 11)
        let store = MacLibraryFactsStore(loader: fake.loader())

        await store.ensureFacts(artistIds: [11])
        #expect(store.artistTrackCount(forArtistId: 11) == 5)

        store.invalidate()
        // 值仍在（等新一轮预取整体替换，避免计数闪 0）
        #expect(store.artistTrackCount(forArtistId: 11) == 5)
    }

    @Test("★ 活锁已消：失效作废在途过期补齐，而失效后的新一轮补齐一定落地")
    func latestExplicitFillAlwaysLands() async {
        let fake = FakeFactsLoader()
        fake.setArtistCount(5, for: 11)
        fake.setGateOpen(true)
        let store = MacLibraryFactsStore(loader: fake.loader())

        // 第一轮补齐挂在门上（模拟慢取数）
        let firstFill = Task { await store.ensureFacts(artistIds: [11]) }
        #expect(await waitUntil { fake.artistCalls == [11] })

        store.invalidate() // 期间曲库已变
        fake.openGate() // 放行过期取数
        await firstFill.value
        await settle()

        // 过期结果被丢弃（不污染新代号；旧值/默认值继续被读，不闪 0）
        #expect(store.artistTrackCount(forArtistId: 11) == 0)

        // `invalidate()` 的唯一调用点 `MacLibraryView.reloadLibrary` 在同一函数里
        // 紧接着发起新一轮补齐 → 一定落地（这正是活锁被消的地方）
        await store.ensureFacts(artistIds: [11])
        #expect(store.artistTrackCount(forArtistId: 11) == 5)
        #expect(fake.artistCalls == [11, 11])
    }
}
