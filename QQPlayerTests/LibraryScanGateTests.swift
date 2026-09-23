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
//  本文件锁四件事：
//   ① 三个必需分支（空库 0.7h ⇒ 扫 / 非空 0.7h ⇒ 跳过 / 3h ⇒ 扫）；
//   ② **计数读不到（哨兵 `-1`）不得当空库**（走节流分支，不是强制扫）；
//   ③ 空库那条的**文案可区分**（不与既有两行混）；
//   ④ 平台边界：`forcesScanWhenLibraryIsEmpty` 在 iOS = true、在 macOS = false
//      （macOS 行为逐字节不变，理由见 `LibraryScanGate` 文件头）。
//
//  取数口径（与实现同一套，见 `LibraryScanGate` 文件头）：入参是 `trackCount: Int`——
//  `0` = 空库；`> 0` = 非空；`LibraryScanGate.unknownTrackCount`（`-1`）= 读不到。
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

    /// 必需分支 3（**保持现行为**）：3 小时前扫过 ⇒ 扫（空库 / 非空 / 读不到都一样）。
    @Test("窗口外：3 小时前扫过 ⇒ 扫（三种取数形态都一样）")
    func elapsedIntervalAlwaysScans() {
        for count in [emptyLibrary, nonEmptyLibrary, unreadableLibrary] {
            let result = decision(hoursAgo: 3, trackCount: count)
            #expect(result.kind == .intervalElapsed, "trackCount=\(count) 时应走窗口外分支")
            #expect(result.shouldScan)
        }
    }

    /// 必需分支 4（**本包修正**）：计数**读不到**（哨兵 `-1`）⇒ **不得当空库**。
    /// 口径 = 读不到按「非空」处理 → 节流窗口内保持跳过（避免退化成每次启动强制全量扫）。
    @Test("计数读不到：0.7 小时前扫过 ⇒ 仍跳过（不许把「读不到」当「空库」）")
    func unreadableTrackCountIsNotTreatedAsEmpty() {
        // 哨兵本身不是 0（否则等于 fail-open）。
        #expect(LibraryScanGate.unknownTrackCount != 0, "哨兵不得与「空库」同值")
        #expect(unreadableLibrary != emptyLibrary)

        let unreadable = decision(hoursAgo: 0.7, trackCount: unreadableLibrary)
        #expect(unreadable.kind == .recentlyScanned, "读不到 ≠ 空库，不得走强制扫")
        #expect(!unreadable.shouldScan)

        #if os(iOS)
            // 同一时刻，成功的 0 与「读不到」必须是**两种**决策（本包区分的核心）。
            let empty = decision(hoursAgo: 0.7, trackCount: emptyLibrary)
            #expect(empty.kind == .emptyLibrary)
            #expect(empty.kind != unreadable.kind)
            #expect(empty.shouldScan && !unreadable.shouldScan)
        #endif

        // 读不到的布尔视图同样为 false。
        let shouldScan = LibraryScanGate.shouldPerformAutoScan(
            lastScanDate: scanned(hoursAgo: 0.7),
            trackCount: unreadableLibrary,
            now: now
        )
        #expect(!shouldScan)
    }

    // MARK: - ② 边界与历史分支

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

    // MARK: - ③ 文案可区分（新增行不与既有两行混）

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

    // MARK: - ④ 平台边界（macOS 行为不变）

    @Test("平台边界：空库强制扫规则 iOS 生效、macOS 关闭")
    func platformBoundaryOfEmptyLibraryRule() {
        #if os(iOS)
            #expect(LibraryScanGate.forcesScanWhenLibraryIsEmpty, "iOS 必须生效（本包修复点）")
        #else
            #expect(!LibraryScanGate.forcesScanWhenLibraryIsEmpty, "macOS 必须关闭（行为零变化）")
        #endif
        // 节流值 = 历史值（两处内联实现里就是 1.0）。
        #expect(LibraryScanGate.minimumIntervalHours == 1.0)
    }
}
