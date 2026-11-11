//
//  SyncLibraryPushController+Concurrency.swift
//  QQPlayer
//
//  局域网同步阶段 C（2026-11-11）：推送控制器的**文件级并发派发**（与状态机/账目分离，
//  沿用 SyncCollectionSyncCoordinator+Execution 的「主类放状态、扩展放流程」写法）。
//
//  口径：
//  - 实际并发度 = min(本端 policy 上限, 对端 `file_ack.maxConcurrentFiles` 声明)；
//    对端未声明（旧端）→ 1，即串行，行为与 v1 完全一致（零回归）。
//  - 全局在途字节上限由 `SyncTransferBudget` 跨文件共享，触顶就停派新块（不排队、不轮询）。
//  - 每个文件一个 `SyncFileSender`（自带窗口 + ack 超时），槽位仅用于日志定位。
//

import Foundation

extension SyncLibraryPushController {
    // MARK: 文件级并发派发（N 个文件同时在途）

    /// 驱动队列：在**实际并发度**允许的范围内，给空闲槽位喂新文件。
    ///
    /// 实际并发度 = min(本端 policy 上限, 对端 `file_ack.maxConcurrentFiles` 声明)；
    /// 对端未声明（旧端）→ 恒为 1，行为与串行版本完全一致（零回归）。
    /// 内存回环下 `send` 会同步跑完整轮（onCompletion 在 send 内触发 → `pump` 重入被
    /// `pumping` 挡住）；真实网络下 `send` 返回时仍在传输 → 继续补下一个槽位。
    func pump() {
        lock.lock()
        if pumping {
            lock.unlock()
            return
        }
        pumping = true
        lock.unlock()
        defer {
            lock.lock()
            pumping = false
            lock.unlock()
        }
        while true {
            lock.lock()
            let isPushing: Bool = {
                if case .pushing = stateValue { return true }
                return false
            }()
            let concurrency = effectiveConcurrencyLocked()
            let hasRoom = senders.count < concurrency
            let next: PendingPush? = (hasRoom && !queue.isEmpty) ? queue.removeFirst() : nil
            let idle = senders.isEmpty
            let drained = queue.isEmpty
            lock.unlock()

            guard isPushing else { return }
            guard let pending = next else {
                // 队列空且没有在途文件 → 本轮真的结束；否则等在途文件 onCompletion 再驱动
                if idle && drained { transition(to: .done(summaryValue)) }
                return
            }
            dispatch(pending)
        }
    }

    /// 派一个文件：建 sender、挂协商/终态钩子、登记槽位。单文件失败只影响它自己。
    func dispatch(_ pending: PendingPush) {
        let fileID = pending.entry.fileID
        lock.lock()
        let concurrency = effectiveConcurrencyLocked()
        let slot = lowestFreeSlotLocked()
        let sender = SyncFileSender(session: session)
        sender.budget = budget
        sender.metricConcurrency = concurrency
        sender.metricSlot = slot
        sender.onConcurrencyNegotiated = { [weak self] declared in
            self?.handleNegotiatedConcurrency(declared)
        }
        sender.onCompletion = { [weak self] outcome in
            self?.handleSendOutcome(outcome, fileID: fileID)
        }
        senders[fileID] = sender
        dispatchedPaths[fileID] = pending.entry.relativePath
        peakConcurrency = max(peakConcurrency, senders.count)
        lock.unlock()
        do {
            try sender.send(
                fileURL: pending.fileURL,
                fileID: fileID,
                name: pending.entry.transferName,
                precomputedSHA256: pending.sha256Hex
            )
        } catch {
            lock.lock()
            senders[fileID] = nil
            dispatchedPaths[fileID] = nil
            lock.unlock()
            appendFailure(
                SyncPushFailure(
                    relativePath: pending.entry.relativePath,
                    reason: SyncPushFailureReason.sendFailed,
                    detail: "\(error)"
                )
            )
        }
    }

    /// 对端声明并发文件数（本文件第一条 meta ack 到达时回调）：旧端不声明 → 保持串行。
    func handleNegotiatedConcurrency(_ declared: Int?) {
        lock.lock()
        negotiatedConcurrency = declared
        lock.unlock()
        pump() // 协商出 >1 时立刻补派排队文件
    }

    /// 实际并发度（锁内）：本端上限 / 对端声明取小；未协商 = 1（串行，旧端零回归）。
    func effectiveConcurrencyLocked() -> Int {
        let declared = negotiatedConcurrency ?? 1
        return max(1, min(concurrencyPolicy.maxConcurrentFiles, declared))
    }

    /// 最低空闲槽位（0 起；并发日志用）。
    func lowestFreeSlotLocked() -> Int {
        var used = Set(senders.values.compactMap(\.metricSlot))
        var slot = 0
        while used.contains(slot) { slot += 1 }
        used.insert(slot)
        return slot
    }

    func handleSendOutcome(_ outcome: SyncFileSender.Outcome, fileID: String) {
        lock.lock()
        senders[fileID] = nil
        let path = dispatchedPaths.removeValue(forKey: fileID)
        lock.unlock()
        switch outcome {
        case .succeeded:
            if let path {
                lock.lock()
                summaryValue.completed.append(path)
                lock.unlock()
                onFilePushed?(path)
            }
        case let .failed(error):
            if let path {
                appendFailure(
                    SyncPushFailure(
                        relativePath: path,
                        reason: SyncPushFailureReason.sendFailed,
                        detail: "\(error)"
                    )
                )
            }
        }
        pump()
    }
}
