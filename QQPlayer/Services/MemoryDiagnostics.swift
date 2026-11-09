//
//  MemoryDiagnostics.swift
//  QQPlayer
//
//  内存诊断打点：读 task_vm_info.phys_footprint（MB），统一走 AppLog 落盘。
//
//  背景（2026-11-09 真机）：CarPlay 无线投屏播放到 229s 时日志硬断，前 3 分钟收到 7 次
//  内存警告。线上日志里没有可对照的占用曲线，事后只能靠猜。这里只做观测：
//  启动 / 开始播放 / 播放中每 30 秒 / 收到内存警告 / 前后台切换各打一条，前缀统一
//  `📊 Memory:`，方便 `grep '📊 Memory:'` 拉整条曲线。不引入轮询、不改播放逻辑。
//

// target: ios-only

import Foundation

@MainActor
enum MemoryDiagnostics {
    /// 常驻内存（MB）：phys_footprint 是 iOS 判定 jetsam 的口径，比 resident_size 更贴近真实压力。
    /// 取不到时退化为 0（只影响这条日志的可读性，不影响主流程）。
    static var footprintMegabytes: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024 / 1024
    }

    /// 打一条内存快照。event 用短语（启动 / 开始播放 / 播放中 / 内存警告 / scenePhase 等）。
    static func log(_ event: String) {
        let footprint = footprintMegabytes
        guard footprint > 0 else {
            AppLog.info(.general, "📊 Memory: \(event) (unavailable)")
            return
        }
        AppLog.info(.general, String(format: "📊 Memory: %@ %.1f MB", event, footprint))
    }

    private static var lastPeriodicLogAt: Date?

    /// 周期打点：不到间隔直接返回（播放中 30s 一次，不给每个 tick 加成本）。
    static func logPeriodically(_ event: String, interval: TimeInterval = 30) {
        let now = Date()
        if let last = lastPeriodicLogAt, now.timeIntervalSince(last) < interval {
            return
        }
        lastPeriodicLogAt = now
        log(event)
    }
}
