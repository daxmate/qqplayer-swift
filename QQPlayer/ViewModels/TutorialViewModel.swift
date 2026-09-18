//
//  TutorialViewModel.swift
//  QQPlayer
//
//  View model for the tutorial flow
//
//  M3-2（2026-09-10）：iOS 音乐存储已切本地沙盒 Documents（退役 iCloud），
//  Tutorial 收敛为单步「添加音乐」引导——原 Apple ID / iCloud Drive 检测步骤
//  与相关 CloudKit/ubiquity 探测整体退役。
//

import Foundation
import Observation

// target: ios-only（QQPlayer/ViewModels 不在 QQPlayerMac 白名单）
//
// 2026-09-18 批 1「叶子」：ObservableObject → @Observable（按属性追踪）。
// 本类型无跨对象订阅、无 fanout（唯一消费点 TutorialView）、无显式 objectWillChange 依赖，
// 字段也只有 currentStep 一个且全仓无人读 —— 迁移不改变任何可见刷新时机。
@MainActor
@Observable
class TutorialViewModel {
    /// 单步引导，保留计数字段以兼容既有视图结构（当前恒为 0）。
    var currentStep: Int = 0

    func nextStep() {
        // 单步引导无下一步（保留 API 以最小化视图改动）。
    }

    func previousStep() {
        // 单步引导无上一步。
    }

    func completeTutorial() {
        // Save that tutorial has been completed
        UserDefaults.standard.set(true, forKey: "HasCompletedTutorial")
        print("✅ Tutorial completed and saved to UserDefaults")
    }

    nonisolated static func shouldShowTutorial() -> Bool {
        return !UserDefaults.standard.bool(forKey: "HasCompletedTutorial")
    }
}
