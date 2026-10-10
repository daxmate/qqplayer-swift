//
//  MacDocumentsStorageRelocation.swift
//  QQPlayer
//
//  target: shared（**唯一调用方是 macOS 组合根** QQPlayerMacApp；逻辑保持平台无关，
//  以便 iOS 测试 target 用合成目录覆盖 —— 纯 Foundation，无 AppKit / 平台分支）
//
//  macOS App 数据**一次性迁出** ~/Documents → ~/Library/Application Support/QQPlayerMac/
//  （2026-10-10）：用户开了 iCloud「桌面与文稿文件夹」后 ~/Documents 即 iCloud 云盘，
//  App 数据不该落那里。**iOS 端零变化**（iOS 仍落 .qqplayer/… 沙盒隐藏根）。
//
//  —— 硬约束（照 LibraryLayoutMigrationV2Migrator 的模式）——
//   · **只搬不删**：全程只用 moveItem（同卷原子改名）—— 写入新位置成功即源消失，
//     失败则源**原样保留**、下次启动重试；**没有任何删除 / 覆盖动作**。
//   · **冲突不覆盖**：目标已存在 → 跳过并计数（绝不覆盖，也绝不删源）。
//   · **幂等 / 可重入**：完成门 = UserDefaults 标记（成功才置位）；未置位每次启动重跑，
//     逐项动作本身幂等（源不存在 = 无事发生）。
//   · **不阻塞启动**：清单小（十几项），同步跑；失败项不中断其余项。
//   · **可观测**：搬运 / 跳过 / 失败计数落 AppLog；run 返回 Summary 供测试断言。
//   · **干跑**：run(dryRun: true) 或启动参数 --mac-documents-relocation-dry-run：只统计不搬。
//   · **绝不触碰**：~/Music/QQPlayer（曲库根，MacLibraryRoot）与任何 iOS / App Group 路径。
//
//  —— 与旧位置只读兼容的关系 ——
//  搬迁后旧位置的文件不再被读（各消费点读新位置 + 旧位置只读兜底，见 StateManager /
//  AlignedLyricsStore / LyricsManager / LyricsSearch）。搬迁失败（源保留）时，这些只读兜底
//  保证用户既有数据仍可见、不被静默丢。
//

import Foundation

enum MacDocumentsStorageRelocation {
    /// 完成门（成功且无失败项才置位 → 否则下次启动重试）。
    static let completionDefaultsKey = "mac.documentsStorageRelocationCompleted.v1"

    /// 干跑开关（启动参数；真机先看清单再放手）。
    static let dryRunLaunchArgument = "--mac-documents-relocation-dry-run"

    /// 一轮搬迁的账目（日志 / 干跑清单 / 测试断言用）。
    struct Summary: Equatable, Sendable {
        var isDryRun = false
        /// 完成门已置位 → 本轮直接跳过（未做任何事）。
        var alreadyCompleted = false
        /// 已搬入的目标落点（相对 App 数据根）。
        var moved: [String] = []
        /// 跳过（目标已存在 = 冲突不覆盖）。
        var skipped: [String] = []
        /// 失败（源保留，下次重试；不中断其余项）。
        var failed: [String] = []

        var movedCount: Int { moved.count }
        var skippedCount: Int { skipped.count }
        var failedCount: Int { failed.count }
        /// 完成 = 无失败项（跳过 = 早已搬过 / 目标被占，不算失败）。
        var didComplete: Bool { failed.isEmpty }

        /// 一行摘要（日志与测试共用）。
        var logLine: String {
            "搬迁=\(movedCount) 跳过=\(skippedCount) 失败=\(failedCount)"
        }
    }

    /// 一条搬迁项：旧 Documents 相对组件 → 新 App Support 相对组件（默认同名，子路径名保持不变）。
    struct Item: Equatable {
        let legacy: [String]
        let destination: [String]
        let isFile: Bool

        init(legacy: [String], destination: [String]? = nil, file: Bool) {
            self.legacy = legacy
            self.destination = destination ?? legacy
            self.isFile = file
        }
    }

    /// 搬迁清单（**迁移映射表**：旧目录 / 文件名的唯一落点）。
    ///
    /// 名字尽量复用 LibraryRoot 常量（Artwork / Lyrics / Logs / 各状态文件名）；无常量者
    /// （缓存目录名、meta、歌单目录等）就地字面量 —— 本文件即这些旧名的「搬迁源」清单
    /// （与 LibraryLayoutMigrationPlan / …V2Plan 同类）。
    static let items: [Item] = [
        Item(legacy: [LibraryRoot.artworkDirectoryName], file: false),
        Item(legacy: [LibraryRoot.lyricsDirectoryName], file: false),
        Item(legacy: ["lyrics-aligned"], file: false),
        Item(legacy: ["lyrics-cache"], file: false),
        Item(legacy: ["SpotifyCache"], file: false),
        Item(legacy: ["DiscogsCache"], file: false),
        Item(legacy: ["HybridMusicCache"], file: false),
        Item(legacy: ["meta"], file: false),
        Item(legacy: [LibraryRoot.logsDirectoryName], file: false),
        Item(legacy: ["qqplayer-playlists"], file: false),
        Item(legacy: [LibraryRoot.favoritesFileName], file: true),
        Item(legacy: [LibraryRoot.playerStateFileName], file: true),
        Item(legacy: [LibraryRoot.pairingFileName], file: true),
        Item(legacy: [LibraryRoot.externalBookmarksFileName], file: true),
        // 旧位置 Documents/ArtworkMapping.plist → 新 Artwork/ArtworkMapping.plist
        // （改名前的旧位置；与上一条 Documents/Artwork/ 同目，放最后以免与目录搬迁抢目标）。
        Item(
            legacy: [LibraryRoot.artworkMappingFileName],
            destination: [LibraryRoot.artworkDirectoryName, LibraryRoot.artworkMappingFileName],
            file: true
        ),
    ]

    /// 干跑是否被请求（启动参数）。
    static func dryRunRequested(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(dryRunLaunchArgument)
    }

    /// 执行一轮搬迁（同步；生产在 QQPlayerMacApp.init 最早处调用，测试直调）。
    ///
    /// 幂等：完成门已置位且非干跑 → 直接返回（不做任何事）。
    /// - Parameters:
    ///   - fileManager: Documents / Application Support 根的解析缝（测试注入临时根）。
    ///   - defaults: 完成门存储（测试注入独立 suite）。
    ///   - dryRun: 只统计不搬、不置完成门。
    @discardableResult
    static func run(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard,
        dryRun: Bool = false
    ) -> Summary {
        var summary = Summary()
        summary.isDryRun = dryRun

        if !dryRun, defaults.bool(forKey: completionDefaultsKey) {
            summary.alreadyCompleted = true
            AppLog.info(.migration, "📦 MacDocumentsRelocation: 完成门已置位，跳过（幂等）")
            return summary
        }

        guard let documents = LibraryRoot.documentsRootURL(fileManager: fileManager) else {
            summary.failed.append("documentsRootUnavailable")
            AppLog.error(.migration, "📦 MacDocumentsRelocation: Documents 不可解析，本轮跳过")
            return summary
        }
        guard let appSupportRoot = LibraryRoot.macAppSupportRootURL(fileManager: fileManager) else {
            summary.failed.append("appSupportRootUnavailable")
            AppLog.error(.migration, "📦 MacDocumentsRelocation: Application Support 不可解析，本轮跳过")
            return summary
        }

        for item in items {
            let source = resolve(documents, item.legacy, isFile: item.isFile)
            let destination = resolve(appSupportRoot, item.destination, isFile: item.isFile)
            let key = item.destination.joined(separator: "/")

            // 源不存在 = 无事发生（幂等；不计数）。
            guard fileManager.fileExists(atPath: source.path) else { continue }

            // 冲突不覆盖：目标已存在 → 跳过并计数（源原样留旧位置）。
            if fileManager.fileExists(atPath: destination.path) {
                summary.skipped.append(key)
                AppLog.warn(.migration, "📦 MacDocumentsRelocation: 目标已存在，跳过（不覆盖）：\(key)")
                continue
            }

            if dryRun {
                summary.moved.append(key)
                AppLog.info(.migration, "📦 MacDocumentsRelocation（干跑）将要搬：\(key)")
                continue
            }

            do {
                let parent = destination.deletingLastPathComponent()
                if !fileManager.fileExists(atPath: parent.path) {
                    try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
                }
                // 只搬不删：同卷原子改名 —— 成功即源消失、目标就位；抛错即源原样保留。
                try fileManager.moveItem(at: source, to: destination)
                summary.moved.append(key)
            } catch {
                // 失败不中断：源保留、下次启动重试。
                summary.failed.append("\(key):\(error)")
                AppLog.error(.migration, "📦 MacDocumentsRelocation: 搬迁失败（源保留）：\(key) → \(error)")
            }
        }

        let role = dryRun ? "（干跑）" : ""
        AppLog.info(.migration, "📦 MacDocumentsRelocation\(role): \(summary.logLine)")

        guard !dryRun else { return summary }
        if summary.didComplete {
            defaults.set(true, forKey: completionDefaultsKey)
        } else {
            AppLog.warn(.migration, "📦 MacDocumentsRelocation: 有失败项，完成门不置位（下次启动重试）")
        }
        return summary
    }

    /// 清完成门（测试与人工重跑用；生产不调用）。
    static func resetCompletionGate(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: completionDefaultsKey)
    }

    /// 相对组件 → 绝对 URL（末组件为文件时 isFile 控制目录位）。
    private static func resolve(_ base: URL, _ components: [String], isFile: Bool) -> URL {
        var url = base
        for (index, component) in components.enumerated() {
            let isLast = index == components.count - 1
            url.appendPathComponent(component, isDirectory: !(isLast && isFile))
        }
        return url
    }
}
