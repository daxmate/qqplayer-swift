//
//  SyncManifestReconciler.swift
//  QQPlayer
//
//  局域网同步（S2, M3-3a）manifest 对账纯逻辑（零 IO、可测）：
//  远端 manifest vs 本地 manifest →
//    - toFetch   ：本地缺失，或同路径但内容不同（需从对端拉取）
//    - toDelete  ：**仅同步集合内**且远端已消失（远端 manifest 无此路径）
//    - unchanged ：路径 + content_hash 一致
//    - protectedSkipped：本可删但因**私有区**豁免而被跳过的本地条目（诊断/审计）
//
//  删除语义（docs/lan-sync-design.md §6.1 硬要求）：
//  「只删除同步集合内 manifest 消失的项；Client 本地私有区（文件 App 导入 /
//   未配对来源）永不自动动。」
//  本文件只产出"待删列表 + 保护白名单判定"，**不删任何文件**——真实删除执行
//  （含 UI 确认、逐条落盘）归 M3-3b 接线。
//
//  内容判定策略：双侧 contentHash 均非空且相等 = 一致；任一侧为 nil（尚未指纹）
//  = 内容未知 = 保守判为"需拉取"（宁可多传一次，不可漏传导致两端内容不一致）。
//

import Foundation

/// 一次对账的结果（全部按 relativePath 升序，确定性）。
struct SyncManifestReconciliation: Equatable, Sendable {
    /// 需拉取的远端条目（本地缺失 / 内容不同）。
    var toFetch: [ManifestEntry]
    /// 需删除的本地条目（同步集合内、远端已消失、非私有区）。
    var toDelete: [ManifestEntry]
    /// 已一致的远端条目（路径 + content_hash 相同）。
    var unchanged: [ManifestEntry]
    /// 因私有区豁免被跳过删除的本地条目（不删；可观测）。
    var protectedSkipped: [ManifestEntry]

    /// 无差异（幂等重跑判据）。
    var isEmpty: Bool {
        toFetch.isEmpty && toDelete.isEmpty
    }
}

/// 删除范围（纯值）：本地哪些条目归同步管 + 私有区豁免名单。
struct SyncDeleteScope: Equatable, Sendable {
    /// 参与删除判定的本地相对路径集合（= 本地条目经同步集合过滤后的结果）。
    /// nil = 全库镜像（所有本地条目都归同步管）。
    var managedRelativePaths: Set<String>?
    /// 私有区豁免：本地非同步来源（文件 App 导入 / 未配对来源），**永不删除**。
    /// 优先级高于 managedRelativePaths。
    var protectedRelativePaths: Set<String>

    /// 全库镜像 + 无豁免。
    static let mirrorAll = SyncDeleteScope()

    init(managedRelativePaths: Set<String>? = nil, protectedRelativePaths: Set<String> = []) {
        self.managedRelativePaths = managedRelativePaths
        self.protectedRelativePaths = protectedRelativePaths
    }

    /// 是否属于私有区（豁免删除）。
    func isProtected(_ relativePath: String) -> Bool {
        protectedRelativePaths.contains(relativePath)
    }

    /// 是否归同步管（可被删除的条件之一）。
    func manages(_ relativePath: String) -> Bool {
        guard !isProtected(relativePath) else { return false }
        guard let managed = managedRelativePaths else { return true }
        return managed.contains(relativePath)
    }
}

enum SyncManifestReconciler {
    /// 对账（纯函数）。
    /// - remote：对端在同步集合下的 manifest（已按集合过滤）。
    /// - local：本端本地 manifest（**全量**，含私有区；删除判定由 deleteScope 收口）。
    static func reconcile(
        remote: [ManifestEntry],
        local: [ManifestEntry],
        deleteScope: SyncDeleteScope = .mirrorAll
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

        // 远端已消失的本地条目：仅"同步集合内且非私有区"才进 toDelete
        var toDelete: [ManifestEntry] = []
        var protectedSkipped: [ManifestEntry] = []
        for entry in localByPath.values where remoteByPath[entry.relativePath] == nil {
            if deleteScope.isProtected(entry.relativePath) {
                protectedSkipped.append(entry)
            } else if deleteScope.manages(entry.relativePath) {
                toDelete.append(entry)
            }
            // 否则：不在同步集合内 —— 不是同步管的事，静默忽略（不删不报）
        }

        return SyncManifestReconciliation(
            toFetch: sorted(toFetch),
            toDelete: sorted(toDelete),
            unchanged: sorted(unchanged),
            protectedSkipped: sorted(protectedSkipped)
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

    /// 由同步集合推导删除范围：managed = 本地条目经集合过滤后的路径集；
    /// protected = 显式传入的私有区名单（调用方从"非同步来源"标记/清单取得）。
    /// `.all` 镜像回落为 nil（"全部本地文件"，含对账后新出现的条目），
    /// 与 `SyncDeleteScope.mirrorAll` 同义。
    static func deleteScope(
        collection: SyncCollection,
        members: SyncCollectionMembers = SyncCollectionMembers(),
        localEntries: [ManifestEntry],
        protectedRelativePaths: Set<String> = []
    ) -> SyncDeleteScope {
        guard collection.kind != .all else {
            return SyncDeleteScope(managedRelativePaths: nil, protectedRelativePaths: protectedRelativePaths)
        }
        let managed = Set(collection.filter(localEntries, members: members).map(\.relativePath))
        return SyncDeleteScope(managedRelativePaths: managed, protectedRelativePaths: protectedRelativePaths)
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
