//
//  SyncLastResultStore.swift
//  QQPlayer
//
//  同步「最近一次结果」持久化（2026-09-27 批 persist-last-sync-result）。
//
//  为什么需要：Mac 同步面板的「最近一次结果」区块此前只活在 `MacSyncRunViewModel.reportSummary`
//  里 —— 离开同步页 / 重启 App 必回「还没有同步记录。」，用户看不到上次跑到哪、有没有失败。
//
//  收口（本文件 = 该语义的**唯一**持久化入口 + **唯一**投影入口）：
//  - 存储形状照抄 `MacSearchHistoryStore`（UserDefaults + JSON Codable + 版本化 key +
//    损坏回落不抛），但**可注入 defaults**（照 `SyncHostCenter.init(defaults:trustStore:)`），
//    以免测试污染标准域；
//  - 按**对端分桶**（key = peerID）→ 连上某设备只回显该设备那次的结论；
//  - 快照 ⇄ `SyncUIReportSummary` 的双向投影只在这里（禁止别处再算，`isEmptyPlanAlreadyIdentical`
//    / `isSuccess` 判定一律复用既有 computed，不复制）；
//  - 「落盘口径」「恢复口径」「相对时间文案」都是纯函数，全部可单测。
//
//  ⚠️ 可测性：本文件放共享 Core（`QQPlayer/Services/`）→ iOS / Mac 两端都编译，
//  `QQPlayerTests` 真跑（Mac 侧 view model 不单测，判定全在这里与 `SyncUIState`）。
//

import Foundation

// MARK: - 快照

/// 一次同步结果的**可持久化快照**（`Codable`；与 `SyncUIReportSummary` 双向投影）。
struct SyncLastResultSnapshot: Codable, Equatable, Sendable {
    /// 快照格式版本（解码版本不符 → 视为损坏，不读）。
    static let currentSchemaVersion = 1
    /// 失败清单落盘上限（超出只保留计数真值）。
    static let failedItemsLimit = 20

    var schemaVersion: Int
    /// 本次运行完成时刻（`latest()` 按它取最新）。
    var finishedAt: Date
    /// 对端 Device ID（分桶 key）。
    var peerID: String
    /// 对端展示名（跨设备回显时上屏）。
    var peerDisplayName: String
    /// 传输方向（`"upload"` / `"download"`；`SyncTransferDirection` 不是 String raw enum，
    /// 故存字符串 + 本文件的纯函数双向映射）。
    var direction: String

    var pushedCount: Int
    var pulledCount: Int
    var skippedCount: Int
    var peerAlreadyHasCount: Int
    var peerAlreadyHasSample: [String]
    /// 失败**真值**（可与 `failedItems.count` 不等 —— 清单被截断）。
    var failedCount: Int
    var failedItems: [FailedItem]
    var unresolvedCount: Int
    var unknownPlaylistIDs: [String]
    var isEmptySelection: Bool
    var isLibraryWide: Bool
    var abortReason: String?
    var lyricsDiscardedCount: Int
    var lyricsKeptLocalCount: Int

    /// 失败清单一行（持久化形状；与界面层的 `SyncUIFailedItem` 同构）。
    struct FailedItem: Codable, Equatable, Sendable {
        var relativePath: String
        var reason: String
        var isPush: Bool
    }
}

// MARK: - 方向映射（纯函数，双向可逆；未知值 → nil）

extension SyncLastResultSnapshot {
    /// 方向 → 存储字符串。
    static func directionString(_ direction: SyncTransferDirection) -> String {
        switch direction {
        case .upload: return "upload"
        case .download: return "download"
        }
    }

    /// 存储字符串 → 方向（未知值 → nil）。
    static func direction(fromString raw: String) -> SyncTransferDirection? {
        switch raw {
        case "upload": return .upload
        case "download": return .download
        default: return nil
        }
    }

    /// 版本不符 / 方向未知 → 不可用（读取时一律跳过，绝不崩）。
    var isUsable: Bool {
        schemaVersion == Self.currentSchemaVersion
            && Self.direction(fromString: direction) != nil
    }
}

// MARK: - 投影（唯一映射）

extension SyncLastResultSnapshot {
    /// `SyncUIReportSummary` → 快照（失败清单截断到上限，**保留真值计数**）。
    init(
        summary: SyncUIReportSummary,
        finishedAt: Date,
        peerID: String,
        peerDisplayName: String,
        direction: SyncTransferDirection
    ) {
        self.init(
            schemaVersion: Self.currentSchemaVersion,
            finishedAt: finishedAt,
            peerID: peerID,
            peerDisplayName: peerDisplayName,
            direction: Self.directionString(direction),
            pushedCount: summary.pushedCount,
            pulledCount: summary.pulledCount,
            skippedCount: summary.skippedCount,
            peerAlreadyHasCount: summary.peerAlreadyHasCount,
            peerAlreadyHasSample: summary.peerAlreadyHasSample,
            failedCount: summary.failedCount,
            failedItems: summary.failedItems.prefix(Self.failedItemsLimit).map {
                FailedItem(relativePath: $0.relativePath, reason: $0.reason, isPush: $0.isPush)
            },
            unresolvedCount: summary.unresolvedCount,
            unknownPlaylistIDs: summary.unknownPlaylistIDs,
            isEmptySelection: summary.isEmptySelection,
            isLibraryWide: summary.isLibraryWide,
            abortReason: summary.abortReason,
            lyricsDiscardedCount: summary.lyricsDiscarded.count,
            lyricsKeptLocalCount: summary.lyricsKeptLocal.count
        )
    }
}

extension SyncUIReportSummary {
    /// 快照 → 结果摘要（复用既有字段与 `isEmptyPlanAlreadyIdentical` / `isSuccess` 判定）。
    ///
    /// ⚠️ `failedCount` 用快照的**真值**，绝不用 `failedItems.count` 推（清单可能被截断）。
    /// 歌词只存计数（明细路径不进持久层；界面只用计数上屏）→ 用等长占位重建，保证 `.count` 不变。
    static func make(snapshot: SyncLastResultSnapshot) -> SyncUIReportSummary {
        SyncUIReportSummary(
            pushedCount: snapshot.pushedCount,
            pulledCount: snapshot.pulledCount,
            skippedCount: snapshot.skippedCount,
            peerAlreadyHasCount: snapshot.peerAlreadyHasCount,
            peerAlreadyHasSample: Array(snapshot.peerAlreadyHasSample.prefix(peerAlreadyHasSampleLimit)),
            failedCount: snapshot.failedCount,
            failedItems: snapshot.failedItems.map {
                SyncUIFailedItem(relativePath: $0.relativePath, reason: $0.reason, isPush: $0.isPush)
            },
            unresolvedCount: snapshot.unresolvedCount,
            unknownPlaylistIDs: snapshot.unknownPlaylistIDs,
            isEmptySelection: snapshot.isEmptySelection,
            isLibraryWide: snapshot.isLibraryWide,
            abortReason: snapshot.abortReason,
            lyricsDiscarded: Array(repeating: "", count: snapshot.lyricsDiscardedCount),
            lyricsKeptLocal: Array(repeating: "", count: snapshot.lyricsKeptLocalCount)
        )
    }
}

// MARK: - 存取（唯一持久化入口；UserDefaults + 版本化 key）

enum SyncLastResultStore {
    /// 版本化存储 key（值 = JSON `[peerID: SyncLastResultSnapshot]`）。
    static let storageKey = "syncLastResult.v1"

    /// 全部桶（缺数据 / JSON 损坏 → 空字典，不抛）。
    static func buckets(defaults: UserDefaults = .standard) -> [String: SyncLastResultSnapshot] {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: SyncLastResultSnapshot].self, from: data)
        else {
            return [:]
        }
        return decoded
    }

    /// 存一次结果（按 `snapshot.peerID` 覆盖该桶；编码失败静默不写）。
    static func save(_ snapshot: SyncLastResultSnapshot, defaults: UserDefaults = .standard) {
        var all = buckets(defaults: defaults)
        all[snapshot.peerID] = snapshot
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// 读某设备的桶（缺数据 / 版本不符 / 方向未知 → nil）。
    static func load(peerID: String, defaults: UserDefaults = .standard) -> SyncLastResultSnapshot? {
        guard let snapshot = buckets(defaults: defaults)[peerID], snapshot.isUsable else { return nil }
        return snapshot
    }

    /// 跨设备「最近一次」（不可用的桶跳过；无可用桶 → nil）。
    static func latest(defaults: UserDefaults = .standard) -> SyncLastResultSnapshot? {
        buckets(defaults: defaults).values
            .filter(\.isUsable)
            .max { $0.finishedAt < $1.finishedAt }
    }
}

// MARK: - 回显口径（口径 1 的唯一实现）

enum SyncLastResultRestore {
    /// 恢复结论：快照 + 是否跨设备回显。
    typealias Resolved = (snapshot: SyncLastResultSnapshot, isCrossDevice: Bool)

    /// 连上某设备 → 只回显**该设备分桶**（`isCrossDevice = false`）；
    /// 未连接（或该设备无桶）→ 跨设备「最近一次」（`isCrossDevice = true`，结论行附设备名）；
    /// 无任何可用桶 → nil（界面回退「还没有同步记录。」）。
    ///
    /// `connectedPeerName` 只在命中桶的展示名为空时补一次（落盘时拿不到名字的兜底）；
    /// 展示名一律以快照为准（那是那次运行真实的设备名）。
    static func resolve(
        connectedPeerID: String?,
        connectedPeerName: String?,
        buckets: [String: SyncLastResultSnapshot]
    ) -> Resolved? {
        let usable = buckets.filter { $0.value.isUsable }
        if let connectedPeerID, var hit = usable[connectedPeerID] {
            if hit.peerDisplayName.isEmpty, let connectedPeerName {
                hit.peerDisplayName = connectedPeerName
            }
            return (hit, false)
        }
        guard let newest = usable.values.max(by: { $0.finishedAt < $1.finishedAt }) else { return nil }
        return (newest, true)
    }
}

// MARK: - 落盘口径（口径 3 的唯一实现）

enum SyncLastResultPersistRule {
    /// 跳过空选择与用户取消；其余终态（成功 / 有失败 / 掉线中止）都落盘。
    static func shouldPersist(summary: SyncUIReportSummary, interruption: SyncUIInterruption) -> Bool {
        guard !summary.isEmptySelection else { return false }
        guard interruption != .cancelled else { return false }
        return true
    }
}

// MARK: - 相对时间文案（纯函数；注入 now / locale）

enum SyncUIRelativeTimeText {
    /// 相对时间短文案（例：「5 分钟前」/「5 minutes ago」）。
    static func short(from date: Date, now: Date, locale: Locale) -> String {
        short(from: date, now: now, locale: locale) { target, reference in
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.dateTimeStyle = .named
            formatter.unitsStyle = .full
            return formatter.localizedString(for: target, relativeTo: reference)
        }
    }

    /// 可注入 formatter 的变体（测试用假 formatter 逼出回落路径）。
    static func short(
        from date: Date,
        now: Date,
        locale: Locale,
        relative: (Date, Date) -> String?
    ) -> String {
        if let text = relative(date, now), !text.isEmpty {
            return text
        }
        return absolute(from: date, locale: locale)
    }

    /// 绝对日期文案（相对时间不可得时的回落；同样注入 locale，纯、可测）。
    static func absolute(from date: Date, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
