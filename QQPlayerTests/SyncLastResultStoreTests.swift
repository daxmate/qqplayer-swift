//
//  SyncLastResultStoreTests.swift
//  QQPlayerTests
//
//  2026-09-27 批 persist-last-sync-result：同步「最近一次结果」持久化的纯逻辑用例。
//
//  被测 = 共享 Core `QQPlayer/Services/SyncLastResultStore.swift`：
//  - 快照 Codable 往返（失败清单顺序 / 方向 / 中止原因）
//  - 损坏 / 缺字段 / 版本不符 / 未知方向 → 一律 nil（不崩）
//  - 失败清单截断但保留真值计数
//  - 按对端分桶 + 跨设备「最近一次」
//  - 恢复口径（连上设备只回显该桶；未连接回显跨设备）
//  - 落盘口径（空选择 / 用户取消不落盘）
//  - 投影一致性（report 直投 == 快照回读）
//  - 相对时间文案（注入 now / locale，含回落绝对文案）
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 测试夹具

/// 独立 suite 的 UserDefaults（不污染标准域）。
private func makeSyncDefaults() -> UserDefaults {
    UserDefaults(suiteName: "sync-last-result-tests-\(UUID().uuidString)") ?? .standard
}

/// 一份字段完整的可用快照。
private func makeSyncSnapshot(
    peerID: String,
    finishedAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
    direction: SyncTransferDirection = .upload
) -> SyncLastResultSnapshot {
    var summary = SyncUIReportSummary()
    summary.pushedCount = 1
    return SyncLastResultSnapshot(
        summary: summary,
        finishedAt: finishedAt,
        peerID: peerID,
        peerDisplayName: "设备 \(peerID)",
        direction: direction
    )
}

// MARK: - Codable 往返

struct SyncLastResultStoreRoundTripTests {
    @Test("快照往返：写入独立 suite → load 字段全等（失败清单顺序 / 方向 / 中止原因）")
    func roundTrip() {
        let defaults = makeSyncDefaults()
        var report = SyncCollectionSyncReport()
        report.pushed = ["p2.m4a", "p1.m4a"]
        report.pulled = ["q1.m4a"]
        report.skipped = ["s1.m4a"]
        report.unresolvedCount = 2
        report.unknownPlaylistIDs = ["gone"]
        report.pushAbortReason = "推送中止"
        report.pushFailed = [
            SyncPushFailure(relativePath: "z9.m4a", reason: SyncPushFailureReason.sendFailed, detail: nil),
        ]
        report.pullFailed = [
            SyncFileFetchFailure(relativePath: "a1.m4a", reason: SyncFetchFailureReason.notFound),
        ]
        report.lyricsDiscarded = ["l1.m4a"]
        report.lyricsKeptLocal = ["l2.m4a", "l3.m4a"]

        let snapshot = SyncLastResultSnapshot(
            summary: SyncUIReportSummary.make(report: report),
            finishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            peerID: "peer-A",
            peerDisplayName: "iPhone 15",
            direction: .download
        )
        SyncLastResultStore.save(snapshot, defaults: defaults)

        let loaded = SyncLastResultStore.load(peerID: "peer-A", defaults: defaults)
        #expect(loaded == snapshot)
        #expect(loaded?.failedItems.map(\.relativePath) == ["a1.m4a", "z9.m4a"])
        #expect(loaded?.failedItems.map(\.isPush) == [false, true])
        #expect(loaded?.direction == "download")
        #expect(loaded?.abortReason == "推送中止")
        #expect(loaded?.lyricsDiscardedCount == 1)
        #expect(loaded?.lyricsKeptLocalCount == 2)
    }
}

// MARK: - 损坏回落

struct SyncLastResultStoreCorruptionTests {
    @Test("非 JSON / 空字典 / 缺字段 / 版本不符 / 未知方向 → 一律 nil，不崩")
    func corruptionFallsBack() {
        let key = SyncLastResultStore.storageKey

        // 非 JSON 字节
        let garbage = makeSyncDefaults()
        garbage.set(Data([0x00, 0x01, 0x02, 0xFF]), forKey: key)
        #expect(SyncLastResultStore.load(peerID: "peer-A", defaults: garbage) == nil)
        #expect(SyncLastResultStore.latest(defaults: garbage) == nil)

        // 合法 JSON 但空字典
        let emptyDict = makeSyncDefaults()
        emptyDict.set(Data("{}".utf8), forKey: key)
        #expect(SyncLastResultStore.load(peerID: "peer-A", defaults: emptyDict) == nil)
        #expect(SyncLastResultStore.latest(defaults: emptyDict) == nil)

        // 缺 finishedAt 等必填字段 → 整表解码失败
        let missingField = makeSyncDefaults()
        missingField.set(
            Data(#"{"peer-A":{"schemaVersion":1,"peerID":"peer-A"}}"#.utf8),
            forKey: key
        )
        #expect(SyncLastResultStore.load(peerID: "peer-A", defaults: missingField) == nil)

        // schemaVersion 不符
        let future = makeSyncDefaults()
        var futureSnapshot = makeSyncSnapshot(peerID: "peer-A")
        futureSnapshot.schemaVersion = 999
        SyncLastResultStore.save(futureSnapshot, defaults: future)
        #expect(SyncLastResultStore.load(peerID: "peer-A", defaults: future) == nil)
        #expect(SyncLastResultStore.latest(defaults: future) == nil)

        // 未知方向值
        let unknownDirection = makeSyncDefaults()
        var badDirection = makeSyncSnapshot(peerID: "peer-A")
        badDirection.direction = "sideways"
        SyncLastResultStore.save(badDirection, defaults: unknownDirection)
        #expect(SyncLastResultStore.load(peerID: "peer-A", defaults: unknownDirection) == nil)
    }
}

// MARK: - 清单截断

struct SyncLastResultStoreTruncationTests {
    @Test("21 条失败 → 落盘 20 条、真值计数 21；回读 failedCount 不按清单推")
    func truncation() {
        let defaults = makeSyncDefaults()
        var summary = SyncUIReportSummary()
        summary.failedCount = 21
        summary.failedItems = (1 ... 21).map {
            SyncUIFailedItem(relativePath: "f\($0).m4a", reason: "reason", isPush: true)
        }
        let snapshot = SyncLastResultSnapshot(
            summary: summary,
            finishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            peerID: "peer-A",
            peerDisplayName: "设备 peer-A",
            direction: .upload
        )
        #expect(snapshot.failedItems.count == 20)
        #expect(snapshot.failedCount == 21)
        #expect(snapshot.failedItems.first?.relativePath == "f1.m4a")
        #expect(snapshot.failedItems.last?.relativePath == "f20.m4a")

        SyncLastResultStore.save(snapshot, defaults: defaults)
        let restored = SyncLastResultStore.load(peerID: "peer-A", defaults: defaults)
            .map { SyncUIReportSummary.make(snapshot: $0) }
        #expect(restored?.failedCount == 21)
        #expect(restored?.failedItems.count == 20)
    }
}

// MARK: - 分桶

struct SyncLastResultStoreBucketingTests {
    @Test("两个 peerID 互不串；latest 取 finishedAt 最新")
    func bucketing() {
        let defaults = makeSyncDefaults()
        let older = makeSyncSnapshot(peerID: "peer-A", finishedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = makeSyncSnapshot(peerID: "peer-B", finishedAt: Date(timeIntervalSince1970: 1_800_000_000))
        SyncLastResultStore.save(older, defaults: defaults)
        SyncLastResultStore.save(newer, defaults: defaults)

        #expect(SyncLastResultStore.load(peerID: "peer-A", defaults: defaults)?.peerID == "peer-A")
        #expect(SyncLastResultStore.load(peerID: "peer-B", defaults: defaults)?.peerID == "peer-B")
        #expect(SyncLastResultStore.load(peerID: "peer-C", defaults: defaults) == nil)
        #expect(SyncLastResultStore.latest(defaults: defaults)?.peerID == "peer-B")

        // 同桶覆盖：新的一次替换旧的
        let replaced = makeSyncSnapshot(peerID: "peer-A", finishedAt: Date(timeIntervalSince1970: 1_900_000_000))
        SyncLastResultStore.save(replaced, defaults: defaults)
        #expect(SyncLastResultStore.latest(defaults: defaults)?.peerID == "peer-A")
    }
}

// MARK: - 恢复口径

struct SyncLastResultRestoreTests {
    @Test("命中桶 = 同设备；未连接 / 无该桶 = 跨设备最近一次；空 = nil")
    func resolve() {
        let buckets = [
            "peer-A": makeSyncSnapshot(peerID: "peer-A", finishedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            "peer-B": makeSyncSnapshot(peerID: "peer-B", finishedAt: Date(timeIntervalSince1970: 1_800_000_000)),
        ]

        let hit = SyncLastResultRestore.resolve(
            connectedPeerID: "peer-A",
            connectedPeerName: "A",
            buckets: buckets
        )
        #expect(hit?.snapshot.peerID == "peer-A")
        #expect(hit?.isCrossDevice == false)

        let crossDevice = SyncLastResultRestore.resolve(
            connectedPeerID: nil,
            connectedPeerName: nil,
            buckets: buckets
        )
        #expect(crossDevice?.snapshot.peerID == "peer-B")
        #expect(crossDevice?.isCrossDevice == true)

        // 连着没有桶的设备 → 也回跨设备最近一次
        let otherPeer = SyncLastResultRestore.resolve(
            connectedPeerID: "peer-C",
            connectedPeerName: "C",
            buckets: buckets
        )
        #expect(otherPeer?.snapshot.peerID == "peer-B")
        #expect(otherPeer?.isCrossDevice == true)

        #expect(SyncLastResultRestore.resolve(connectedPeerID: nil, connectedPeerName: nil, buckets: [:]) == nil)
    }

    @Test("命中桶但展示名为空 → 用当前连接名补一次")
    func fillsMissingDisplayName() {
        var snapshot = makeSyncSnapshot(peerID: "peer-A")
        snapshot.peerDisplayName = ""
        let resolved = SyncLastResultRestore.resolve(
            connectedPeerID: "peer-A",
            connectedPeerName: "补上的名字",
            buckets: ["peer-A": snapshot]
        )
        #expect(resolved?.snapshot.peerDisplayName == "补上的名字")
    }
}

// MARK: - 落盘口径

struct SyncLastResultPersistRuleTests {
    @Test("空选择 / 用户取消不落盘；成功 / 有失败 / 掉线中止落盘")
    func persistRule() {
        var emptySelection = SyncUIReportSummary()
        emptySelection.isEmptySelection = true
        #expect(!SyncLastResultPersistRule.shouldPersist(summary: emptySelection, interruption: .none))
        #expect(!SyncLastResultPersistRule.shouldPersist(summary: emptySelection, interruption: .cancelled))

        var success = SyncUIReportSummary()
        success.pushedCount = 1
        #expect(SyncLastResultPersistRule.shouldPersist(summary: success, interruption: .none))
        #expect(!SyncLastResultPersistRule.shouldPersist(summary: success, interruption: .cancelled))
        #expect(SyncLastResultPersistRule.shouldPersist(summary: success, interruption: .sessionClosed))

        var failed = success
        failed.failedCount = 2
        #expect(SyncLastResultPersistRule.shouldPersist(summary: failed, interruption: .none))
        #expect(SyncLastResultPersistRule.shouldPersist(summary: failed, interruption: .sessionClosed))
    }
}

// MARK: - 投影一致性

struct SyncLastResultProjectionTests {
    @Test("report 直投 == 快照回读（对端已一致例举 / 失败清单顺序 / 中止原因）")
    func projectionConsistency() {
        var report = SyncCollectionSyncReport()
        report.pushed = ["p1.m4a", "p2.m4a"]
        report.pulled = ["q1.m4a"]
        report.skipped = ["s1.m4a", "s2.m4a", "s3.m4a", "s4.m4a"]
        report.unresolvedCount = 1
        report.unknownPlaylistIDs = ["ghost"]
        report.pullAbortReason = "拉取中止"
        report.pushFailed = [
            SyncPushFailure(relativePath: "z9.m4a", reason: SyncPushFailureReason.sendFailed, detail: nil),
        ]
        report.pullFailed = [
            SyncFileFetchFailure(relativePath: "a1.m4a", reason: SyncFetchFailureReason.notFound),
        ]

        let direct = SyncUIReportSummary.make(report: report)
        let snapshot = SyncLastResultSnapshot(
            summary: direct,
            finishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            peerID: "peer-A",
            peerDisplayName: "iPhone",
            direction: .upload
        )
        let restored = SyncUIReportSummary.make(snapshot: snapshot)

        #expect(restored == direct)
        #expect(restored.peerAlreadyHasCount == 4)
        #expect(restored.peerAlreadyHasSample == ["s1.m4a", "s2.m4a", "s3.m4a"])
        #expect(restored.abortReason == "拉取中止")
        #expect(restored.failedItems.map(\.relativePath) == ["a1.m4a", "z9.m4a"])
        #expect(restored.isEmptyPlanAlreadyIdentical == direct.isEmptyPlanAlreadyIdentical)
        #expect(restored.isSuccess == direct.isSuccess)
    }

    @Test("歌词明细路径不进持久层，但计数必须还原（界面只用计数）")
    func lyricsCountsSurvive() {
        var summary = SyncUIReportSummary()
        summary.lyricsDiscarded = ["l1.m4a", "l2.m4a"]
        summary.lyricsKeptLocal = ["l3.m4a"]
        let snapshot = SyncLastResultSnapshot(
            summary: summary,
            finishedAt: Date(timeIntervalSince1970: 1_800_000_000),
            peerID: "peer-A",
            peerDisplayName: "iPhone",
            direction: .download
        )
        let restored = SyncUIReportSummary.make(snapshot: snapshot)
        #expect(restored.lyricsDiscarded.count == 2)
        #expect(restored.lyricsKeptLocal.count == 1)
    }
}

// MARK: - 相对时间文案

struct SyncUIRelativeTimeTextTests {
    @Test("en 含 minute / zh-Hans 含 分钟；同一时刻不崩、非空")
    func relativeText() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let past = now.addingTimeInterval(-300)
        #expect(
            SyncUIRelativeTimeText.short(from: past, now: now, locale: Locale(identifier: "en_US"))
                .contains("minute")
        )
        #expect(
            SyncUIRelativeTimeText.short(from: past, now: now, locale: Locale(identifier: "zh-Hans"))
                .contains("分钟")
        )
        #expect(!SyncUIRelativeTimeText.short(from: now, now: now, locale: Locale(identifier: "en_US")).isEmpty)
    }

    @Test("formatter 返回 nil / 空串 → 回落绝对日期文案（含年份）")
    func absoluteFallback() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let past = now.addingTimeInterval(-300)
        let year = Calendar(identifier: .gregorian).component(.year, from: past)

        let nilFallback = SyncUIRelativeTimeText.short(
            from: past,
            now: now,
            locale: Locale(identifier: "en_US")
        ) { _, _ in nil }
        #expect(!nilFallback.isEmpty)
        #expect(nilFallback.contains(String(year)))

        let emptyFallback = SyncUIRelativeTimeText.short(
            from: past,
            now: now,
            locale: Locale(identifier: "en_US")
        ) { _, _ in "" }
        #expect(emptyFallback.contains(String(year)))

        let absolute = SyncUIRelativeTimeText.absolute(from: past, locale: Locale(identifier: "zh-Hans"))
        #expect(absolute.contains(String(year)))
    }
}
