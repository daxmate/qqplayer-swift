//
//  EQModels.swift
//  QQPlayer
//
//  EQ helper types: Double rounding extension and EQError
//

import Foundation

// Helper extension for rounding doubles
extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

// MARK: - 预设应用的同源校验（纯函数，可单测）

/// 异步加载结果只在「请求的预设仍是当前预设」时才落地。
///
/// 背景（2026-09-12 审计 P4）：applyEQSettings 的 Task 捕获调用时的 preset，
/// `await loadBands` 返回后不校验 → 快速切换 A→B 时，后完成的 A 会把
/// eqFrequencies/eqGains 覆盖回 A（UI 显示 B，听感是 A），直到下一次操作才纠正。
/// updatePresetBands 已有该校验——统一走本入口，避免两套判定（行为单一事实源）。
enum EQPresetApplyGate {
    static func shouldApply(requestedPresetId: Int64?, currentPresetId: Int64?) -> Bool {
        requestedPresetId == currentPresetId
    }
}

// MARK: - Errors

enum EQError: Error, LocalizedError {
    case cannotDeleteBuiltInPreset
    case invalidImportData
    case invalidGraphicEQFormat
    case presetNotFound

    var errorDescription: String? {
        switch self {
        case .cannotDeleteBuiltInPreset:
            return "Cannot delete built-in presets"
        case .invalidImportData:
            return "Invalid preset import data"
        case .invalidGraphicEQFormat:
            return "Invalid GraphicEQ format. Expected format: 'GraphicEQ: freq1 gain1; freq2 gain2; ...'"
        case .presetNotFound:
            return "Preset not found"
        }
    }
}
