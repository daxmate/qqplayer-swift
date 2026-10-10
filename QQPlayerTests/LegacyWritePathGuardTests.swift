//
//  LegacyWritePathGuardTests.swift
//  QQPlayerTests
//
//  **长期防复发守卫**：12 个历史落点的**写入点**必须解析到隐藏根（iOS），旧位置只许读。
//
//  —— 为什么需要这条守卫（2026-09-22 真机形态）——
//  真机 `Documents/` 根上又出现了一批**改名前**的落点：
//    `ArtworkCache/` `ArtworkMapping.plist` `SpotifyCache/` `DiscogsCache/` `HybridMusicCache/`
//    `lyrics-aligned/` `lyrics-manual/` `lyrics-cache/` `qqplayer-playlists/`
//    `app.log` `db-debug.log` `sync-diag.log`
//  形态上等同「写入点仍落旧位置」。隐藏布局 v2/v2.1（`docs`：`LibraryRoot` 单一入口）之后，
//  这 12 处**写入**都必须经 `LibraryRoot` 解析到 `<Documents>/.qqplayer/**`（macOS 逐字节保持现状）；
//  旧位置只剩**只读兼容**（迁移未跑到时还能读到用户既有数据）。
//
//  —— 守卫口径（两类判据）——
//  ① **运行期闭合**：把 `.documentDirectory` 解析重定向到临时根的注入 FM（`DocumentsRootFileManager`）
//     下，`StateManager` 保存链 / 歌词库落点解析出的路径必须落在注入根**内**，
//     且**不得**等于该根下的旧位置；`documentDirectoryResolutionCount` 必须增长
//     （内部绕回 `.default` 时零增长 —— 与 `DocumentsDerivedPathGuardTests` 同款判据）。
//  ② **形状（源码级，fail-closed）**：9 个旧目录名作为**字符串字面量**只允许出现在
//     「迁移映射表」与「只读兼容」这两类文件里；写入侧文件必须经 `LibraryRoot` 的 scratch 解析
//     （缓存类）或 `LibraryRoot.logsDirectoryURL`（日志类）解析落点。文件读不到 / 扫描目录为空
//     ⇒ 判红，绝不静默通过。
//
//  口径提醒：本文件只锚「写入落点不得是旧位置」，各链路的业务断言归各自的套件。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite("旧位置写入点守卫：写入解析到隐藏根、旧位置只读", .serialized)
struct LegacyWritePathGuardTests {
    // MARK: - Fixture（与 DocumentsDerivedPathGuardTests 同一注入基建）

    /// 临时 Documents 根 + 指向它的注入 FM（每用例独立，结束即删）。
    private func withDocumentsRoot(_ body: (URL, DocumentsRootFileManager) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("qqplayer-legacy-write-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try body(root, DocumentsRootFileManager(documentsRoot: root))
    }

    /// 真机/模拟器容器的 Documents 根（泄漏判据的反面样本）。
    private var realDocumentsRoot: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// 注入根下的隐藏根（iOS）/ Documents 根（macOS）—— 落点期望值的唯一算法。
    private static func scopedRoot(_ documents: URL) -> URL {
        #if os(iOS)
            return documents.appendingPathComponent(LibraryRoot.hiddenRootDirectoryName, isDirectory: true)
        #else
            return documents
        #endif
    }

    // MARK: - ① 运行期：StateManager 保存链

    @Test("StateManager 保存链：状态落点在内层专用目录，旧位置（qqplayer-playlists / 根上文件）不被创建")
    func stateManagerSavesNeverCreateLegacyLocations() throws {
        try withDocumentsRoot { documents, fileManager in
            let resolutionsBefore = fileManager.documentDirectoryResolutionCount
            try StateManager.shared.saveFavorites(["g1", "g2"], fileManager: fileManager)
            try StateManager.shared.savePlaylist(
                PlaylistState(
                    slug: "legacy-write-guard",
                    title: "LegacyWriteGuard",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                    items: [("g1", Date(timeIntervalSince1970: 1_700_000_000))]
                ),
                fileManager: fileManager
            )
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
            let playlists = try #require(LibraryRoot.playlistsDirectoryURL(fileManager: fileManager))
            let playerState = try #require(LibraryRoot.playerStateFileURL(fileManager: fileManager))
            let playlistFile = playlists.appendingPathComponent("playlist-legacy-write-guard.json")

            // 真的落盘（父目录被自动创建）+ 全部落在注入根内、且不在真容器里。
            let prefix = documents.path + "/"
            for url in [favorites, playlistFile, playerState] {
                #expect(url.path.hasPrefix(prefix), "落点跑到注入根之外：\(url.path)")
                #expect(FileManager.default.fileExists(atPath: url.path), "未落盘：\(url.path)")
                if let real = realDocumentsRoot {
                    #expect(!url.path.hasPrefix(real.path + "/"), "解析到了真机容器：\(url.path)")
                }
            }

            #if os(iOS)
                // 隐藏布局：状态类全部收进 `.qqplayer/state/`，旧根位置一个都不许出现。
                let hidden = Self.scopedRoot(documents)
                #expect(favorites.path == hidden.appendingPathComponent(LibraryRoot.hiddenStateDirectoryName)
                    .appendingPathComponent(LibraryRoot.favoritesFileName).path)
                #expect(playlists.path == hidden.appendingPathComponent(LibraryRoot.hiddenStateDirectoryName)
                    .appendingPathComponent(LibraryRoot.hiddenPlaylistsDirectoryName).path)
                #expect(playerState.path == hidden.appendingPathComponent(LibraryRoot.hiddenStateDirectoryName)
                    .appendingPathComponent(LibraryRoot.playerStateFileName).path)

                let legacyPlaylistsFolder = documents.appendingPathComponent("qqplayer-playlists", isDirectory: true)
                #expect(
                    !FileManager.default.fileExists(atPath: legacyPlaylistsFolder.path),
                    "写入点把旧位置 `Documents/qqplayer-playlists/` 又建了出来"
                )
                #expect(
                    !FileManager.default.fileExists(atPath: documents.appendingPathComponent(LibraryRoot.favoritesFileName).path),
                    "写入点把旧位置 `Documents/qqplayer-favorites.json` 又写了出来"
                )
                #expect(
                    !FileManager.default.fileExists(atPath: documents.appendingPathComponent(LibraryRoot.playerStateFileName).path),
                    "写入点把旧位置 `Documents/qqplayer-player-state.json` 又写了出来"
                )
            #endif

            #expect(
                fileManager.documentDirectoryResolutionCount > resolutionsBefore,
                "StateManager 保存链内部未使用注入 FM（Documents 根经 .default 解析）"
            )
        }
    }

    // MARK: - ① 运行期：歌词库落点

    @Test("歌词库落点：aligned 目录解析到隐藏根，且不等于旧位置")
    func alignedLyricsDirectoryNeverResolvesToLegacyLocation() throws {
        try withDocumentsRoot { documents, fileManager in
            let directory = try #require(AlignedLyricsStore.defaultDirectory(fileManager: fileManager))
            let prefix = documents.path + "/"
            #expect(directory.path.hasPrefix(prefix))
            if let real = realDocumentsRoot {
                #expect(!directory.path.hasPrefix(real.path + "/"))
            }

            // 旧位置（v2 之前的 `Documents/lyrics-aligned/`）**不得**是落点。
            let legacy = documents.appendingPathComponent("lyrics-aligned", isDirectory: true)
            #expect(
                directory.standardizedFileURL.path != legacy.standardizedFileURL.path,
                "aligned 歌词写入点解析到了旧位置：\(directory.path)"
            )

            #if os(iOS)
                let expected = Self.scopedRoot(documents)
                    .appendingPathComponent(LibraryRoot.hiddenLyricsDirectoryName, isDirectory: true)
                    .appendingPathComponent(LibraryRoot.hiddenAlignedLyricsDirectoryName, isDirectory: true)
                #expect(directory.path == expected.path)
            #endif
        }
    }

    // MARK: - ② 形状守卫：源码里的旧位置字面量（fail-closed）

    /// 9 个旧目录名 → **允许**出现该字符串字面量的文件（相对仓库根）。
    ///
    /// 只有两类文件可出现在这里：
    ///  · **迁移映射表**（`LibraryLayoutMigrationPlan` / `LibraryLayoutMigrationV2Plan`）：名字是搬迁的**源**；
    ///  · **只读兼容**（`LibraryRoot` 的 macOS 现状数组与常量、`AlignedLyricsStore` / `LyricsManager` /
    ///    `StateManager` / `LyricsSearch` 的 legacy 只读兜底）。
    /// 写入侧文件（`SpotifyAPI` / `DiscogsAPI` / `HybridMusicAPI` / `AppLog` / `DatabaseManager` /
    /// `SyncConnectDiag` …）**一个都不许**：它们的落点必须经 `LibraryRoot`。
    static let legacyNameAllowedFiles: [String: Set<String>] = [
        "ArtworkCache": [
            "QQPlayer/Services/LibraryLayoutMigrationPlan.swift",
            "QQPlayer/Services/LibraryLayoutMigrationV2Plan.swift",
        ],
        "ArtworkMapping.plist": [
            "QQPlayer/Services/LibraryRoot.swift",
        ],
        "SpotifyCache": [
            "QQPlayer/Services/LibraryLayoutMigrationV2Plan.swift",
            "QQPlayer/Services/MacDocumentsStorageRelocation.swift",
            "QQPlayer/Services/SpotifyAPI.swift",
        ],
        "DiscogsCache": [
            "QQPlayer/Services/DiscogsAPI.swift",
            "QQPlayer/Services/LibraryLayoutMigrationV2Plan.swift",
            "QQPlayer/Services/MacDocumentsStorageRelocation.swift",
        ],
        "HybridMusicCache": [
            "QQPlayer/Services/HybridMusicAPI.swift",
            "QQPlayer/Services/LibraryLayoutMigrationV2Plan.swift",
            "QQPlayer/Services/MacDocumentsStorageRelocation.swift",
        ],
        "lyrics-aligned": [
            "QQPlayer/Services/AlignedLyricsStore.swift",
            "QQPlayer/Services/LibraryLayoutMigrationV2Plan.swift",
            "QQPlayer/Services/LibraryRoot.swift",
            "QQPlayer/Services/MacDocumentsStorageRelocation.swift",
        ],
        "lyrics-manual": [
            "QQPlayer/Services/LibraryLayoutMigrationPlan.swift",
            "QQPlayer/Services/LibraryLayoutMigrationV2Plan.swift",
            "QQPlayer/Services/LyricsManager.swift",
        ],
        "lyrics-cache": [
            "QQPlayer/Services/AlignedLyricsStore.swift",
            "QQPlayer/Services/LibraryLayoutMigrationV2Plan.swift",
            "QQPlayer/Services/LibraryRoot.swift",
            "QQPlayer/Services/LyricsSearch.swift",
            "QQPlayer/Services/MacDocumentsStorageRelocation.swift",
        ],
        "qqplayer-playlists": [
            "QQPlayer/Services/LibraryLayoutMigrationV2Plan.swift",
            "QQPlayer/Services/LibraryRoot.swift",
            "QQPlayer/Services/MacDocumentsStorageRelocation.swift",
            "QQPlayer/Services/StateManager.swift",
        ],
    ]

    /// 写入侧文件的**落点必须经 `LibraryRoot`**（回归判据：改回 `Documents/<旧名>` 即红）。
    static let writerResolverRequirements: [String: String] = [
        "QQPlayer/Services/SpotifyAPI.swift": "LibraryRoot.scratchCacheDirectoryURL",
        "QQPlayer/Services/DiscogsAPI.swift": "LibraryRoot.scratchCacheDirectoryURL",
        "QQPlayer/Services/HybridMusicAPI.swift": "LibraryRoot.scratchCacheDirectoryURL",
        "QQPlayer/Services/LyricsSearchCache.swift": "LibraryRoot.scratchLyricsSearchCacheDirectoryURL",
        "QQPlayer/Services/AppLog.swift": "LibraryRoot.logsDirectoryURL",
        "QQPlayer/Services/DatabaseManager.swift": "LibraryRoot.logsDirectoryURL",
        "QQPlayer/Services/SyncConnectDiag.swift": "LibraryRoot.logsDirectoryURL",
        "QQPlayer/Services/InterruptionDiagnostics.swift": "LibraryRoot.logsDirectoryURL",
        "QQPlayer/Services/ArtworkManager.swift": "LibraryRoot.artworkDirectoryURL",
        "QQPlayer/Services/AlignedLyricsStore.swift": "LibraryRoot.alignedLyricsDirectoryURL",
        "QQPlayer/Services/LyricsManager.swift": "LibraryRoot.manualLyricsDirectoryURL",
        "QQPlayer/Services/LyricsSearch.swift": "LibraryRoot.lyricsCacheTracksDirectoryURL",
        "QQPlayer/Services/StateManager.swift": "LibraryRoot.playlistsDirectoryURL",
    ]

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// 仓库内某相对路径的文件内容（读不到 = 直接抛错 ⇒ 守卫判红，不静默通过）。
    private static func source(at relativePath: String) throws -> String {
        try String(contentsOf: repositoryRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// `QQPlayer/` 下全部 `.swift`（相对仓库根升序）。
    private static func scannedSwiftFiles() throws -> [String] {
        let root = repositoryRoot.appendingPathComponent("QQPlayer", isDirectory: true)
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]),
            "QQPlayer/ 不可枚举（守卫 fail-closed）"
        )
        let rootPrefix = root.path + "/"
        var result: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append("QQPlayer/" + url.path.replacingOccurrences(of: rootPrefix, with: ""))
        }
        return result.sorted()
    }

    @Test("形状守卫：旧目录名字面量只出现在迁移映射表 / 只读兼容文件里")
    func legacyDirectoryLiteralsConfinedToMigrationAndReadOnlyHelpers() throws {
        let files = try Self.scannedSwiftFiles()
        #expect(!files.isEmpty, "扫描结果为空（守卫 fail-closed）")

        var contents: [String: String] = [:]
        for file in files {
            contents[file] = try Self.source(at: file)
        }

        var violations: [String] = []
        for (name, allowed) in Self.legacyNameAllowedFiles.sorted(by: { $0.key < $1.key }) {
            // 只认**字符串字面量**（`"<name>"` / `"<name>/…"`），注释里的裸名字不计。
            let needles = ["\"\(name)\"", "\"\(name)/"]
            for (file, text) in contents.sorted(by: { $0.key < $1.key }) {
                guard needles.contains(where: { text.contains($0) }) else { continue }
                if !allowed.contains(file) {
                    violations.append("\(file) 出现旧目录名字面量 `\(name)`（允许的文件：\(allowed.sorted().joined(separator: ", "))）")
                }
            }
        }
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }

    @Test("形状守卫：写入侧落点必须经 LibraryRoot 解析（改回 Documents/<旧名> 即红）")
    func writerResolversGoThroughLibraryRoot() throws {
        for (file, requiredSymbol) in Self.writerResolverRequirements.sorted(by: { $0.key < $1.key }) {
            let text = try Self.source(at: file)
            #expect(text.contains(requiredSymbol), "\(file) 的落点未走 \(requiredSymbol)")
        }
    }
}
