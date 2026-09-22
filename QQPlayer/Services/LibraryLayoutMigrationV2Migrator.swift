//
//  LibraryLayoutMigrationV2Migrator.swift
//  QQPlayer
//
// target: ios-only（iOS 沙盒：`Documents/` 根部收敛为「只留 `Music/` 可见」）
//
//  「**只留 `Music/` 可见**」迁移（v2.1）的**一次性执行器**：把 `Documents/` 下除 `Music/`
//  以外的一切（DB、状态、封面、歌词、日志、元数据、各类缓存、回收区残留）搬进隐藏根
//  `Documents/.qqplayer/{db,state,artwork,lyrics,logs,meta,cache,trash}/`。
//  计划由纯逻辑 `LibraryLayoutMigrationV2Planner` 产出。
//
//  —— 硬约束 ——
//   · **幂等 / 可重入**：完成门是 UserDefaults 标记（成功才置位），不靠「文件是否在旧位置」猜；
//     未置位则每次启动重跑，逐项动作本身也幂等（源不存在 = 无事发生）。
//   · **只搬不删**：全程只用 move（含改名），**没有任何删除/覆盖动作**。
//   · **不阻塞启动**：文件动作在后台串行队列上（`runInBackground`）。唯一例外见下「启动时机」。
//   · **可观测**：迁移前后各打一次「根条目数」；每类搬/改名/空壳清扫/跳过/失败计数。
//   · **干跑**：`run(dryRun: true)`（或启动参数 `--hidden-layout-dry-run`）只统计不搬。
//   · **不动 DB**：`Music/` 未动、`track.path` 仍相对 `Music` 根 ⇒ 不存在 v1 那种「搬文件 + 改
//     DB 行」的顺序问题。对「DB 绝对存储路径指向某个待搬根条目」的情况采取**跳过该条目**的
//     保守策略（`referencedByStoredPath`）—— 宁可留它在根上，也不让引用悬空。
//
//  —— v2.1 修正（真机失败：`03f867e` 在设备上没达成「根只留 Music」）——
//   失败现象：`Documents/` 根仍裸露 10 项（`Artwork/ Logs/ Lyrics/ lyrics-cache/
//   qqplayer-playlists/ SpotifyCache/ DiscogsCache/ HybridMusicCache/ app.log db-debug.log`），
//   因为启动期组件**先**建好隐藏目标目录 ⇒ 迁移跑到时 10 项全部命中「目标已存在 ⇒ 整项跳过」。
//   两处修正：
//   ① **冲突递归合并 + 同名改名后缀**（规则与计划见 `LibraryLayoutMigrationV2Plan`）：
//      目录冲突逐子项处理、同名子项/同名文件一律改名后缀（`<name>.legacy-<ts>`）搬入；
//      合并后的空壳目录改名搬进 `trash/`。**绝不覆盖、绝不删除**。
//   ② **迁移时机提前**（见下）——在组件建目录**之前**先跑一轮，从根上消除冲突。
//
//  —— 启动时机不变量（v2.1）——
//   `Documents/` 根上的隐藏**目标目录**一旦被任何组件先建出来，本迁移就只能走「合并」路径
//   （改名后缀、空壳清扫）。因此生产顺序写死为 **两轮**：
//     · 第一轮 `runStartupPrepass()`：`AppDelegate.application(_:didFinishLaunchingWithOptions:)`
//       **首句**、**同步**跑（此刻 `AppCoordinator` / `AppServices` / 各视图 singleton 尚未构造，
//       `ArtworkManager` 等还没建 `.qqplayer/artwork` …）。同步是刻意的：异步会与紧随其后的
//       组件构造竞争，「早于组件」就不再成立。这一轮**不置完成门**。
//     · 第二轮 `runInBackground()`（`AppCoordinator.initialize()`，在 `SandboxMusicMigrator`
//       与 v1 之后）：**收尾一轮**，判据见下「完成门」，它才置完成门。
//   **为什么第一轮不置门**：启动还没走完 —— v1（`LibraryLayoutMigrator`）会无条件建出
//   `Documents/{Music,Lyrics,Artwork,Logs}` 四个规划目录（它的 `plannedDirectoryNames`），
//   首装设备上这发生在第一轮之后；若第一轮就置门，这些根目录将永远留在可见区。故门只在
//   v1 之后的收尾一轮、且**根上确无可搬残留**时才置位。
//   确实无法早于的（进程最早期的日志文件 `app.log` / `db-debug.log` —— `AppLog` 与
//   `DatabaseManager` 在更早的钩子里就会写）由「同名文件 ⇒ 改名后缀搬入」兜底。
//
//  —— 完成门语义（v2.1 修正）——
//   仅当「**根上已无可搬条目**（`residue` 为空）**且失败 = 0**」时才置位；否则不置位、下次启动
//   重试。`referencedByStoredPath` 这类**保守例外**（见上）不计入残留，不阻塞置位。
//   **新门 key** `library.layoutMigrationV2_1Completed.v1`：v2（`…V2Completed.v1`）已在旧设备上
//   置位过，沿用旧 key 这些设备永远不会再跑一轮 ⇒ 换新 key 让它们再收一轮尾。
//
//  —— 与 v1 的顺序 ——
//   v2 两轮都在 v1 之后**收尾**（第一轮在 v1 之前只是抢占式清理，见上）；两道完成门独立。
//

import Foundation

/// 一次性迁移执行器（iOS 生产路径）。
final class LibraryLayoutMigrationV2Migrator: @unchecked Sendable {
    static let shared = LibraryLayoutMigrationV2Migrator()

    /// 完成门（成功且根无残留才置位 → 否则下次启动重试）。与 v1 门互不干扰。
    static let completionDefaultsKey = "library.layoutMigrationV2_1Completed.v1"

    /// **旧门 key（刻意不再读取）**：v2 在设备上置位过它 ⇒ 沿用会让这些设备永远不再跑，
    /// 剩下的根条目收不干净。留此常量只为解释「为什么换 key」，生产不读不写。
    static let legacyCompletionDefaultsKey = "library.layoutMigrationV2Completed.v1"

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
        /// 其中「目标同名 ⇒ 改名后缀搬入」的件数（其余为原样搬入）。
        var renamedTotal = 0
        /// 合并后清掉的空壳目录（改名搬进隐藏回收区；只搬不删）。
        var sweptShells: [String] = []
        var skipped: [String] = []
        var failed: [String] = []
        var kept: [String] = []
        /// 本轮跑完后根上仍「该搬未搬」的条目（完成门判据；`referencedByStoredPath` 例外不计入）。
        var residue: [String] = []
        /// 计划一行账（干跑/真跑共用口径）。
        var planLine = ""
        /// 迁移前后打点（Documents 根部条目数，含隐藏）。
        var rootEntryCountBefore = 0
        var rootEntryCountAfter = 0

        var movedTotal: Int { movedByDestination.values.reduce(0, +) }
        /// 完成 = 无失败 **且** 根上无可搬残留（有残留不置位、下次启动重试）。
        var didComplete: Bool { failed.isEmpty && residue.isEmpty }

        /// 一行摘要（日志与报告共用）。
        var logLine: String {
            let byDestination = movedByDestination
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            return "根条目=\(rootEntryCountBefore)→\(rootEntryCountAfter)"
                + " 搬迁=\(movedTotal)(改名=\(renamedTotal))(\(byDestination)) 空壳清扫=\(sweptShells.count)"
                + " 跳过=\(skipped.count) 失败=\(failed.count) 留原位=\(kept.count) 残留=\(residue.count)"
        }
    }

    private let database: DatabaseManager
    private let defaults: UserDefaults
    private let fileManager: FileManager
    /// 后台串行队列：生产触发点（收尾一轮）经它（不阻塞启动）。
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

    /// 启动早期**抢占式一轮**（同步；不置完成门）。
    ///
    /// 调用点写死为 `AppDelegate.application(_:didFinishLaunchingWithOptions:)` 首句 ——
    /// 见文件头「启动时机不变量」：必须**早于任何组件创建隐藏目标目录**，且只有同步才算数。
    /// 这一轮只做「把根上整目录形态的条目先收进隐藏根」，让紧随其后的组件直接在隐藏根里
    /// 建自己的子目录；收尾与置门由 `initialize()` 那一轮完成。
    @discardableResult
    func runStartupPrepass() -> Summary {
        execute(dryRun: false, setsCompletionGate: false)
    }

    /// 生产收尾入口：后台串行队列执行，不阻塞调用方。
    func runInBackground(
        dryRun: Bool = LibraryLayoutMigrationV2Migrator.dryRunRequested,
        completion: (@Sendable (Summary) -> Void)? = nil
    ) {
        queue.async { [self] in
            let summary = execute(dryRun: dryRun, setsCompletionGate: true)
            completion?(summary)
        }
    }

    /// 执行一轮（同步；测试直调）。幂等：完成门已置位且非干跑 → 直接返回。
    @discardableResult
    func run(dryRun: Bool = false) -> Summary {
        execute(dryRun: dryRun, setsCompletionGate: true)
    }

    /// 清完成门（测试与人工重跑用；生产不调用）。
    func resetCompletionGate() {
        defaults.removeObject(forKey: Self.completionDefaultsKey)
    }

    private func markCompleted() {
        defaults.set(true, forKey: Self.completionDefaultsKey)
    }

    // MARK: - 一轮

    private func execute(dryRun: Bool, setsCompletionGate: Bool) -> Summary {
        var summary = Summary()
        summary.isDryRun = dryRun

        if !dryRun, defaults.bool(forKey: Self.completionDefaultsKey) {
            summary.alreadyCompleted = true
            AppLog.info(.migration, "🫥 HiddenLayout v2.1: 完成门已置位，跳过（幂等）")
            return summary
        }

        guard let documentsRoot = LibraryRoot.documentsRootURL(fileManager: fileManager) else {
            summary.failed.append("documentsRootUnavailable")
            AppLog.error(.migration, "🫥 HiddenLayout v2.1: Documents 不可解析，本轮跳过")
            return summary
        }

        summary.rootEntryCountBefore = rootEntryCount(in: documentsRoot)

        let timestamp = LibraryLayoutMigrationV2Rules.legacyTimestamp()
        let referenced = referencedRootEntries(documentRoot: documentsRoot)
        let plan = makePlan(in: documentsRoot, timestamp: timestamp, referencedSourceRelativePaths: referenced)
        summary.planLine = plan.planLine
        summary.kept = plan.kept
        summary.skipped = plan.skips.map { "\($0.sourceRelativePath)(\($0.reason))" }

        let role = dryRun ? "（干跑）" : (setsCompletionGate ? "" : "（启动早期抢占一轮）")
        AppLog.info(.migration, "🫥 HiddenLayout v2.1\(role): \(plan.planLine)"
            + " · 根条目=\(summary.rootEntryCountBefore) 留原位=\(plan.kept.count)")

        if dryRun {
            // 干跑：只统计，不碰磁盘、不置完成门（不受完成门影响）。
            record(plan: plan, into: &summary, logPrefix: "🫥 HiddenLayout v2.1（干跑）")
            for skip in plan.skips {
                AppLog.warn(.migration, "🫥 HiddenLayout v2.1（干跑）跳过：\(skip.sourceRelativePath)（\(skip.reason)）")
            }
            summary.rootEntryCountAfter = summary.rootEntryCountBefore
            return summary
        }

        // ① 逐项搬迁：建父目录 → 落地前二次确认目标（被占 ⇒ 再改名）→ move（失败 = 未动，原件保留）。
        for move in plan.moves {
            moveSingle(move, timestamp: timestamp, in: documentsRoot, into: &summary)
        }

        // ② 空壳清扫：合并后留下的空目录（内容已全部搬入）改名搬进 `trash/`。
        //    还有子项没搬走（某项失败）⇒ 留在原位：计入残留 ⇒ 完成门不置位、下次启动重试。
        for sweep in plan.shellSweeps {
            sweepEmptyShell(sweep, timestamp: timestamp, in: documentsRoot, into: &summary)
        }

        summary.rootEntryCountAfter = rootEntryCount(in: documentsRoot)

        // ③ 完成门判据：**根上已无可搬条目** 且 失败 = 0（有残留 ⇒ 不置位）。
        let residuePlan = makePlan(
            in: documentsRoot, timestamp: timestamp, referencedSourceRelativePaths: referenced
        )
        summary.residue = residuePlan.residueSourceRelativePaths

        AppLog.info(.migration, "🫥 HiddenLayout v2.1\(summary.didComplete ? " 完成" : " 未完成"): \(summary.logLine)")
        guard setsCompletionGate else { return summary }
        if summary.didComplete {
            markCompleted()
        } else {
            AppLog.warn(.migration, "🫥 HiddenLayout v2.1: 根上仍有残留 / 有失败项，完成门不置位（下次启动重试）")
        }
        return summary
    }

    /// 记一笔「将要搬」的账（干跑口径；与真跑共用同一套分类与计数）。
    private func record(
        plan: LibraryLayoutMigrationV2Plan,
        into summary: inout Summary,
        logPrefix: String
    ) {
        for move in plan.moves {
            let kind = destinationKind(of: move.destinationRelativePath)
            summary.movedByDestination[kind, default: 0] += 1
            if move.renamed { summary.renamedTotal += 1 }
            AppLog.info(.migration, "\(logPrefix)\(move.renamed ? "改名搬入" : "将要搬")：\(move.sourceRelativePath) → \(move.destinationRelativePath)")
        }
    }

    // MARK: - 单条动作

    private func moveSingle(
        _ move: LibraryLayoutMigrationV2Plan.Move,
        timestamp: String,
        in documentsRoot: URL,
        into summary: inout Summary
    ) {
        let source = documentsRoot.appendingPathComponent(move.sourceRelativePath)
        let plannedDestination = documentsRoot.appendingPathComponent(move.destinationRelativePath)
        let kind = destinationKind(of: move.destinationRelativePath)

        guard fileManager.fileExists(atPath: source.path) else {
            summary.skipped.append("\(move.sourceRelativePath)(sourceMissing)")
            return
        }
        // 落地前二次确认：计划生成后到落地前的窗口里可能又冒出同名条目（或改名后缀本身被占）
        // ⇒ 再换一个改名后缀，**绝不覆盖**。
        let renamed = move.renamed || fileManager.fileExists(atPath: plannedDestination.path)
        let destination = renamed
            ? uniqueLegacyDestination(for: plannedDestination, timestamp: timestamp)
            : plannedDestination

        let parent = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            do {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                summary.createdDirectories.append(relativePath(parent, in: documentsRoot))
            } catch {
                summary.failed.append("createDirectory:\(relativePath(parent, in: documentsRoot)):\(error)")
                AppLog.error(.migration, "🫥 HiddenLayout v2.1: 建目录失败 \(parent.path)：\(error)")
                return
            }
        }

        do {
            try fileManager.moveItem(at: source, to: destination)
            summary.movedByDestination[kind, default: 0] += 1
            if renamed { summary.renamedTotal += 1 }
        } catch {
            // 搬失败：原件仍在原处（move 失败 = 未动）；不影响其余项。
            summary.failed.append("move:\(move.sourceRelativePath):\(error)")
            AppLog.error(.migration, "🫥 HiddenLayout v2.1: 搬迁失败（原件保留）：\(move.sourceRelativePath) → \(error)")
        }
    }

    private func sweepEmptyShell(
        _ sweep: LibraryLayoutMigrationV2Plan.ShellSweep,
        timestamp: String,
        in documentsRoot: URL,
        into summary: inout Summary
    ) {
        let source = documentsRoot.appendingPathComponent(sweep.sourceRelativePath)
        guard fileManager.fileExists(atPath: source.path) else { return }
        // 空壳才搬：还有子项未搬走（某项失败）⇒ 留在原位（残留在 ③ 里体现 ⇒ 完成门不置位）。
        guard let remaining = try? fileManager.contentsOfDirectory(atPath: source.path),
              remaining.isEmpty else {
            AppLog.warn(.migration, "🫥 HiddenLayout v2.1: 空壳未清（仍有子项，留待下次启动）：\(sweep.sourceRelativePath)")
            return
        }
        let plannedDestination = documentsRoot.appendingPathComponent(sweep.destinationRelativePath)
        let destination = fileManager.fileExists(atPath: plannedDestination.path)
            ? uniqueLegacyDestination(for: plannedDestination, timestamp: timestamp)
            : plannedDestination
        let parent = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: parent.path) {
            do {
                try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                summary.createdDirectories.append(relativePath(parent, in: documentsRoot))
            } catch {
                summary.failed.append("createDirectory:\(relativePath(parent, in: documentsRoot)):\(error)")
                return
            }
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
            summary.sweptShells.append(sweep.sourceRelativePath)
        } catch {
            summary.failed.append("sweepShell:\(sweep.sourceRelativePath):\(error)")
            AppLog.error(.migration, "🫥 HiddenLayout v2.1: 空壳清扫失败（原件保留）：\(sweep.sourceRelativePath) → \(error)")
        }
    }

    /// 目标已被占 ⇒ 逐次追加 `-N` 的改名落点（**绝不覆盖**）。
    private func uniqueLegacyDestination(for destination: URL, timestamp: String) -> URL {
        let directory = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        var candidate = destination
        var attempt = 1
        while fileManager.fileExists(atPath: candidate.path), attempt < 100 {
            attempt += 1
            candidate = directory.appendingPathComponent(
                LibraryLayoutMigrationV2Rules.legacyName(name, timestamp: timestamp, attempt: attempt)
            )
        }
        return candidate
    }

    // MARK: - 计划

    /// 用真实文件系统构建目录视图并产出计划（规划的 IO 只在这一次注入里发生）。
    private func makePlan(
        in documentsRoot: URL,
        timestamp: String,
        referencedSourceRelativePaths: Set<String>
    ) -> LibraryLayoutMigrationV2Plan {
        let view = LibraryLayoutMigrationV2Planner.DirectoryView(
            exists: { [fileManager] relativePath in
                fileManager.fileExists(atPath: documentsRoot.appendingPathComponent(relativePath).path)
            },
            children: { [fileManager] relativePath in
                let url = documentsRoot.appendingPathComponent(relativePath)
                guard let entries = try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: []
                ) else {
                    return nil
                }
                return entries.map { entry in
                    LibraryLayoutMigrationV2Planner.RootEntry(
                        name: entry.lastPathComponent,
                        isDirectory: (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    )
                }
            }
        )
        return LibraryLayoutMigrationV2Planner.makePlan(
            .init(
                rootEntries: rootEntries(in: documentsRoot),
                referencedSourceRelativePaths: referencedSourceRelativePaths,
                timestamp: timestamp,
                source: view,
                destination: view
            )
        )
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
            AppLog.warn(.migration, "🫥 HiddenLayout v2.1: \(referenced.count) 个根条目被 DB 绝对路径引用，本轮跳过：\(referenced.sorted().joined(separator: ", "))")
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
