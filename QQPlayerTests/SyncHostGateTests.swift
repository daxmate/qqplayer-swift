//
//  SyncHostGateTests.swift
//  QQPlayerTests
//
//  M6（T1）同步 Host 常驻监听启停判定 `SyncHostGate` 纯逻辑测试：
//  - 开关关闭 → 不启动
//  - 重复 start 幂等（已运行 → 不再启动，不重启监听）
//  - 开关切换的启停判定（关闭且运行中 → 停；其余 → 无动作）
//  - 全组合枚举：判定与动作恒一致（防两个入口漂移）
//
//  为什么这些能测：`SyncHostGate` 刻意放在共享 Core（QQPlayer/Services/），
//  不带监听器/DB 依赖 → iOS 单测 target（QQPlayerTests）可直接覆盖
//  （M6 契约 A3；Mac 侧真生命周期靠编译 + 审查 + 真机验收）。
//

import Testing

@testable import QQPlayer

struct SyncHostGateTests {
    @Test("开关关闭：不启动（缺省路径不监听，未运行时无动作）")
    func disabledDoesNotStart() {
        #expect(!SyncHostGate.shouldStart(allowsLAN: false, isRunning: false))
        #expect(!SyncHostGate.shouldStop(allowsLAN: false, isRunning: false))
        #expect(SyncHostGate.toggleAction(allowsLAN: false, isRunning: false) == .none)
    }

    @Test("开关开启且未运行：可以启动")
    func enabledAndIdleStarts() {
        #expect(SyncHostGate.shouldStart(allowsLAN: true, isRunning: false))
        #expect(!SyncHostGate.shouldStop(allowsLAN: true, isRunning: false))
        #expect(SyncHostGate.toggleAction(allowsLAN: true, isRunning: false) == .start)
    }

    @Test("重复 start 幂等：已运行 → 不再启动（不重启监听、不作废 QR nonce）")
    func runningIsNoOp() {
        #expect(!SyncHostGate.shouldStart(allowsLAN: true, isRunning: true))
        #expect(!SyncHostGate.shouldStop(allowsLAN: true, isRunning: true))
        #expect(SyncHostGate.toggleAction(allowsLAN: true, isRunning: true) == .none)
    }

    @Test("开关关闭且运行中：应停止")
    func disabledWhileRunningStops() {
        #expect(SyncHostGate.shouldStop(allowsLAN: false, isRunning: true))
        #expect(!SyncHostGate.shouldStart(allowsLAN: false, isRunning: true))
        #expect(SyncHostGate.toggleAction(allowsLAN: false, isRunning: true) == .stop)
    }

    @Test("全组合枚举：动作与两个判定入口恒一致（防漂移）")
    func allCombinationsStayConsistent() {
        for allowsLAN in [true, false] {
            for isRunning in [true, false] {
                let action = SyncHostGate.toggleAction(allowsLAN: allowsLAN, isRunning: isRunning)
                #expect(
                    SyncHostGate.shouldStart(allowsLAN: allowsLAN, isRunning: isRunning) == (action == .start)
                )
                #expect(
                    SyncHostGate.shouldStop(allowsLAN: allowsLAN, isRunning: isRunning) == (action == .stop)
                )
                // start / stop 判定互斥（不可能同时要求启停）
                #expect(
                    !(SyncHostGate.shouldStart(allowsLAN: allowsLAN, isRunning: isRunning)
                        && SyncHostGate.shouldStop(allowsLAN: allowsLAN, isRunning: isRunning))
                )
            }
        }
    }
}
