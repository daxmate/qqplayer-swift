//
//  SyncSelectionStore.swift
//  QQPlayer
//
//  M6（T2，2026-09-11）同步选择集**持久化**（UserDefaults JSON，平台无关，可单测）。
//
//  背景：`SyncCollectionSelection`（`QQPlayer/Sync/SyncCollectionSelection.swift`）
//  是纯值类型，没有存储；M6 同步页需要一个「上次勾了什么」的持久化入口
//  （docs/m6-sync-ui-plan.md §5.3：v1 用 UserDefaults JSON 够用，将来要多端/多主机
//  区分再上表）。
//
//  为什么自建私有 DTO 而不是给 `SyncCollectionSelection` 加 Codable：
//  M6 硬约束「禁止修改 `QQPlayer/Sync/` 下任何文件」（另一并行任务共用该目录），
//  且选择集的**线上/本端语义分离**（见该文件头注释）——存档形态是**本端**实现细节，
//  不该反向绑定到模型上。因此本文件内自建 `StoredSelection`（带版本字段），
//  编解码只在此处。
//
//  失败语义（契约 C2 硬要求）：缺失 / 损坏 / 非法 / 未知 kind 一律回退
//  **空选择** `.playlists([])`（= 不推不拉），绝不抛、绝不崩。
//
//  为什么注入 UserDefaults：单测要用独立 suite，不能污染 `.standard`
//  （同 `DatabaseManager` 的测试缝思路）。
//

import Foundation

/// 同步选择集读写（UserDefaults JSON）。
struct SyncSelectionStore {
    /// 存档键（v1 单主机会话；将来多主机再按主机 ID 分键）。
    ///
    /// ⚠️ 键名里的 `v1` 是**键的**版本（P1b 存档格式已升到 payload 内 `version = 2`）：
    /// 改键名会让已有用户的选择集凭空消失，而 v1 存档本来就按「无 kind / 旧 kind」兼容。
    static let defaultKey = "sync.collectionSelection.v1"

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = SyncSelectionStore.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    /// 读存档。缺失 / 损坏 / 非法值 → 空选择（`.playlists([])`），绝不抛。
    func load() -> SyncCollectionSelection {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(StoredSelection.self, from: data)
        else {
            return .playlists([])
        }
        return stored.selection
    }

    /// 写存档。写盘前走 `normalized`：非法标识 / 非法路径一律丢弃，
    /// 保证「写进去的形态」与「读得出来的形态」一致（round-trip 稳定）。
    func save(_ selection: SyncCollectionSelection) {
        guard let data = try? JSONEncoder().encode(StoredSelection(selection.normalized)) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    // MARK: - 存档形态（私有）

    /// 存档 DTO：显式 `version` + `kind` 字符串判别 + 值数组。
    /// 为什么不用 Swift 的 enum 自动 Codable：`all` 没有载荷，case 编码形态随
    /// 编译器版本演进（未来若给模型加 case，自动编码会静默改变存档结构）；
    /// 显式 kind 字符串 + 版本号让存档格式可控、可演进（未知 kind/版本 → 空选择）。
    private struct StoredSelection: Codable {
        /// 存档格式版本（结构变更时递增；未知版本按空选择处理）。
        /// - v1：`all` / `playlists` / `relativePaths`
        /// - v2（P1b 2026-11-16）：新增 `playlistBundle` + `smartSnapshots`；v1 存档照旧可读
        static let currentVersion = 2
        /// 旧存档里有的最小版本号（更小的值 = 损坏/臆造 → 空选择）。
        static let minVersion = 1
        static let kindAll = "all"
        static let kindPlaylists = "playlists"
        static let kindRelativePaths = "relativePaths"
        static let kindPlaylistBundle = "playlistBundle"

        var version: Int
        var kind: String
        var values: [String]
        /// `playlistBundle` 的智能源快照表（v2 新增；其余 kind / v1 存档无此字段）。
        var smartSnapshots: [String: [String]]?

        init(_ selection: SyncCollectionSelection) {
            version = Self.currentVersion
            switch selection {
            case .all:
                kind = Self.kindAll
                values = []
            case let .playlists(ids):
                kind = Self.kindPlaylists
                values = ids
            case let .relativePaths(paths):
                kind = Self.kindRelativePaths
                values = paths
            case let .playlistBundle(playlists, snapshots):
                kind = Self.kindPlaylistBundle
                values = playlists
                smartSnapshots = snapshots
            }
        }

        /// 存档 → 选择集。未知版本 / 未知 kind → **空选择**（保守：宁可不同步，
        /// 也不把未知形态猜成某个选择集）。
        var selection: SyncCollectionSelection {
            guard (Self.minVersion ... Self.currentVersion).contains(version) else {
                return .playlists([])
            }
            switch kind {
            case Self.kindAll:
                return .all
            case Self.kindPlaylists:
                return .playlists(values)
            case Self.kindRelativePaths:
                return .relativePaths(values)
            case Self.kindPlaylistBundle:
                // bundle 是 v2 形态：v1 存档里出现 = 臆造 → 空选择；缺快照字段 = 损坏
                guard version >= 2, let snapshots = smartSnapshots else { return .playlists([]) }
                return SyncCollectionSelection
                    .playlistBundle(playlists: values, smartSnapshots: snapshots)
                    .normalized
            default:
                return .playlists([])
            }
        }
    }
}
