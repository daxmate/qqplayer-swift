//
//  LibraryLayoutMigrator.swift
//  QQPlayer
//
// target: ios-only（iOS 沙盒语义：曲库根 = `<Documents>/Music`；macOS 曲库在
// `~/Music/QQPlayer`，跑本迁移器只会去动用户的 `~/Documents`）
//
//  曲库文件夹化（2026-09-22）**一次性迁移执行器**：把 Documents 根下「规划类」文件搬进
//  `Music/` `Lyrics/` `Artwork/` `Logs/`，并把 DB 里仍是绝对路径的曲目行改写成
//  「相对 Music 根」的相对路径。计划由纯逻辑 `LibraryLayoutMigrationPlanner` 产出。
//
//  —— 硬约束（用户 2026-09-22 13:1x 拍板）——
//   · **幂等 / 可重入**：完成门是 UserDefaults 标记（成功才置位），不靠「文件是否在旧
//     位置」猜；未置位则每次启动重跑，逐项动作本身也幂等（源不存在 = 无事发生）。
//   · **失败不删原件**：全程只用 move（同卷 rename），**没有任何删除/覆盖动作**；
//     任何失败路径都保证旧文件仍在原处（目标存在 → 跳过，绝不覆盖）。
//   · **不阻塞启动**：文件与 DB 动作全部在后台串行队列上（`runInBackground`）。
//   · **可观测**：迁移前后各打一次「曲库行数 + 文件数」，每类搬/跳过/失败计数；
//     单条失败不影响其余项。
//   · **干跑**：`run(dryRun: true)`（或启动参数 `--library-layout-dry-run`）只统计不搬。
//
//  —— 顺序与失败补偿（为什么「先搬后改」）——
//   先搬文件、再改 DB 行，逐项进行（每项：move 成功 → 立刻改该行 path）。
//   理由：两个方向失败一次的后果不对称 ——
//   · 先搬后改失败：库里该行仍是**旧绝对路径**，而文件已在 `Music/` 下 → 主扫的
//     P1 路径自愈（`staleStoredPath` → `migrateTrackForMovedFile` 只回写 path）
//     下一次启动必然修好；文件一个字节没丢。
//   · 先改后搬失败：库里该行指向 `Music/<rel>` 而文件还在 Documents 根 → 该行落在
//     扫描根内但文件不存在 → `reconcileMissingFiles` 会把行删掉（用户数据受损）。
//   所以：**先搬后改**，且「搬成功才改」。
//

import Foundation

/// 一次性迁移执行器（iOS 生产路径；macOS 曲库不在 `Documents/Music` 下，天然无事发生）。
final class LibraryLayoutMigrator: @unchecked Sendable {
    static let shared = LibraryLayoutMigrator()

    /// 完成门（成功才置位 → 失败下次启动重试）。
    static let completionDefaultsKey = "library.layoutMigrationCompleted.v1"

    /// 干跑开关（启动参数；真机先看清单再放手）。
    static let dryRunLaunchArgument = "--library-layout-dry-run"

    static var dryRunRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(dryRunLaunchArgument)
    }

    /// 一轮迁移的账目（日志 / 干跑清单 / 测试断言用）。
    struct Summary: Equatable, Sendable {
        var isDryRun = false
        /// 完成门已置位 → 本轮直接跳过（未做任何事）。
        var alreadyCompleted = false
        /// 规划目录不存在 → 已建（干跑时不建）。
        var createdDirectories: [String] = []
        var movedByCategory: [String: Int] = [:]
        var skipped: [String] = []
        var failed: [String] = []
        /// DB path 改写成功 / 失败条数。
        var rewrittenPaths = 0
        var rewriteFailures = 0
        /// 迁移前后打点。
        var trackRowsBefore = 0
        var trackRowsAfter = 0
        var rootFileCountBefore = 0
        var musicFileCountBefore = 0
        var musicFileCountAfter = 0

        var movedTotal: Int { movedByCategory.values.reduce(0, +) }
        var didComplete: Bool { failed.isEmpty && rewriteFailures == 0 }

        /// 一行摘要（日志与报告共用）。
        var logLine: String {
            let byCategory = movedByCategory
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            return "曲库行=\(trackRowsBefore)→\(trackRowsAfter) 曲库文件=\(musicFileCountBefore)→\(musicFileCountAfter)"
                + " 搬迁=\(movedTotal)(\(byCategory)) 跳过=\(skipped.count) 失败=\(failed.count)"
                + " 改path=\(rewrittenPaths)(失败\(rewriteFailures))"
        }
    }

    private let database: DatabaseManager
    private let defaults: UserDefaults
    private let fileManager: FileManager
    /// 后台串行队列：生产触发点全部经它（不阻塞启动）。
    private let queue = DispatchQueue(label: "com.daxmate.qqplayer.library-layout-migration", qos: .utility)

    init(
        database: DatabaseManager = .shared,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.database = database
        self.defaults = defaults
        self.fileManager = fileManager
    }

    // MARK: - 入口

    /// 生产入口：后台串行队列执行，不阻塞调用方。
    func runInBackground(
        dryRun: Bool = LibraryLayoutMigrator.dryRunRequested,
        completion: (@Sendable (Summary) -> Void)? = nil
    ) {
        queue.async { [self] in
            let summary = run(dryRun: dryRun)
            completion?(summary)
        }
    }

    /// 执行一轮（同步；测试直调）。幂等：完成门已置位且非干跑 → 直接返回。
    @discardableResult
    func run(dryRun: Bool = false) -> Summary {
        var summary = Summary()
        summary.isDryRun = dryRun

        if !dryRun, defaults.bool(forKey: Self.completionDefaultsKey) {
            summary.alreadyCompleted = true
            AppLog.info(.migration, "📦 LibraryLayout: 完成门已置位，跳过（幂等）")
            return summary
        }

        guard let documentsRoot = LibraryRoot.documentsRootURL(fileManager: fileManager) else {
            summary.failed.append("documentsRootUnavailable")
            AppLog.error(.migration, "📦 LibraryLayout: Documents 不可解析，本轮跳过")
            return summary
        }
        let musicRoot = documentsRoot.appendingPathComponent(LibraryRoot.musicDirectoryName, isDirectory: true)

        summary.trackRowsBefore = (try? database.getAllTracks().count) ?? 0
        summary.rootFileCountBefore = fileCount(in: documentsRoot, directChildrenOnly: true, includeDirectories: false)
        summary.musicFileCountBefore = fileCount(in: musicRoot, directChildrenOnly: true, includeDirectories: false)

        // ① 建规划目录（干跑只统计）
        if dryRun {
            summary.createdDirectories = LibraryRoot.plannedDirectoryNames.filter {
                !fileManager.fileExists(atPath: documentsRoot.appendingPathComponent($0, isDirectory: true).path)
            }
        } else {
            for name in LibraryRoot.plannedDirectoryNames {
                let url = documentsRoot.appendingPathComponent(name, isDirectory: true)
                if !fileManager.fileExists(atPath: url.path) {
                    do {
                        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                        summary.createdDirectories.append(name)
                    } catch {
                        summary.failed.append("createDirectory:\(name):\(error)")
                        AppLog.error(.migration, "📦 LibraryLayout: 建目录失败 \(name)：\(error)")
                    }
                }
            }
        }

        // ② 枚举候选 + 现有目标（冲突判定）
        let candidates = enumerateCandidates(in: documentsRoot)
        let existingTargets = enumerateExistingTargets(in: documentsRoot)

        // ③ 生成计划
        let plan = LibraryLayoutMigrationPlanner.makePlan(
            candidates: candidates,
            existingTargets: existingTargets,
            trackRows: trackRows(in: documentsRoot)
        )

        summary.skipped = plan.skips.map { "\($0.sourceRelativePath)(\($0.reason))" }

        if plan.moves.isEmpty && plan.rewrites.isEmpty {
            AppLog.info(.migration, "📦 LibraryLayout: 无待搬文件（\(summary.logLine)）")
            if !dryRun { markCompleted() }
            summary.musicFileCountAfter = summary.musicFileCountBefore
            return summary
        }

        AppLog.info(.migration, "📦 LibraryLayout\(dryRun ? "（干跑）" : ""): 待搬 \(plan.moves.count) 件 / 跳过 \(plan.skips.count) 件 / 改 path \(plan.rewrites.count) 条"
            + " · \(summary.logLine)")

        if dryRun {
            // 干跑：只统计，不碰磁盘、不写库、不置完成门。
            for move in plan.moves {
                summary.movedByCategory[move.category.rawValue, default: 0] += 1
                AppLog.info(.migration, "📦 LibraryLayout（干跑）将要搬：\(move.sourceRelativePath) → \(move.destinationDirectory)/\(move.destinationName)")
            }
            for skip in plan.skips {
                AppLog.warn(.migration, "📦 LibraryLayout（干跑）跳过：\(skip.sourceRelativePath)（\(skip.reason)）")
            }
            summary.musicFileCountAfter = summary.musicFileCountBefore
            return summary
        }

        // ④ 逐项：先搬文件，成功才改该行 path（见文件头「顺序与失败补偿」）
        var rewriteByStableId: [String: LibraryLayoutMigrationPlan.PathRewrite] = [:]
        for rewrite in plan.rewrites { rewriteByStableId[rewrite.stableId] = rewrite }

        for move in plan.moves {
            let source = documentsRoot.appendingPathComponent(move.sourceRelativePath)
            let destination = documentsRoot
                .appendingPathComponent(move.destinationDirectory, isDirectory: true)
                .appendingPathComponent(move.destinationName)

            // 目标二次确认：计划生成后到落地前的窗口里可能又冒出同名文件 → 绝不覆盖。
            guard !fileManager.fileExists(atPath: destination.path) else {
                summary.skipped.append("\(move.sourceRelativePath)(targetAppeared)")
                AppLog.warn(.migration, "📦 LibraryLayout: 目标已存在，跳过不覆盖：\(destination.path)")
                continue
            }
            guard fileManager.fileExists(atPath: source.path) else {
                summary.skipped.append("\(move.sourceRelativePath)(sourceMissing)")
                continue
            }
            do {
                try fileManager.moveItem(at: source, to: destination)
                summary.movedByCategory[move.category.rawValue, default: 0] += 1
            } catch {
                // 搬失败：原件仍在原处（move 失败 = 未动）；不改 DB、不影响其余项。
                summary.failed.append("move:\(move.sourceRelativePath):\(error)")
                AppLog.error(.migration, "📦 LibraryLayout: 搬迁失败（原件保留）：\(move.sourceRelativePath) → \(error)")
                continue
            }

            // 改 path：只针对曲库音频（歌词/封面/日志没有 track 行）。
            guard move.category == .music else { continue }
            guard let row = trackRow(matching: move.sourceRelativePath, in: documentsRoot) else { continue }
            do {
                try database.migrateTrackForMovedFile(
                    oldStableId: row.stableId,
                    newPath: destination.path,
                    fileManager: fileManager
                )
                summary.rewrittenPaths += 1
                if let rewrite = rewriteByStableId[row.stableId] {
                    AppLog.info(.migration, "📦 LibraryLayout: path 改写 \(rewrite.oldStoredPath) → \(rewrite.newStoredPath)")
                }
            } catch {
                summary.rewriteFailures += 1
                summary.failed.append("rewritePath:\(row.stableId):\(error)")
                // 文件已在新位置：下次启动主扫的 P1 路径自愈会补上（见文件头）。
                AppLog.warn(.migration, "📦 LibraryLayout: 改 path 失败（下次启动扫描自愈）：\(row.stableId) → \(error)")
            }
        }

        summary.trackRowsAfter = (try? database.getAllTracks().count) ?? summary.trackRowsBefore
        summary.musicFileCountAfter = fileCount(in: musicRoot, directChildrenOnly: true, includeDirectories: false)

        AppLog.info(.migration, "📦 LibraryLayout\(summary.didComplete ? " 完成" : " 有失败项"): \(summary.logLine)")
        if summary.didComplete {
            markCompleted()
        } else {
            // 未完成 → 不置门，下次启动重试（逐项幂等）。
            AppLog.warn(.migration, "📦 LibraryLayout: 本轮有失败项，完成门不置位（下次启动重试）")
        }
        return summary
    }

    /// 清完成门（测试与人工重跑用；生产不调用）。
    func resetCompletionGate() {
        defaults.removeObject(forKey: Self.completionDefaultsKey)
    }

    private func markCompleted() {
        defaults.set(true, forKey: Self.completionDefaultsKey)
    }

    // MARK: - 枚举

    private func enabledAudioExtensions() -> [String] {
        MusicDirectoryScanner.enabledExtensions(from: DeleteSettings.load())
    }

    /// Documents 根下「规划类」文件（含旧目录内的一层文件）。
    /// **目录本身一律不搬**（用户口径 ⑤）；旧目录内容搬空后目录保留（本批不删）。
    private func enumerateCandidates(in documentsRoot: URL) -> [LibraryLayoutMigrationPlanner.Candidate] {
        let audioExtensions = enabledAudioExtensions()
        var candidates: [LibraryLayoutMigrationPlanner.Candidate] = []

        guard let entries = try? fileManager.contentsOfDirectory(
            at: documentsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return candidates
        }

        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let size = Int64(values?.fileSize ?? 0)
            if values?.isDirectory == true {
                let directoryName = entry.lastPathComponent
                guard LibraryLayoutMigrationRules.legacyDirectories.contains(where: { $0.name == directoryName }),
                      let inner = try? fileManager.contentsOfDirectory(
                          at: entry,
                          includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                          options: [.skipsHiddenFiles]
                      )
                else { continue }
                for file in inner {
                    let innerValues = try? file.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    guard innerValues?.isDirectory != true else { continue }
                    let name = file.lastPathComponent
                    guard let category = LibraryLayoutMigrationRules.category(
                        rootFileName: name,
                        directoryName: directoryName,
                        enabledAudioExtensions: audioExtensions
                    ) else { continue }
                    candidates.append(
                        LibraryLayoutMigrationPlanner.Candidate(
                            sourceRelativePath: "\(directoryName)/\(name)",
                            size: Int64(innerValues?.fileSize ?? 0),
                            category: category
                        )
                    )
                }
                continue
            }

            let name = entry.lastPathComponent
            // 封面映射表**不是待搬文件**：它是元数据，由 `ArtworkManager`（映射读写唯一入口）
            // 在启动时把「旧位置 ∪ 新位置」合并后写进新位置（`Documents/Artwork/`），每次启动都跑。
            // 这里按普通文件搬会引入两条丢映射的路径（详见规则函数的注释）；旧位置**保持不动**
            // 作为只读兼底（`ArtworkManager.loadMapping` 每次都读它）。
            guard !LibraryLayoutMigrationRules.isArtworkMappingFileName(name) else {
                AppLog.info(.migration, "📦 LibraryLayout: 封面映射表按元数据语义不搬（由 ArtworkManager 合并），旧位置保留：\(name)")
                continue
            }
            guard let category = LibraryLayoutMigrationRules.category(
                rootFileName: name,
                directoryName: nil,
                enabledAudioExtensions: audioExtensions
            ) else { continue }
            candidates.append(
                LibraryLayoutMigrationPlanner.Candidate(
                    sourceRelativePath: name,
                    size: size,
                    category: category
                )
            )
        }
        return candidates
    }

    /// 规划目录里已存在的文件（同名冲突判定；只列一层，与单层口径一致）。
    private func enumerateExistingTargets(in documentsRoot: URL) -> [LibraryLayoutMigrationPlanner.ExistingTarget] {
        var targets: [LibraryLayoutMigrationPlanner.ExistingTarget] = []
        for name in LibraryRoot.plannedDirectoryNames {
            let directory = documentsRoot.appendingPathComponent(name, isDirectory: true)
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                let values = try? entry.resourceValues(forKeys: [.fileSizeKey])
                targets.append(
                    LibraryLayoutMigrationPlanner.ExistingTarget(
                        directory: name,
                        name: entry.lastPathComponent,
                        size: Int64(values?.fileSize ?? 0)
                    )
                )
            }
        }
        return targets
    }

    /// DB 曲目行 → 规划输入（旧 Documents 相对路径由「绝对路径 − 旧 Documents 前缀」算得）。
    private func trackRows(in documentsRoot: URL) -> [LibraryLayoutMigrationPlanner.TrackRow] {
        let tracks = (try? database.getAllTracks()) ?? []
        return tracks.map { track in
            LibraryLayoutMigrationPlanner.TrackRow(
                stableId: track.stableId,
                storedPath: track.path,
                legacyDocumentsRelativePath: legacyDocumentsRelativePath(
                    ofStoredPath: track.path,
                    documentsRoot: documentsRoot
                )
            )
        }
    }

    /// 存储形态 → 相对**旧** Documents 根的路径（不在 Documents 下 / 已是相对形态 → nil）。
    private func legacyDocumentsRelativePath(ofStoredPath path: String, documentsRoot: URL) -> String? {
        guard !path.isEmpty, !LibraryRoot.isRelativeStoredPath(path) else { return nil }
        let rebased = LibraryRoot.rebasedFromLegacyContainer(path, fileManager: fileManager)
        guard LibraryRoot.isInsideDocuments(rebased, fileManager: fileManager) else { return nil }
        return SyncManifestGenerator.relativePath(
            of: URL(fileURLWithPath: rebased),
            baseDirectory: documentsRoot
        )
    }

    /// 已搬走的源对应的 DB 行（按「旧 Documents 相对路径」匹配）。
    private func trackRow(
        matching sourceRelativePath: String,
        in documentsRoot: URL
    ) -> LibraryLayoutMigrationPlanner.TrackRow? {
        trackRows(in: documentsRoot).first { $0.legacyDocumentsRelativePath == sourceRelativePath }
    }

    // MARK: - 计数

    /// 目录下的条目数（`directChildrenOnly` = 只数一层；与单层曲库口径一致）。
    private func fileCount(
        in directory: URL,
        directChildrenOnly: Bool,
        includeDirectories: Bool
    ) -> Int {
        guard fileManager.fileExists(atPath: directory.path) else { return 0 }
        if directChildrenOnly {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return 0 }
            return entries.filter { entry in
                includeDirectories
                    || (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
            }.count
        }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if includeDirectories || !isDirectory { count += 1 }
        }
        return count
    }
}
