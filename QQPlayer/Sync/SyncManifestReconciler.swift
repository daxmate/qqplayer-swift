//
//  SyncManifestReconciler.swift
//  QQPlayer
//
//  局域网同步（S2, M3-3a）manifest 对账纯逻辑（零 IO、可测）：
//  远端 manifest vs 本地 manifest →
//    - toFetch   ：本地缺失，或同路径但内容不同（需从对端拉取）
//    - unchanged ：路径 + content_hash 一致
//
//  同步语义（docs/lan-sync-design.md §6.1 硬要求）：**不传播删除**。
//  任一端删除歌曲都是本地事务——iPhone 删歌不影响 Mac，Mac 删歌不影响 iPhone；
//  同步只做「补齐缺失 + 内容不同则更新」，**永不因对端 manifest 变化而删任何一端
//  文件**。因此本文件只产出"待拉取"决策：远端没有而本地有的条目不是同步的事，
//  直接不看（既不拉取也不删除，本端原样保留）。
//
//  内容判定策略：双侧 contentHash 均非空且相等 = 一致；任一侧为 nil（尚未指纹）
//  = 内容未知 = 保守判为"需拉取"（宁可多传一次，不可漏传导致两端内容不一致）。
//

import Foundation

/// 一次对账的结果（全部按 relativePath 升序，确定性）。
struct SyncManifestReconciliation: Equatable, Sendable {
    /// 需拉取的远端条目（本地缺失 / 内容不同）。
    var toFetch: [ManifestEntry]
    /// 已一致的远端条目（路径 + content_hash 相同）。
    var unchanged: [ManifestEntry]

    /// 无动作可做（幂等重跑判据）：远端条目全部已一致。
    var isEmpty: Bool {
        toFetch.isEmpty
    }
}

enum SyncManifestReconciler {
    /// 对账（纯函数）。
    /// - remote：对端在同步集合下的 manifest（已按集合过滤）。
    /// - local：本端本地 manifest（全量）；仅用于判定"本地是否已有该路径 / 内容
    ///   是否相同"，**不参与任何删除判定**（不传播删除）。
    static func reconcile(
        remote: [ManifestEntry],
        local: [ManifestEntry]
    ) -> SyncManifestReconciliation {
        let remoteByPath = indexByPath(remote)
        let localByPath = indexByPath(local)

        var toFetch: [ManifestEntry] = []
        var unchanged: [ManifestEntry] = []
        for entry in remoteByPath.values {
            guard let localEntry = localByPath[entry.relativePath] else {
                toFetch.append(entry)
                continue
            }
            if contentMatches(local: localEntry, remote: entry) {
                unchanged.append(entry)
            } else {
                toFetch.append(entry)
            }
        }

        // 远端没有而本地有的条目：不传播删除 —— 本端保留，不进任何待处理列表。
        return SyncManifestReconciliation(
            toFetch: sorted(toFetch),
            unchanged: sorted(unchanged)
        )
    }

    /// 内容是否一致：双侧 contentHash 均非空且相等。nil = 未知 = 不一致（保守）。
    /// internal：M3-3b 若引入 size/mtime 快捷判定，复用同一处判定语义。
    static func contentMatches(local: ManifestEntry, remote: ManifestEntry) -> Bool {
        guard let localHash = local.contentHash, let remoteHash = remote.contentHash else {
            return false
        }
        return localHash == remoteHash
    }

    // MARK: - 内部

    /// 按路径索引（重复路径 later wins：调用方给的是最终快照，后者更新）。
    private static func indexByPath(_ entries: [ManifestEntry]) -> [String: ManifestEntry] {
        var index: [String: ManifestEntry] = [:]
        for entry in entries {
            index[entry.relativePath] = entry
        }
        return index
    }

    private static func sorted(_ entries: [ManifestEntry]) -> [ManifestEntry] {
        entries.sorted { $0.relativePath < $1.relativePath }
    }
}
