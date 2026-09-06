//
//  StateManagerTests.swift
//  QQPlayerTests
//
//  StateManager 本地持久化防回归测试（favorites / playlists / playerState /
//  Cosmos→QQPlayer legacy 路径迁移）。
//
//  背景：状态文件管理（iCloud 优先、本地 Documents 兜底）在 8-29 架构改名后新增
//  migrateLegacyPaths 幂等迁移，只在真机升级路径验证过一次。CI 模拟器无 iCloud
//  （ubiquityIdentityToken == nil）→ 全部走本地 Documents 分支，可测真实落盘路径。
//  注意：StateManager 是单例 shared，测试共享实例 → suite 串行（.serialized），
//  每个用例前清场本地状态文件（qqplayer-* / cosmos-*），避免用例间串扰。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite(.serialized)
struct StateManagerTests {
    private var docs: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func cleanLocalStateFiles() {
        let fm = FileManager.default
        for name in ["qqplayer-favorites.json", "qqplayer-player-state.json",
                     "cosmos-favorites.json", "cosmos-player-state.json"] {
            try? fm.removeItem(at: docs.appendingPathComponent(name))
        }
        for dir in ["qqplayer-playlists", "cosmos-playlists"] {
            try? fm.removeItem(at: docs.appendingPathComponent(dir))
        }
    }

    private func write(_ data: Data, to name: String) throws {
        try data.write(to: docs.appendingPathComponent(name), options: .atomic)
    }

    // MARK: - migrateLegacyPaths

    @Test("migrate：legacy 文件存在且新位置空闲 → 移动并改名")
    func migrateMovesLegacy() throws {
        defer { cleanLocalStateFiles() }
        cleanLocalStateFiles()

        let legacy = docs.appendingPathComponent("cosmos-favorites.json")
        try Data("{\"version\":1,\"updatedAt\":\"2026-01-01T00:00:00Z\",\"favorites\":[\"a\",\"b\"]}".utf8)
            .write(to: legacy)

        StateManager.shared.migrateLegacyPaths()

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        let migrated = docs.appendingPathComponent("qqplayer-favorites.json")
        #expect(FileManager.default.fileExists(atPath: migrated.path))
    }

    @Test("migrate：新位置已占用 → legacy 副本仅删除（残留清理）")
    func migrateRemovesResidue() throws {
        defer { cleanLocalStateFiles() }
        cleanLocalStateFiles()

        let legacy = docs.appendingPathComponent("cosmos-favorites.json")
        try Data("{\"version\":1,\"updatedAt\":\"2026-01-01T00:00:00Z\",\"favorites\":[\"old\"]}".utf8)
            .write(to: legacy)
        let current = docs.appendingPathComponent("qqplayer-favorites.json")
        try Data("{\"version\":1,\"updatedAt\":\"2026-01-01T00:00:00Z\",\"favorites\":[\"new\"]}".utf8)
            .write(to: current)

        StateManager.shared.migrateLegacyPaths()

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        // 新位置内容未被覆盖
        let loaded = try StateManager.shared.loadFavorites()
        #expect(loaded == ["new"])
    }

    @Test("migrate：幂等（无 legacy 时重复调用无副作用）")
    func migrateIdempotent() throws {
        defer { cleanLocalStateFiles() }
        cleanLocalStateFiles()

        StateManager.shared.migrateLegacyPaths()
        StateManager.shared.migrateLegacyPaths() // 不应抛
        #expect(!FileManager.default.fileExists(atPath: docs.appendingPathComponent("cosmos-playlists").path))
    }

    // MARK: - Favorites

    @Test("favorites：本地往返保存与读取")
    func favoritesRoundTrip() throws {
        defer { cleanLocalStateFiles() }
        cleanLocalStateFiles()

        try StateManager.shared.saveFavorites(["track-1", "track-2"])
        let loaded = try StateManager.shared.loadFavorites()
        #expect(loaded == ["track-1", "track-2"])
    }

    @Test("favorites：本地文件损坏 → 返回空数组（不抛错，走 iCloud 兜底失败路径）")
    func favoritesCorruptFileReturnsEmpty() throws {
        defer { cleanLocalStateFiles() }
        cleanLocalStateFiles()

        try write(Data("not json at all".utf8), to: "qqplayer-favorites.json")
        let loaded = try StateManager.shared.loadFavorites()
        #expect(loaded.isEmpty)
    }

    @Test("favorites：无任何文件 → 空数组")
    func favoritesMissingFileReturnsEmpty() throws {
        defer { cleanLocalStateFiles() }
        cleanLocalStateFiles()
        let loaded = try StateManager.shared.loadFavorites()
        #expect(loaded.isEmpty)
    }

    // MARK: - PlayerState

    @Test("playerState：本地往返保存与读取")
    func playerStateRoundTrip() throws {
        defer { cleanLocalStateFiles() }
        cleanLocalStateFiles()

        let state = PlayerState(
            currentTrackStableId: "abc123",
            playbackTime: 42.5,
            isPlaying: true,
            queueTrackIds: ["a", "b"],
            currentIndex: 1,
            isRepeating: false,
            isShuffled: true,
            isLoopingSong: false,
            originalQueueTrackIds: ["a", "b"],
            lastSavedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try StateManager.shared.savePlayerState(state)
        let loaded = try StateManager.shared.loadPlayerState()
        #expect(loaded?.currentTrackStableId == "abc123")
        #expect(loaded?.playbackTime == 42.5)
        #expect(loaded?.isShuffled == true)
        #expect(loaded?.currentIndex == 1)
    }

    // MARK: - Playlists

    @Test("playlist：save → load → delete 生命周期")
    func playlistLifecycle() throws {
        defer { cleanLocalStateFiles() }
        cleanLocalStateFiles()

        let playlist = PlaylistState(
            slug: "my-list",
            title: "我的歌单",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            items: [("track-x", Date(timeIntervalSince1970: 1_700_000_100))]
        )
        try StateManager.shared.savePlaylist(playlist)

        let loaded = try StateManager.shared.loadPlaylist(slug: "my-list")
        #expect(loaded?.title == "我的歌单")
        #expect(loaded?.items.first?.trackId == "track-x")

        try StateManager.shared.deletePlaylist(slug: "my-list")
        let afterDelete = try StateManager.shared.loadPlaylist(slug: "my-list")
        #expect(afterDelete == nil)
    }

    @Test("playlist：getAllPlaylists 只返回本地且跳过损坏文件")
    func playlistGetAll() throws {
        defer { cleanLocalStateFiles() }
        cleanLocalStateFiles()

        let a = PlaylistState(slug: "a", title: "A", createdAt: Date(), items: [])
        let b = PlaylistState(slug: "b", title: "B", createdAt: Date(), items: [])
        try StateManager.shared.savePlaylist(a)
        try StateManager.shared.savePlaylist(b)
        // 塞一个损坏文件（非 JSON）到歌单目录
        let dir = docs.appendingPathComponent("qqplayer-playlists", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("broken".utf8).write(to: dir.appendingPathComponent("playlist-broken.json"))

        let all = try StateManager.shared.getAllPlaylists()
        let slugs = all.map(\.slug).sorted()
        #expect(slugs == ["a", "b"])
    }
}
