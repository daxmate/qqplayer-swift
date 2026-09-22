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
//   · **只搬不删**：全程只有 move（含改名）；搬不动的留在原处并记账。
//   · **冲突不覆盖**：目标已存在 → 见下（目录合并 / 文件改名），**绝不覆盖、绝不删除**。
//   · **未规划条目不动**：不在映射表里的根条目一律保留（保守，记入 `kept`）。
//   · **同步协议目录不动**：`.sync-incoming/` 属同步链路语义（曲库根内隐藏目录），
//     保留原位（见 `keepInPlaceReasons`）。
//
//  —— v2.1 修正：冲突要「合并」，不是「整项跳过」——
//  真机失败证据（2026-09-22，设备 `00dax's iPhone`，v2 `03f867e`）：启动期各组件
//  （`ArtworkManager` / 各 API 缓存 / 状态与日志）**先**把隐藏目标目录建好，迁移**后**跑，
//  于是 10 个根条目一律命中「目标已存在 ⇒ 整项跳过」而留在 `Documents/` 根上：
//  `Artwork/ Logs/ Lyrics/ lyrics-cache/ qqplayer-playlists/ SpotifyCache/ DiscogsCache/`
//  `HybridMusicCache/ app.log db-debug.log`。
//  · 对**目录**：目标目录已存在 ⇒ **递归合并**（逐子项处理），子项同名 ⇒ **改名后缀**
//    （`<name>.legacy-<yyyyMMdd-HHmmss>`）搬入；合并后源目录成空壳 ⇒ 空壳也**不删**，
//    改名后缀搬进隐藏回收区 `trash/`。
//  · 对**同名文件**（`app.log` / `db-debug.log` 与新位置同名）⇒ 同样改名后缀搬入。
//  最终目标不变：**根上不留任何可搬条目**，且旧数据一个字节不丢。
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

    // MARK: - 冲突改名（v2.1：目标同名 ⇒ 改名后缀搬入，绝不覆盖）

    /// 改名后缀前缀（`app.log` → `app.log.legacy-20260922-153000`）。
    static let legacySuffixPrefix = ".legacy-"

    /// 改名后缀的时间戳（`yyyyMMdd-HHmmss`，设备本地时区）—— 后缀的**唯一生成点**。
    /// 一轮迁移只取一次（同一轮内所有改名共用同一个 ts，便于人工按批次识别）。
    static func legacyTimestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// 目标名 → 改名后的名字。**调用方负责确认落点可用**（本函数不探盘）。
    static func legacyName(_ name: String, timestamp: String, attempt: Int = 1) -> String {
        let base = "\(name)\(legacySuffixPrefix)\(timestamp)"
        return attempt <= 1 ? base : "\(base)-\(attempt)"
    }

    /// 目标同名文件的改名落点（同父目录 + 后缀）。
    static func legacySiblingPath(of destinationRelativePath: String, timestamp: String) -> String {
        let components = destinationRelativePath.split(separator: "/").map(String.init)
        guard let name = components.last else { return destinationRelativePath }
        let renamed = legacyName(name, timestamp: timestamp)
        return (components.dropLast() + [renamed]).joined(separator: "/")
    }

    /// 合并后空壳目录的落点：隐藏回收区 `trash/` 下的改名条目
    /// （只搬不删 —— 空壳也不删，改名后移入回收区，根目录才干净）。
    static func shellSweepDestination(sourceRelativePath: String, timestamp: String) -> String {
        let name = sourceRelativePath.split(separator: "/").last.map(String.init) ?? sourceRelativePath
        return hiddenRelativePath([Destination.trash.directoryName, legacyName(name, timestamp: timestamp)])
    }

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
        LibraryRoot.trashDirectoryName: hiddenRelativePath([Destination.trash.directoryName]),
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
    /// 一次搬迁（源 = 根条目名 / 合并后的子项相对路径，目标 = 相对 Documents 根）。
    struct Move: Equatable {
        let sourceRelativePath: String
        let destinationRelativePath: String
        /// 目标同名已存在 ⇒ 用了改名后缀（`<name>.legacy-<ts>`）搬入，**绝不覆盖**。
        let renamed: Bool
    }

    /// 跳过（原因进日志与干跑清单）。
    struct Skip: Equatable {
        let sourceRelativePath: String
        /// `referencedByStoredPath` / `unreadableSourceDirectory`
        let reason: String
    }

    /// 合并后剩下的**空壳目录**（内容已全部规划搬入）→ 改名后缀搬进隐藏回收区。
    /// 只搬不删：空壳不删，搬走后根目录才干净，且一个字节没丢。
    struct ShellSweep: Equatable {
        let sourceRelativePath: String
        let destinationRelativePath: String
    }

    var moves: [Move] = []
    var skips: [Skip] = []
    /// 保留原位的条目（`name(reason)`；含 Music / 隐藏根 / 同步目录 / 未规划项）。
    var kept: [String] = []
    var shellSweeps: [ShellSweep] = []

    var isEmpty: Bool { moves.isEmpty && skips.isEmpty && shellSweeps.isEmpty }
    /// 其中「改名搬入」的件数（其余为原样搬入）。
    var renamedCount: Int { moves.filter(\.renamed).count }
    /// 干跑与真跑共用的一行计划账（口径只有这一份）。
    var planLine: String {
        "将要搬 \(moves.count)（其中改名搬入 \(renamedCount)）/ 跳过 \(skips.count) / 空壳清扫 \(shellSweeps.count)"
    }

    /// 本轮跑完后根上仍「该搬未搬」的条目（完成门判据；`referencedByStoredPath` 例外不计入）。
    var residueSourceRelativePaths: [String] {
        (moves.map(\.sourceRelativePath) + shellSweeps.map(\.sourceRelativePath)).sorted()
    }
}

/// 计划生成器（纯函数；目录 IO 经 `DirectoryView` 注入 ⇒ 本类型自身零 IO）。
enum LibraryLayoutMigrationV2Planner {
    /// 一个条目事实。
    struct RootEntry: Equatable {
        let name: String
        let isDirectory: Bool
    }

    /// 目录树只读视图（IO 由调用方注入 ⇒ 规划器零 IO、可纯逻辑单测）。
    struct DirectoryView {
        /// 路径（相对 Documents 根，POSIX）是否存在（文件或目录均可）。
        let exists: (String) -> Bool
        /// 目录的直接子项；不存在 / 不是目录 / 读失败 → nil（**空目录 → `[]`**）。
        let children: (String) -> [RootEntry]?
    }

    /// 规划输入。
    struct Inputs {
        /// Documents 根的一级条目（含隐藏条目）。
        var rootEntries: [RootEntry]
        /// 被 DB 绝对存储路径引用的根条目名 → **不搬**（保守，防引用悬空）。
        var referencedSourceRelativePaths: Set<String> = []
        /// 改名后缀的时间戳（同一轮内唯一）。
        var timestamp: String = LibraryLayoutMigrationV2Rules.legacyTimestamp()
        /// 源侧视图（Documents 根子树）。
        var source: DirectoryView
        /// 目标侧视图（隐藏根子树）。
        var destination: DirectoryView
    }

    /// 生成计划。
    ///
    /// 冲突处理（v2.1）：目标已存在时 **不整项跳过**——
    /// · 源与目标**都是目录** ⇒ 递归合并（逐子项）；同名子项 ⇒ 改名后缀搬入；
    /// · 同名**文件** / 类型不匹配 ⇒ 改名后缀搬入。
    /// 全程 **绝不覆盖、绝不删除**；合并后的空壳目录另列 `shellSweeps`（改名搬进 `trash/`）。
    ///
    /// 顺序：搬迁按目标路径**层数升序**（浅的先搬，父目标由整目录/子项搬迁自然产生）；
    /// 空壳清扫按源路径**层数降序**（内层空壳先搬，外层才可能空）。
    static func makePlan(_ inputs: Inputs) -> LibraryLayoutMigrationV2Plan {
        var plan = LibraryLayoutMigrationV2Plan()

        for entry in inputs.rootEntries {
            switch LibraryLayoutMigrationV2Rules.classify(
                rootEntryName: entry.name, isDirectory: entry.isDirectory
            ) {
            case let .keep(reason):
                plan.kept.append("\(entry.name)(\(reason))")
            case let .move(destination):
                if inputs.referencedSourceRelativePaths.contains(entry.name) {
                    plan.skips.append(
                        LibraryLayoutMigrationV2Plan.Skip(
                            sourceRelativePath: entry.name, reason: "referencedByStoredPath"
                        )
                    )
                    continue
                }
                planEntry(
                    entry,
                    sourceRelativePath: entry.name,
                    destinationRelativePath: destination,
                    inputs: inputs,
                    into: &plan
                )
            }
        }

        plan.moves.sort { lhs, rhs in
            let lhsDepth = lhs.destinationRelativePath.split(separator: "/").count
            let rhsDepth = rhs.destinationRelativePath.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
            return lhs.sourceRelativePath < rhs.sourceRelativePath
        }
        plan.shellSweeps.sort { lhs, rhs in
            let lhsDepth = lhs.sourceRelativePath.split(separator: "/").count
            let rhsDepth = rhs.sourceRelativePath.split(separator: "/").count
            if lhsDepth != rhsDepth { return lhsDepth > rhsDepth }
            return lhs.sourceRelativePath < rhs.sourceRelativePath
        }
        return plan
    }

    /// 规划单个条目（递归；合并路径下 `entry` 是**子项**，源/目标都是完整相对路径）。
    private static func planEntry(
        _ entry: RootEntry,
        sourceRelativePath: String,
        destinationRelativePath: String,
        inputs: Inputs,
        into plan: inout LibraryLayoutMigrationV2Plan
    ) {
        // 目标不存在 ⇒ 原样搬（目录 = 整目录一次 rename，保持原子）。
        guard inputs.destination.exists(destinationRelativePath) else {
            plan.moves.append(
                LibraryLayoutMigrationV2Plan.Move(
                    sourceRelativePath: sourceRelativePath,
                    destinationRelativePath: destinationRelativePath,
                    renamed: false
                )
            )
            return
        }
        // 目标已存在且**双方都是目录** ⇒ 递归合并（整目录跳过是错的：会把内容留在根上）。
        if entry.isDirectory,
           inputs.destination.children(destinationRelativePath) != nil,
           let children = inputs.source.children(sourceRelativePath) {
            for child in children {
                planEntry(
                    child,
                    sourceRelativePath: "\(sourceRelativePath)/\(child.name)",
                    destinationRelativePath: "\(destinationRelativePath)/\(child.name)",
                    inputs: inputs,
                    into: &plan
                )
            }
            // 内容全部规划搬入 ⇒ 源目录必成空壳；空壳不删，改名后缀搬进隐藏回收区。
            plan.shellSweeps.append(
                LibraryLayoutMigrationV2Plan.ShellSweep(
                    sourceRelativePath: sourceRelativePath,
                    destinationRelativePath: LibraryLayoutMigrationV2Rules.shellSweepDestination(
                        sourceRelativePath: sourceRelativePath, timestamp: inputs.timestamp
                    )
                )
            )
            return
        }
        // 同名**文件**冲突 / 类型不匹配 ⇒ 改名后缀搬入（绝不覆盖，根目录仍被清空）。
        plan.moves.append(
            LibraryLayoutMigrationV2Plan.Move(
                sourceRelativePath: sourceRelativePath,
                destinationRelativePath: LibraryLayoutMigrationV2Rules.legacySiblingPath(
                    of: destinationRelativePath, timestamp: inputs.timestamp
                ),
                renamed: true
            )
        )
    }
}
