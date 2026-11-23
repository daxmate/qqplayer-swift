//
//  ReplayGainMath.swift
//  QQPlayer
//
//  ReplayGain 音量归一化纯计算层：无 IO、无状态、无并发，全分支可单测。
//
//  产品口径（2026-11 用户拍板）：
//   - 默认开启，模式按曲目；可切按专辑 / 关闭；
//   - 预放大（preamp）-12 … +6 dB，默认 0，独立于 EQ 的用户预放大；
//   - 防削波默认开，峰值上限 -1 dBFS：maxGain = -1 - 20*log10(peak)，
//     最终增益取 min(目标增益, maxGain)；无 peak 时不设上限（仍受预放大范围约束）；
//   - 专辑模式缺 album gain 回退按曲目；都缺则增益 0；
//   - 最终结果 clamp 到 [-24, +12] dB。
//

import Foundation

/// ReplayGain 计算入口（纯函数集合）。
enum ReplayGainMath {
    /// 最终增益下限（dB）。
    static let minGainDB: Double = -24
    /// 最终增益上限（dB）。
    static let maxGainDB: Double = 12
    /// 预放大范围（dB）。
    static let preampMinDB: Double = -12
    static let preampMaxDB: Double = 6
    /// 防削波峰值上限（dBFS）。
    static let peakCeilingDB: Double = -1

    /// 一首歌的原始 ReplayGain 数据（单位 dB / 线性峰值）。
    struct Gains: Equatable, Sendable {
        var trackGain: Double?
        var trackPeak: Double?
        var albumGain: Double?
        var albumPeak: Double?

        init(
            trackGain: Double? = nil,
            trackPeak: Double? = nil,
            albumGain: Double? = nil,
            albumPeak: Double? = nil
        ) {
            self.trackGain = trackGain
            self.trackPeak = trackPeak
            self.albumGain = albumGain
            self.albumPeak = albumPeak
        }

        /// 是否有任何可用增益（track 或 album）。
        var hasAnyGain: Bool {
            trackGain != nil || albumGain != nil
        }
    }

    /// 按模式挑选目标增益与对应峰值。返回 nil = 无可用数据（增益按 0 处理）。
    static func selectedGain(_ gains: Gains, mode: ReplayGainMode) -> (gain: Double, peak: Double?)? {
        switch mode {
        case .off:
            return nil
        case .track:
            guard let trackGain = gains.trackGain else { return nil }
            return (trackGain, gains.trackPeak)
        case .album:
            if let albumGain = gains.albumGain {
                // 专辑峰值缺失时退回曲目峰值（同一批文件通常同源）
                return (albumGain, gains.albumPeak ?? gains.trackPeak)
            }
            // 专辑模式缺 album gain → 回退按曲目
            guard let trackGain = gains.trackGain else { return nil }
            return (trackGain, gains.trackPeak)
        }
    }

    /// 防削波允许的最大增益（dB）；不防削波 / peak 缺失或非法 → nil（不设上限）。
    static func maxGainForPeak(_ peak: Double?, preventClipping: Bool) -> Double? {
        guard preventClipping, let peak, peak.isFinite, peak > 0 else { return nil }
        return peakCeilingDB - 20 * log10(peak)
    }

    /// 把预放大夹到产品范围 [-12, +6]。
    static func clampPreamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, preampMinDB), preampMaxDB)
    }

    /// 把最终增益夹到 [-24, +12]。
    static func clampGain(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, minGainDB), maxGainDB)
    }

    /// 计算最终应用增益（dB）。mode == .off 或无数据 → 0。
    ///
    /// 顺序：基础增益 + 预放大 → 峰值限幅 → clamp 到 [-24, +12]。
    /// 注：限幅后仍 clamp 到下限 -24 是产品口径（极响曲目保持 -24 而不是更低）。
    static func resolveGain(
        _ gains: Gains,
        mode: ReplayGainMode,
        preampDB: Double,
        preventClipping: Bool
    ) -> Double {
        guard let selected = selectedGain(gains, mode: mode) else { return 0 }
        var gain = selected.gain + clampPreamp(preampDB)
        if let ceiling = maxGainForPeak(selected.peak, preventClipping: preventClipping) {
            gain = min(gain, ceiling)
        }
        return clampGain(gain)
    }
}
