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
//
//  隔离口径（2026-09-22）：每个用例**按用例注入**一个把 `.documentDirectory` 解析指向自己的
//  临时根的 `FileManager`（`DocumentsRootTestSupport.swift`），经 `StateManager.*(fileManager:)`
//  生效 —— 不再碰真机容器 Documents，也不再依赖（已删除的）进程级静态
//  `LibraryRoot.documentsRootOverride`（该静态被并行套件互相改写 ⇒ 本套件 5 条红，
//  见 CI run `35704744895`）。
//  注意：StateManager 是单例 shared，测试共享实例 → suite 仍串行（.serialized），
//  每个用例前清场自己临时根下的状态文件（qqplayer-* / cosmos-*），避免用例间串扰。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite(.serialized)
struct StateManagerTests {
    // MARK: - Fixture

    /// 临时 Documents 根（真实文件系统） + 指向它的注入式 `FileManager`（每用例独立，结束即删除）。
    private func withDocumentsRoot(_ body: (FileManager) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-state-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try body(DocumentsRootFileManager(documentsRoot: root))
    }

    /// 旧位置 = **本用例注入的** Documents 根（不经 `LibraryRoot` 的 scoped 落点）。
    /// 生产 `migrateLegacyPaths` 的 legacy 源、以及各 `legacy*FileURL` 只读兜底都读它
    /// （`fileManager.urls(for: .documentDirectory…)` —— 现在也走同一个注入缝）。
    private func legacyDocuments(fileManager: FileManager) -> URL {
        fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 清场：**新旧两个位置都清**（都在本用例的临时根下）。
    /// 隐藏布局（2026-09-22）后状态文件落 scoped 落点（iOS = `Documents/.qqplayer/state/…`），
    /// 旧位置仍平铺在 Documents 根 —— 只清旧位置会把上一用例写在新位置的文件留给下一用例
    /// （2026-09-22 CI 实证：`favoritesMissingFileReturnsEmpty` 读到 `["track-1","track-2"]`，
    /// 正是前面 round-trip 用例写进新位置的残留）。新位置一律经 `LibraryRoot` 的 scoped 入口取，
    /// 不写死字面量路径。
    private func cleanLocalStateFiles(fileManager: FileManager) {
        let fm = FileManager.default
        for url in [LibraryRoot.favoritesFileURL(fileManager: fileManager),
                    LibraryRoot.playerStateFileURL(fileManager: fileManager),
                    LibraryRoot.playlistsDirectoryURL(fileManager: fileManager)].compactMap({ $0 }) {
            try? fm.removeItem(at: url)
        }
        let legacyRoot = legacyDocuments(fileManager: fileManager)
        for name in ["qqplayer-favorites.json", "qqplayer-player-state.json",
                     "cosmos-favorites.json", "cosmos-player-state.json"] {
            try? fm.removeItem(at: legacyRoot.appendingPathComponent(name))
        }
        for dir in ["qqplayer-playlists", "cosmos-playlists"] {
            try? fm.removeItem(at: legacyRoot.appendingPathComponent(dir))
        }
    }

    /// 写样本到**指定 URL**（按需建父目录 —— scoped 落点 `Documents/.qqplayer/state/` 可能还不存在）。
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    // MARK: - migrateLegacyPaths

    @Test("migrate：legacy 文件存在且新位置空闲 → 移动并改名")
    func migrateMovesLegacy() throws {
        try withDocumentsRoot { fileManager in
            defer { cleanLocalStateFiles(fileManager: fileManager) }
            cleanLocalStateFiles(fileManager: fileManager)

            let legacy = legacyDocuments(fileManager: fileManager)
                .appendingPathComponent("cosmos-favorites.json")
            try write(Data("{\"version\":1,\"updatedAt\":\"2026-01-01T00:00:00Z\",\"favorites\":[\"a\",\"b\"]}".utf8), to: legacy)

            StateManager.shared.migrateLegacyPaths(fileManager: fileManager)

            #expect(!FileManager.default.fileExists(atPath: legacy.path))
            // 目标已收进隐藏布局落点（iOS = `.qqplayer/state/qqplayer-favorites.json`）。
            // 旧断言查的是 `Documents/qqplayer-favorites.json` —— 那是**旧位置**（v2 起只作只读兜底），
            // 生产不再往那里写（2026-09-22 CI 实证：新位置有、旧位置永远等不到）⇒ 断言过期。
            let migrated = try #require(LibraryRoot.favoritesFileURL(fileManager: fileManager))
            #expect(FileManager.default.fileExists(atPath: migrated.path))
            // 语义不变：搬过去的内容经生产读取路径仍读得到。
            #expect(try StateManager.shared.loadFavorites(fileManager: fileManager) == ["a", "b"])
        }
    }

    @Test("migrate：新位置已占用 → legacy 副本仅删除（残留清理）")
    func migrateRemovesResidue() throws {
        try withDocumentsRoot { fileManager in
            defer { cleanLocalStateFiles(fileManager: fileManager) }
            cleanLocalStateFiles(fileManager: fileManager)

            let legacy = legacyDocuments(fileManager: fileManager)
                .appendingPathComponent("cosmos-favorites.json")
            try write(Data("{\"version\":1,\"updatedAt\":\"2026-01-01T00:00:00Z\",\"favorites\":[\"old\"]}".utf8), to: legacy)
            // 「新位置已占用」必须在**新位置**放文件：旧位置不是新位置（2026-09-22 CI 实证：
            // 写旧位置会被生产判为「新位置空闲」→ 反而把 legacy 原样搬过去，读回 ["old"]）。
            let current = try #require(LibraryRoot.favoritesFileURL(fileManager: fileManager))
            try write(Data("{\"version\":1,\"updatedAt\":\"2026-01-01T00:00:00Z\",\"favorites\":[\"new\"]}".utf8), to: current)

            StateManager.shared.migrateLegacyPaths(fileManager: fileManager)

            #expect(!FileManager.default.fileExists(atPath: legacy.path))
            // 新位置内容未被覆盖
            let loaded = try StateManager.shared.loadFavorites(fileManager: fileManager)
            #expect(loaded == ["new"])
        }
    }

    // MARK: - Favorites

    @Test("favorites：本地往返保存与读取")
    func favoritesRoundTrip() throws {
        try withDocumentsRoot { fileManager in
            defer { cleanLocalStateFiles(fileManager: fileManager) }
            cleanLocalStateFiles(fileManager: fileManager)

            try StateManager.shared.saveFavorites(["track-1", "track-2"], fileManager: fileManager)
            let loaded = try StateManager.shared.loadFavorites(fileManager: fileManager)
            #expect(loaded == ["track-1", "track-2"])
        }
    }

    @Test("favorites：本地文件损坏 → 返回空数组（不抛错，走 iCloud 兜底失败路径）")
    func favoritesCorruptFileReturnsEmpty() throws {
        try withDocumentsRoot { fileManager in
            defer { cleanLocalStateFiles(fileManager: fileManager) }
            cleanLocalStateFiles(fileManager: fileManager)

            // 损坏样本写到**生产读取的第一个位置**（scoped 落点）：新位置优先级最高，
            // 写旧位置会被「新位置优先」跳过（新位置残留就又变成串扰源），测不到损坏分支。
            let corrupt = try #require(LibraryRoot.favoritesFileURL(fileManager: fileManager))
            try write(Data("not json at all".utf8), to: corrupt)
            let loaded = try StateManager.shared.loadFavorites(fileManager: fileManager)
            #expect(loaded.isEmpty)
        }
    }

    @Test("favorites：无任何文件 → 空数组")
    func favoritesMissingFileReturnsEmpty() throws {
        try withDocumentsRoot { fileManager in
            defer { cleanLocalStateFiles(fileManager: fileManager) }
            cleanLocalStateFiles(fileManager: fileManager)
            let loaded = try StateManager.shared.loadFavorites(fileManager: fileManager)
            #expect(loaded.isEmpty)
        }
    }

    // MARK: - PlayerState

    @Test("playerState：本地往返保存与读取")
    func playerStateRoundTrip() throws {
        try withDocumentsRoot { fileManager in
            defer { cleanLocalStateFiles(fileManager: fileManager) }
            cleanLocalStateFiles(fileManager: fileManager)

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
            try StateManager.shared.savePlayerState(state, fileManager: fileManager)
            let loaded = try StateManager.shared.loadPlayerState(fileManager: fileManager)
            #expect(loaded?.currentTrackStableId == "abc123")
            #expect(loaded?.playbackTime == 42.5)
            #expect(loaded?.isShuffled == true)
            #expect(loaded?.currentIndex == 1)
        }
    }

    // MARK: - Playlists

    @Test("playlist：save → load → delete 生命周期")
    func playlistLifecycle() throws {
        try withDocumentsRoot { fileManager in
            defer { cleanLocalStateFiles(fileManager: fileManager) }
            cleanLocalStateFiles(fileManager: fileManager)

            let playlist = PlaylistState(
                slug: "my-list",
                title: "我的歌单",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                items: [("track-x", Date(timeIntervalSince1970: 1_700_000_100))]
            )
            try StateManager.shared.savePlaylist(playlist, fileManager: fileManager)

            let loaded = try StateManager.shared.loadPlaylist(slug: "my-list", fileManager: fileManager)
            #expect(loaded?.title == "我的歌单")
            #expect(loaded?.items.first?.trackId == "track-x")

            try StateManager.shared.deletePlaylist(slug: "my-list", fileManager: fileManager)
            let afterDelete = try StateManager.shared.loadPlaylist(slug: "my-list", fileManager: fileManager)
            #expect(afterDelete == nil)
        }
    }

    @Test("playlist：getAllPlaylists 只返回本地且跳过损坏文件")
    func playlistGetAll() throws {
        try withDocumentsRoot { fileManager in
            defer { cleanLocalStateFiles(fileManager: fileManager) }
            cleanLocalStateFiles(fileManager: fileManager)

            let a = PlaylistState(slug: "a", title: "A", createdAt: Date(), items: [])
            let b = PlaylistState(slug: "b", title: "B", createdAt: Date(), items: [])
            try StateManager.shared.savePlaylist(a, fileManager: fileManager)
            try StateManager.shared.savePlaylist(b, fileManager: fileManager)
            // 塞一个损坏文件（非 JSON）到歌单目录（**旧位置**：`playlistGetAll` 的合并口径要覆盖它）
            let dir = legacyDocuments(fileManager: fileManager)
                .appendingPathComponent("qqplayer-playlists", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("broken".utf8).write(to: dir.appendingPathComponent("playlist-broken.json"))

            let all = try StateManager.shared.getAllPlaylists(fileManager: fileManager)
            let slugs = all.map(\.slug).sorted()
            #expect(slugs == ["a", "b"])
        }
    }
}
