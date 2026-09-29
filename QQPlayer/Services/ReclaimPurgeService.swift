//
//  ReclaimPurgeService.swift
//  QQPlayer
//
//  回收区「彻底删除 / 清空」的**唯一入口**（2026-09-29 回收区管理批）。
//
//  用户口径（2026-09-29 原话）：「2、清空」；细化口径：删除 = **彻底删除**（不可恢复）
//  + **二次确认**（文案含数量与占用），另有「清空整个回收区」。
//
//  范围（用户 2026-09-29 08:22 收窄）：只做**生产回收区** `<曲库根>/.Trash`。
//
//  行为：
//   · 逐条 `removeItem`（**永久删除**，回收区里没有更下一层容器）；
//   · 返回删除计数与释放字节；**失败逐条如实上报**（文件名 + 原因），不吞错、不中断其余；
//   · 只删文件，不碰曲库 DB（回收区文件本来就不在库里 —— 它们是在删除时被移出曲库根的）；
//   · 目录本身留着（空目录无副作用，下次删除继续用）。
//
//  与 `TrackDeletionService` 的边界：那条链是「删一首歌」（文件动作 + 删曲目库引用），
//  由 `TrackDeletionShapeContractTests` 守护其唯一性；本链**不碰 DB 引用**，只是清理回收区
//  里的文件，故不是「第二份删除实现」（`removeItem` 且无 `deleteTrack(` —— 形状判据明确排除）。
//

import Foundation

/// 一次彻底删除的结果（计数 + 释放字节 + 逐条失败原因）。
struct ReclaimPurgeSummary: Equatable {
    /// 成功删除的条目数。
    var deleted = 0
    /// 释放的字节（按枚举时的占用计）。
    var freedBytes: Int64 = 0
    /// 失败条目（`文件名: 原因`，逐条如实上报）。
    var failures: [String] = []

    var failedCount: Int { failures.count }
}

enum ReclaimPurgeService {
    /// 彻底删除给定条目（不可恢复）。失败不中断其余条目。
    static func purge(
        _ entries: [ReclaimAreaEntry],
        fileManager: FileManager = .default
    ) -> ReclaimPurgeSummary {
        var summary = ReclaimPurgeSummary()
        for entry in entries {
            guard fileManager.fileExists(atPath: entry.url.path) else {
                // 界面期间已被别处删除：不算失败，也不计释放（占用已不在了）。
                AppLog.info(.general, "🗑️ reclaim purge: 条目已不在，跳过 \(entry.existingName)")
                continue
            }
            do {
                try fileManager.removeItem(at: entry.url)
                summary.deleted += 1
                summary.freedBytes += entry.byteSize
            } catch {
                AppLog.warn(.general, "⚠️ reclaim purge: 删除失败 \(entry.existingName)：\(error)")
                summary.failures.append("\(entry.existingName): \(error)")
            }
        }
        AppLog.info(
            .general,
            "🗑️ reclaim purge: deleted=\(summary.deleted) freed=\(summary.freedBytes)B failed=\(summary.failedCount)"
        )
        return summary
    }

    /// 清空整个生产回收区（枚举 → 全量彻底删除）。
    static func purgeAll(
        libraryRoot: URL,
        fileManager: FileManager = .default
    ) -> ReclaimPurgeSummary {
        purge(
            ReclaimAreaCatalog.entries(libraryRoot: libraryRoot, fileManager: fileManager),
            fileManager: fileManager
        )
    }
}
