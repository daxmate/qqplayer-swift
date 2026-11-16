//
//  SyncCollectionSelection+Bundle.swift
//  QQPlayer
//
//  P1b（2026-11-16）智能源整组勾选 = 快照：**bundle 形态的派生/规范化/纯转移**。
//  从 `SyncCollectionSelection.swift` 原样搬出（结构预算：单文件 ≤ 600 行），
//  语义零变化；声明仍是 `SyncCollectionSelection` 的成员，只是换了文件。
//
//  口径（决策 7/9/10）见 `SyncCollectionSelection.swift` 头部与 `docs/lan-sync-design.md`。
//

import Foundation

// MARK: - bundle 形态（P1b：智能源快照）

extension SyncCollectionSelection {
    /// bundle 里的「歌单标识」校验：真实歌单 / 收藏，**拒绝** `@smart:*`
    /// （智能源只能进 `smartSnapshots`）。`.playlists` 的校验口径**不变**（读兼容）。
    static func isValidBundlePlaylistID(_ id: String) -> Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return isValidPlaylistID(trimmed) && !isSmartSourceID(trimmed)
    }

    /// 规范化 bundle 的歌单标识：同 `normalizePlaylistIDs`，额外拒绝 `@smart:*`。
    static func normalizeBundlePlaylistIDs(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for id in raw {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidBundlePlaylistID(trimmed) else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            out.append(trimmed)
        }
        return out.sorted()
    }

    /// 规范化快照表：键必须是合法 `@smart:*`；值走**既有**相对路径规范化
    /// （`SyncFetchRequest.normalize`：丢非法 / 去重 / 升序）——不另写第二份规则。
    /// 空列表整键丢弃（空快照 = 没勾，与「空选择 = 不推不拉」同口径）。
    static func normalizeSmartSnapshots(_ raw: [String: [String]]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for (sourceID, paths) in raw {
            let key = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidSmartSourceID(key) else { continue }
            let normalized = SyncFetchRequest.normalize(paths)
            guard !normalized.isEmpty else { continue }
            out[key] = normalized
        }
        return out
    }

    /// 是否「库级」选择（不过滤）。
    var isLibraryWide: Bool {
        if case .all = self { return true }
        return false
    }

    /// 规范化后的歌单标识（`.playlists` / `.playlistBundle` 的**真实歌单**部分；
    /// 其余 → nil）。bundle 只给真实歌单：智能源标识不在其中（它们在快照表里）。
    var playlistIDs: [String]? {
        switch self {
        case let .playlists(raw):
            return SyncCollectionSelection.normalizePlaylistIDs(raw)
        case let .playlistBundle(playlists, _):
            return SyncCollectionSelection.normalizeBundlePlaylistIDs(playlists)
        case .all, .relativePaths:
            return nil
        }
    }

    /// 规范化后的智能源快照表（非 `.playlistBundle` → nil）。
    var smartSnapshots: [String: [String]]? {
        guard case let .playlistBundle(_, snapshots) = self else { return nil }
        return SyncCollectionSelection.normalizeSmartSnapshots(snapshots)
    }

    /// 规范化后的相对路径（非 `.relativePaths` → nil）。
    var relativePaths: [String]? {
        guard case let .relativePaths(raw) = self else { return nil }
        return SyncFetchRequest.normalize(raw)
    }

    /// **空选择集语义 = 不推不拉**（决策 9：同步集合 = 用户显式选择）。
    /// 注意与 `.all`（全库）**语义相反**，任何调用方都不许把两者混用。
    var isEmptySelection: Bool {
        switch self {
        case .all:
            return false
        case let .playlists(raw):
            return SyncCollectionSelection.normalizePlaylistIDs(raw).isEmpty
        case let .relativePaths(raw):
            return SyncFetchRequest.normalize(raw).isEmpty
        case let .playlistBundle(playlists, snapshots):
            return SyncCollectionSelection.normalizeBundlePlaylistIDs(playlists).isEmpty
                && SyncCollectionSelection.normalizeSmartSnapshots(snapshots).isEmpty
        }
    }

    /// 规范化后的等价选择集（非法值一律丢弃；`.all` 原样）。
    var normalized: SyncCollectionSelection {
        switch self {
        case .all:
            return .all
        case let .playlists(raw):
            return .playlists(SyncCollectionSelection.normalizePlaylistIDs(raw))
        case let .relativePaths(raw):
            return .relativePaths(SyncFetchRequest.normalize(raw))
        case let .playlistBundle(playlists, snapshots):
            return .playlistBundle(
                playlists: SyncCollectionSelection.normalizeBundlePlaylistIDs(playlists),
                smartSnapshots: SyncCollectionSelection.normalizeSmartSnapshots(snapshots)
            )
        }
    }

    // MARK: 纯转移（P1b：智能源勾选 / 取消，零 IO）

    /// 勾选智能源：把**当时**展开的相对路径写入快照，真实歌单原样保留。
    ///
    /// - 空路径（源 0 首）→ **不写入**，原样返回（调用方按未勾选处理并给可见反馈）；
    /// - 已有同源快照 → 整体替换（再次勾选 = 重新取当时曲目，不做并集累加）；
    /// - `self` 为 `.playlists` 时迁移成 `.playlistBundle`；`.all` / `.relativePaths`
    ///   与歌单模式互斥（调用方不应走到），按「只保留该快照」保守处理。
    func settingSmartSnapshot(sourceID: String, paths: [String]) -> SyncCollectionSelection {
        let key = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SyncCollectionSelection.isValidSmartSourceID(key) else { return self }
        let normalizedPaths = SyncFetchRequest.normalize(paths)
        guard !normalizedPaths.isEmpty else { return self }

        var playlists: [String] = []
        var snapshots: [String: [String]] = [:]
        switch self {
        case let .playlistBundle(rawPlaylists, rawSnapshots):
            playlists = SyncCollectionSelection.normalizeBundlePlaylistIDs(rawPlaylists)
            snapshots = SyncCollectionSelection.normalizeSmartSnapshots(rawSnapshots)
        case let .playlists(raw):
            playlists = SyncCollectionSelection.normalizeBundlePlaylistIDs(raw)
        case .all, .relativePaths:
            break
        }
        snapshots[key] = normalizedPaths
        return .playlistBundle(playlists: playlists, smartSnapshots: snapshots)
    }

    /// 取消勾选智能源：删该源快照；两个集合都空时回落 `.playlists([])`（= 空选择，
    /// 不推不拉）。非 bundle 形态没有可删的快照 → 原样返回。
    func removingSmartSnapshot(sourceID: String) -> SyncCollectionSelection {
        let key = sourceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case let .playlistBundle(rawPlaylists, rawSnapshots) = self else { return self }
        var snapshots = SyncCollectionSelection.normalizeSmartSnapshots(rawSnapshots)
        snapshots.removeValue(forKey: key)
        let playlists = SyncCollectionSelection.normalizeBundlePlaylistIDs(rawPlaylists)
        // 快照空了就退回既有 `.playlists` 形态（不让空快照表在存档里常驻）
        guard !snapshots.isEmpty else {
            return playlists.isEmpty ? .playlists([]) : .playlists(playlists)
        }
        return .playlistBundle(playlists: playlists, smartSnapshots: snapshots)
    }
}
