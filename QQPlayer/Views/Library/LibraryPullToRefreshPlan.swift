//
//  LibraryPullToRefreshPlan.swift
//  QQPlayer
//
//  首页**下拉刷新编排决策**（纯逻辑，可单测）：
//  有已配对桌面端 → 先握手连接（IOSPassiveSyncCenter.connectAndWait）+ 全库重扫；
//  无已配对桌面端 → 跳过握手，只重读本机曲库并给轻量提示。
//
//  为什么抽成纯函数：下拉手势本身依赖真机/视图生命周期，无法单测；把「无配对则跳过
//  握手」这条判据单独表达出来，iOS 测试 target 才能直接锁死这条分支
//  （用例见 QQPlayerTests/LibraryPullToRefreshPlanTests.swift）。
//
// target: ios-only（消费端 = iOS 首页 LibraryView；Mac 侧为 MacLibraryView）
//

/// 下拉刷新编排计划。
enum LibraryPullToRefreshPlan: Equatable {
    /// 无已配对桌面端：跳过握手，只刷新（重读）本机曲库，并给轻量提示。
    case refreshOnly
    /// 有已配对桌面端：先握手连接，再全库重扫 + 重读曲库。
    case connectThenSync

    /// 已配对主机数 → 计划。
    static func make(pairedHostCount: Int) -> LibraryPullToRefreshPlan {
        pairedHostCount > 0 ? .connectThenSync : .refreshOnly
    }
}
