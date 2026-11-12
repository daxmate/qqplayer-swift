//
//  SyncDataSyncCoordinator+Ledger.swift
//  QQPlayer
//
//  协调器的「收帧账目」扩展（2026-11-12 T1 从 SyncDataSyncCoordinator.swift 抽出）：
//  peer 回调 → 账目累加 → 收尾。逻辑逐字不变（仅 private → internal，供扩展访问共享状态）。
//  抽出理由：协调器文件撞到 600 行结构预算（StructuralBudgetContractTests）。
//

import Foundation

extension SyncDataSyncCoordinator {
    // MARK: 收帧账目（peer 回调 → 锁外）

    func recordApplied(_ count: Int) {
        lock.lock()
        let wasFinished = stage == .finished
        notePullAnswerLocked(wasFinished: wasFinished)
        reportValue.tally.accumulate(.applied, count: count)
        lock.unlock()
        logAnswerReceived(wasFinished: wasFinished, applied: count, groups: nil)
        finish(failure: nil)
    }

    /// INV-36：一次 pull 应答到达时的记账——与重发代际 / 等待窗口**无关**。
    ///
    /// 收尾后才到 = 迟到（`pullLate`），否则 = 正常收到（`pullRecv`）。两种都照常
    /// 累加账目（数据已由 peer 落库）；`finish` 本身幂等，不会二次收尾。
    func notePullAnswerLocked(wasFinished: Bool) {
        if wasFinished {
            reportValue.pullLate += 1
        } else {
            reportValue.pullRecv += 1
        }
    }

    /// 重复批（已应用过）——不重复应用，但同样算「对端已应答」。
    func recordDuplicateBatch(_ count: Int) {
        lock.lock()
        let wasFinished = stage == .finished
        notePullAnswerLocked(wasFinished: wasFinished)
        reportValue.pullDuplicates += 1
        lock.unlock()
        AppLog.info(
            .sync,
            "ℹ️ SyncDataSyncCoordinator: 收到重复批（已应用过 \(count) 行，不重复应用；peer=\(resolvedPeerID)）"
        )
        finish(failure: nil)
    }

    /// 拉取方向：把一类结果的**按实体分组**累加进账目并收尾。
    ///
    /// 收尾语义与收口前逐字一致：这些回调**任一到达**即视为「对端已应答」
    /// （挂起 / 未定位即使空数组也上报 → 空数组 = 累加零条 + 照常收尾）。
    func recordAnswered(_ outcome: SyncRowOutcome, groups: [SyncEntityOutcomeCount]) {
        lock.lock()
        let wasFinished = stage == .finished
        notePullAnswerLocked(wasFinished: wasFinished)
        for group in groups {
            reportValue.tally.accumulate(outcome, entity: group.entity, count: group.count)
        }
        lock.unlock()
        logAnswerReceived(wasFinished: wasFinished, applied: nil, groups: groups)
        finish(failure: nil)
    }

    /// 「收到应答 / 迟到帧」各一行（info）：收尾后再来的帧只累加账目，不二次收尾。
    func logAnswerReceived(
        wasFinished: Bool,
        applied: Int?,
        groups: [SyncEntityOutcomeCount]?
    ) {
        if wasFinished {
            AppLog.info(
                .sync,
                "ℹ️ SyncDataSyncCoordinator: 已收尾会话收到迟到的应答帧（只累加账目，不二次收尾；peer=\(resolvedPeerID)）"
            )
            return
        }
        let detail: String
        if let applied {
            detail = "应用 \(applied) 行"
        } else {
            let total = (groups ?? []).reduce(0) { $0 + $1.count }
            detail = "分组应答 \(total) 行"
        }
        AppLog.info(
            .sync,
            "ℹ️ SyncDataSyncCoordinator: 收到对端应答（\(detail)，第 \(pullAttempt) 次尝试；peer=\(resolvedPeerID)）"
        )
    }

    /// 发送方向：本端发出去但缺身份键的行数（按实体分组）。**只累加，不收尾**——这不是
    /// 「对端应答」。
    func recordPushedMissingIdentity(_ groups: [SyncEntityOutcomeCount]) {
        lock.lock()
        for group in groups {
            reportValue.tally.accumulate(.missingIdentity, entity: group.entity, count: group.count)
        }
        lock.unlock()
    }

    func recordIgnoredDeletes(_ count: Int) {
        lock.lock()
        reportValue.tally.accumulate(.ignoredDelete, count: count)
        lock.unlock()
        finish(failure: nil)
    }}
