//
//  LibraryPullToRefreshPlanTests.swift
//  QQPlayerTests
//
// target: ios-only
//
//  Task（2026-10-10）首页下拉刷新编排决策守卫：
//    ① 无已配对桌面端 → refreshOnly（跳过握手，只重读本机曲库）
//    ② 有已配对桌面端 → connectThenSync（先握手连接，再全库重扫 + 重读）
//    ③ 负数（异常输入）也按「无配对」处理（跳过握手，不崩）
//
//  纯判定级用例：不碰网络 / 不读 DB / 不启模拟器交互。
//

import Testing

@testable import QQPlayer

@Suite("首页下拉刷新编排决策")
struct LibraryPullToRefreshPlanTests {
    @Test("无已配对桌面端 → 跳过握手，只刷新")
    func noPairedHostRefreshesOnly() {
        #expect(LibraryPullToRefreshPlan.make(pairedHostCount: 0) == .refreshOnly)
    }

    @Test("有已配对桌面端 → 先握手再重扫")
    func pairedHostConnectsThenSyncs() {
        #expect(LibraryPullToRefreshPlan.make(pairedHostCount: 1) == .connectThenSync)
        #expect(LibraryPullToRefreshPlan.make(pairedHostCount: 3) == .connectThenSync)
    }

    @Test("负数（异常输入）按无配对处理")
    func negativeCountRefreshesOnly() {
        #expect(LibraryPullToRefreshPlan.make(pairedHostCount: -1) == .refreshOnly)
    }
}
