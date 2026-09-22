//
//  LibraryLayoutMigrationPlan.swift
//  QQPlayer
//
// target: ios-only（本文件被 `LibraryLayoutMigrator` 与 iOS 单测消费；消费端全在 iOS）
//
//  曲库文件夹化（2026-09-22）**一次性迁移的纯逻辑**：给定「Documents 根现有什么」、
//  「DB 里现有哪几种 path」，产出每个文件要不要搬 / 搬到哪 / 哪些行要改 path。
//  零 IO、平台无关、可单测；执行器只负责按计划落地（见 `LibraryLayoutMigrator`）。
//
//  用户口径（2026-09-22 13:1x 拍板，逐条落在这里）：
//   ① `Documents/` 文件夹化：`Music/`（曲库）、`Lyrics/`（手工歌词）、`Artwork/`（封面缓存）、
//      `Logs/`（app.log / db-debug.log 等）；
//   ② 曲库扫描只认 `Documents/Music`，且 **Music 下不再有子目录**（单层，不递归）；
//   ③ `track.path` 存「相对 Music 根」的相对路径；
//   ④ 现有曲目（在 Documents 根）首启自动搬：幂等、可重入、**失败不删原件**；
//   ⑤ **未规划文件一律不动**；Music 下若已有历史子目录，本批不递归、不搬平。
//
//  本批**只搬文件、不搬目录、不删目录**：
//   · Documents 根下的目录（含历史 `Music/<子目录>`）一律不动；
//   · 目标同名冲突 → 不覆盖、保留原件、计入「跳过」。
//

import Foundation

/// 迁移规则（分类的唯一事实源）。
enum LibraryLayoutMigrationRules {
    /// 规划目录是哪个（nil = **未规划 → 一律不动**，用户口径 ⑤）。
    enum Category: String, CaseIterable, Sendable {
        case music
        case lyrics
        case artwork
        case logs

        /// 目标目录名（取 `LibraryRoot` 常量，别处不写字面量）。
        var directoryName: String {
            switch self {
            case .music: return LibraryRoot.musicDirectoryName
            case .lyrics: return LibraryRoot.lyricsDirectoryName
            case .artwork: return LibraryRoot.artworkDirectoryName
            case .logs: return LibraryRoot.logsDirectoryName
            }
        }
    }

    /// 改名前的旧目录（每个 = 一个「目录内容整体搬进规划目录」的源）。
    /// 只列**目录**：其内部文件搬到 `category`，不搬目录本身、不留残留目录（空目录保留）。
    static let legacyDirectories: [(name: String, category: Category)] = [
        ("lyrics-manual", .lyrics),
        ("ArtworkCache", .artwork),
    ]

    /// 改名前的旧文件（Documents 根直接躺着、且属于规划类的文件）→ 目标类别。
    static let legacyRootFileNames: [(name: String, category: Category)] = [
        (LibraryRoot.artworkMappingFileName, .artwork),
    ]

    /// 封面映射表是**元数据**，不是待搬文件 / 缓存文件。
    ///
    /// 映射表的读写唯一入口是 `ArtworkManager`（它持有内存副本 + 去抖写盘；
    /// 背着它改 plist 会被下一次 `saveMapping()` 覆盖回去 —— 同 `TrackIdentityMigration` 口径）：
    /// "旧位置 ∪ 新位置"的合并由它在启动时（`loadMapping`）完成并落到新位置，每次都跑。
    ///
    /// 一次性迁移器**不得**把它当普通文件搬：
    ///   · 搬进 `Artwork/` 后会与「缓存清理把该目录当纯缓存」叠加 ⇒ 映射表被当孤儿删（2026-09-22 回归），
    ///   · 目标已存在而整项跳过 ⇒ 旧位置成为**读不到的**死文件（`loadMapping` 以新位置优先）。
    static func isArtworkMappingFileName(_ name: String) -> Bool {
        name == LibraryRoot.artworkMappingFileName
    }

    /// Documents 根下的日志文件名（固定名）。
    static let legacyLogFileNames: Set<String> = [
        "app.log",
        "db-debug.log",
        "intr-debug.log",
        "sync-diag.log",
    ]

    /// 日志归档命名（`LogRotation` 口径：`app.log.N`）→ 也归 `Logs/`。
    static func isLogArchiveName(_ name: String) -> Bool {
        guard name.hasPrefix("app.log.") else { return false }
        let suffix = name.dropFirst("app.log.".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
    }

    /// 分类：Documents 根下的一个文件（含旧目录内的文件）→ 目标类别（nil = 未规划，不动）。
    ///
    /// - Parameters:
    ///   - rootFileName: Documents 根下的文件名（旧目录内的文件传目录名 + `/` + 文件名）
    ///   - directoryName: 该文件所在子目录名（nil = 直接在 Documents 根）
    ///   - enabledAudioExtensions: 当前收录的音频扩展名（小写）
    static func category(
        rootFileName name: String,
        directoryName: String?,
        enabledAudioExtensions: [String]
    ) -> Category? {
        if let directoryName {
            guard let legacy = legacyDirectories.first(where: { $0.name == directoryName }) else {
                return nil // 未规划目录（如 lyrics-cache/）→ 不动
            }
            return legacy.category
        }
        if enabledAudioExtensions.contains((name as NSString).pathExtension.lowercased()) {
            return .music
        }
        if legacyLogFileNames.contains(name) || isLogArchiveName(name) {
            return .logs
        }
        if let legacy = legacyRootFileNames.first(where: { $0.name == name }) {
            return legacy.category
        }
        return nil
    }
}

/// 迁移计划（纯值；执行器照它落地）。
struct LibraryLayoutMigrationPlan: Equatable {
    /// 一个候选搬迁项（源 = Documents 相对路径，目标 = `<目标目录>/<文件名>`）。
    struct Move: Equatable {
        let category: LibraryLayoutMigrationRules.Category
        /// 相对 Documents 根的源路径（`song.flac` / `lyrics-manual/abc.json`）。
        let sourceRelativePath: String
        /// 目标目录名（`Music` / `Lyrics` / `Artwork` / `Logs`）。
        let destinationDirectory: String
        /// 目标下文件名。
        let destinationName: String
    }

    /// 跳过项（原因进日志与干跑清单）。
    struct Skip: Equatable {
        let sourceRelativePath: String
        /// `targetExistsSameSize` / `targetExistsDifferentSize`
        let reason: String
    }

    /// DB path 改写（旧绝对路径 → 相对 Music 根）。
    struct PathRewrite: Equatable {
        let stableId: String
        let oldStoredPath: String
        let newStoredPath: String
    }

    var moves: [Move] = []
    var skips: [Skip] = []
    var rewrites: [PathRewrite] = []

    /// 本次要建的规划目录名（顺序稳定）。
    var directories = LibraryRoot.plannedDirectoryNames

    var isEmpty: Bool { moves.isEmpty && skips.isEmpty && rewrites.isEmpty }
}

/// 计划生成器（纯函数；输入全部注入，无 IO）。
enum LibraryLayoutMigrationPlanner {
    /// Documents 根下的一个候选文件事实。
    struct Candidate: Equatable {
        /// 相对 Documents 根的路径（`song.flac` / `lyrics-manual/abc.json`）。
        let sourceRelativePath: String
        let size: Int64
        let category: LibraryLayoutMigrationRules.Category
    }

    /// 目标目录里已存在的一个同名文件事实（冲突判定用）。
    struct ExistingTarget: Equatable {
        let directory: String
        let name: String
        let size: Int64
    }

    /// DB 里一行曲目（只取改写判定需要的字段）。
    struct TrackRow: Equatable {
        let stableId: String
        /// 存储形态（绝对路径 = 旧行；相对路径 = 已迁完的行）。
        let storedPath: String
        /// 该行文件相对「**旧** Documents 根」的路径（执行器算；不在 Documents 下 → nil）。
        let legacyDocumentsRelativePath: String?
    }

    /// 生成计划。
    ///
    /// 冲突判定：目标目录已存在**同名**文件 → 不覆盖、保留原件、计入跳过
    /// （`targetExistsSameSize` / `targetExistsDifferentSize` 只用于诊断，动作都是跳过）。
    ///
    /// path 改写：只改「文件本次确实会搬进曲库根」的行 —— 按
    /// `legacyDocumentsRelativePath` 与候选源路径精确匹配；未搬的行（未规划 / 冲突跳过 /
    /// 外部文件 / 已在曲库根）一律不动。
    static func makePlan(
        candidates: [Candidate],
        existingTargets: [ExistingTarget],
        trackRows: [TrackRow]
    ) -> LibraryLayoutMigrationPlan {
        var plan = LibraryLayoutMigrationPlan()
        var movedSources = Set<String>()

        for candidate in candidates {
            let destinationDirectory = candidate.category.directoryName
            let destinationName = (candidate.sourceRelativePath as NSString).lastPathComponent
            if let existing = existingTargets.first(where: {
                $0.directory == destinationDirectory && $0.name == destinationName
            }) {
                plan.skips.append(
                    LibraryLayoutMigrationPlan.Skip(
                        sourceRelativePath: candidate.sourceRelativePath,
                        reason: existing.size == candidate.size
                            ? "targetExistsSameSize"
                            : "targetExistsDifferentSize"
                    )
                )
                continue
            }
            plan.moves.append(
                LibraryLayoutMigrationPlan.Move(
                    category: candidate.category,
                    sourceRelativePath: candidate.sourceRelativePath,
                    destinationDirectory: destinationDirectory,
                    destinationName: destinationName
                )
            )
            movedSources.insert(candidate.sourceRelativePath)
        }

        for row in trackRows {
            // 只有「本次真搬进了曲库根」的行才改 path；其余一律不动（口径 ⑤）。
            guard let legacy = row.legacyDocumentsRelativePath,
                  movedSources.contains(legacy),
                  let move = plan.moves.first(where: { $0.sourceRelativePath == legacy }),
                  move.category == .music,
                  !LibraryRoot.isRelativeStoredPath(row.storedPath) else {
                continue
            }
            plan.rewrites.append(
                LibraryLayoutMigrationPlan.PathRewrite(
                    stableId: row.stableId,
                    oldStoredPath: row.storedPath,
                    newStoredPath: move.destinationName
                )
            )
        }

        return plan
    }
}
