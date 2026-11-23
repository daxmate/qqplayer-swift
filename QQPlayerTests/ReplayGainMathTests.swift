//
//  ReplayGainMathTests.swift
//  QQPlayerTests
//
//  ReplayGain 纯计算层全分支：模式 / 回退 / 峰值限幅 / clamp / 异值 / 无数据。
//  以及设置模型的 UserDefaults 往返与默认值。
//

import Foundation
import Testing

@testable import QQPlayer

struct ReplayGainMathTests {
    // MARK: - 模式

    @Test("off 模式：即使有数据也返回 0")
    func offModeReturnsZero() {
        let gains = ReplayGainMath.Gains(trackGain: -6, trackPeak: 0.9, albumGain: -4, albumPeak: 0.95)
        #expect(ReplayGainMath.resolveGain(gains, mode: .off, preampDB: 3, preventClipping: true) == 0)
    }

    @Test("track 模式：用 track gain")
    func trackModeUsesTrackGain() {
        let gains = ReplayGainMath.Gains(trackGain: -6.5, trackPeak: nil, albumGain: -3, albumPeak: nil)
        #expect(ReplayGainMath.resolveGain(gains, mode: .track, preampDB: 0, preventClipping: true) == -6.5)
    }

    @Test("album 模式：优先 album gain")
    func albumModePrefersAlbumGain() {
        let gains = ReplayGainMath.Gains(trackGain: -6.5, trackPeak: nil, albumGain: -3.2, albumPeak: nil)
        #expect(ReplayGainMath.resolveGain(gains, mode: .album, preampDB: 0, preventClipping: true) == -3.2)
    }

    @Test("album 模式：缺 album gain 回退按曲目")
    func albumModeFallsBackToTrackGain() {
        let gains = ReplayGainMath.Gains(trackGain: -6.5, trackPeak: nil, albumGain: nil, albumPeak: nil)
        #expect(ReplayGainMath.resolveGain(gains, mode: .album, preampDB: 0, preventClipping: true) == -6.5)
    }

    @Test("album 模式：album peak 缺失时退回 track peak 做限幅")
    func albumModeFallsBackToTrackPeak() {
        let gains = ReplayGainMath.Gains(trackGain: -6, trackPeak: 0.5, albumGain: 6, albumPeak: nil)
        // maxGain = -1 - 20*log10(0.5) ≈ +5.02 dB
        let result = ReplayGainMath.resolveGain(gains, mode: .album, preampDB: 0, preventClipping: true)
        #expect(abs(result - 5.0206) < 0.001)
    }

    @Test("都缺数据：增益 0")
    func noDataReturnsZero() {
        let gains = ReplayGainMath.Gains()
        #expect(ReplayGainMath.resolveGain(gains, mode: .track, preampDB: 6, preventClipping: true) == 0)
        #expect(ReplayGainMath.resolveGain(gains, mode: .album, preampDB: 6, preventClipping: true) == 0)
    }

    // MARK: - 预放大

    @Test("预放大叠加并夹到 [-12, +6]")
    func preampClamped() {
        let gains = ReplayGainMath.Gains(trackGain: -3, trackPeak: nil)
        #expect(ReplayGainMath.resolveGain(gains, mode: .track, preampDB: 20, preventClipping: false) == 3)
        #expect(ReplayGainMath.resolveGain(gains, mode: .track, preampDB: -50, preventClipping: false) == -15)
        #expect(ReplayGainMath.resolveGain(gains, mode: .track, preampDB: 2.5, preventClipping: false) == -0.5)
    }

    // MARK: - 防削波

    @Test("防削波：峰值 1.0 → 上限 -1 dB")
    func peakLimitAtUnity() {
        let gains = ReplayGainMath.Gains(trackGain: 6, trackPeak: 1.0)
        #expect(ReplayGainMath.resolveGain(gains, mode: .track, preampDB: 0, preventClipping: true) == -1)
    }

    @Test("防削波：峰值 0.5 → 上限约 +5.02 dB")
    func peakLimitAtHalf() {
        let gains = ReplayGainMath.Gains(trackGain: 12, trackPeak: 0.5)
        let expected = ReplayGainMath.peakCeilingDB - 20 * log10(0.5)
        #expect(abs(ReplayGainMath.resolveGain(gains, mode: .track, preampDB: 0, preventClipping: true) - expected) < 0.001)
    }

    @Test("防削波关闭：不受峰值约束")
    func peakLimitDisabled() {
        let gains = ReplayGainMath.Gains(trackGain: 6, trackPeak: 1.0)
        #expect(ReplayGainMath.resolveGain(gains, mode: .track, preampDB: 0, preventClipping: false) == 6)
    }

    @Test("峰值限幅只降不升")
    func peakLimitOnlyLowers() {
        let gains = ReplayGainMath.Gains(trackGain: -10, trackPeak: 0.2)
        // 上限 ≈ +12.98，目标 -10 不受影响
        #expect(ReplayGainMath.resolveGain(gains, mode: .track, preampDB: 0, preventClipping: true) == -10)
    }

    @Test("非法峰值（0 / 负数 / 非有限）忽略")
    func invalidPeakIgnored() {
        for peak in [0.0, -0.5, Double.nan, Double.infinity] {
            let gains = ReplayGainMath.Gains(trackGain: 5, trackPeak: peak)
            #expect(ReplayGainMath.resolveGain(gains, mode: .track, preampDB: 0, preventClipping: true) == 5)
        }
    }

    // MARK: - clamp

    @Test("最终增益夹到 [-24, +12]")
    func finalGainClamped() {
        let loud = ReplayGainMath.Gains(trackGain: 30)
        #expect(ReplayGainMath.resolveGain(loud, mode: .track, preampDB: 6, preventClipping: false) == ReplayGainMath.maxGainDB)

        let quiet = ReplayGainMath.Gains(trackGain: -40)
        #expect(ReplayGainMath.resolveGain(quiet, mode: .track, preampDB: -12, preventClipping: false) == ReplayGainMath.minGainDB)
    }

    @Test("极响 + 防削波：限幅后仍不低于 -24")
    func clippingStillRespectsFloor() {
        let gains = ReplayGainMath.Gains(trackGain: 12, trackPeak: 5.0)
        // 上限 = -1 - 20*log10(5) ≈ -14.97，高于下限
        let result = ReplayGainMath.resolveGain(gains, mode: .track, preampDB: 0, preventClipping: true)
        #expect(abs(result - (-1 - 20 * log10(5.0))) < 0.001)
    }

    @Test("NaN 增益值兜底为 0")
    func nanGainFallsBackToZero() {
        let gains = ReplayGainMath.Gains(trackGain: Double.nan)
        #expect(ReplayGainMath.resolveGain(gains, mode: .track, preampDB: 0, preventClipping: true) == 0)
    }
}

struct ReplayGainSettingsTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "ReplayGainSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("默认：开启 + 按曲目 + 预放大 0 + 防削波开 + 补算开")
    func defaults() {
        let defaults = makeDefaults()
        let settings = ReplayGainSettings.load(from: defaults)
        #expect(settings.isEnabled)
        #expect(settings.mode == .track)
        #expect(settings.preampDB == 0)
        #expect(settings.preventClipping)
        #expect(settings.analyzeMissingTracks)
    }

    @Test("往返：保存后读回一致")
    func roundTrip() {
        let defaults = makeDefaults()
        var settings = ReplayGainSettings.default
        settings.mode = .album
        settings.preampDB = 3.5
        settings.preventClipping = false
        settings.analyzeMissingTracks = false
        settings.save(to: defaults)

        let loaded = ReplayGainSettings.load(from: defaults)
        #expect(loaded.mode == .album)
        #expect(loaded.preampDB == 3.5)
        #expect(loaded.preventClipping == false)
        #expect(loaded.analyzeMissingTracks == false)
    }

    @Test("开关语义：关闭记住最后模式，重开恢复该模式")
    func toggleSemantics() {
        var settings = ReplayGainSettings.default
        settings.mode = .album
        settings.isEnabled = false
        #expect(settings.mode == .off)
        settings.isEnabled = true
        #expect(settings.mode == .album)
    }
}
