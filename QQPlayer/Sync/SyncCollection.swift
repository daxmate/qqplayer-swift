//
//  SyncCollection.swift
//  QQPlayer
//
//  局域网同步（S2, M3-3a）同步集合语义 + manifest 过滤（纯逻辑，零 IO）。
//
//  集合（docs/lan-sync-design.md §6.1「同步集合 v1：全库镜像 + 歌单/歌曲勾选」）：
//  - .all           全库镜像（该端曲库全部文件）
//  - .playlists(ids) 指定歌单（id = 歌单标识：本端 slug / 对端 stableId，跨端由
//                    M3-3b 的引用映射收口；v1 集合只在本端解释）
//  - .tracks(ids)   手动勾选歌曲（id = 歌曲 stableId）
//
//  过滤只做"条目 → 是否属于集合"的判定：歌单 → 歌曲 stableId 的展开是 DB 侧事实，
//  由调用方以 SyncCollectionMembers 注入（纯值），保证本文件可单测、零 IO。
//
//  删除语义配套：SyncManifestReconciler.deleteScope(...) 用同一 filter 推导
//  "本地哪些条目归同步管"，未入选的本地条目（私有区）永不出现在 toDelete。
//

import Foundation

/// 同步集合（线上载荷元素；Codable 手写风格 = kind + ids，字段稳定便于跨版本兼容）。
struct SyncCollection: Codable, Equatable, Sendable {
    /// 集合类型。
    enum Kind: String, Codable, Equatable, Sendable {
        case all
        case playlists
        case tracks
    }

    var kind: Kind
    /// playlists = 歌单标识列表；tracks = 歌曲 stableId 列表；all 忽略（空数组）。
    var ids: [String]

    /// 全库镜像。
    static let all = SyncCollection(kind: .all, ids: [])

    /// 指定歌单集合。
    static func playlists(_ ids: [String]) -> SyncCollection {
        SyncCollection(kind: .playlists, ids: ids)
    }

    /// 手动勾选歌曲集合。
    static func tracks(_ ids: [String]) -> SyncCollection {
        SyncCollection(kind: .tracks, ids: ids)
    }

    /// 选择性集合但一个 id 都没给（= 不选任何文件；与 .all 语义相反，不可混淆）。
    var isEmptySelection: Bool {
        kind != .all && ids.isEmpty
    }
}

/// 集合成员解析结果（纯值）：歌单 → 歌曲 stableId 的展开，由 DB 侧提供。
struct SyncCollectionMembers: Equatable, Sendable {
    /// 歌单标识 → 该歌单内歌曲 stableId 集合。
    var stableIdsByPlaylist: [String: Set<String>]

    init(stableIdsByPlaylist: [String: Set<String>] = [:]) {
        self.stableIdsByPlaylist = stableIdsByPlaylist
    }
}

extension SyncCollection {
    /// 集合内歌曲 stableId 全集。
    /// - .all → nil（无限制，代表"全部本地文件"，含尚未映射 stableId 的条目）
    /// - .tracks → ids
    /// - .playlists → 各歌单成员并集（未知歌单 → 空集，不报错；对端集合不可解释
    ///   时"选不出文件"比"误删文件"安全）
    func selectedStableIds(members: SyncCollectionMembers) -> Set<String>? {
        switch kind {
        case .all:
            return nil
        case .tracks:
            return Set(ids)
        case .playlists:
            var union: Set<String> = []
            for playlistID in ids {
                union.formUnion(members.stableIdsByPlaylist[playlistID] ?? [])
            }
            return union
        }
    }

    /// 集合过滤：entries → 属于该集合的条目（输出按 relativePath 升序，确定性）。
    /// 条目 stableId 为 nil（尚未与曲库行映射）时仅 .all 收录——选择性集合无从判定。
    func filter(_ entries: [ManifestEntry], members: SyncCollectionMembers = SyncCollectionMembers()) -> [ManifestEntry] {
        guard let selected = selectedStableIds(members: members) else {
            return entries.sorted { $0.relativePath < $1.relativePath }
        }
        return entries
            .filter { entry in entry.stableId.map { selected.contains($0) } ?? false }
            .sorted { $0.relativePath < $1.relativePath }
    }
}
