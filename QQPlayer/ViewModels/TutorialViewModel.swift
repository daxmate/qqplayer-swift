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

@MainActor
class TutorialViewModel: ObservableObject {
    /// 单步引导，保留计数字段以兼容既有视图结构（当前恒为 0）。
    @Published var currentStep: Int = 0

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
