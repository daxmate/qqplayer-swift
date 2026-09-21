//
//  SyncCollectionSyncCoordinator+Execution.swift
//  QQPlayer
//
//  E1（2026-09-21）：`SyncCollectionSyncCoordinator` 拆分片 —— 对外状态投影 +
//  计划阶段（对端 manifest / 单向差集 / 单一方向推进）+ R3b 播放数据「跟歌走」。**纯搬家**。
//

import Foundation

extension SyncCollectionSyncCoordinator {
    // MARK: 对外状态

    var state: SyncCollectionSyncState {
        lock.lock()
        defer { lock.unlock() }
        return stateValue
    }

    /// 账目**实时值**：意图（planned/skipped/未解析）来自计划阶段，结果（pushed /
    /// pulled / 失败）一律从两个控制器的**当前** summary 现读。
    ///
    /// 为什么必须现读而不是快照：控制器的落盘/入库账目可能晚于其 `.done` 回调
    /// （harness 实测：拉取控制器的 `summary.completed` 在结果帧回调之后才补齐），
    /// 快照会把刚补齐的文件漏记（账目与事实不符）。
    var report: SyncCollectionSyncReport {
        lock.lock()
        var snapshot = reportValue
        let push = pushController
        let pull = pullController
        lock.unlock()
        if let summary = push?.summary {
            snapshot.pushed = summary.completed
            snapshot.pushFailed = summary.failed
            snapshot.pushSkipped = summary.skipped
        }
        if let summary = pull?.summary {
            snapshot.pulled = summary.completed
            snapshot.pullFailed = summary.failed
            snapshot.pullSkipped = summary.unchanged
            snapshot.reportedPulled = summary.reportedCompleted.sorted()
            snapshot.lyricsDiscarded = summary.orphanLyricsSkipped.sorted()
            snapshot.lyricsKeptLocal = summary.keptLocalLyrics.sorted()
        }
        return snapshot
    }

    /// 选择集展开结果（诊断/UI：未解析明细等）。
    var expansion: SyncCollectionExpansion {
        lock.lock()
        defer { lock.unlock() }
        return expansionValue
    }

    // MARK: 计划

    /// 本端（Mac）全量清单（曲库 + aligned 歌词）。
    private func localManifest() -> [ManifestEntry] {
        SyncManifestGenerator.generate(files: descriptor.sourceFiles()) + descriptor.lyricsEntries()
    }

    func handlePeerManifest(_ response: SyncManifestResponse) {
        lock.lock()
        let isPlanning = stage == .planning
        let expansion = expansionValue
        let direction = directionValue
        if isPlanning {
            // S2（2026-09-12 审计修复）：在**同一临界区**内从 `.planning` 迁出
            // （`.planned`）。本方法解锁后还要算期望集合/差集（全库 stat，耗时），
            // 这段时间里到点检查若抢到锁就会看到一个「清单已到但仍在计划态」的编排，
            // → 判超时 + 置终态 → 随后的 beginTransfers 被守挡住 = 一条文件都不传。
            // 迁出后到点检查只可能看到 .planned / .pushing / .pulling / .finished，
            // 「清单已到并开始传输」与「计划态超时失败」从此互斥。
            stage = .planned
        }
        lock.unlock()
        guard isPlanning else { return } // 幂等：只认计划阶段的第一次响应
        // 清单已到：到点检查不再需要（幂等；已触发的 item 不受影响）。
        cancelPeerManifestTimeout()

        onPeerManifestReceived?(response)

        // T7：期望集合（对账基准）按方向取——upload 看本端/本端展开，download 看对端清单/选择集本身。
        let local = localManifest()
        let expected = SyncExpectedPlanner.expected(
            selection: selection,
            direction: direction,
            expansion: expansion,
            localManifest: local,
            remoteManifest: response.entries
        )
        let diff = SyncCollectionDiffPlanner.plan(
            expected: expected,
            local: local,
            remote: response.entries,
            direction: direction
        )

        lock.lock()
        reportValue.plannedPush = diff.toPush
        reportValue.plannedPull = diff.toPull
        reportValue.skipped = diff.unchanged
        reportValue.missingBoth = diff.missingBoth
        reportValue.remoteOnlyIgnored = diff.remoteOnlyIgnored
        reportValue.conflictingKept = diff.conflictingKept
        reportValue.localOnlySkipped = diff.localOnlySkipped
        reportValue.peerOnlySkipped = diff.peerOnlySkipped
        peerManifestEntriesValue = response.entries
        // 后续（控制器自己的）manifest 响应不再触发本类计划
        let peer = manifestPeer
        manifestPeer = nil
        lock.unlock()
        peer?.onManifestReceived = nil
        peer?.onDecodeFailure = nil

        beginTransfers()
    }

    /// T7：按方向只走一个阶段（upload → 推；download → 拉），不再先推后拉。
    private func beginTransfers() {
        lock.lock()
        let direction = directionValue
        lock.unlock()
        switch direction {
        case .upload:
            beginPush()
        case .download:
            beginPull()
        }
    }

    private func beginPush() {
        lock.lock()
        guard stage == .planned else {
            lock.unlock()
            return
        }
        let planned = reportValue.plannedPush
        guard !planned.isEmpty else {
            lock.unlock()
            finishStage()
            return
        }
        stage = .pushing
        lock.unlock()
        emit(state: .pushing)

        let controller = SyncLibraryPushController(
            session: session,
            descriptor: descriptor,
            selection: .relativePaths(planned),
            members: members,
            fileManager: fileManager
        )
        controller.onStateChange = { [weak self] state in self?.handlePushState(state) }
        controller.onFilePushed = { [weak self] path in
            self?.onFileTransferred?(path)
            self?.recordTransferred(path, direction: .push)
        }
        lock.lock()
        pushController = controller
        lock.unlock()

        do {
            try controller.start()
        } catch {
            lock.lock()
            if reportValue.pushAbortReason == nil {
                reportValue.pushAbortReason = "启动推送失败：\(error)"
            }
            lock.unlock()
            finishStage()
            return
        }
        // 内存回环：start() 内可能已跑完终态 → 补一次（handlePushState 幂等）
        handlePushState(controller.state)
    }

    private func handlePushState(_ state: SyncLibraryPushState) {
        lock.lock()
        guard stage == .pushing else {
            lock.unlock()
            return
        }
        switch state {
        case .done:
            break // 结果账目由 `report` 实时合并控制器 summary
        case let .failed(reason):
            if reportValue.pushAbortReason == nil {
                reportValue.pushAbortReason = reason
            }
        default:
            lock.unlock()
            return
        }
        lock.unlock()
        carryPlaybackData(direction: .push)
        finishStage()
    }

    private func beginPull() {
        lock.lock()
        guard stage == .planned else {
            lock.unlock()
            return
        }
        let planned = reportValue.plannedPull
        let direction = directionValue
        guard !planned.isEmpty else {
            lock.unlock()
            finishStage()
            return
        }
        stage = .pulling
        lock.unlock()
        emit(state: .pulling)

        var pullConfiguration = SyncLibraryPullConfiguration()
        // T7：拉取时向对端请求的集合与计划阶段同一映射（download 下对端已按集合收口）
        pullConfiguration.collection = selection.remoteRequestCollection(for: direction)
        pullConfiguration.selection = .relativePaths(planned)
        pullConfiguration.incomingDirectoryName = configuration.incomingDirectoryName

        let controller = SyncLibraryPullController(
            session: session,
            descriptor: descriptor,
            sink: sink,
            configuration: pullConfiguration,
            lyricsStore: lyricsStore,
            lyricsMapping: lyricsMapping,
            fileManager: fileManager
        )
        controller.onStateChange = { [weak self] state in self?.handlePullState(state) }
        controller.onFileApplied = { [weak self] path in
            self?.onFileTransferred?(path)
            self?.recordTransferred(path, direction: .pull)
        }
        lock.lock()
        pullController = controller
        lock.unlock()

        do {
            try controller.start()
        } catch {
            lock.lock()
            if reportValue.pullAbortReason == nil {
                reportValue.pullAbortReason = "启动拉取失败：\(error)"
            }
            lock.unlock()
            finishStage()
            return
        }
        handlePullState(controller.state)
    }

    private func handlePullState(_ state: SyncLibraryPullState) {
        lock.lock()
        guard stage == .pulling else {
            lock.unlock()
            return
        }
        switch state {
        case .done:
            break // 结果账目由 `report` 实时合并控制器 summary
        case let .failed(reason):
            if reportValue.pullAbortReason == nil {
                reportValue.pullAbortReason = reason
            }
        default:
            lock.unlock()
            return
        }
        lock.unlock()
        carryPlaybackData(direction: .pull)
        finishStage()
    }

    // MARK: R3b 播放数据「跟歌走」

    /// 一个方向收尾后：把该方向**成功传输**的歌的播放数据带过去（决策 8）。
    /// 未注入驱动 / 无成功传输 = 直接返回（行为与 R3a 一致）；失败只记账，不影响编排终态。
    private func carryPlaybackData(direction: SyncPlaybackCarryDirection) {
        guard let driver = playbackCarry else { return }
        let pulled = report.reportedPulled
        lock.lock()
        let transferred = direction == .push
            ? pushTransferredValue
            // 拉取方向：以对端回报的送达集为准（阶段收尾时已可用）；本端落位回调会晚于
            // 结果帧，两边取并集兜底（任一先到时都能得到完整集合）。
            : Array(Set(pullTransferredValue).union(pulled)).sorted()
        let peerEntries = peerManifestEntriesValue
        lock.unlock()
        guard !transferred.isEmpty else { return }
        do {
            let plan = try direction == .push
                ? driver.carryPush(transferredPaths: transferred, peerEntries: peerEntries)
                : driver.carryPull(transferredPaths: transferred, peerEntries: peerEntries)
            lock.lock()
            if direction == .push {
                reportValue.playbackCarriedPush = plan.carriedPaths
            } else {
                reportValue.playbackCarriedPull = plan.carriedPaths
            }
            lock.unlock()
        } catch {
            lock.lock()
            if reportValue.playbackCarryError == nil {
                reportValue.playbackCarryError = "\(error)"
            }
            lock.unlock()
        }
    }

    /// 记一条已确认传输的相对路径（完成回调；去重保持传输序）。
    private func recordTransferred(_ relativePath: String, direction: SyncPlaybackCarryDirection) {
        lock.lock()
        defer { lock.unlock() }
        switch direction {
        case .push:
            guard !pushTransferredValue.contains(relativePath) else { return }
            pushTransferredValue.append(relativePath)
        case .pull:
            guard !pullTransferredValue.contains(relativePath) else { return }
            pullTransferredValue.append(relativePath)
        }
    }
}
