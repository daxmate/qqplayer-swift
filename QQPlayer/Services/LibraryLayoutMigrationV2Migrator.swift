//
//  LibraryLayoutMigrationV2Migrator.swift
//  QQPlayer
//
// target: ios-only（iOS 沙盒：`Documents/` 根部收敛为「只留 `Music/` 可见」）
//
//  「**只留 `Music/` 可见**」迁移（v2）的**一次性执行器**：把 `Documents/` 下除 `Music/`
//  以外的一切（DB、状态、封面、歌词、日志、元数据、各类缓存、回收区残留）搬进隐藏根
//  `Documents/.qqplayer/{db,state,artwork,lyrics,logs,meta,cache,trash}/`。
//  计划由纯逻辑 `LibraryLayoutMigrationV2Planner` 产出。
//
//  —— 硬约束 ——
//   · **幂等 / 可重入**：完成门是 UserDefaults 标记（成功才置位），不靠「文件是否在旧位置」猜；
//     未置位则每次启动重跑，逐项动作本身也幂等（源不存在 = 无事发生）。
//   · **只搬不删**：全程只用 move（同卷 rename），**没有任何删除/覆盖动作**；
//     任何失败路径都保证旧条目仍在原处（目标存在 → 跳过，绝不覆盖）。
//   · **不阻塞启动**：文件动作全部在后台串行队列上（`runInBackground`）。
//   · **可观测**：迁移前后各打一次「根条目数」；每类搬/跳过/失败计数；单条失败不影响其余项。
//   · **干跑**：`run(dryRun: true)`（或启动参数 `--hidden-layout-dry-run`）只统计不搬。
//   · **不动 DB**：`Music/` 未动、`track.path` 仍相对 `Music` 根 ⇒ 不存在 v1 那种「搬文件 + 改
//     DB 行」的顺序问题。对「DB 绝对存储路径指向某个待搬根条目」的情况采取**跳过该条目**的
//     保守策略（`referencedByStoredPath`）—— 宁可留它在根上，也不让引用悬空。
//
//  —— 与 v1 的顺序 ——
//  v2 在 v1 之后跑（`AppCoordinator` 顺序 await）；两道完成门独立，互不阻断。
//

import Foundation

/// 一次性迁移执行器（iOS 生产路径）。
final class LibraryLayoutMigrationV2Migrator: @unchecked Sendable {
    static let shared = LibraryLayoutMigrationV2Migrator()

    /// 完成门（成功才置位 → 失败下次启动重试）。与 v1 门互不干扰。
    static let completionDefaultsKey = "library.layoutMigrationV2Completed.v1"

    /// 干跑开关（启动参数；真机先看清单再放手）。
    static let dryRunLaunchArgument = "--hidden-layout-dry-run"

    static var dryRunRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(dryRunLaunchArgument)
    }

    /// 一轮迁移的账目（日志 / 干跑清单 / 测试断言用）。
    struct Summary: Equatable, Sendable {
        var isDryRun = false
        /// 完成门已置位 → 本轮直接跳过（未做任何事）。
        var alreadyCompleted = false
        /// 目标父目录不存在 → 已建（干跑时不建）。
        var createdDirectories: [String] = []
        var movedByDestination: [String: Int] = [:]
        var skipped: [String] = []
        var failed: [String] = []
        var kept: [String] = []
        /// 迁移前后打点（Documents 根部条目数，含隐藏）。
        var rootEntryCountBefore = 0
        var rootEntryCountAfter = 0

        var movedTotal: Int { movedByDestination.values.reduce(0, +) }
        var didComplete: Bool { failed.isEmpty }

        /// 一行摘要（日志与报告共用）。
        var logLine: String {
            let byDestination = movedByDestination
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            return "根条目=\(rootEntryCountBefore)→\(rootEntryCountAfter)"
                + " 搬迁=\(movedTotal)(\(byDestination)) 跳过=\(skipped.count) 失败=\(failed.count)"
                + " 留原位=\(kept.count)"
        }
    }

    private let database: DatabaseManager
    private let defaults: UserDefaults
    private let fileManager: FileManager
    /// 后台串行队列：生产触发点全部经它（不阻塞启动）。
    private let queue = DispatchQueue(label: "com.daxmate.qqplayer.hidden-layout-migration", qos: .utility)

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
        dryRun: Bool = LibraryLayoutMigrationV2Migrator.dryRunRequested,
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
            AppLog.info(.migration, "🫥 HiddenLayout v2: 完成门已置位，跳过（幂等）")
            return summary
        }

        guard let documentsRoot = LibraryRoot.documentsRootURL(fileManager: fileManager) else {
            summary.failed.append("documentsRootUnavailable")
            AppLog.error(.migration, "🫥 HiddenLayout v2: Documents 不可解析，本轮跳过")
            return summary
        }

        summary.rootEntryCountBefore = rootEntryCount(in: documentsRoot)

        let plan = LibraryLayoutMigrationV2Planner.makePlan(
            rootEntries: rootEntries(in: documentsRoot),
            existingDestinationRelativePaths: existingDestinationRelativePaths(in: documentsRoot),
            referencedSourceRelativePaths: referencedRootEntries(documentRoot: documentsRoot)
        )
        summary.kept = plan.kept
        summary.skipped = plan.skips.map { "\($0.sourceRelativePath)(\($0.reason))" }

        if plan.moves.isEmpty {
            AppLog.info(.migration, "🫥 HiddenLayout v2: 无待搬条目（\(summary.logLine)）")
            if !dryRun { markCompleted() }
            summary.rootEntryCountAfter = summary.rootEntryCountBefore
            return summary
        }

        AppLog.info(.migration, "🫥 HiddenLayout v2\(dryRun ? "（干跑）" : ""): 待搬 \(plan.moves.count) 件"
            + " / 跳过 \(plan.skips.count) 件 · 根条目=\(summary.rootEntryCountBefore)"
            + " 留原位=\(plan.kept.count)")

        if dryRun {
            // 干跑：只统计，不碰磁盘、不置完成门。
            for move in plan.moves {
                let kind = destinationKind(of: move.destinationRelativePath)
                summary.movedByDestination[kind, default: 0] += 1
                AppLog.info(.migration, "🫥 HiddenLayout v2（干跑）将要搬：\(move.sourceRelativePath) → \(move.destinationRelativePath)")
            }
            for skip in plan.skips {
                AppLog.warn(.migration, "🫥 HiddenLayout v2（干跑）跳过：\(skip.sourceRelativePath)（\(skip.reason)）")
            }
            summary.rootEntryCountAfter = summary.rootEntryCountBefore
            return summary
        }

        // 逐项搬迁：建父目录 → 二次确认目标不存在 → 搬（move 失败 = 未动，原件保留）。
        for move in plan.moves {
            let source = documentsRoot.appendingPathComponent(move.sourceRelativePath)
            let destination = documentsRoot.appendingPathComponent(move.destinationRelativePath)
            let kind = destinationKind(of: move.destinationRelativePath)

            let parent = destination.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: parent.path) {
                do {
                    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                    summary.createdDirectories.append(relativePath(parent, in: documentsRoot))
                } catch {
                    summary.failed.append("createDirectory:\(relativePath(parent, in: documentsRoot)):\(error)")
                    AppLog.error(.migration, "🫥 HiddenLayout v2: 建目录失败 \(parent.path)：\(error)")
                    continue
                }
            }

            // 目标二次确认：计划生成后到落地前的窗口里可能又冒出同名条目 → 绝不覆盖。
            guard !fileManager.fileExists(atPath: destination.path) else {
                summary.skipped.append("\(move.sourceRelativePath)(targetAppeared)")
                AppLog.warn(.migration, "🫥 HiddenLayout v2: 目标已存在，跳过不覆盖：\(destination.path)")
                continue
            }
            guard fileManager.fileExists(atPath: source.path) else {
                summary.skipped.append("\(move.sourceRelativePath)(sourceMissing)")
                continue
            }
            do {
                try fileManager.moveItem(at: source, to: destination)
                summary.movedByDestination[kind, default: 0] += 1
            } catch {
                // 搬失败：原件仍在原处（move 失败 = 未动）；不影响其余项。
                summary.failed.append("move:\(move.sourceRelativePath):\(error)")
                AppLog.error(.migration, "🫥 HiddenLayout v2: 搬迁失败（原件保留）：\(move.sourceRelativePath) → \(error)")
            }
        }

        summary.rootEntryCountAfter = rootEntryCount(in: documentsRoot)
        AppLog.info(.migration, "🫥 HiddenLayout v2\(summary.didComplete ? " 完成" : " 有失败项"): \(summary.logLine)")
        if summary.didComplete {
            markCompleted()
        } else {
            // 未完成 → 不置门，下次启动重试（逐项幂等）。
            AppLog.warn(.migration, "🫥 HiddenLayout v2: 本轮有失败项，完成门不置位（下次启动重试）")
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

    /// 根部条目（**含隐藏条目**：`.Trash` 要搬，`.sync-incoming` 由规则表保留）。
    private func rootEntries(in documentsRoot: URL) -> [LibraryLayoutMigrationV2Planner.RootEntry] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: documentsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }
        return entries.map { entry in
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return LibraryLayoutMigrationV2Planner.RootEntry(
                name: entry.lastPathComponent, isDirectory: isDirectory
            )
        }
    }

    private func rootEntryCount(in documentsRoot: URL) -> Int {
        rootEntries(in: documentsRoot).count
    }

    /// 目标位置已存在的路径（相对 Documents 根）：逐级下探隐藏根 + 各映射目标。
    ///
    /// 冲突判定只需要「映射表里出现过的目标」——按映射表的**值集合**逐个探存在性，
    /// 而不是遍历整棵隐藏树（隐藏树可能很大，且遍历结果与判定无关）。
    private func existingDestinationRelativePaths(in documentsRoot: URL) -> Set<String> {
        var candidates = Set(LibraryLayoutMigrationV2Rules.rootFileDestinations.values)
        candidates.formUnion(LibraryLayoutMigrationV2Rules.rootDirectoryDestinations.values)
        var existing = Set<String>()
        for candidate in candidates where fileManager.fileExists(
            atPath: documentsRoot.appendingPathComponent(candidate).path
        ) {
            existing.insert(candidate)
        }
        return existing
    }

    /// 被 DB **绝对**存储路径引用的根条目名（保守跳过；见文件头）。
    private func referencedRootEntries(documentRoot: URL) -> Set<String> {
        let documentsPrefix = documentRoot.standardizedFileURL.path
        let tracks = (try? database.getAllTracks()) ?? []
        var referenced = Set<String>()
        for track in tracks {
            let stored = track.path
            guard !stored.isEmpty, !LibraryRoot.isRelativeStoredPath(stored) else { continue }
            let rebased = LibraryRoot.rebasedFromLegacyContainer(stored, fileManager: fileManager)
            guard rebased.hasPrefix(documentsPrefix) else { continue }
            let suffix = rebased.dropFirst(documentsPrefix.count)
            let components = suffix.split(separator: "/", omittingEmptySubsequences: true)
            guard let first = components.first else { continue }
            let entryName = String(first)
            guard LibraryRoot.musicDirectoryName != entryName,
                  LibraryRoot.hiddenRootDirectoryName != entryName else { continue }
            referenced.insert(entryName)
        }
        if !referenced.isEmpty {
            AppLog.warn(.migration, "🫥 HiddenLayout v2: \(referenced.count) 个根条目被 DB 绝对路径引用，本轮跳过：\(referenced.sorted().joined(separator: ", "))")
        }
        return referenced
    }

    // MARK: - 计数辅助

    /// 目标一级子目录名（日志分类用；`db` / `state` / `artwork` / …）。
    private func destinationKind(of destinationRelativePath: String) -> String {
        let components = destinationRelativePath.split(separator: "/")
        guard components.count >= 2 else { return "root" }
        return String(components[1])
    }

    private func relativePath(_ url: URL, in documentsRoot: URL) -> String {
        LibraryRoot.relativePath(of: url, baseDirectory: documentsRoot) ?? url.lastPathComponent
    }
}
