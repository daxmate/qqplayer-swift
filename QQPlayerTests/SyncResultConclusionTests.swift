//
//  SyncResultConclusionTests.swift
//  QQPlayerTests
//
//  2026-09-25「结果区默认折叠」批：**结论行**（折叠态下唯一常显的一行）的纯逻辑用例。
//
//  被测 = `SyncEntityOutcomeDisclosure.fileConclusion(_:lyricsResend:)`（Mac E 结果区）与
//  `SyncEntityOutcomeDisclosure.dataConclusion(_:)`（Mac F 数据同步结果区），实现见
//  `QQPlayer/Sync/SyncEntityOutcomeDisclosure.swift`。
//
//  为什么单独一层：折叠之后「哪些指标常显、什么文案 key、什么严重度」本身就是用户可见的
//  行为（失败与缺口不许被折进沉默），而它必须是**纯逻辑**，不能散在 View 里。
//
//  ⚠️ 这些用例必须**能变红**：喂合成输入（全 0 指标 / 单缺口 / 多缺口 / 空计划已一致 /
//  空选择），断言段的集合、顺序、计数与严重度。只断言「当前通过」= 永远绿。
//

import Testing

@testable import QQPlayer

// MARK: - 文件同步（E 结果区）结论行

struct SyncFileResultConclusionTests {
    /// 成功（有传输）：只出非零段，零计数不上屏（R2）。
    @Test("成功：段 = 已送达 / 已接收 / 已一致（只出非零），全部正常严重度")
    func successShowsOnlyNonZeroSegments() {
        var report = SyncCollectionSyncReport()
        report.pushed = ["p1.m4a", "p2.m4a"]
        report.pulled = ["q1.m4a"]
        report.skipped = ["s1.m4a", "s2.m4a", "s3.m4a"]

        let line = SyncEntityOutcomeDisclosure.fileConclusion(
            SyncUIReportSummary.make(report: report),
            lyricsResend: nil
        )

        #expect(line.segments.map(\.labelKey) == [
            "sync_run_result_pushed",
            "sync_run_result_pulled",
            "sync_run_result_skipped",
        ])
        #expect(line.segments.map(\.count) == [2, 1, 3])
        #expect(line.segments.allSatisfy { $0.severity == .normal })
        #expect(line.messageKey == nil)
        #expect(line.hasDetail)
    }

    /// 部分失败：失败段在末位、计数如实、严重度 = failure（R3：失败永不折叠进沉默）。
    @Test("部分失败：失败段追加在末位，严重度 = failure")
    func partialFailureAppendsFailureSegment() {
        var report = SyncCollectionSyncReport()
        report.pushed = ["p1.m4a"]
        report.pushFailed = [
            SyncPushFailure(relativePath: "z9.m4a", reason: SyncPushFailureReason.sendFailed, detail: nil),
        ]
        report.pullFailed = [
            SyncFileFetchFailure(relativePath: "a1.m4a", reason: SyncFetchFailureReason.notFound),
        ]

        let line = SyncEntityOutcomeDisclosure.fileConclusion(
            SyncUIReportSummary.make(report: report),
            lyricsResend: nil
        )

        #expect(line.segments.map(\.labelKey) == ["sync_run_result_pushed", "sync_run_result_failed"])
        #expect(line.segments.map(\.count) == [1, 2])
        #expect(line.segments.map(\.severity) == [.normal, .failure])
        #expect(line.messageKey == nil)
    }

    /// 空选择：整句兜底（不显示计数段）；详情的有无由「补发轮是否跑过」决定。
    @Test("空选择：整句兜底文案；补发轮跑过时详情仍在（E2 事实并入详情，不丢）")
    func emptySelectionUsesSentenceFallback() {
        var report = SyncCollectionSyncReport()
        report.isEmptySelection = true
        let summary = SyncUIReportSummary.make(report: report)

        let withoutResend = SyncEntityOutcomeDisclosure.fileConclusion(summary, lyricsResend: nil)
        #expect(withoutResend.segments.isEmpty)
        #expect(withoutResend.messageKey == "sync_run_result_empty_selection")
        #expect(!withoutResend.hasDetail)

        var resend = SyncLyricsResendSummary()
        resend.pendingResend = ["@lyrics/a.lrc"]
        let withResend = SyncEntityOutcomeDisclosure.fileConclusion(summary, lyricsResend: resend)
        #expect(withResend.messageKey == "sync_run_result_empty_selection")
        #expect(withResend.hasDetail)
    }

    /// 计划为空但「对端已一致」：结论行说「已一致 N」，既有判定语义不变（详情里仍有例举块）。
    @Test("对端已一致：结论行「已一致 N」，isEmptyPlanAlreadyIdentical 语义保留")
    func alreadyIdenticalKeepsExistingSemantics() {
        var report = SyncCollectionSyncReport()
        report.skipped = ["s1.m4a", "s2.m4a"]
        let summary = SyncUIReportSummary.make(report: report)

        #expect(summary.isEmptyPlanAlreadyIdentical)
        let line = SyncEntityOutcomeDisclosure.fileConclusion(summary, lyricsResend: nil)
        #expect(line.segments.map(\.labelKey) == ["sync_run_result_skipped"])
        #expect(line.segments.map(\.count) == [2])
        #expect(line.segments.map(\.severity) == [.normal])
    }

    /// 非空选择但一个计数都没有：不留空白结论行（兜底文案），指标墙仍在详情里。
    @Test("非空选择 + 全 0：兜底「没有需要同步的改动」，不留空行")
    func allZeroCountsFallBackToNothingNew() {
        let line = SyncEntityOutcomeDisclosure.fileConclusion(
            SyncUIReportSummary.make(report: SyncCollectionSyncReport()),
            lyricsResend: nil
        )

        #expect(line.segments.isEmpty)
        #expect(line.messageKey == SyncEntityOutcomeDisclosure.nothingNewKey)
        #expect(line.hasDetail)
    }
}

// MARK: - 数据同步（F 结果区）结论行

struct SyncDataResultConclusionTests {
    /// 合成一次**已收尾**的数据同步账目。
    private func finished(_ build: (inout SyncDataSyncReport) -> Void) -> SyncDataSyncReport {
        var report = SyncDataSyncReport()
        build(&report)
        report.isFinished = true
        return report
    }

    /// 未收尾 = 没有结论（界面显示「还没有同步过播放数据」）。
    @Test("未收尾：无段、无兜底文案、无详情")
    func unfinishedHasNoConclusion() {
        let line = SyncEntityOutcomeDisclosure.dataConclusion(SyncDataSyncReport())
        #expect(line.segments.isEmpty)
        #expect(line.messageKey == nil)
        #expect(!line.hasDetail)
    }

    /// 全 0 指标：结论行为空 ⇒ 兜底文案（恒 0 的指标格不进结论行）。
    @Test("全 0 指标：结论行无段（消噪音），详情仍在")
    func allZeroMetricsAreSuppressed() {
        let line = SyncEntityOutcomeDisclosure.dataConclusion(finished { _ in })
        #expect(line.segments.isEmpty)
        #expect(line.messageKey == SyncEntityOutcomeDisclosure.nothingNewKey)
        #expect(line.hasDetail)
    }

    /// 单缺口：只出这一段，且按缺口上色。
    @Test("单缺口（挂起）：只出一段、severity = gap")
    func singleGapOnlySegment() {
        let line = SyncEntityOutcomeDisclosure.dataConclusion(
            finished { $0.tally.accumulate(.suspended, count: 3) }
        )
        #expect(line.segments.map(\.labelKey) == ["sync_run_data_result_pending"])
        #expect(line.segments.map(\.count) == [3])
        #expect(line.segments.map(\.severity) == [.gap])
        #expect(line.messageKey == nil)
    }

    /// 多缺口 + 正常结果：顺序 = 投影给的顺序，零项被剔除，缺口 / 正常分色。
    @Test("多缺口 + 正常：顺序与严重度按投影，零项剔除")
    func multipleGapsKeepProjectionOrderAndSeverity() {
        let report = finished {
            $0.tally.overwrite(.outbound, with: 5)
            $0.tally.accumulate(.applied, count: 9)
            $0.tally.accumulate(.unresolved, count: 2)
            $0.tally.accumulate(.applyFailed, count: 1)
            $0.tally.accumulate(.ambiguousIdentity, count: 4)
            $0.tally.accumulate(.ignoredDelete, count: 7)
        }

        let line = SyncEntityOutcomeDisclosure.dataConclusion(report)

        #expect(line.segments.map(\.labelKey) == [
            "sync_run_data_result_sent",
            "sync_run_data_result_applied",
            "sync_run_data_result_unresolved",
            "sync_run_data_apply_failed",
            "sync_run_data_ambiguous_identity",
            "sync_run_data_result_skipped",
        ])
        #expect(line.segments.map(\.count) == [5, 9, 2, 1, 4, 7])
        #expect(line.segments.map(\.severity) == [.normal, .normal, .gap, .gap, .gap, .normal])
    }

    /// 每个类别都有计数时的段顺序 = `conclusionOrder`（含挂起 / 忽略删除，无遗漏）。
    @Test("段顺序与投影顺序表逐项一致（含挂起 / 忽略删除）")
    func segmentOrderMatchesProjectionOrder() {
        let report = finished { report in
            for outcome in SyncRowOutcome.allCases {
                report.tally.accumulate(outcome, count: 1)
            }
        }

        let line = SyncEntityOutcomeDisclosure.dataConclusion(report)

        #expect(line.segments.count == SyncRowOutcome.allCases.count)
        #expect(
            line.segments.map(\.labelKey)
                == SyncEntityOutcomeDisclosure.conclusionOrder
                .map(SyncEntityOutcomeDisclosure.outcomeLabelKey)
        )
    }

    /// 段文案 key 全部来自既有投影（不新造汇总文案）：与 `placement` 的 key 集合一致。
    @Test("段文案 key = 既有投影的 key 集合（不新增汇总文案）")
    func segmentKeysComeFromExistingProjection() {
        let report = finished { report in
            for outcome in SyncRowOutcome.allCases {
                report.tally.accumulate(outcome, count: 1)
            }
        }
        let line = SyncEntityOutcomeDisclosure.dataConclusion(report)

        let expected = Set(SyncRowOutcome.allCases.map(SyncEntityOutcomeDisclosure.outcomeLabelKey))
        #expect(Set(line.segments.map(\.labelKey)) == expected)
    }
}

// MARK: - 形状（防漂移）

struct SyncResultConclusionShapeTests {
    /// 顺序表恰好覆盖全部结果类别（新增 `SyncRowOutcome` 漏表态即红）。
    @Test("conclusionOrder 恰好覆盖全部结果类别，且不重复")
    func conclusionOrderCoversEveryOutcome() {
        #expect(Set(SyncEntityOutcomeDisclosure.conclusionOrder) == Set(SyncRowOutcome.allCases))
        #expect(SyncEntityOutcomeDisclosure.conclusionOrder.count == SyncRowOutcome.allCases.count)
    }

    /// 缺口严重度的集合必须 = 「有东西没落本地」的既有判据集合（两处口径漂移即红）。
    @Test("缺口严重度集合 == disclosesByEntity 集合（防两套缺口口径漂移）")
    func gapSeverityMatchesDisclosurePredicate() {
        let bySeverity = SyncRowOutcome.allCases.filter {
            SyncEntityOutcomeDisclosure.conclusionSeverity($0) == .gap
        }
        let byPredicate = SyncRowOutcome.allCases.filter(SyncEntityOutcomeDisclosure.disclosesByEntity)
        #expect(Set(bySeverity) == Set(byPredicate))
    }

    /// 折叠态用的两个新 key 固定（换 key 必须同步改五语文案）。
    @Test("折叠态 key：详情标签 / 无改动兜底")
    func collapseKeysAreStable() {
        #expect(SyncEntityOutcomeDisclosure.detailLabelKey == "sync_result_detail")
        #expect(SyncEntityOutcomeDisclosure.nothingNewKey == "sync_result_nothing_new")
    }
}
