//
//  SyncCollectionSyncCoordinator+Models.swift
//  QQPlayer
//
//  E1（2026-09-21）：`SyncCollectionSyncCoordinator` 拆分片 —— 纯逻辑与账目模型
//  （差集规划 + 配置 / 状态 / 账目）。**纯搬家**：正文与主片逐字相同，仅换文件。
//

import Foundation

// MARK: - 差集（纯逻辑，可单测）

/// 选中集合下的一次**单向**差集（对账键 = relativePath，身份键 = content_hash）。
///
/// T7（2026-09-11）：差集按方向收窄——`toPush` 只在 upload 产出、`toPull` 只在
/// download 产出；两个方向**不可能同时非空**（用户显式选了一个方向就是只跑它）。
struct SyncCollectionDiff: Equatable, Sendable {
    /// 对端缺 / 内容不同 → 推送（升序；**仅 upload**）
    var toPush: [String] = []
    /// 本端缺 → 拉取（升序；**仅 download**）
    var toPull: [String] = []
    /// 两侧都有且内容一致 → 零传输（升序）
    var unchanged: [String] = []
    /// 期望里有、但**两侧都没有实体**的路径（什么都不做；诊断用）
    var missingBoth: [String] = []
    /// 对端多出来的条目（不在选中集合内）→ **什么都不做**（决策 7；仅记账）
    var remoteOnlyIgnored: [String] = []
    /// download：两侧都有但内容不同 → **不覆盖本端**（保守：本端保留，仅记账）
    var conflictingKept: [String] = []
    /// download：本端有、对端没有 → 什么都不做（**不推也不删**，仅记账）
    var localOnlySkipped: [String] = []
    /// upload：对端有、本端没有 → 什么都不做（**不拉**，仅记账）
    var peerOnlySkipped: [String] = []

    /// 本次要动的路径总数（诊断/UI）。
    var transferCount: Int { toPush.count + toPull.count }
}

enum SyncCollectionDiffPlanner {
    /// **单向**差集（纯函数）：`expected` = 本次对账基准（见 `SyncExpectedPlanner`），
    /// `local` / `remote` = **全量** manifest（本端 / 对端）。
    ///
    /// 判定（内容判据与既有 planner 逐字一致：双侧 contentHash 非空且相等 = 一致）：
    ///
    /// upload（只推，**不产生 toPull**）：
    /// - 两侧都有：一致 → `unchanged`；不同 → `toPush`（**本端权威**）
    /// - 只有本端有 → `toPush`（对端缺 → 补齐）
    /// - 只有对端有 → `peerOnlySkipped`（上传方向不往回拉，仅记账）
    ///
    /// download（只拉，**不产生 toPush**）：
    /// - 两侧都有：一致 → `unchanged`；不同 → `conflictingKept`（**不覆盖本端**）
    /// - 只有对端有 → `toPull`（本端缺 → 补齐）
    /// - 只有本端有 → `localOnlySkipped`（下载方向不推也不删，仅记账）
    ///
    /// 两方向共通：两侧都没有 → `missingBoth`（不伪造、不动手）；
    /// 对端多出的条目 → `remoteOnlyIgnored`（**不传播删除**）。
    static func plan(
        expected: [String],
        local: [ManifestEntry],
        remote: [ManifestEntry],
        direction: SyncTransferDirection
    ) -> SyncCollectionDiff {
        var localByPath: [String: ManifestEntry] = [:]
        for entry in local { localByPath[entry.relativePath] = entry } // later wins（最终快照）
        var remoteByPath: [String: ManifestEntry] = [:]
        for entry in remote { remoteByPath[entry.relativePath] = entry }

        var diff = SyncCollectionDiff()
        let wanted = Set(expected)
        for path in wanted.sorted() {
            let localEntry = localByPath[path]
            let remoteEntry = remoteByPath[path]
            switch (localEntry, remoteEntry) {
            case let (localEntry?, remoteEntry?):
                if SyncManifestReconciler.contentMatches(local: localEntry, remote: remoteEntry) {
                    diff.unchanged.append(path)
                } else if direction == .upload {
                    diff.toPush.append(path)
                } else {
                    diff.conflictingKept.append(path)
                }
            case (_?, nil):
                if direction == .upload {
                    diff.toPush.append(path)
                } else {
                    diff.localOnlySkipped.append(path)
                }
            case (nil, _?):
                if direction == .upload {
                    diff.peerOnlySkipped.append(path)
                } else {
                    diff.toPull.append(path)
                }
            case (nil, nil):
                diff.missingBoth.append(path)
            }
        }
        diff.remoteOnlyIgnored = Set(remote.map(\.relativePath))
            .filter { !wanted.contains($0) }
            .sorted()
        return diff
    }
}

// MARK: - 计划阶段日志（唯一格式化入口）

/// 计划阶段诊断日志的**唯一**格式化入口（纯函数、零 IO、零状态）。
///
/// 为什么单独成类型而不写在协调器里：这些行是**断言对象**（`SyncCollectionPlanLogTests`
/// 逐字段比对）。格式一旦散在调用点，就会出现第二份模板；把行收成纯函数后，
/// 协调器只负责把返回的行交给 `SyncConnectDiag.log`（日志唯一出口），
/// 测试也无需复制字符串模板——模板只此一份。
///
/// 背景（E-1，2026-09-21 实测）：计划阶段此前零日志，于是「真的传完了」与
/// 「计划判为空（零字节）」在诊断日志上完全同形，只能靠猜。本类型补的就是这个『算了什么』。
enum SyncCollectionPlanLog {
    /// 空计划行的一致样本上限（超过只留前 `sampleLimit` 条，其余折成 `…(+n)`）。
    static let sampleLimit = 3

    /// 方向标签（日志用词与代码/协议同词，便于 grep）。
    static func directionLabel(_ direction: SyncTransferDirection) -> String {
        switch direction {
        case .upload: return "upload"
        case .download: return "download"
        }
    }

    /// 一致样本后缀（升序前 `limit` 条；走空 = 空串；超出部分折成 `…(+n)`）。
    static func sampleSuffix(_ paths: [String], limit: Int = SyncCollectionPlanLog.sampleLimit) -> String {
        guard !paths.isEmpty else { return "" }
        let head = paths.prefix(max(0, limit))
        let overflow = paths.count - head.count
        let joined = head.joined(separator: ", ")
        return overflow > 0 ? " \(joined)…(+\(overflow))" : " \(joined)"
    }

    /// 计划阶段日志行（1 行；计划为空时 2 行）。
    ///
    /// 行 1（恒定）：`📋 同步计划 方向=… 选择=N 本端=M 对端=K 推送=P 拉取=L 一致=U 两侧无=X 对端多=Y`
    /// 行 2（仅 `P == 0 且 L == 0`）：`⏭️ 计划为空 → 不传输（对端自报已一致 U 项）` + 一致样本。
    ///
    /// 字段口径：N=`selectionCount`（本次对账基准条目数）、M=`localCount`（本端全量清单）、
    /// K=`peerCount`（对端自报清单）、P/L/U/X/Y 取 `diff` 对应字段。
    static func lines(
        direction: SyncTransferDirection,
        selectionCount: Int,
        localCount: Int,
        peerCount: Int,
        diff: SyncCollectionDiff
    ) -> [String] {
        var lines = [
            "📋 同步计划 方向=\(directionLabel(direction))"
                + " 选择=\(selectionCount) 本端=\(localCount) 对端=\(peerCount)"
                + " 推送=\(diff.toPush.count) 拉取=\(diff.toPull.count) 一致=\(diff.unchanged.count)"
                + " 两侧无=\(diff.missingBoth.count) 对端多=\(diff.remoteOnlyIgnored.count)",
        ]
        if diff.toPush.isEmpty, diff.toPull.isEmpty {
            lines.append(
                "⏭️ 计划为空 → 不传输（对端自报已一致 \(diff.unchanged.count) 项）"
                    + sampleSuffix(diff.unchanged)
            )
        }
        return lines
    }
}

// MARK: - 配置 / 状态 / 账目

/// 编排配置（选择集 + 方向之外的参数）。
///
/// T7：原先的 `remoteCollection` 配置项已移除——对端请求集合现在由
/// `SyncCollectionSelection.remoteRequestCollection(for:)` **按方向**唯一确定
/// （可配置 = 可能配错，方向语义必须是单一事实源）。
struct SyncCollectionSyncConfiguration: Equatable, Sendable {
    /// 落地目录名（曲库根内隐藏目录；透传拉取控制器）
    var incomingDirectoryName: String = ".sync-incoming"
    /// 计划阶段**等对端清单**的上限（秒）。对端 App 不在前台就不会应答，
    /// 没有上限 = 用户看到「点开始后一直等」。`<= 0` = 不启用超时。
    var peerManifestTimeout: TimeInterval = 20
}

/// 一次编排的进度状态。
enum SyncCollectionSyncState: Equatable, Sendable {
    case idle
    /// 已请求对端 manifest，等应答（并算差集）
    case planning
    /// 正在推送（对端缺的歌）
    case pushing
    /// 正在拉取（本端缺的歌）
    case pulling
    /// 收尾完成（账目见 report）
    case done
    /// 失败（计划阶段致命错误 / 用户取消）
    case failed(String)

    static func isTerminal(_ state: SyncCollectionSyncState) -> Bool {
        switch state {
        case .done, .failed: return true
        default: return false
        }
    }
}

/// 编排设置集后的账目（M6 UI 直接消费；本类不做 UI）。
struct SyncCollectionSyncReport: Equatable, Sendable {
    /// 本次编排的传输方向（用户显式选择；`start(direction:)` 写入，UI 据此展示）
    var direction: SyncTransferDirection = .upload
    /// 计划推送的相对路径（升序；非空仅当 `direction == .upload`）
    var plannedPush: [String] = []
    /// 计划拉取的相对路径（升序；非空仅当 `direction == .download`）
    var plannedPull: [String] = []
    /// 两侧一致、零传输（升序）
    var skipped: [String] = []
    /// 期望里两侧都没有实体的路径（升序；什么都不做）
    var missingBoth: [String] = []
    /// 对端多出的条目（升序；**不传播删除**，仅记账）
    var remoteOnlyIgnored: [String] = []
    /// download：两侧都有但内容不同 → **本端保留**（不覆盖；UI 展示「已存在但内容不同」）
    var conflictingKept: [String] = []
    /// download：本端有、对端没有 → 既不下推也不删（仅记账）
    var localOnlySkipped: [String] = []
    /// upload：对端有、本端没有 → 不拉回（仅记账）
    var peerOnlySkipped: [String] = []
    /// 展开时未解析的曲目数（未指纹 / 未入库）
    var unresolvedCount: Int = 0
    /// 展开时忽略的未知/非法歌单标识（升序）
    var unknownPlaylistIDs: [String] = []
    /// 选择集是否为空（空 = 不推不拉，连 manifest 都不请求）
    var isEmptySelection: Bool = false
    /// 选择集是否库级（`.all`）
    var isLibraryWide: Bool = false
    /// 已确认送达对端的相对路径（推送序）
    var pushed: [String] = []
    /// 推送失败（本地不可读 / 传输失败 / 声明被丢弃）
    var pushFailed: [SyncPushFailure] = []
    /// 推送方向被跳过的相对路径（对端已一致）
    var pushSkipped: [String] = []
    /// 推送阶段中止原因（nil = 未中止）
    var pushAbortReason: String?
    /// 已落盘并入库的相对路径（接收序，含歌词 wire 路径）
    var pulled: [String] = []
    /// 拉取失败（对端报告）
    var pullFailed: [SyncFileFetchFailure] = []
    /// 拉取方向被跳过的相对路径（本端已一致）
    var pullSkipped: [String] = []
    /// 拉取方向收到、但本端**无对应歌曲**的 aligned 歌词（丢弃；下一轮自动补发，F2 ②）
    var lyricsDiscarded: [String] = []
    /// 拉取方向收到、本端**已有**对齐结果 → 保留本端（F2「只补不覆盖」，未覆盖）
    var lyricsKeptLocal: [String] = []
    /// 拉取阶段中止原因（nil = 未中止）
    var pullAbortReason: String?
    /// 对端回报送达的相对路径（`sync_fetch_result.completed`；升序；诊断/携带定范围用）
    var reportedPulled: [String] = []
    /// 是否请求过对端 manifest（空选择集 = false）
    var didRequestPeerManifest: Bool = false
    /// R3b：播放数据「跟歌走」——推送方向已带走的歌曲相对路径（升序）
    var playbackCarriedPush: [String] = []
    /// R3b：播放数据「跟歌走」——拉取方向请求带回的歌曲相对路径（升序）
    var playbackCarriedPull: [String] = []
    /// R3b：播放数据携带失败原因（nil = 未失败 / 未接线）
    var playbackCarryError: String?

    /// 本次实际传输的文件数（诊断/UI）。
    var transferCount: Int { pushed.count + pulled.count }
    /// 推送方向是否全部送达。
    var isPushComplete: Bool { pushAbortReason == nil && pushFailed.isEmpty }
    /// 拉取方向是否全部落地。
    var isPullComplete: Bool { pullAbortReason == nil && pullFailed.isEmpty }
    /// 本次编排是否完全成功（无中止、无失败项）。
    var isComplete: Bool { isPushComplete && isPullComplete }
}
