//
//  SpeechAssetInstallPlanner.swift
//  QQPlayer
//
//  语音模型资产安装的纯决策逻辑（不依赖 Speech 框架，可在任意 iOS 版本单测）。
//  引擎只按 SpeechAssetStep 行动，状态判断不散落在 installAssetsIfNeeded 里。
//

import Foundation

/// 模型资产状态（Speech.AssetInventory.Status 的自有镜像，便于单测）。
enum SpeechAssetStatus: Equatable {
    /// 当前语言不可用（系统不支持该模型）。
    case unsupported
    /// 系统正在下载 / 已排队。
    case downloading
    /// 可安装（未被下载占用）。
    case supported
    /// 已安装完成。
    case installed
}

/// 安装循环的下一步动作。
enum SpeechAssetStep: Equatable {
    /// 已就绪，可以开始转写。
    case ready
    /// 系统正在下载 / 排队，等下一轮再查。
    case wait
    /// 可以申请安装请求并下载。
    case install
    /// 当前语言不支持，直接失败。
    case unsupported
}

/// 资产安装的定时与决策口径（纯函数，单测覆盖）。
enum SpeechAssetInstallPlanner {
    /// 轮询间隔。
    static let pollInterval: TimeInterval = 0.5
    /// 总预算：首次模型下载 20–40s，慢网留余量。
    static let budget: TimeInterval = 120

    /// 状态 → 下一步动作。
    static func step(for status: SpeechAssetStatus) -> SpeechAssetStep {
        switch status {
        case .installed:
            return .ready
        case .downloading:
            return .wait
        case .supported:
            return .install
        case .unsupported:
            return .unsupported
        }
    }

    /// 预算是否还有剩余（严格小于才算有剩余）。
    static func hasBudgetRemaining(elapsed: TimeInterval, budget: TimeInterval) -> Bool {
        elapsed < budget
    }
}
