//
//  SyncLWWReconcile.swift
//  QQPlayer
//
//  局域网同步（S2, M4-1）播放数据 LWW 对账纯逻辑——无 IO、无 GRDB、可单测。
//
//  输入：本端 outbox 批 + 远端 outbox 批；按 (entity, row_key) 分组，
//  同键冲突以 updated_at(毫秒) 大者胜；平局规则见 resolve()。
//  输出：远端胜出的行（调用方逐条应用）。本端胜出的行无需动作（本端已是事实源，
//  会通过后续推送让对端收敛），因此本函数只返回"应应用的远端行"。
//
//  时钟超前门（契约 B1 / INV-34，2026-11-09）：远端 `updated_at` 比本机超前超过容差
//  （5 分钟）的行**不应用**，经 `MergeResult.futureRejected` 带出供上层按实体计数上屏
//  ——防「来自未来」的旧值永久压过本端新值。
//
//  v1 简化（决策写入完成报告）：
//  - 业务行时间戳调研：favorite / play_history / playlist_item 无 updated_at 列
//    （play_history 无、favorite 无、playlist_item 无）→ v1 用 outbox.updated_at
//    时间序（outbox 即事实源，单 Host-单 Client 足够）；playlist 表有 updated_at，
//    但混用两套时钟会让平局/时序规则复杂化，v1 统一 outbox 时钟，行级 LWW 演进留
//    M4-2（届时若引入业务时间戳比较，只改本文件的比较函数，契约不变）。
//  - 平局（同键同 updated_at）：upsert vs upsert → 本端胜（不应用远端，避免乒乓）；
//    delete vs upsert → delete 胜（删除是显式用户意图，且删除后行已不在本端，
//    若本端恰有同键残留 upsert，delete 必须压过它才能收敛）；delete vs delete →
//    不应用（本端已删则无需动作；本端无此键则远端 delete 无对象可删）。
//  - 组内多行：每键取 updated_at 最大（同 updated_at 取 id 最大 = 最新落库）的一行
//    代表该键，再跨端比较（outbox 允许同键多行：多次 upsert 覆盖、upsert 后 delete）。
//

import Foundation

enum SyncLWWReconcile {
    /// 对账结果：应应用的远端行（升序 updated_at；调用方逐条应用即可幂等收敛）。
    struct Outcome: Equatable, Sendable {
        /// 远端胜出、需应用的行（可能为空 = 全部本端胜出/平局不应用）。
        var applyRemote: [SyncChangeLogRow] = []
    }

    /// 时钟超前容差（毫秒）：契约 B1（`docs/sync-contract.md` E 行）承诺「对端时间戳
    /// **超前**本机超过容差（5 分钟）的行不应用并计数上屏」。**唯一出处**——别处不得
    /// 再写这个魔法数（新增判定一律调 `isAheadOfClock`）。
    static let clockSkewToleranceMs: Int64 = 300_000

    /// 本机当前毫秒时间戳（`merge` 的 `nowMs` 默认值）。判定一律用注入值，测试不靠真实时钟。
    static func defaultNowMs() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded())
    }

    /// 该远端时间戳是否**超前本机超过容差**（B1 时钟超前门）。
    ///
    /// 边界（用例钉死）：差值 **> 容差**才拒绝；**恰好等于容差放行**——「超过」的语义是
    /// 严格大于，且容差边缘更像正常时钟漂移而非病态时钟。
    static func isAheadOfClock(_ remoteUpdatedAtMs: Int64, nowMs: Int64) -> Bool {
        remoteUpdatedAtMs - nowMs > clockSkewToleranceMs
    }

    /// 合并结果：本端胜出的键（供调用方决定是否回推，v1 未用，预留）。
    struct MergeResult: Equatable, Sendable {
        var applyRemote: [SyncChangeLogRow]
        var localWins: [SyncChangeLogRow]
        /// 因**时钟超前**（B1）被拒绝、**不应用**的远端行：调用方按实体计数上屏（INV-34）。
        var futureRejected: [SyncChangeLogRow] = []
    }

    /// 解析一组同键行，返回代表行（updated_at 最大；平局取 id 最大）。
    static func representative(of rows: [SyncChangeLogRow]) -> SyncChangeLogRow? {
        rows.max { a, b in
            if a.updatedAtMs != b.updatedAtMs { return a.updatedAtMs < b.updatedAtMs }
            return (a.id ?? 0) < (b.id ?? 0)
        }
    }

    /// 对账：两组 outbox 批 → MergeResult。见文件头 v1 规则。
    /// - Parameters:
    ///   - localRows: 本端 outbox 批（可为某键的全部历史或增量批）
    ///   - remoteRows: 远端 outbox 批（同一批）
    ///   - nowMs: 本机当前时间（毫秒）。**可注入**：B1 时钟超前门靠它做确定性判定；
    ///     生产调用走默认值，测试一律显式传入。
    /// 两批都可含多键；本函数按 (entity, row_key) 分组后逐键比较。
    static func merge(
        localRows: [SyncChangeLogRow],
        remoteRows: [SyncChangeLogRow],
        nowMs: Int64 = SyncLWWReconcile.defaultNowMs()
    ) -> MergeResult {
        // 按 (entity, row_key) 分组
        func key(_ row: SyncChangeLogRow) -> String { "\(row.entity)|\(row.rowKey)" }

        var localByKey: [String: SyncChangeLogRow] = [:]
        for row in localRows {
            let k = key(row)
            if let existing = localByKey[k] {
                if row.updatedAtMs > existing.updatedAtMs
                    || (row.updatedAtMs == existing.updatedAtMs && (row.id ?? 0) > (existing.id ?? 0)) {
                    localByKey[k] = row
                }
            } else {
                localByKey[k] = row
            }
        }
        var remoteByKey: [String: SyncChangeLogRow] = [:]
        for row in remoteRows {
            let k = key(row)
            if let existing = remoteByKey[k] {
                if row.updatedAtMs > existing.updatedAtMs
                    || (row.updatedAtMs == existing.updatedAtMs && (row.id ?? 0) > (existing.id ?? 0)) {
                    remoteByKey[k] = row
                }
            } else {
                remoteByKey[k] = row
            }
        }

        var applyRemote: [SyncChangeLogRow] = []
        var localWins: [SyncChangeLogRow] = []

        // 时钟超前门（B1 / INV-34）：远端代表行的时间戳超前本机超过容差 → 该键**不应用**，
        // 行原样带出供上层按实体计数。本端有同键行时它照常是本端胜出（本端事实会回推收敛）。
        let aheadKeys = remoteByKey
            .filter { isAheadOfClock($0.value.updatedAtMs, nowMs: nowMs) }
            .map(\.key)
        var futureRejected: [SyncChangeLogRow] = []
        for k in aheadKeys {
            guard let remote = remoteByKey.removeValue(forKey: k) else { continue }
            futureRejected.append(remote)
            if let local = localByKey[k] { localWins.append(local) }
        }

        // 远端独有的键：直接应用（含远端 delete：本端无对象可删时应用层幂等跳过）。
        for (k, remote) in remoteByKey where localByKey[k] == nil {
            applyRemote.append(remote)
        }
        // 同键比较
        for (k, remote) in remoteByKey {
            guard let local = localByKey[k] else { continue }
            if remote.updatedAtMs > local.updatedAtMs {
                applyRemote.append(remote)
            } else if remote.updatedAtMs == local.updatedAtMs {
                // 平局：delete 压 upsert（显式删除意图优先）；否则本端胜
                // 判定走单一事实源（2026-09-17）：本文件不得再出现第二处 delete 判定。
                if SyncChangeLogDeletionPolicy.tieBreakPrefersRemoteDelete(
                    remoteOp: remote.op,
                    localOp: local.op
                ) {
                    applyRemote.append(remote)
                } else {
                    localWins.append(local)
                }
            } else {
                localWins.append(local)
            }
        }

        applyRemote.sort { ($0.updatedAtMs, $0.id ?? 0) < ($1.updatedAtMs, $1.id ?? 0) }
        localWins.sort { ($0.updatedAtMs, $0.id ?? 0) < ($1.updatedAtMs, $1.id ?? 0) }
        return MergeResult(applyRemote: applyRemote, localWins: localWins, futureRejected: futureRejected)
    }
}
