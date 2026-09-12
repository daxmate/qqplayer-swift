//
//  MacLibraryFactsStoreTests.swift
//  QQPlayerTests
//
//  曲库卡片事实缓存（MacLibraryFactsStore）语义回归用例
//  —— 2026-09-12 审计批次 B4 · M2。
//
//  修复前视图 body 里直接同步调 DatabaseManager（专辑网格每卡每帧 2 次整表查询、
//  歌手/歌单行每行每帧 1–3 次、歌曲 Table 每可见行每帧 1 次）——这些调用直连 DB
//  单例、没有任何缝，只能靠读代码。本文件用注入的假取数器锁定新契约：
//  1) body 侧读只查缓存，未命中不再同步打 DB，而是回默认值 + 异步补齐；
//  2) 同一 id 并发读只调度一次取数；
//  3) 补齐完成后读到真值，且二次读不再取数；
//  4) `invalidate()` 保留已发布旧值（重载期间不闪 0），但作废在途结果
//     （代号不匹配 → 过期补齐不得写入缓存）。
//  修复前这些断言连编译都过不了（MacLibraryFactsStore 符号不存在）。
//

import Foundation
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
@MainActor
private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
struct MacLibraryFactsStoreTests {
    @Test("缓存未命中：body 侧读回默认值且不阻塞，补齐后读到真值")
    func lazyFillOnCacheMiss() async {
        let fake = FakeFactsLoader()
        fake.setArtistCount(42, for: 7)
        let store = MacLibraryFactsStore(loader: fake.loader())

        // 首次读：同步返回默认 0（修复前这里是同步 DB 查询），不阻塞主线程
        #expect(store.artistTrackCount(forArtistId: 7) == 0)

        // 补齐跑在后续的 Task 上（同 actor 的同步断言点必然还没执行取数，
        // 修复前这里断言「立即已取数」是错的——CI 上必然失败）→ 等补齐完成再断言
        let filled = await waitUntil { fake.artistCalls == [7] }
        #expect(filled)
        #expect(store.artistTrackCount(forArtistId: 7) == 42)
        // 二次读命中缓存：不再取数
        #expect(fake.artistCalls == [7])
    }

    @Test("同一 id 连续多次读只调度一次取数")
    func coalescesConcurrentReads() async {
        let fake = FakeFactsLoader()
        fake.setArtistCount(9, for: 3)
        let store = MacLibraryFactsStore(loader: fake.loader())

        for _ in 0 ..< 5 {
            _ = store.artistTrackCount(forArtistId: 3)
        }

        #expect(await waitUntil { fake.artistCalls == [3] })
        #expect(store.artistTrackCount(forArtistId: 3) == 9)
        // 5 次读只调度一次取数（inFlight 去重）
        #expect(fake.artistCalls == [3])
    }

    @Test("专辑事实：标题/曲目数同次取数填充")
    func albumFactsFilled() async {
        let fake = FakeFactsLoader()
        var facts = MacLibraryFactsStore.AlbumFacts()
        facts.title = "Album X"
        facts.trackCount = 12
        fake.setAlbumFacts(facts, for: 5)
        let store = MacLibraryFactsStore(loader: fake.loader())

        #expect(store.albumFacts(forAlbumId: 5) == MacLibraryFactsStore.AlbumFacts())
        await settle()

        let loaded = store.albumFacts(forAlbumId: 5)
        #expect(loaded.title == "Album X")
        #expect(loaded.trackCount == 12)
        #expect(fake.albumCalls == [5])
    }

    @Test("歌单事实：条目数填充")
    func playlistFactsFilled() async {
        let fake = FakeFactsLoader()
        var facts = MacLibraryFactsStore.PlaylistFacts()
        facts.itemCount = 4
        fake.setPlaylistFacts(facts, for: 2)
        let store = MacLibraryFactsStore(loader: fake.loader())

        #expect(store.playlistFacts(forPlaylistId: 2).itemCount == 0)
        await settle()
        #expect(store.playlistFacts(forPlaylistId: 2).itemCount == 4)
        #expect(fake.playlistCalls == [2])
    }

    @Test("invalidate 保留已发布旧值（重载期间不闪 0）")
    func invalidateKeepsPublishedValues() async {
        let fake = FakeFactsLoader()
        fake.setArtistCount(5, for: 11)
        let store = MacLibraryFactsStore(loader: fake.loader())

        _ = store.artistTrackCount(forArtistId: 11)
        await settle()
        #expect(store.artistTrackCount(forArtistId: 11) == 5)

        store.invalidate()
        // 值仍在（等新一轮预取整体替换，避免计数闪 0）
        #expect(store.artistTrackCount(forArtistId: 11) == 5)
    }

    @Test("invalidate 作废在途结果：过期补齐不得写入缓存")
    func invalidateDropsInFlightResult() async {
        let fake = FakeFactsLoader()
        var facts = MacLibraryFactsStore.AlbumFacts()
        facts.title = "过期结果"
        fake.setAlbumFacts(facts, for: 5)
        fake.setGateOpen(true)
        let store = MacLibraryFactsStore(loader: fake.loader())

        _ = store.albumFacts(forAlbumId: 5) // 命中未缓存 → 调度（取数挂在门上）
        #expect(await waitUntil { fake.albumCalls == [5] }) // 已进入取数并在门上挂起

        store.invalidate() // 期间曲库已变
        fake.openGate() // 放行过期取数
        await settle()

        // 代号不匹配 → 过期结果被丢弃（仍是默认值，等新一轮预取填充）
        #expect(store.albumFacts(forAlbumId: 5).title.isEmpty)
    }
}
