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

import Accelerate
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

    private let binCount = 32
    private let fftSize = 1024
    private var fftSetup: FFTSetup?
    private weak var installedEngine: AVAudioEngine?
    private var lastMainUpdate: Date = .distantPast
    private let mainUpdateInterval: TimeInterval = 1.0 / 30.0

    /// 峰值保持平滑（attack 即时，decay 缓降——频谱条不闪跳）。
    /// 音频线程（process）与主线程（removeTap 置零）都会访问 → NSLock 保护。
    private var smoothed: [Float] = []
    private let lock = NSLock()
    /// 每回调衰减量：mainMixer tap 按 IO 周期回调（实测 buffer ~4800 帧 ≈ 9-10Hz），
    /// 0.05/回调 ≈ 0.45/s，从满到零约 2s——跟随音乐有活力又不闪跳。
    private let decayPerFrame: Float = 0.05

    private init() {
        let log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        levels = Array(repeating: 0, count: binCount)
        smoothed = Array(repeating: 0, count: binCount)
    }

    // MARK: - Tap 生命周期（主线程）

    /// 幂等安装 mainMixer tap（engine 运行中调用；同引擎已装 / 引擎未跑则跳过）。
    func ensureTap(engine: AVAudioEngine) {
        if installedEngine === engine { return }
        if installedEngine != nil { removeTap() }
        guard engine.isRunning else { return }
        installedEngine = engine
        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: AVAudioFrameCount(fftSize),
            format: nil
        ) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        isActive = true
    }

    /// 移除 tap（暂停/切到 SFB 曲目/引擎停止时调用）。
    func removeTap() {
        guard let engine = installedEngine else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        installedEngine = nil
        isActive = false
        lock.lock()
        smoothed = Array(repeating: 0, count: binCount)
        lock.unlock()
        levels = Array(repeating: 0, count: binCount)
    }

    // MARK: - DSP（音频线程）

    private func process(buffer: AVAudioPCMBuffer) {
        guard let fftSetup,
              let channelData = buffer.floatChannelData,
              buffer.frameLength > 0 else { return }

        let frameCount = Int(buffer.frameLength)
        let count = min(frameCount, fftSize)
        var samples = [Float](repeating: 0, count: fftSize)
        samples.withUnsafeMutableBufferPointer { dst in
            dst.baseAddress?.update(from: channelData[0], count: count)
        }

        // zrip 打包：实序列按 (偶→实部, 奇→虚部) 拆成 N/2 个 split complex
        var realp = [Float](repeating: 0, count: fftSize / 2)
        var imagp = [Float](repeating: 0, count: fftSize / 2)
        for k in 0 ..< fftSize / 2 {
            realp[k] = samples[2 * k]
            imagp[k] = samples[2 * k + 1]
        }

        // 前向 FFT（zrip 原地：输出仍在这两个数组）
        var split = DSPSplitComplex(realp: &realp, imagp: &imagp)
        let log2n = vDSP_Length(log2(Float(fftSize)))
        vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

        // |X|² 取前半有效 bin（0...N/2-1），再除 N 开方得幅度
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        magnitudes.withUnsafeMutableBufferPointer { mp in
            var splitOut = DSPSplitComplex(realp: &realp, imagp: &imagp)
            vDSP_zvmags(&splitOut, 1, mp.baseAddress!, 1, vDSP_Length(fftSize / 2))
        }
        var scale = Float(1.0) / Float(fftSize)
        vDSP_vsmul(magnitudes, 1, &scale, &magnitudes, 1, vDSP_Length(fftSize / 2))
        // |X|² 开方得幅度（手写循环：vvsqrtf 旧 API 需 Int32 指针，512 次/帧开销可忽略）
        var sqrtOut = [Float](repeating: 0, count: fftSize / 2)
        for i in 0 ..< fftSize / 2 {
            sqrtOut[i] = sqrt(magnitudes[i])
        }

        // 对数频段聚合：40Hz-奈奎斯特映射到 binCount 段（每段取均值，跳过 DC）
        let sampleRate = max(Float(buffer.format.sampleRate), 1)
        let binWidth = sampleRate / Float(fftSize)
        let usableBins = min(Int(16_000 / binWidth), fftSize / 2 - 1)
        var bins = [Float](repeating: 0, count: binCount)
        let lowFreq: Float = 40
        let highFreq = sampleRate / 2
        for b in 0 ..< binCount {
            let f0 = lowFreq * powf(highFreq / lowFreq, Float(b) / Float(binCount))
            let f1 = lowFreq * powf(highFreq / lowFreq, Float(b + 1) / Float(binCount))
            let i0 = max(1, Int(f0 / binWidth))
            // min(usableBins, …) 截断后可能 i1 <= i0（高频段起点已超出可听上限）
            // → 闭/开区间都会崩「Range requires lowerBound <= upperBound」（2026-09-05 真机实锤）
            let i1 = min(usableBins, max(i0 + 1, Int(f1 / binWidth)))
            guard i1 > i0 else { continue }
            var sum: Float = 0
            var n = 0
            for i in i0 ..< i1 {
                sum += sqrtOut[i]
                n += 1
            }
            bins[b] = n > 0 ? sum / Float(n) : 0
        }
        // 底噪削减 + 增益 + 截断到 0...1
        for i in 0 ..< binCount {
            bins[i] = min(1, max(0, (bins[i] - 0.004) * 3.0))
        }

        // 峰值保持平滑（锁保护，removeTap 可能并发置零）
        lock.lock()
        for i in 0 ..< binCount {
            if bins[i] > smoothed[i] {
                smoothed[i] = bins[i]
            } else {
                smoothed[i] = max(0, smoothed[i] - decayPerFrame)
            }
        }
        let snapshot = smoothed
        lock.unlock()

        // 节流跳到主线程（~30fps，SwiftUI 绘制频率）
        let now = Date()
        guard now.timeIntervalSince(lastMainUpdate) >= mainUpdateInterval else { return }
        lastMainUpdate = now
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.levels = snapshot
        }
    }
}
