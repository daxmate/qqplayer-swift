//
//  DocumentsDerivedPathGuardTests.swift
//  QQPlayerTests
//
//  **长期防复发守卫**（2026-09-22 CI 事故 `35707598276` 的沉淀）：
//  **在注入 FM 下，任何 Documents 派生路径都不得经 `.default` 解析。**
//
//  —— 为什么需要这条守卫（事故形态）——
//  测试隔离的统一缝是「注入一个把 `.documentDirectory` 解析重定向到临时根的 `FileManager`」
//  （见 `DocumentsRootTestSupport.swift`）。只要**链条内部有一处**改回 `FileManager.default`，
//  注入就静默失效：解析落到**真机容器**，用例于是「看不见自己搭的文件」。
//  2026-09-22 真实发生：`DatabaseManager.migrateTrackForMovedFile` 内部用
//  `LibraryRoot.storedPath(forAbsolutePath:)` + `generatePathStableId(forPath:)`（都硬 `.default`）
//  ⇒ 临时根里的 `song.flac` 被判成「曲库外绝对路径」、并按真容器重算 stableId ⇒ 行查不到。
//  这类回归**不会让编译失败、也不会让其它用例红**，只让某几条用例变得「莫名其妙」。
//
//  —— 守卫口径（两类判据，互为补充）——
//  ① **闭合**：注入根 `R` 下产出的路径 / 身份，必须与「直接以 `R`（及其 `Music/`）为根的
//     闭合派生」一致；且不得等于「按 `.default`（真机容器）派生」的结果。
//  ② **注入 FM 真被走到**：`DocumentsRootFileManager.documentDirectoryResolutionCount`
//     在关键链路上必须增长 —— 内部绕回 `.default` 时它零增长（最强的漏网判据）。
//
//  覆盖范围（与任务包审计表同源的「关键链路」）：各 `LibraryRoot` 便捷入口、
//  DB identity / storedPath 派生链（`migrateTrackForMovedFile`）、StateManager 保存链。
//
//  口径提醒：本文件只做**根闭合 / 注入生效**判定，不重复各链路的业务断言
//  （那是 `LibraryLayoutMigrationTests` / `StateManagerTests` / `LibraryHiddenLayoutMigrationTests` 的职责）。
//

import Foundation
import GRDB
import Testing

@testable import QQPlayer

@Suite("Documents 派生路径守卫：注入 FM 下不得经 .default 解析", .serialized)
struct DocumentsDerivedPathGuardTests {
    // MARK: - Fixture

    /// 临时 Documents 根 + 指向它的注入 FM（每用例独立，结束即删）。
    private func withDocumentsRoot(_ body: (URL, DocumentsRootFileManager) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-guard-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try body(root, DocumentsRootFileManager(documentsRoot: root))
    }

    /// 真机/模拟器容器的 Documents 根（`.default` 解析结果）—— 泄漏判据的「反面样本」。
    private var realDocumentsRoot: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// 内存库 + `DatabaseManager`（与其它套件同一测试缝）。
    private func makeManager() throws -> DatabaseManager {
        let queue = try DatabaseQueue()
        let manager = DatabaseManager(dbWriter: queue)
        try manager.createTables()
        return manager
    }

    // MARK: - ① 各 LibraryRoot 便捷入口：落在注入根内

    @Test("各 Documents 派生落点都在注入根内、且不在真机容器里")
    func everyLibraryRootCategoryConfinedToInjectedRoot() throws {
        try withDocumentsRoot { documents, fileManager in
            // 解析是确定的：同一输入两次结果一致（纯路径拼接，无隐藏静态）。
            let categories: [(String, URL?)] = [
                ("musicRoot", LibraryRoot.musicRootURL(fileManager: fileManager)),
                ("hiddenRoot", LibraryRoot.hiddenRootURL(fileManager: fileManager)),
                ("database", LibraryRoot.databaseDirectoryURL(fileManager: fileManager)),
                ("state", LibraryRoot.stateDirectoryURL(fileManager: fileManager)),
                ("favorites", LibraryRoot.favoritesFileURL(fileManager: fileManager)),
                ("playlists", LibraryRoot.playlistsDirectoryURL(fileManager: fileManager)),
                ("playerState", LibraryRoot.playerStateFileURL(fileManager: fileManager)),
                ("pairing", LibraryRoot.pairingFileURL(fileManager: fileManager)),
                ("externalBookmarks", LibraryRoot.externalBookmarksFileURL(fileManager: fileManager)),
                ("artwork", LibraryRoot.artworkDirectoryURL(fileManager: fileManager)),
                ("artworkMapping", LibraryRoot.artworkMappingFileURL(fileManager: fileManager)),
                ("manualLyrics", LibraryRoot.manualLyricsDirectoryURL(fileManager: fileManager)),
                ("alignedLyrics", LibraryRoot.alignedLyricsDirectoryURL(fileManager: fileManager)),
                ("lyricsCacheTracks", LibraryRoot.lyricsCacheTracksDirectoryURL(fileManager: fileManager)),
                ("lyricsSearchCache", LibraryRoot.lyricsSearchCacheDirectoryURL(fileManager: fileManager)),
                ("logs", LibraryRoot.logsDirectoryURL(fileManager: fileManager)),
                ("meta", LibraryRoot.metaDirectoryURL(fileManager: fileManager)),
                ("cache", LibraryRoot.cacheDirectoryURL(fileManager: fileManager)),
                ("namedCache", LibraryRoot.namedCacheDirectoryURL("SpotifyCache", fileManager: fileManager)),
                ("trash", LibraryRoot.trashDirectoryURL(fileManager: fileManager)),
            ]
            let prefix = documents.path + "/"
            for (name, url) in categories {
                let resolved = try #require(url, "\(name) 应可解析")
                #expect(resolved.path.hasPrefix(prefix), "\(name) 落在注入根之外：\(resolved.path)")
                if let real = realDocumentsRoot {
                    // 泄漏判据：真机容器的 Documents 前缀**不得**出现在注入结果里。
                    #expect(
                        !resolved.path.hasPrefix(real.path + "/"),
                        "\(name) 解析到了真机容器（注入 FM 未生效）：\(resolved.path)"
                    )
                }
            }
            // 解析确实走了注入 FM（调用点全部显式传 FM，计数必然增长）。
            #expect(fileManager.documentDirectoryResolutionCount >= categories.count)
        }
    }

    @Test("存储形态换算在注入根内闭合（相对 ↔ 绝对）")
    func storedPathRoundTripConfinedToInjectedRoot() throws {
        try withDocumentsRoot { documents, fileManager in
            let musicRoot = documents.appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
            let inside = musicRoot.appendingPathComponent("song.flac")

            // 曲库内 → 相对形态；再解回绝对 URL 必须回到注入根内。
            #expect(LibraryRoot.storedPath(for: inside, fileManager: fileManager) == "song.flac")
            #expect(
                LibraryRoot.absoluteURL(forStoredPath: "song.flac", fileManager: fileManager).path
                    == inside.standardizedFileURL.path
            )
            // 泄漏判据：注入根**之外**的绝对路径不得被相对化（若内部走 `.default`，
            // 真机容器的 `Documents/Music` 会把它当"曲库内"处理 ⇒ 这里判红）。
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("qqplayer-guard-outside-\(UUID().uuidString).flac")
            #expect(LibraryRoot.storedPath(for: outside, fileManager: fileManager) == outside.standardizedFileURL.path)
        }
    }

    // MARK: - ② DB identity / storedPath 派生链（本次事故的现场）

    #if os(iOS)
        @Test("身份基准根与 stableId 派生走注入 FM（不经 .default）")
        func identityDerivationConfinedToInjectedRoot() throws {
            try withDocumentsRoot { documents, fileManager in
                let musicRoot = documents.appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
                let inside = musicRoot.appendingPathComponent("song.flac")

                // 基准根本身必须来自注入 FM。
                #expect(DatabaseManager.defaultStableIdRoot(fileManager: fileManager) == musicRoot)

                // 闭合派生：与「以注入 Music 根为基准」显式算出的 id 必须一致。
                let injectedDerived = DatabaseManager.generatePathStableId(
                    forPath: inside.path, fileManager: fileManager
                )
                #expect(
                    injectedDerived
                        == DatabaseManager.generatePathStableId(forPath: "song.flac", relativeRoot: musicRoot)
                )
                // 泄漏判据：按真机容器派生会退化成「整条绝对路径」⇒ id 必须**不同**。
                #expect(
                    injectedDerived
                        != DatabaseManager.generatePathStableId(
                            forPath: inside.path, relativeRoot: DatabaseManager.defaultStableIdRoot
                        )
                )
            }
        }
    #endif

    @Test("migrateTrackForMovedFile：注入根内闭合，且真的走了注入 FM")
    func migrateTrackForMovedFileConfinedToInjectedRoot() throws {
        try withDocumentsRoot { documents, fileManager in
            let manager = try makeManager()
            let musicRoot = documents.appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: musicRoot, withIntermediateDirectories: true)
            // 文件已在搬入后的位置；行按**搬入后**的身份建 —— 迁移应判「id 不变，只回写 path」。
            let destination = musicRoot.appendingPathComponent("song.flac")
            try Data(repeating: 0x41, count: 8).write(to: destination)

            let stableId = DatabaseManager.generatePathStableId(
                forPath: destination.path, fileManager: fileManager
            )
            try manager.upsertTrack(
                Track(
                    stableId: stableId,
                    title: "Song",
                    durationMs: 1000,
                    path: documents.appendingPathComponent("song.flac").path,
                    fileSize: 8,
                    modificationDate: 1000
                )
            )

            let resolutionsBefore = fileManager.documentDirectoryResolutionCount
            let returned = try manager.migrateTrackForMovedFile(
                oldStableId: stableId,
                newPath: destination.path,
                fileManager: fileManager
            )

            // 闭合：返回 id 与注入根派生一致（内部若按真容器重算 ⇒ 不一致 ⇒ 判红）。
            #expect(returned == stableId)
            let row = try manager.getTrack(byStableId: stableId)
            #expect(row?.path == "song.flac")
            #expect(row?.stableId == stableId)
            // 注入 FM 真被走到：内部绕回 `.default` 时此计数不会增长。
            #expect(
                fileManager.documentDirectoryResolutionCount > resolutionsBefore,
                "migrateTrackForMovedFile 内部未使用注入 FM（Documents 根经 .default 解析）"
            )
        }
    }

    // MARK: - ③ StateManager 保存链（本次事故的现场）

    @Test("StateManager 保存链：落在注入根内、父目录缺失也能保存、注入 FM 真被走到")
    func stateManagerSavePathsConfinedToInjectedRoot() throws {
        try withDocumentsRoot { documents, fileManager in
            defer { cleanStateFiles(fileManager: fileManager) }
            cleanStateFiles(fileManager: fileManager)

            let resolutionsBefore = fileManager.documentDirectoryResolutionCount
            // `.qqplayer/state` 此刻不存在（全新安装形态）：保存链必须自己建父目录。
            try StateManager.shared.saveFavorites(["g1", "g2"], fileManager: fileManager)
            try StateManager.shared.savePlayerState(
                PlayerState(
                    currentTrackStableId: "g1",
                    playbackTime: 1.5,
                    isPlaying: false,
                    queueTrackIds: ["g1", "g2"],
                    currentIndex: 0,
                    isRepeating: false,
                    isShuffled: false,
                    isLoopingSong: false,
                    originalQueueTrackIds: ["g1", "g2"],
                    lastSavedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                fileManager: fileManager
            )

            let favorites = try #require(LibraryRoot.favoritesFileURL(fileManager: fileManager))
            let playerState = try #require(LibraryRoot.playerStateFileURL(fileManager: fileManager))
            let prefix = documents.path + "/"
            #expect(favorites.path.hasPrefix(prefix))
            #expect(playerState.path.hasPrefix(prefix))
            if let real = realDocumentsRoot {
                #expect(!favorites.path.hasPrefix(real.path + "/"))
                #expect(!playerState.path.hasPrefix(real.path + "/"))
            }
            // 真的落盘（父目录被自动创建）且能读回。
            #expect(FileManager.default.fileExists(atPath: favorites.path))
            #expect(FileManager.default.fileExists(atPath: playerState.path))
            #expect(try StateManager.shared.loadFavorites(fileManager: fileManager) == ["g1", "g2"])
            #expect(
                fileManager.documentDirectoryResolutionCount > resolutionsBefore,
                "StateManager 保存链内部未使用注入 FM（Documents 根经 .default 解析）"
            )
        }
    }

    /// 清场：注入根下新旧两个落点的状态文件（不碰真机容器）。
    private func cleanStateFiles(fileManager: DocumentsRootFileManager) {
        let fm = FileManager.default
        for url in [
            LibraryRoot.favoritesFileURL(fileManager: fileManager),
            LibraryRoot.playerStateFileURL(fileManager: fileManager),
            LibraryRoot.playlistsDirectoryURL(fileManager: fileManager),
        ].compactMap({ $0 }) {
            try? fm.removeItem(at: url)
        }
        for name in ["qqplayer-favorites.json", "qqplayer-player-state.json"] {
            try? fm.removeItem(at: fileManager.documentsRoot.appendingPathComponent(name))
        }
    }
}
