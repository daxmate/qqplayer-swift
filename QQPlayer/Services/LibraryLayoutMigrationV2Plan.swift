//
//  LibraryLayoutMigrationV2Plan.swift
//  QQPlayer
//
// target: ios-only（迁移执行器与消费端全在 iOS；macOS 曲库根在 `~/Music/QQPlayer`，
// 根部布局与隐藏根无关 ⇒ 本文件不参与 macOS 行为）
//
//  「**只留 `Music/` 可见**」迁移（v2）的**纯逻辑**：给定「Documents 根现有什么条目」、
//  「目标位置已存在什么」、「哪些条目被 DB 绝对路径引用」，产出每个条目要不要搬 / 搬到哪。
//  零 IO、可单测；执行器只负责按计划落地（见 `LibraryLayoutMigrationV2Migrator`）。
//
//  用户口径（2026-09-22 15:0x 拍板）：
//   · 「除了歌曲之类的跟 APP 运行有关的内容，这些裸露在外面挺不好的，可以放在隐藏文件夹中。」
//   · 「好的，**只有 Music 可见**。」
//
//  目标树（唯一可见 = `Music/`）：
//    Documents/
//      Music/                 ← 唯一可见（曲库；单层扫描；track.path 仍相对 Music 根）
//      .qqplayer/             ← 隐藏根
//        db/  state/  artwork/  lyrics/  logs/  meta/  cache/  trash/
//
//  —— 与 v1 的关系 ——
//  v1（`LibraryLayoutMigrationPlan`）把根部**规划类文件**搬进 `Documents/{Music,Lyrics,Artwork,Logs}`；
//  v2 把 `Documents/` 下**除 `Music/` 以外的一切**收进隐藏根（v1 建的那几个目录本身也在 v2 的搬迁
//  范围内）。两道完成门互不干扰（`library.layoutMigrationCompleted.v1` / `…V2Completed.v1`），
//  v2 在 v1 之后跑。**v2 不改 `track.path`**：`Music/` 未动、`track.path` 仍相对 `Music` 根，
//  因此不存在 v1 那种「先搬文件后改 DB」的顺序问题。
//
//  —— 硬约束 ——
//   · **只搬不删**：全程只有 move；搬不动的留在原处并记账。
//   · **冲突不覆盖**：目标已存在 → 跳过、保留原件。
//   · **未规划条目不动**：不在映射表里的根条目一律保留（保守，记入 `kept`）。
//   · **同步协议目录不动**：`.sync-incoming/` 属同步链路语义（曲库根内隐藏目录），
//     保留原位（见 `keepInPlaceReasons`）。
//

import Foundation

/// v2 迁移规则（映射表的唯一事实源）。
enum LibraryLayoutMigrationV2Rules {
    /// 隐藏根下的一级子目录。
    enum Destination: String, CaseIterable, Sendable {
        case database
        case state
        case artwork
        case lyrics
        case logs
        case meta
        case cache
        case trash

        /// 目录名（取 `LibraryRoot` 常量，别处不写字面量）。
        var directoryName: String {
            switch self {
            case .database: return LibraryRoot.hiddenDatabaseDirectoryName
            case .state: return LibraryRoot.hiddenStateDirectoryName
            case .artwork: return LibraryRoot.hiddenArtworkDirectoryName
            case .lyrics: return LibraryRoot.hiddenLyricsDirectoryName
            case .logs: return LibraryRoot.hiddenLogsDirectoryName
            case .meta: return LibraryRoot.hiddenMetaDirectoryName
            case .cache: return LibraryRoot.hiddenCacheDirectoryName
            case .trash: return LibraryRoot.hiddenTrashDirectoryName
            }
        }
    }

    /// 一个根条目的归类结果。
    enum Classification: Equatable {
        /// 搬到 `destinationRelativePath`（相对 Documents 根）。
        case move(destinationRelativePath: String)
        /// 保留原位（`reason` 进报告与日志）。
        case keep(reason: String)
    }

    // MARK: - 保留原位

    /// 根部必须保留的条目及原因。
    static let keepInPlaceReasons: [String: String] = [
        LibraryRoot.musicDirectoryName: "visibleLibraryRoot",
        LibraryRoot.hiddenRootDirectoryName: "hiddenRootTarget",
        ".sync-incoming": "syncProtocolIncomingDirectory",
    ]

    /// 根上的 DB 三件套：由 `DatabaseManager` 在**打开连接之前**搬（不在本迁移器职责内）。
    static let databaseFileNames: Set<String> = [
        LibraryRoot.musicLibraryFileName,
        "\(LibraryRoot.musicLibraryFileName)-shm",
        "\(LibraryRoot.musicLibraryFileName)-wal",
    ]

    // MARK: - 映射表

    /// 隐藏根下相对路径（`[.qqplayer] + components`）。
    static func hiddenRelativePath(_ components: [String]) -> String {
        ([LibraryRoot.hiddenRootDirectoryName] + components).joined(separator: "/")
    }

    /// 根**文件**名 → 目标相对路径。
    ///
    /// ⚠️ DB 三件套（`.sqlite` / `-shm` / `-wal`）**刻意不在此表**：它们由 `DatabaseManager`
    /// 在**打开连接之前**迁进 `.qqplayer/db/`（见 `keepInPlaceReasons` 的
    /// `handledByDatabaseRelocation`）—— 移动打开中的 WAL/SHM 有一致性风险，归 DB 层所有。
    static let rootFileDestinations: [String: String] = [
        LibraryRoot.favoritesFileName: hiddenRelativePath([
            Destination.state.directoryName, LibraryRoot.favoritesFileName,
        ]),
        LibraryRoot.playerStateFileName: hiddenRelativePath([
            Destination.state.directoryName, LibraryRoot.playerStateFileName,
        ]),
        LibraryRoot.pairingFileName: hiddenRelativePath([
            Destination.state.directoryName, LibraryRoot.pairingFileName,
        ]),
        LibraryRoot.externalBookmarksFileName: hiddenRelativePath([
            Destination.state.directoryName, LibraryRoot.externalBookmarksFileName,
        ]),
        LibraryRoot.appLogFileName: hiddenRelativePath([
            Destination.logs.directoryName, LibraryRoot.appLogFileName,
        ]),
        LibraryRoot.dbDebugLogFileName: hiddenRelativePath([
            Destination.logs.directoryName, LibraryRoot.dbDebugLogFileName,
        ]),
        LibraryRoot.interruptionDebugLogFileName: hiddenRelativePath([
            Destination.logs.directoryName, LibraryRoot.interruptionDebugLogFileName,
        ]),
        LibraryRoot.syncDiagnosticsLogFileName: hiddenRelativePath([
            Destination.logs.directoryName, LibraryRoot.syncDiagnosticsLogFileName,
        ]),
    ]

    /// 根目录名 → 目标相对路径（**整体搬迁**，不改目录名以外的东西）。
    static let rootDirectoryDestinations: [String: String] = [
        "qqplayer-playlists": hiddenRelativePath([
            Destination.state.directoryName, LibraryRoot.hiddenPlaylistsDirectoryName,
        ]),
        // v1 建的目标目录，v2 收进隐藏根（内容构成不变，仅父目录下沉）。
        LibraryRoot.artworkDirectoryName: hiddenRelativePath([Destination.artwork.directoryName]),
        "ArtworkCache": hiddenRelativePath([
            Destination.artwork.directoryName, "cache",
        ]),
        LibraryRoot.lyricsDirectoryName: hiddenRelativePath([
            Destination.lyrics.directoryName, LibraryRoot.hiddenManualLyricsDirectoryName,
        ]),
        "lyrics-aligned": hiddenRelativePath([
            Destination.lyrics.directoryName, LibraryRoot.hiddenAlignedLyricsDirectoryName,
        ]),
        "lyrics-cache": hiddenRelativePath([
            Destination.lyrics.directoryName, LibraryRoot.hiddenLyricsCacheDirectoryName,
        ]),
        "lyrics-manual": hiddenRelativePath([
            Destination.lyrics.directoryName, LibraryRoot.hiddenLegacyManualLyricsDirectoryName,
        ]),
        LibraryRoot.logsDirectoryName: hiddenRelativePath([Destination.logs.directoryName]),
        "meta": hiddenRelativePath([Destination.meta.directoryName]),
        "SpotifyCache": hiddenRelativePath([
            Destination.cache.directoryName, "SpotifyCache",
        ]),
        "DiscogsCache": hiddenRelativePath([
            Destination.cache.directoryName, "DiscogsCache",
        ]),
        "HybridMusicCache": hiddenRelativePath([
            Destination.cache.directoryName, "HybridMusicCache",
        ]),
        "qqplayer-assets": hiddenRelativePath([
            Destination.cache.directoryName, "qqplayer-assets",
        ]),
        ".Trash": hiddenRelativePath([Destination.trash.directoryName]),
    ]

    /// 根部日志归档名（`app.log.N`）→ 也归 `logs/`。
    static func isLogArchiveName(_ name: String) -> Bool {
        guard name.hasPrefix("\(LibraryRoot.appLogFileName).") else { return false }
        let suffix = name.dropFirst(LibraryRoot.appLogFileName.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// 根**文件**名 → 目标相对路径（含日志归档；`.log` / `.txt` 诊断文件都归 `logs/`）。
    static func rootFileDestination(_ name: String) -> String? {
        if let known = rootFileDestinations[name] { return known }
        if isLogArchiveName(name) {
            return hiddenRelativePath([Destination.logs.directoryName, name])
        }
        if ["eq-debug.log", "karaoke-debug.log", "iCloudDiagnostics.txt"].contains(name) {
            return hiddenRelativePath([Destination.logs.directoryName, name])
        }
        return nil
    }

    /// 分类一个根部条目。
    static func classify(rootEntryName name: String, isDirectory: Bool) -> Classification {
        if let reason = keepInPlaceReasons[name] { return .keep(reason: reason) }
        // DB 三件套：归 DB 层（打开连接前搬迁），本迁移器不碰。
        if !isDirectory, databaseFileNames.contains(name) {
            return .keep(reason: "handledByDatabaseRelocation")
        }
        // 隐藏条目（`.` 开头）只有显式登记过才动 —— 未登记的隐藏条目一律保留
        // （协议目录、系统目录等，不为整齐去动）。
        if name.hasPrefix(".") {
            guard let destination = rootDirectoryDestinations[name], isDirectory else {
                return .keep(reason: "unplannedHiddenEntry")
            }
            return .move(destinationRelativePath: destination)
        }
        if isDirectory {
            guard let destination = rootDirectoryDestinations[name] else {
                return .keep(reason: "unplannedDirectory")
            }
            return .move(destinationRelativePath: destination)
        }
        guard let destination = rootFileDestination(name) else {
            return .keep(reason: "unplannedFile")
        }
        return .move(destinationRelativePath: destination)
    }
}

/// v2 迁移计划（纯值；执行器照它落地）。
struct LibraryLayoutMigrationV2Plan: Equatable {
    /// 一次搬迁（源 = 根条目名，目标 = 相对 Documents 根的目标路径）。
    struct Move: Equatable {
        let sourceRelativePath: String
        let destinationRelativePath: String
    }

    /// 跳过（原因进日志与干跑清单）。
    struct Skip: Equatable {
        let sourceRelativePath: String
        /// `targetExists` / `referencedByStoredPath`
        let reason: String
    }

    var moves: [Move] = []
    var skips: [Skip] = []
    /// 保留原位的条目（`name(reason)`；含 Music / 隐藏根 / 同步目录 / 未规划项）。
    var kept: [String] = []

    var isEmpty: Bool { moves.isEmpty && skips.isEmpty }
}

/// 计划生成器（纯函数；输入全部注入，无 IO）。
enum LibraryLayoutMigrationV2Planner {
    /// 根目录下的一个条目事实。
    struct RootEntry: Equatable {
        let name: String
        let isDirectory: Bool
    }

    /// 生成计划。
    ///
    /// - `existingDestinationRelativePaths`：目标位置**已存在**的路径（文件或目录）→ 冲突则跳过、不覆盖。
    /// - `referencedSourceRelativePaths`：被 DB 绝对存储路径引用的根条目名 → **不搬**（保守，防引用悬空）。
    ///
    /// 顺序：按目标路径**层数升序**（浅的先搬）—— 保证「父目标由整目录搬迁自然产生」，
    /// 避免先建出的父目录把后面整目录的搬迁误判成冲突。
    static func makePlan(
        rootEntries: [RootEntry],
        existingDestinationRelativePaths: Set<String>,
        referencedSourceRelativePaths: Set<String> = []
    ) -> LibraryLayoutMigrationV2Plan {
        var plan = LibraryLayoutMigrationV2Plan()
        var moves: [LibraryLayoutMigrationV2Plan.Move] = []

        for entry in rootEntries {
            switch LibraryLayoutMigrationV2Rules.classify(rootEntryName: entry.name, isDirectory: entry.isDirectory) {
            case let .keep(reason):
                plan.kept.append("\(entry.name)(\(reason))")
            case let .move(destination):
                if referencedSourceRelativePaths.contains(entry.name) {
                    plan.skips.append(
                        LibraryLayoutMigrationV2Plan.Skip(
                            sourceRelativePath: entry.name, reason: "referencedByStoredPath"
                        )
                    )
                    continue
                }
                if existingDestinationRelativePaths.contains(destination) {
                    plan.skips.append(
                        LibraryLayoutMigrationV2Plan.Skip(
                            sourceRelativePath: entry.name, reason: "targetExists"
                        )
                    )
                    continue
                }
                moves.append(
                    LibraryLayoutMigrationV2Plan.Move(
                        sourceRelativePath: entry.name, destinationRelativePath: destination
                    )
                )
            }
        }

        moves.sort { lhs, rhs in
            let lhsDepth = lhs.destinationRelativePath.split(separator: "/").count
            let rhsDepth = rhs.destinationRelativePath.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.sourceRelativePath < rhs.sourceRelativePath
        }
        plan.moves = moves
        return plan
    }
}
