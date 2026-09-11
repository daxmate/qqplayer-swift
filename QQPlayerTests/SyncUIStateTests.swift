//
//  SyncUIStateTests.swift
//  QQPlayerTests
//
//  M6（T3）同步界面决策纯逻辑 `SyncUIState` 测试：
//  - 「能否开始同步」各分支（未配对 / 未连接 / 会话不可用 / 同步中 / 空选择 / 可开始）
//  - 阶段映射（协调器状态 + 会话状态 → 界面阶段；终态不被掉线覆盖）
//  - 进度聚合（总数/已传封顶、0 总数不确定态、方向）
//  - 规模/时长的人类可读格式
//  - 选择集摘要（歌单级 / 单曲级 / 全库；未知歌单与未知大小记账）
//  - 结果摘要（数字 + 失败清单 + 未解析 + 未知歌单）
//  - 三级模式 ↔ 选择集映射
//
//  这些用例能跑，是因为被测类型刻意放在共享 Core（`QQPlayer/Services/SyncUIState.swift`）：
//  纯值 + 纯函数、零 IO、零 SwiftUI（M6 契约 A3）。
//

import Testing

@testable import QQPlayer

// MARK: - 能否开始

struct SyncUIStartGateTests {
    @Test("未配对（无已配对设备 + 未连接）：提示先配对，而不是「去连接」")
    func notPaired() {
        let availability = SyncUIStartGate.evaluate(
            hasPairedDevice: false,
            isConnected: false,
            hasSession: false,
            isRunning: false,
            isEmptySelection: true
        )
        #expect(availability == .notPaired)
        #expect(!availability.canStart)
    }

    @Test("已配对但未连接：提示去 iPhone 上连接")
    func pairedNotConnected() {
        let availability = SyncUIStartGate.evaluate(
            hasPairedDevice: true,
            isConnected: false,
            hasSession: false,
            isRunning: false,
            isEmptySelection: false
        )
        #expect(availability == .notConnected)
    }

    @Test("已连接但会话未就绪（曲库根不可用 → 没接线）：曲库不可用")
    func connectedWithoutSession() {
        let availability = SyncUIStartGate.evaluate(
            hasPairedDevice: true,
            isConnected: true,
            hasSession: false,
            isRunning: false,
            isEmptySelection: false
        )
        #expect(availability == .libraryUnavailable)
    }

    @Test("同步进行中：按钮态是「正在同步」而不是「空选择」")
    func runningWinsOverEmptySelection() {
        let availability = SyncUIStartGate.evaluate(
            hasPairedDevice: true,
            isConnected: true,
            hasSession: true,
            isRunning: true,
            isEmptySelection: true
        )
        #expect(availability == .alreadyRunning)
    }

    @Test("空选择：提示先选内容")
    func emptySelection() {
        let availability = SyncUIStartGate.evaluate(
            hasPairedDevice: true,
            isConnected: true,
            hasSession: true,
            isRunning: false,
            isEmptySelection: true
        )
        #expect(availability == .emptySelection)
    }

    @Test("连接 + 会话 + 非空选择 + 未运行：可以开始")
    func ready() {
        let availability = SyncUIStartGate.evaluate(
            hasPairedDevice: true,
            isConnected: true,
            hasSession: true,
            isRunning: false,
            isEmptySelection: false
        )
        #expect(availability == .ready)
        #expect(availability.canStart)
    }

    @Test("全组合枚举：canStart 当且仅当 .ready（防判定漂移）")
    func canStartOnlyWhenReady() {
        for hasPairedDevice in [true, false] {
            for isConnected in [true, false] {
                for hasSession in [true, false] {
                    for isRunning in [true, false] {
                        for isEmptySelection in [true, false] {
                            let availability = SyncUIStartGate.evaluate(
                                hasPairedDevice: hasPairedDevice,
                                isConnected: isConnected,
                                hasSession: hasSession,
                                isRunning: isRunning,
                                isEmptySelection: isEmptySelection
                            )
                            #expect(availability.canStart == (availability == .ready))
                            // 未连接时永远不可能给出 .ready
                            if !isConnected { #expect(availability != .ready) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 阶段映射

struct SyncUIPhaseTests {
    @Test("未连接 + 空闲/对账中/传输中 → 界面显示未连接")
    func disconnectedOverridesNonTerminal() {
        #expect(SyncUIPhase.resolve(isConnected: false, state: .idle) == .disconnected)
        #expect(SyncUIPhase.resolve(isConnected: false, state: .planning) == .disconnected)
        #expect(SyncUIPhase.resolve(isConnected: false, state: .pushing) == .disconnected)
        #expect(SyncUIPhase.resolve(isConnected: false, state: .pulling) == .disconnected)
    }

    @Test("已连接：逐态映射")
    func connectedMapping() {
        #expect(SyncUIPhase.resolve(isConnected: true, state: .idle) == .idle)
        #expect(SyncUIPhase.resolve(isConnected: true, state: .planning) == .planning)
        #expect(SyncUIPhase.resolve(isConnected: true, state: .pushing) == .pushing)
        #expect(SyncUIPhase.resolve(isConnected: true, state: .pulling) == .pulling)
        #expect(SyncUIPhase.resolve(isConnected: true, state: .done) == .done)
        #expect(SyncUIPhase.resolve(isConnected: true, state: .failed("boom")) == .failed("boom"))
    }

    @Test("终态不被掉线覆盖：跑完/失败后对端断开，结果仍然可见")
    func terminalStatesSurviveDisconnect() {
        #expect(SyncUIPhase.resolve(isConnected: false, state: .done) == .done)
        #expect(SyncUIPhase.resolve(isConnected: false, state: .failed("cancelled")) == .failed("cancelled"))
    }

    @Test("是否进行中 / 是否终态")
    func busyAndTerminal() {
        #expect(SyncUIPhase.planning.isBusy)
        #expect(SyncUIPhase.pushing.isBusy)
        #expect(SyncUIPhase.pulling.isBusy)
        #expect(!SyncUIPhase.idle.isBusy)
        #expect(!SyncUIPhase.done.isBusy)
        #expect(!SyncUIPhase.disconnected.isBusy)

        #expect(SyncUIPhase.done.isTerminal)
        #expect(SyncUIPhase.failed("x").isTerminal)
        #expect(!SyncUIPhase.pushing.isTerminal)
        #expect(!SyncUIPhase.idle.isTerminal)
    }
}

// MARK: - 进度聚合

struct SyncUIProgressAggregatorTests {
    private func report(push: Int, pull: Int) -> SyncCollectionSyncReport {
        var report = SyncCollectionSyncReport()
        report.plannedPush = (0 ..< push).map { "push/\($0).m4a" }
        report.plannedPull = (0 ..< pull).map { "pull/\($0).m4a" }
        return report
    }

    @Test("总数 = 计划推送 + 计划拉取；已传按计划封顶")
    func totalsAndClamp() {
        let progress = SyncUIProgressAggregator.make(
            phase: .pushing,
            report: report(push: 3, pull: 2),
            completed: 1,
            currentPath: "push/1.m4a"
        )
        #expect(progress.total == 5)
        #expect(progress.completed == 1)
        #expect(progress.direction == .push)
        #expect(progress.currentPath == "push/1.m4a")
        #expect(abs(progress.fraction - 0.2) < 0.0001)

        // 完成后不越界：协调器的推送控制器可能重排重试 → 回调次数超过计划数
        let overflow = SyncUIProgressAggregator.make(
            phase: .pulling,
            report: report(push: 3, pull: 2),
            completed: 9,
            currentPath: nil
        )
        #expect(overflow.completed == 5)
        #expect(overflow.clampedCompleted == 5)
        #expect(overflow.fraction == 1.0)
        #expect(overflow.isTransferFinished)
        #expect(overflow.direction == .pull)
    }

    @Test("0 总数（还没出计划）：不确定态，不除零、不越界")
    func zeroTotal() {
        let progress = SyncUIProgressAggregator.make(
            phase: .planning,
            report: SyncCollectionSyncReport(),
            completed: 4,
            currentPath: nil
        )
        #expect(progress.total == 0)
        #expect(progress.isDeterminate == false)
        #expect(progress.fraction == 0)
        #expect(progress.clampedCompleted == 0)
        #expect(progress.direction == .none)
        #expect(!progress.isTransferFinished)
    }

    @Test("负数已传（防御性）归零")
    func negativeCompleted() {
        let progress = SyncUIProgressAggregator.make(
            phase: .pushing,
            report: report(push: 2, pull: 0),
            completed: -3,
            currentPath: nil
        )
        #expect(progress.completed == 0)
        #expect(progress.fraction == 0)
    }

    @Test("非传输阶段方向为 none（对账中 / 完成）")
    func directionByPhase() {
        #expect(SyncUIProgressAggregator.direction(for: .idle) == .none)
        #expect(SyncUIProgressAggregator.direction(for: .planning) == .none)
        #expect(SyncUIProgressAggregator.direction(for: .done) == .none)
        #expect(SyncUIProgressAggregator.direction(for: .failed("x")) == .none)
        #expect(SyncUIProgressAggregator.direction(for: .pushing) == .push)
        #expect(SyncUIProgressAggregator.direction(for: .pulling) == .pull)
    }

    @Test("直接构造的极端值也不越界（防 View 侧手搓）")
    func directConstructionStaysSafe() {
        let progress = SyncUIProgress(phase: .pushing, completed: 100, total: 4, currentPath: nil, direction: .push)
        #expect(progress.clampedCompleted == 4)
        #expect(progress.fraction == 1.0)

        let negativeTotal = SyncUIProgress(phase: .pushing, completed: 3, total: -1, currentPath: nil, direction: .push)
        #expect(negativeTotal.clampedCompleted == 0)
        #expect(negativeTotal.fraction == 0)
    }
}

// MARK: - 文案数值格式

struct SyncUISizeTextTests {
    @Test("零与负数：0 B")
    func zeroAndNegative() {
        #expect(SyncUISizeText.humanReadable(bytes: 0) == "0 B")
        #expect(SyncUISizeText.humanReadable(bytes: -1024) == "0 B")
    }

    @Test("字节级不带小数")
    func bytes() {
        #expect(SyncUISizeText.humanReadable(bytes: 1) == "1 B")
        #expect(SyncUISizeText.humanReadable(bytes: 512) == "512 B")
        #expect(SyncUISizeText.humanReadable(bytes: 1023) == "1023 B")
    }

    @Test("进位与一位小数（去尾 .0）")
    func units() {
        #expect(SyncUISizeText.humanReadable(bytes: 1024) == "1 KB")
        #expect(SyncUISizeText.humanReadable(bytes: 1536) == "1.5 KB")
        #expect(SyncUISizeText.humanReadable(bytes: 1024 * 1024) == "1 MB")
        #expect(SyncUISizeText.humanReadable(bytes: 1024 * 1024 * 1024) == "1 GB")
    }

    @Test("4.2 GB 量级（二次确认文案用过的例子）")
    func gigabytes() {
        // 4.2 GiB
        let bytes: Int64 = 4_509_715_660
        #expect(SyncUISizeText.humanReadable(bytes: bytes) == "4.2 GB")
    }

    @Test("TB 量级")
    func terabytes() {
        #expect(SyncUISizeText.humanReadable(bytes: 1024 * 1024 * 1024 * 1024) == "1 TB")
    }
}

struct SyncUIDurationTextTests {
    @Test("分:秒 / 时:分:秒")
    func shortFormats() {
        #expect(SyncUIDurationText.short(seconds: 0) == "0:00")
        #expect(SyncUIDurationText.short(seconds: 65) == "1:05")
        #expect(SyncUIDurationText.short(seconds: 599) == "9:59")
        #expect(SyncUIDurationText.short(seconds: 3600) == "1:00:00")
        #expect(SyncUIDurationText.short(seconds: 3661) == "1:01:01")
        #expect(SyncUIDurationText.short(seconds: -5) == "0:00")
    }
}

// MARK: - 选择集摘要

struct SyncUISelectionSummaryTests {
    private let playlists = [
        SyncUIPlaylistOption(id: "@favorites", title: "Favorites", trackCount: 3, totalBytes: 300, missingSizeCount: 0),
        SyncUIPlaylistOption(id: "rock", title: "Rock", trackCount: 10, totalBytes: 1_000, missingSizeCount: 0),
        SyncUIPlaylistOption(id: "jazz", title: "Jazz", trackCount: 4, totalBytes: 400, missingSizeCount: 1),
    ]
    private let tracks = [
        SyncUITrackOption(relativePath: "a.m4a", title: "A", artistName: "X", fileSize: 100),
        SyncUITrackOption(relativePath: "b.m4a", title: "B", artistName: nil, fileSize: 200),
        SyncUITrackOption(relativePath: "c.m4a", title: "C", artistName: nil, fileSize: nil),
    ]

    @Test("空选择：isEmpty，不推不拉")
    func emptySelection() {
        let summary = SyncUISelectionSummarizer.make(
            selection: .playlists([]),
            playlists: playlists,
            tracks: tracks,
            library: .empty
        )
        #expect(summary.isEmpty)
        #expect(summary.trackCount == 0)
        #expect(summary.sizeText == "0 B")
        #expect(!summary.requiresConfirmation)
    }

    @Test("歌单级：曲目数/字节合计 + 未知歌单记账")
    func playlistsSummary() {
        let summary = SyncUISelectionSummarizer.make(
            selection: .playlists(["rock", "jazz", "ghost"]),
            playlists: playlists,
            tracks: tracks,
            library: .empty
        )
        #expect(!summary.isEmpty)
        #expect(summary.playlistCount == 3)
        #expect(summary.trackCount == 14)
        #expect(summary.totalBytes == 1_400)
        #expect(summary.unknownPlaylistIDs == ["ghost"])
        // 有未知歌单 → 大小是下界
        #expect(summary.isBytesPartial)
        #expect(!summary.requiresConfirmation)
    }

    @Test("歌单级：缺文件大小的成员 → 部分估算标记")
    func playlistsPartialSizes() {
        let summary = SyncUISelectionSummarizer.make(
            selection: .playlists(["jazz"]),
            playlists: playlists,
            tracks: tracks,
            library: .empty
        )
        #expect(summary.playlistCount == 1)
        #expect(summary.trackCount == 4)
        #expect(summary.totalBytes == 400)
        #expect(summary.isBytesPartial)
        #expect(summary.unknownPlaylistIDs.isEmpty)
    }

    @Test("单曲级：条数 = 选中的相对路径数；未知大小/未加载计入下界")
    func tracksSummary() {
        let summary = SyncUISelectionSummarizer.make(
            selection: .relativePaths(["b.m4a", "a.m4a", "not-loaded.m4a"]),
            playlists: playlists,
            tracks: tracks,
            library: .empty
        )
        #expect(summary.trackCount == 3)
        #expect(summary.playlistCount == 0)
        #expect(summary.totalBytes == 300)
        #expect(summary.isBytesPartial)
    }

    @Test("单曲级：全部已知大小 → 不做下界标记")
    func tracksCompleteSizes() {
        let summary = SyncUISelectionSummarizer.make(
            selection: .relativePaths(["a.m4a", "b.m4a"]),
            playlists: playlists,
            tracks: tracks,
            library: .empty
        )
        #expect(summary.trackCount == 2)
        #expect(summary.totalBytes == 300)
        #expect(!summary.isBytesPartial)
    }

    @Test("全库：取全库事实，且必须二次确认")
    func librarySummary() {
        let summary = SyncUISelectionSummarizer.make(
            selection: .all,
            playlists: playlists,
            tracks: tracks,
            library: SyncUILibraryFacts(trackCount: 1_234, totalBytes: 4_509_715_660)
        )
        #expect(summary.isLibraryWide)
        #expect(summary.requiresConfirmation)
        #expect(summary.trackCount == 1_234)
        #expect(summary.sizeText == "4.2 GB")
        #expect(!summary.isEmpty)
        #expect(summary.unknownPlaylistIDs.isEmpty)
    }

    @Test("非法歌单标识被规范化丢弃（不给重复计数）")
    func invalidPlaylistIDsDropped() {
        let summary = SyncUISelectionSummarizer.make(
            selection: .playlists(["rock", "", "  ", "rock"]),
            playlists: playlists,
            tracks: tracks,
            library: .empty
        )
        #expect(summary.playlistCount == 1)
        #expect(summary.trackCount == 10)
    }
}

// MARK: - 结果摘要

struct SyncUIReportSummaryTests {
    @Test("数字与失败清单（推送在前，按路径升序）")
    func countsAndFailures() {
        var report = SyncCollectionSyncReport()
        report.pushed = ["p2.m4a", "p1.m4a"]
        report.pulled = ["q1.m4a"]
        report.skipped = ["s1.m4a", "s2.m4a", "s3.m4a"]
        report.unresolvedCount = 2
        report.unknownPlaylistIDs = ["gone"]
        report.pushFailed = [
            SyncPushFailure(relativePath: "z9.m4a", reason: SyncPushFailureReason.sendFailed, detail: nil),
        ]
        report.pullFailed = [
            SyncFileFetchFailure(relativePath: "a1.m4a", reason: SyncFetchFailureReason.notFound),
        ]

        let summary = SyncUIReportSummary.make(report: report)
        #expect(summary.pushedCount == 2)
        #expect(summary.pulledCount == 1)
        #expect(summary.skippedCount == 3)
        #expect(summary.failedCount == 2)
        #expect(summary.transferredCount == 3)
        #expect(summary.unresolvedCount == 2)
        #expect(summary.unknownPlaylistIDs == ["gone"])
        #expect(summary.failedItems.map(\.relativePath) == ["a1.m4a", "z9.m4a"])
        #expect(summary.failedItems.map(\.isPush) == [false, true])
        #expect(!summary.isSuccess)
    }

    @Test("空选择的一次编排：记账如实（不推不拉也算一次结果）")
    func emptySelectionReport() {
        var report = SyncCollectionSyncReport()
        report.isEmptySelection = true
        let summary = SyncUIReportSummary.make(report: report)
        #expect(summary.isEmptySelection)
        #expect(summary.transferredCount == 0)
        #expect(summary.isSuccess)
    }

    @Test("中止原因：推送优先，且视为不成功")
    func abortReason() {
        var report = SyncCollectionSyncReport()
        report.pullAbortReason = "只拉取中止"
        #expect(SyncUIReportSummary.make(report: report).abortReason == "只拉取中止")

        report.pushAbortReason = "推送先中止"
        #expect(SyncUIReportSummary.make(report: report).abortReason == "推送先中止")
        #expect(!SyncUIReportSummary.make(report: report).isSuccess)
    }

    @Test("全成功：无失败项、无中止")
    func fullSuccess() {
        var report = SyncCollectionSyncReport()
        report.pushed = ["a.m4a"]
        report.pulled = ["b.m4a"]
        let summary = SyncUIReportSummary.make(report: report)
        #expect(summary.isSuccess)
        #expect(summary.failedItems.isEmpty)
        #expect(summary.abortReason == nil)
    }
}

// MARK: - 失败原因文案映射

struct SyncUIFailureReasonTextTests {
    @Test("已知原因码 → 复用接收侧既有文案键")
    func knownReasons() {
        #expect(SyncUIFailureReasonText.key(for: SyncPushFailureReason.sendFailed) == "sync_passive_reason_transfer")
        #expect(SyncUIFailureReasonText.key(for: SyncPushFailureReason.receiveFailed) == "sync_passive_reason_transfer")
        #expect(SyncUIFailureReasonText.key(for: SyncPushFailureReason.invalidPath) == "sync_passive_reason_path")
        #expect(SyncUIFailureReasonText.key(for: SyncPushFailureReason.landFailed) == "sync_passive_reason_save")
        #expect(SyncUIFailureReasonText.key(for: SyncFetchFailureReason.notFound) == "sync_passive_reason_path")
        #expect(SyncUIFailureReasonText.key(for: SyncFetchFailureReason.sendFailed) == "sync_passive_reason_transfer")
    }

    @Test("未知原因码 → 回退通用文案（不崩、不显示空）")
    func unknownReason() {
        #expect(SyncUIFailureReasonText.key(for: "totally_new_reason") == SyncUIFailureReasonText.fallbackKey)
        #expect(SyncUIFailureReasonText.key(for: "") == SyncUIFailureReasonText.fallbackKey)
    }

    @Test("本地文件不可用：有专用文案（不是笼统 Failed）")
    func localFileUnavailable() {
        #expect(SyncUIFailureReasonText.key(for: SyncPushFailureReason.localFileUnavailable) == "sync_run_reason_unavailable")
    }
}

// MARK: - 三级模式

struct SyncUISelectionModeTests {
    @Test("模式 + 勾选池 → 选择集（确定性排序）")
    func selectionFromPicks() {
        #expect(
            SyncUISelectionMode.selection(mode: .library, playlistIDs: ["b", "a"], trackPaths: ["z.m4a"])
                == .all
        )
        #expect(
            SyncUISelectionMode.selection(mode: .playlists, playlistIDs: ["b", "a"], trackPaths: [])
                == .playlists(["a", "b"])
        )
        #expect(
            SyncUISelectionMode.selection(mode: .tracks, playlistIDs: [], trackPaths: ["z.m4a", "a.m4a"])
                == .relativePaths(["a.m4a", "z.m4a"])
        )
    }

    @Test("选择集 → 模式（载入存档）")
    func modeFromSelection() {
        #expect(SyncUISelectionMode.mode(for: .all) == .library)
        #expect(SyncUISelectionMode.mode(for: .playlists([])) == .playlists)
        #expect(SyncUISelectionMode.mode(for: .relativePaths([])) == .tracks)
    }

    @Test("往返一致：模式映射不改变语义")
    func roundTrip() {
        for mode in SyncUISelectionMode.allCases {
            let selection = SyncUISelectionMode.selection(
                mode: mode,
                playlistIDs: ["rock"],
                trackPaths: ["a.m4a"]
            )
            #expect(SyncUISelectionMode.mode(for: selection) == mode)
        }
    }
}

// MARK: - 中断提示

struct SyncUIInterruptionTests {
    @Test("无失败态 → 无中断")
    func none() {
        #expect(SyncUIInterruption.resolve(phase: .idle, didDisconnectWhileRunning: false) == .none)
        #expect(SyncUIInterruption.resolve(phase: .done, didDisconnectWhileRunning: true) == .none)
        #expect(SyncUIInterruption.resolve(phase: .pushing, didDisconnectWhileRunning: true) == .none)
    }

    @Test("失败态 + 掉线标记 → 会话断开（优先于 cancelled）")
    func sessionClosed() {
        #expect(
            SyncUIInterruption.resolve(phase: .failed(SyncUIFailureReason.cancelled), didDisconnectWhileRunning: true)
                == .sessionClosed
        )
    }

    @Test("用户取消 → cancelled；其它失败原因不额外归类")
    func cancelled() {
        #expect(
            SyncUIInterruption.resolve(phase: .failed(SyncUIFailureReason.cancelled), didDisconnectWhileRunning: false)
                == .cancelled
        )
        #expect(
            SyncUIInterruption.resolve(phase: .failed("推送失败 1 项"), didDisconnectWhileRunning: false) == .none
        )
    }
}
