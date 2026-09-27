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
//  跨路径内容身份（2026-09-27 去重 bug 修复）：本端**任意路径**已有同 contentHash
//  ⇒ 同一首歌（两台机器命名顺序不同：`歌手 - 标题` vs `标题-歌手`）⇒ 进 `alreadyPresent`，
//  不传输、不落盘（契约：`docs/sync-contract.md`「身份键 = `content_hash`（跨端，优先）」）。
//  判定只此一处——`contentHashIndex(_:)`（建索引）+ `contentAlreadyHeld(entry:otherContentHashes:)`
//  （判同曲）是同一条语义的两半，拉取/推送两端一律复用，不得另写第二份。
//  歌词命名空间不参与跨路径判定（理由见 `contentHashIndex` 文档）。
//

import Foundation

/// 一次对账的结果（全部按 relativePath 升序，确定性）。
struct SyncManifestReconciliation: Equatable, Sendable {
    /// 需拉取的远端条目（本地缺该路径且本端无同内容 / 同路径内容不同）。
    var toFetch: [ManifestEntry]
    /// 已一致的远端条目（路径 + content_hash 相同）。
    var unchanged: [ManifestEntry]
    /// 本端**已有同内容**（content_hash 相同、**路径不同**）的远端条目——内容身份判同曲，
    /// 不传输不落盘。**语义与 `unchanged` 不同**：`unchanged` = 同路径同内容。
    var alreadyPresent: [ManifestEntry] = []

    /// 无动作可做（幂等重跑判据）：没有需拉取的远端条目（全部已一致 / 本端已有同内容）。
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
        let localContentHashes = contentHashIndex(local)

        var toFetch: [ManifestEntry] = []
        var unchanged: [ManifestEntry] = []
        var alreadyPresent: [ManifestEntry] = []
        for entry in remoteByPath.values {
            guard let localEntry = localByPath[entry.relativePath] else {
                // 本端没有该**路径**：再按**内容身份**判一次——本端任意路径已有同
                // contentHash 就是同一首歌（命名顺序不同），不重复传输、不重复落盘。
                if contentAlreadyHeld(entry: entry, otherContentHashes: localContentHashes) {
                    alreadyPresent.append(entry)
                } else {
                    toFetch.append(entry)
                }
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
            unchanged: sorted(unchanged),
            alreadyPresent: sorted(alreadyPresent)
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

    // MARK: - 跨路径内容身份（「对方已有同内容」唯一入口）

    /// 参与内容身份判定的指纹索引（索引侧；判定侧 = `contentAlreadyHeld`）。
    ///
    /// 收录条件：`contentHash` **非空**（nil / 空串 = 尚未指纹，不得参与判定）——
    /// 未指纹条目若入索引，两个不同文件都会被判成「同内容」⇒ 文件永不传输（静默丢数据）。
    ///
    /// 歌词条目**不入索引/不参与判定**：歌词的线上身份是**所属歌曲**指纹（wire 路径
    /// `@lyrics/{歌曲 content_hash}.json`），条目自身的 `contentHash` 是歌词文件字节哈希；
    /// 两份不同歌曲的歌词文件字节可以完全相同（例如都没有对齐结果），跨路径按字节判同曲
    /// 会漏传歌词（F2「只补不覆盖」按 wire 路径判有无）⇒ 歌词链路行为保持逐字不变。
    static func contentHashIndex(_ entries: [ManifestEntry]) -> Set<String> {
        Set(entries.compactMap { entry -> String? in
            guard !SyncLyricsNamespace.isLyricsPath(entry.relativePath) else { return nil }
            guard let hash = entry.contentHash, !hash.isEmpty else { return nil }
            return hash
        })
    }

    /// 「对方已有同内容」的**唯一**判定入口（跨端同曲，路径无关）。
    /// - 判据：条目 `contentHash` 非空、且命中 `otherContentHashes`（= `contentHashIndex` 产出）。
    /// - 未指纹（nil / 空串）、或歌词条目 → `false`（保守 = 退回既有按路径判定）。
    static func contentAlreadyHeld(entry: ManifestEntry, otherContentHashes: Set<String>) -> Bool {
        guard !SyncLyricsNamespace.isLyricsPath(entry.relativePath) else { return false }
        guard let hash = entry.contentHash, !hash.isEmpty else { return false }
        return otherContentHashes.contains(hash)
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
