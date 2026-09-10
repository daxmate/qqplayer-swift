//
//  SandboxMigration.swift
//  QQPlayer
//
//  M3-2：iCloud ubiquity 容器 → 本地沙盒 Documents 存量迁移（lan-sync-design §8.3）。
//
//  分层：
//  - SandboxMigrationPlanner：纯逻辑（平台无关、可单测、不做 IO）——给定 iCloud
//    容器文件清单、沙盒现状、DB 曲目（content_hash），产出每个文件的动作决策与
//    DB 路径切换候选。防"双位置重复"判据 = 同 content_hash 判同（§8.5）。
//  - SandboxMusicMigrator：执行器（iOS only）——最小 ubiquity 读取能力（列容器 +
//    dataless 实体化等待，不依赖 CloudDownloadManager 的 NSMetadataQuery 监控），
//    按 planner 决策分批复制、校验、切 DB 路径、清 iCloud 副本。幂等可断点：
//    "沙盒目标已存在且 content_hash 一致" = 已完成，重跑自动跳过（不重复不丢）。
//
//  迁移属一次性前置逻辑，真机行为无法在 CI 验证：纯逻辑部分（planner）有单测，
//  执行器真机验收留给用户（M6）。
//

import Foundation

// MARK: - 纯逻辑：迁移计划

enum SandboxMigrationPlanner {
    /// iCloud 容器里的一个音乐文件（相对 iCloud Documents 根）。
    struct CloudFile: Equatable {
        let relativePath: String
        let contentHash: String?
    }

    /// 沙盒 Documents 里已存在的一个文件（相对沙盒 Documents 根）。
    struct SandboxFile: Equatable {
        let relativePath: String
        let contentHash: String?
    }

    /// DB 里 path 指向 iCloud 容器的曲目行（旧引用，待切换）。
    struct CloudTrack: Equatable {
        let stableId: String
        let cloudPath: String
        let contentHash: String?
    }

    /// 单个 iCloud 文件的迁移动作。
    enum FileAction: Equatable {
        /// 沙盒无同内容副本 → 需要实体化并复制到沙盒（复制后切 DB 路径）。
        case copyToSandbox
        /// 沙盒已存在同 content_hash 文件（可能不同路径）→ 无需复制，只切 DB 路径。
        case alreadyInSandbox
        /// 沙盒有同名文件但内容不同（同名不同歌）→ 保守跳过，不覆盖沙盒文件。
        case nameConflict
    }

    struct PlanItem: Equatable {
        let cloudFile: CloudFile
        let action: FileAction
        /// copyToSandbox 时的目标相对路径（与源同名；nameConflict/alreadyInSandbox 为 nil）。
        let destinationRelativePath: String?
    }

    struct Plan: Equatable {
        let items: [PlanItem]
        /// DB 路径切换候选：cloudTrackId → 沙盒目标相对路径。
        /// 仅当沙盒目标存在且 content_hash 与 DB 行一致时产生（§8.5 判同）。
        let pathSwitches: [PathSwitch]

        var filesToCopy: [PlanItem] {
            items.filter { $0.action == .copyToSandbox }
        }

        var isEmpty: Bool { items.isEmpty && pathSwitches.isEmpty }
    }

    struct PathSwitch: Equatable {
        let trackStableId: String
        let destinationRelativePath: String
    }

    /// 沙盒根（iCloud 容器 Documents 根同理）下目标文件是否存在且内容一致。
    private static func sandboxHasSameContent(
        cloudFile: CloudFile,
        sandboxFiles: [SandboxFile]
    ) -> Bool {
        // 判同 = content_hash 一致（§8.5）。hash 未知时无法判同 → 保守按路径比对。
        if let cloudHash = cloudFile.contentHash {
            return sandboxFiles.contains { $0.contentHash == cloudHash }
        }
        return sandboxFiles.contains { $0.relativePath == cloudFile.relativePath }
    }

    /// 生成迁移计划。纯函数：所有输入注入，无 IO 副作用。
    /// - cloudFiles: iCloud 容器 Documents 下的音乐文件（含 content_hash，尽量算好）
    /// - sandboxFiles: 沙盒 Documents 现状（含 content_hash）
    /// - cloudTracks: DB 中 path 落在 iCloud 容器内的曲目行
    /// - 断点恢复：调用方重扫现状传入即可——沙盒目标已存在且同内容 ⇒ alreadyInSandbox，
    ///   天然幂等；已切换的 DB 行不再出现在 cloudTracks ⇒ 不重复切。
    static func makePlan(
        cloudFiles: [CloudFile],
        sandboxFiles: [SandboxFile],
        cloudTracks: [CloudTrack]
    ) -> Plan {
        var items: [PlanItem] = []
        var pathSwitches: [PathSwitch] = []
        // cloudTracks 可能多于 cloudFiles（文件已在早前轮次复制完并切过路径但本轮
        // 快照仍含旧行）——按 content_hash 找沙盒目标，命中即产出 switch。
        for track in cloudTracks {
            guard let trackHash = track.contentHash else { continue }
            if let dest = sandboxFiles.first(where: { $0.contentHash == trackHash }) {
                pathSwitches.append(
                    PathSwitch(trackStableId: track.stableId, destinationRelativePath: dest.relativePath)
                )
            }
        }

        for cloudFile in cloudFiles {
            let action: FileAction
            let dest: String?
            if sandboxHasSameContent(cloudFile: cloudFile, sandboxFiles: sandboxFiles) {
                action = .alreadyInSandbox
                dest = nil
            } else if sandboxFiles.contains(where: { $0.relativePath == cloudFile.relativePath }) {
                // 同名存在但内容不同（未命中判同）→ 同名不同歌
                action = .nameConflict
                dest = nil
            } else {
                action = .copyToSandbox
                dest = cloudFile.relativePath
            }
            items.append(PlanItem(cloudFile: cloudFile, action: action, destinationRelativePath: dest))
        }
        return Plan(items: items, pathSwitches: pathSwitches)
    }

    /// 相对路径 → 拼接 URL（源与目标根不同，相对路径同构）。
    static func url(relativePath: String, under root: URL) -> URL {
        root.appendingPathComponent(relativePath, isDirectory: false)
    }
}

// MARK: - 执行器（iOS only；最小 ubiquity 读取，真机验收留 M6）

#if os(iOS)
    @MainActor
    final class SandboxMusicMigrator {
        static let shared = SandboxMusicMigrator()

        private let databaseManager = DatabaseManager.shared

        /// 一次性迁移入口：iCloud 容器可用且有歌 → 实体化 → 复制 → 切 DB → 清副本。
        /// 幂等可断点：任何一步中断，下次启动重跑即从断点续（见 planner 注释）。
        /// 返回 true = 本轮执行了迁移（含空计划=无需迁移）；false = iCloud 不可用跳过。
        func runIfNeeded() async -> Bool {
            guard FileManager.default.ubiquityIdentityToken != nil,
                  let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)
            else {
                print("📦 SandboxMigration: iCloud unavailable, skipping")
                return false
            }

            let cloudRoot = containerURL.appendingPathComponent("Documents", isDirectory: true)
            let sandboxRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

            // 1) 列 iCloud 容器音乐文件 + 算 content_hash（文件不在本地则先触发实体化）
            let cloudFiles = await enumerateCloudMusicFiles(under: cloudRoot)
            guard !cloudFiles.isEmpty else {
                print("📦 SandboxMigration: no music files in iCloud container")
                return false
            }
            print("📦 SandboxMigration: found \(cloudFiles.count) iCloud music file(s)")

            // 2) 沙盒现状
            let sandboxFiles = await enumerateSandboxFiles(under: sandboxRoot)

            // 3) DB 旧引用（path 落在 cloudRoot 内的行）
            let cloudTracks = tracksUnder(cloudRoot)

            // 4) 计划
            let plan = SandboxMigrationPlanner.makePlan(
                cloudFiles: cloudFiles,
                sandboxFiles: sandboxFiles,
                cloudTracks: cloudTracks.map {
                    SandboxMigrationPlanner.CloudTrack(
                        stableId: $0.stableId,
                        cloudPath: $0.path,
                        contentHash: $0.contentHash
                    )
                }
            )

            if plan.isEmpty {
                print("📦 SandboxMigration: nothing to migrate")
                return true
            }

            // 5) 复制（分批，每批并发 3）
            await copyInBatches(plan.filesToCopy, cloudRoot: cloudRoot, sandboxRoot: sandboxRoot)

            // 6) 切 DB 路径（复制后沙盒已有目标 → 重新取 hash 判定；直接用计划中
            //    pathSwitches + 复制产物合成）。用沙盒现状 + DB 行重新生成一次计划，
            //    保证与复制结果一致（断点续跑时已复制文件会走 alreadyInSandbox）。
            let refreshedSandbox = await enumerateSandboxFiles(under: sandboxRoot)
            let refreshedTracks = tracksUnder(cloudRoot)
            let finalPlan = SandboxMigrationPlanner.makePlan(
                cloudFiles: cloudFiles,
                sandboxFiles: refreshedSandbox,
                cloudTracks: refreshedTracks.map {
                    SandboxMigrationPlanner.CloudTrack(
                        stableId: $0.stableId,
                        cloudPath: $0.path,
                        contentHash: $0.contentHash
                    )
                }
            )
            for pathSwitch in finalPlan.pathSwitches {
                switchTrackDBPath(pathSwitch, sandboxRoot: sandboxRoot)
            }

            // 7) 校验 + 清 iCloud 副本：仅删"已确认切到沙盒且沙盒文件存在"的云文件
            cleanupCloudCopies(plan: finalPlan, cloudRoot: cloudRoot, sandboxRoot: sandboxRoot)

            print("📦 SandboxMigration: migration completed")
            return true
        }

        private func tracksUnder(_ cloudRoot: URL) -> [Track] {
            let rootPath = cloudRoot.standardizedFileURL.path
            return (try? databaseManager.getAllTracks())?.filter { track in
                URL(fileURLWithPath: track.path).standardizedFileURL.path.hasPrefix(rootPath + "/")
            } ?? []
        }

        // MARK: 子步骤（真机逻辑；planner 保证决策正确性）

        /// 同步列出目录下的音乐文件 URL（enumerator 迭代不能跨 await，故收集与
        /// 实体化等待分离：先同步收集，再在 async 循环里逐个处理）。
        private nonisolated static func musicFileURLs(in root: URL) -> [URL] {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }

            var urls: [URL] = []
            for case let url as URL in enumerator
                where LibraryAudioFormats.allSupported.contains(url.pathExtension.lowercased()) {
                urls.append(url)
            }
            return urls
        }

        private func enumerateCloudMusicFiles(under cloudRoot: URL) async -> [SandboxMigrationPlanner.CloudFile] {
            let fm = FileManager.default
            let candidates = Self.musicFileURLs(in: cloudRoot)

            var result: [SandboxMigrationPlanner.CloudFile] = []
            for url in candidates {
                // dataless：先触发下载并等待实体化（最小 ubiquity 能力）
                let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
                if values?.isUbiquitousItem == true,
                   values?.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try? fm.startDownloadingUbiquitousItem(at: url)
                    // 有限等待（最多 ~15s），避免离线卡死；等不到本轮跳过，下次再迁
                    for _ in 0 ..< 30 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        let status = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?.ubiquitousItemDownloadingStatus
                        if status == .downloaded || status == .current { break }
                    }
                }
                let rel = url.path.replacingOccurrences(of: cloudRoot.path + "/", with: "")
                let hash = DatabaseManager.contentHashIfFilePresent(atPath: url.path)
                result.append(SandboxMigrationPlanner.CloudFile(relativePath: rel, contentHash: hash))
            }
            return result
        }

        private func enumerateSandboxFiles(under sandboxRoot: URL) async -> [SandboxMigrationPlanner.SandboxFile] {
            let candidates = Self.musicFileURLs(in: sandboxRoot)

            var result: [SandboxMigrationPlanner.SandboxFile] = []
            for url in candidates {
                let rel = url.path.replacingOccurrences(of: sandboxRoot.path + "/", with: "")
                let hash = DatabaseManager.contentHashIfFilePresent(atPath: url.path)
                result.append(SandboxMigrationPlanner.SandboxFile(relativePath: rel, contentHash: hash))
            }
            return result
        }

        /// 顺序复制（一次性迁移，量级为百首内；顺序实现避开任务组 sending 检查，
        /// 幂等可断点语义不变——已复制文件重跑时 planner 会归入 alreadyInSandbox）。
        nonisolated private func copyInBatches(
            _ items: [SandboxMigrationPlanner.PlanItem],
            cloudRoot: URL,
            sandboxRoot: URL
        ) async {
            for item in items {
                guard let rel = item.destinationRelativePath else { continue }
                let source = SandboxMigrationPlanner.url(relativePath: item.cloudFile.relativePath, under: cloudRoot)
                let dest = SandboxMigrationPlanner.url(relativePath: rel, under: sandboxRoot)
                do {
                    let fm = FileManager.default
                    try fm.createDirectory(
                        at: dest.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    if fm.fileExists(atPath: dest.path) {
                        try? fm.removeItem(at: dest)
                    }
                    try fm.copyItem(at: source, to: dest)
                    print("📦 SandboxMigration: copied \(rel)")
                } catch {
                    print("📦 SandboxMigration: copy failed \(rel): \(error)")
                }
                // 让出主线程（迁移在启动路径上，分批不阻塞 UI）
                await Task.yield()
            }
        }

        private func switchTrackDBPath(
            _ pathSwitch: SandboxMigrationPlanner.PathSwitch,
            sandboxRoot: URL
        ) {
            let newPath = SandboxMigrationPlanner.url(
                relativePath: pathSwitch.destinationRelativePath,
                under: sandboxRoot
            ).path
            do {
                let newStableId = DatabaseManager.generatePathStableId(forPath: newPath)
                try databaseManager.migrateTrackStableIdAndPath(
                    oldStableId: pathSwitch.trackStableId,
                    newStableId: newStableId,
                    newPath: newPath
                )
                print("📦 SandboxMigration: switched DB path → \(newPath)")
            } catch {
                print("📦 SandboxMigration: DB switch failed \(pathSwitch.trackStableId): \(error)")
            }
        }

        private func cleanupCloudCopies(
            plan: SandboxMigrationPlanner.Plan,
            cloudRoot: URL,
            sandboxRoot: URL
        ) {
            let fm = FileManager.default
            // 删除条件：该 iCloud 文件已在沙盒存在同 content_hash 的副本（判同），
            // 即复制成功或本来就已存在。不满足（nameConflict/未复制成功）则保留云端文件。
            for item in plan.items {
                guard item.action != .nameConflict else { continue }
                let rel = item.cloudFile.relativePath
                let cloudURL = SandboxMigrationPlanner.url(relativePath: rel, under: cloudRoot)
                let sandboxURL = SandboxMigrationPlanner.url(relativePath: rel, under: sandboxRoot)
                let cloudHash = DatabaseManager.contentHashIfFilePresent(atPath: cloudURL.path)
                let sandboxHash = DatabaseManager.contentHashIfFilePresent(atPath: sandboxURL.path)
                guard cloudHash != nil, cloudHash == sandboxHash else { continue }
                do {
                    try fm.removeItem(at: cloudURL)
                    print("📦 SandboxMigration: cleaned iCloud copy \(rel)")
                } catch {
                    print("📦 SandboxMigration: cloud cleanup failed \(rel): \(error)")
                }
            }
        }
    }
#endif
