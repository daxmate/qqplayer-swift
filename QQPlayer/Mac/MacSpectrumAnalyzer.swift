//
//  MacSpectrumAnalyzer.swift
//  QQPlayer
//
//  Real-time spectrum analyzer for the macOS player visualizer (D4, web 版
//  Visualizer 对齐——频谱 bars 起步，样式子集后续再扩). QQPlayerMac target
//  only: taps the main mixer of the native AVAudioEngine, FFTs the signal
//  (Accelerate/vDSP) and publishes ~32 log-spaced level bins (0...1).
//
//  Constraints:
//  - SFBAudioEngine tracks (Opus/OGG/DSD) run inside SFBAudioEngine's own
//    AudioPlayer, which does not expose an installTap — no data available,
//    the visualizer simply stays inactive for those tracks.
//  - The tap callback runs on the audio thread: DSP happens there, only the
//    final levels snapshot hops onto the main actor (~30 fps throttle).
//
//  2026-09-12 审计 B4 · M3 修复：DSP 状态（FFT setup / smoothed / 节流时间戳）
//  原封在 @MainActor 类型里却被音频线程直接读写（只靠 Swift 5 宽松并发检查放行）。
//  现在全部收进无隔离的 `MacSpectrumDSP`（内部一把锁），本类只剩主 actor 状态
//  （levels / isActive / installedEngine）——单一隔离域，音频线程不再触碰主 actor。
//

import AVFoundation
import Foundation

/// 主混音器实时频谱（QQPlayerMac target only）。
@MainActor
final class MacSpectrumAnalyzer: ObservableObject {
    static let shared = MacSpectrumAnalyzer()

    /// 频段能量（0...1，对数频率分布，视觉条高度用；主线程只读）
    @Published private(set) var levels: [Float] = []
    /// 是否有实时数据（播放中且 tap 已装；false = 视觉化应隐藏/静止）
    @Published private(set) var isActive = false

    /// DSP 核（无隔离；音频线程只碰它）
    private let dsp = MacSpectrumDSP()
    private weak var installedEngine: AVAudioEngine?

    private init() {
        levels = Array(repeating: 0, count: MacSpectrumDSP.binCount)
    }

    // MARK: - Tap 生命周期（主线程）

    /// 幂等安装 mainMixer tap（engine 运行中调用；同引擎已装 / 引擎未跑则跳过）。
    func ensureTap(engine: AVAudioEngine) {
        if installedEngine === engine { return }
        if installedEngine != nil { removeTap() }
        guard engine.isRunning else { return }
        installedEngine = engine
        // 音频线程闭包只捕获 dsp（@unchecked Sendable）与 weak self——
        // 不再从音频线程读写任何主 actor 状态。
        let dsp = self.dsp
        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(MacSpectrumDSP.fftSize),
            format: nil
        ) { [weak self, dsp] buffer, _ in
            guard let snapshot = dsp.process(buffer: buffer) else { return }
            Task { @MainActor in
                self?.levels = snapshot
            }
        }
        isActive = true
    }

    /// 移除 tap（暂停/切到 SFB 曲目/引擎停止时调用）。
    func removeTap() {
        guard let engine = installedEngine else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        installedEngine = nil
        isActive = false
        dsp.reset()
        levels = Array(repeating: 0, count: MacSpectrumDSP.binCount)
    }
}
