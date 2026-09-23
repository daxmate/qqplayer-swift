//
//  LibraryScanGateTests.swift
//  QQPlayerTests
//
// target: ios-only
//
//  Task D（2026-09-23）：**「重装/重编译后打开就该有歌」**的扫描决策回归。
//
//  事故形态（真机日志，连续两次启动都跳过）：
//    ```
//    01:16:56Z ⏰ Last scan was 0.7 hours ago - skipping
//    01:16:56Z ⏭️ Recent app launch - skipping automatic scan (use manual sync button)
//    01:18:03Z ⏭️ Foreground: Skipping auto-scan (use manual sync button)
//    ```
//  `lastLibraryScanDate` 存在**数据容器的 Preferences**（`DeleteSettings`，
//  `Models/SettingsModels.swift`，用的是 `UserDefaults.standard`）——覆盖安装不会清，
//  重装后它仍落在 1 小时节流窗口内 ⇒ 启动不扫；而库此时**可能是空的** ⇒ 打开一直 0 首，
//  只能靠用户手点刷新。故新增判据：**曲库为空 ⇒ 无条件扫**（不受 1 小时节流约束）。
//
//  本文件锁五件事：
//   ① 三个必需分支（空库 0.7h ⇒ 扫 / 非空 0.7h ⇒ 跳过 / 3h ⇒ 扫）；
//   ② **计数读不到（哨兵）⇒ 扫（fail-open）**，且是**独立一态**（不是「空库」）；
//   ③ 空库与读不到两条**可分辨**（日志文案 + 级别都不同）；
//   ④ 空库那条的文案可区分（不与既有两行混）；
//   ⑤ 平台边界：`forcesScanWhenLibraryIsEmpty` 在 iOS = true、在 macOS = false
//      （macOS 行为逐字节不变，理由见 `LibraryScanGate` 文件头）。
//
//  取数口径（与实现同一套，见 `LibraryScanGate` 文件头）：入参是 `trackCount: Int`——
//  `0` = 空库（⇒ 扫）；`> 0` = 非空（走节流）；`LibraryScanGate.unknownTrackCount`（`-1`）
//  = 读不到（⇒ 扫，fail-open，但日志与空库不同）。
//
//  纯判定级用例：不读 UserDefaults、不碰 DB、不启模拟器交互。
//  注意：`#expect` 宏体不接受 `try`；断言一律先取局部变量。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite("启动/回前台扫描决策：空库必扫（Task D）")
struct LibraryScanGateTests {
    /// 固定「现在」（决策是纯函数，时刻注入 ⇒ 无时钟依赖）。
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// 三种取数形态：空库 / 非空 / 读不到（哨兵）。
    private let emptyLibrary = 0
    private let nonEmptyLibrary = 225
    private let unreadableLibrary = LibraryScanGate.unknownTrackCount

    /// `hoursAgo` 小时前。
    private func scanned(hoursAgo: Double) -> Date {
        now.addingTimeInterval(-hoursAgo * 3600)
    }

    private func decision(hoursAgo: Double, trackCount: Int) -> LibraryScanGate.Decision {
        LibraryScanGate.decision(
            lastScanDate: scanned(hoursAgo: hoursAgo),
            trackCount: trackCount,
            now: now
        )
    }

    // MARK: - ① 三个必需分支

    /// 必需分支 1（**本次新增**）：0.7 小时前扫过 + **曲库为空** ⇒ 扫。
    @Test("空库：0.7 小时前扫过也必须扫（1 小时节流不再拦住空库）")
    func emptyLibraryForcesScanInsideThrottleWindow() {
        #if os(iOS)
            let result = decision(hoursAgo: 0.7, trackCount: emptyLibrary)
            #expect(result.kind == .emptyLibrary, "空库必须走强制扫分支，实际：\(result.kind)")
            #expect(result.shouldScan, "空库 = 打开就该有歌：必须扫")
            // 布尔视图（历史调用点语义）与之一致。
            let shouldScan = LibraryScanGate.shouldPerformAutoScan(
                lastScanDate: scanned(hoursAgo: 0.7),
                trackCount: emptyLibrary,
                now: now
            )
            #expect(shouldScan)
        #else
            // macOS：本规则不生效（行为逐字节不变，见 LibraryScanGate 文件头）。
            let result = decision(hoursAgo: 0.7, trackCount: emptyLibrary)
            #expect(result.kind == .recentlyScanned)
            #expect(!result.shouldScan)
        #endif
    }

    /// 必需分支 2（**保持现行为**）：0.7 小时前扫过 + 曲库非空 ⇒ 跳过。
    @Test("非空库：0.7 小时前扫过仍跳过（历史节流不变）")
    func nonEmptyLibraryKeepsThrottle() {
        let result = decision(hoursAgo: 0.7, trackCount: nonEmptyLibrary)
        #expect(result.kind == .recentlyScanned)
        #expect(!result.shouldScan)
        let shouldScan = LibraryScanGate.shouldPerformAutoScan(
            lastScanDate: scanned(hoursAgo: 0.7),
            trackCount: nonEmptyLibrary,
            now: now
        )
        #expect(!shouldScan)
    }

    /// 必需分支 3（**保持现行为**）：3 小时前扫过 ⇒ 扫（三种取数形态都一样）。
    @Test("窗口外：3 小时前扫过 ⇒ 扫（三种取数形态都一样）")
    func elapsedIntervalAlwaysScans() {
        for count in [emptyLibrary, nonEmptyLibrary, unreadableLibrary] {
            let result = decision(hoursAgo: 3, trackCount: count)
            #expect(result.kind == .intervalElapsed, "trackCount=\(count) 时应走窗口外分支")
            #expect(result.shouldScan)
        }
    }

    // MARK: - ② 计数读不到（哨兵）：独立一态 + fail-open ⇒ 扫

    /// 计数读不到 = **独立一态**（不是空库），且 fail-open ⇒ 扫。
    @Test("计数读不到：0.7 小时前扫过也扫（fail-open），且与「空库」是两态")
    func unreadableTrackCountForcesScanAsDistinctState() {
        // 哨兵本身不是 0（否则等于把「读不到」折成「空库」）。
        #expect(LibraryScanGate.unknownTrackCount != 0, "哨兵不得与「空库」同值")
        #expect(unreadableLibrary != emptyLibrary)

        let unreadable = decision(hoursAgo: 0.7, trackCount: unreadableLibrary)
        #expect(unreadable.kind == .unknownTrackCount, "读不到必须走独立态，实际：\(unreadable.kind)")
        #expect(unreadable.shouldScan, "fail-open：计数读不到时宁可多扫一轮，不让用户对着空列表干等")

        // 布尔视图（历史调用点语义）与之一致。
        let shouldScan = LibraryScanGate.shouldPerformAutoScan(
            lastScanDate: scanned(hoursAgo: 0.7),
            trackCount: unreadableLibrary,
            now: now
        )
        #expect(shouldScan)

        #if os(iOS)
            // 同一时刻，「成功的 0」与「读不到」必须是**两种**决策（同为扫，但态不同）。
            let empty = decision(hoursAgo: 0.7, trackCount: emptyLibrary)
            #expect(empty.kind == .emptyLibrary)
            #expect(empty.kind != unreadable.kind)
            #expect(empty.shouldScan && unreadable.shouldScan)
        #endif
    }

    /// 读不到那条日志必须与空库那条**文案 + 级别**都可分辨（排查时要能分清）。
    @Test("读不到与空库可分辨：文案不同 + 级别不同（warn vs info）")
    func unreadableIsDistinguishableFromEmpty() {
        let unreadable = LibraryScanGate.logEntry(for: decision(hoursAgo: 0.7, trackCount: unreadableLibrary))
        let empty = LibraryScanGate.logEntry(for: decision(hoursAgo: 0.7, trackCount: emptyLibrary))

        #if os(iOS)
            #expect(unreadable.message != empty.message, "两条文案必须不同")
            #expect(unreadable.isWarning, "读不到是异常态 ⇒ warn")
            #expect(!empty.isWarning, "空库是正常态（新装/换容器）⇒ info")
            #expect(unreadable.isWarning != empty.isWarning, "级别必须不同")
            #expect(unreadable.message.contains("unreadable"), "文案要点明「读不到」，实际：\(unreadable.message)")
            #expect(unreadable.message.contains("fail-open"))
        #endif
    }

    // MARK: - ③ 边界与历史分支

    /// 从未扫过 ⇒ 扫（历史分支，且不依赖计数判据）。
    @Test("从未扫过 ⇒ 扫（nil 分支与计数判据无关）")
    func neverScannedAlwaysScans() {
        for count in [emptyLibrary, nonEmptyLibrary, unreadableLibrary] {
            let result = LibraryScanGate.decision(lastScanDate: nil, trackCount: count, now: now)
            #expect(result.kind == .neverScanned, "trackCount=\(count) 时 nil 分支必须扫")
            #expect(result.shouldScan)
        }
    }

    /// 节流边界：恰好 1.0 小时 ⇒ 扫（`>=` 语义与历史实现逐字一致）。
    @Test("边界：恰好 1.0 小时 ⇒ 扫（>= 语义不变）")
    func exactlyOneHourScans() {
        let result = decision(hoursAgo: 1.0, trackCount: nonEmptyLibrary)
        #expect(result.kind == .intervalElapsed)
        #expect(result.shouldScan)
        // 略小于 1 小时且非空 ⇒ 跳过（窗口内）。
        let insideWindow = decision(hoursAgo: 0.999, trackCount: nonEmptyLibrary)
        #expect(insideWindow.kind == .recentlyScanned)
    }

    /// 时钟回拨（`lastScanDate` 在未来）：不得变成「窗口外 ⇒ 每启动必扫」的意外路径。
    @Test("时钟回拨：lastScanDate 在未来 ⇒ 非空库仍跳过")
    func futureLastScanDateDoesNotForceScan() {
        let result = LibraryScanGate.decision(
            lastScanDate: now.addingTimeInterval(3600),
            trackCount: nonEmptyLibrary,
            now: now
        )
        #expect(result.kind == .recentlyScanned)
        #expect(!result.shouldScan)
    }

    // MARK: - ④ 穷尽五态 + 文案可区分

    /// 五态**两两不同**且 `shouldScan` 与口径一致（穷尽性回归）。
    @Test("穷尽五态：kind 两两不同，shouldScan 与口径一致")
    func fiveStatesAreExhaustivelyDistinct() {
        let never = LibraryScanGate.decision(lastScanDate: nil, trackCount: nonEmptyLibrary, now: now)
        let elapsed = decision(hoursAgo: 3, trackCount: nonEmptyLibrary)
        let empty = decision(hoursAgo: 0.7, trackCount: emptyLibrary)
        let unreadable = decision(hoursAgo: 0.7, trackCount: unreadableLibrary)
        let recent = decision(hoursAgo: 0.7, trackCount: nonEmptyLibrary)

        let kinds = [never.kind, elapsed.kind, empty.kind, unreadable.kind, recent.kind]
        #expect(Set(kinds.map { String(describing: $0) }).count == 5, "五态必须两两不同")

        // shouldScan：只有 recentlyScanned 为 false（其余四态都扫）。
        #expect(never.shouldScan && elapsed.shouldScan && recent.shouldScan == false)
        if LibraryScanGate.forcesScanWhenLibraryIsEmpty {
            #expect(empty.shouldScan && unreadable.shouldScan, "iOS：空库与读不到都扫")
        }
    }

    @Test("空库那条是新文案：与既有 will scan / skipping 两行逐字不同")
    func emptyLibraryLogLineIsDistinguishable() {
        let empty = LibraryScanGate.logEntry(for: decision(hoursAgo: 0.7, trackCount: emptyLibrary))
        let willScan = LibraryScanGate.logEntry(for: decision(hoursAgo: 3, trackCount: nonEmptyLibrary))
        let skipping = LibraryScanGate.logEntry(for: decision(hoursAgo: 0.7, trackCount: nonEmptyLibrary))
        let never = LibraryScanGate.logEntry(for: LibraryScanGate.decision(
            lastScanDate: nil, trackCount: nonEmptyLibrary, now: now
        ))

        #if os(iOS)
            #expect(empty.message.contains("📚 Library is empty - forcing library scan"))
            #expect(!empty.isWarning, "强制扫是正常路径，不是警告")
            #expect(empty.message != willScan.message)
            #expect(empty.message != skipping.message)
            #expect(empty.message != never.message)
        #endif
        // 既有三条文案保持原样（依赖日志的人不用改解析）。
        #expect(never.message == "🆕 Never scanned before - will perform scan")
        #expect(willScan.message == "⏰ Last scan was 3.0 hours ago - will scan")
        #expect(skipping.message == "⏰ Last scan was 0.7 hours ago - skipping")
        #expect(skipping.isWarning, "跳过仍是 warn（与历史一致）")
    }

    // MARK: - ⑤ 平台边界（macOS 行为不变）

    @Test("平台边界：空库强制扫规则 iOS 生效、macOS 关闭")
    func platformBoundaryOfEmptyLibraryRule() {
        #if os(iOS)
            #expect(LibraryScanGate.forcesScanWhenLibraryIsEmpty, "iOS 必须生效（本包修复点）")
        #else
            #expect(!LibraryScanGate.forcesScanWhenLibraryIsEmpty, "macOS 必须关闭（行为零变化）")
        #endif
        // 节流值 = 历史值（两处内联实现里就是 1.0）。
        #expect(LibraryScanGate.minimumIntervalHours == 1.0)

        // 读不到这条也随平台开关走 ⇒ macOS 下不入强制扫（结果仍是节流分支）。
        if !LibraryScanGate.forcesScanWhenLibraryIsEmpty {
            let unreadable = decision(hoursAgo: 0.7, trackCount: unreadableLibrary)
            #expect(unreadable.kind == .recentlyScanned)
        }
    }
}
