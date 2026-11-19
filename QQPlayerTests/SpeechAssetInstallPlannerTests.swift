//
//  SpeechAssetInstallPlannerTests.swift
//  QQPlayerTests
//
//  资产安装决策的纯函数测试（不碰 Speech 运行时，任何 iOS 版本都能跑）。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite("SpeechAssetInstallPlanner")
struct SpeechAssetInstallPlannerTests {
    @Test("四种资产状态映射到正确的下一步")
    func statusMapsToExpectedStep() {
        #expect(SpeechAssetInstallPlanner.step(for: .installed) == .ready)
        #expect(SpeechAssetInstallPlanner.step(for: .downloading) == .wait)
        #expect(SpeechAssetInstallPlanner.step(for: .supported) == .install)
        #expect(SpeechAssetInstallPlanner.step(for: .unsupported) == .unsupported)
    }

    @Test("预算边界：严格小于才算有剩余")
    func budgetBoundary() {
        let budget: TimeInterval = 120

        #expect(SpeechAssetInstallPlanner.hasBudgetRemaining(elapsed: 0, budget: budget))
        #expect(SpeechAssetInstallPlanner.hasBudgetRemaining(elapsed: 119.999, budget: budget))
        #expect(!SpeechAssetInstallPlanner.hasBudgetRemaining(elapsed: 120, budget: budget))
        #expect(!SpeechAssetInstallPlanner.hasBudgetRemaining(elapsed: 120.001, budget: budget))
    }
}
