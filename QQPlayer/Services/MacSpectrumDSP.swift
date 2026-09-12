//
//  MacSpectrumDSP.swift
//  QQPlayer
//
//  实时频谱 DSP 核（2026-09-12 审计批次 B4 · M3；Accelerate/AVFoundation 双端可用，
//  故放共享 Services 层以便在 iOS 测试 target 单测）。
//
//  缺陷（审计 M3）：DSP 原写在 `@MainActor final class MacSpectrumAnalyzer` 内部，
//  `process(buffer:)` 却由 mainMixer tap 在**音频线程**直接调用，且
//  `lastMainUpdate`（节流时间戳）声明在 @MainActor 类型上却只在音频线程读写、无锁；
//  同类内 `smoothed` 却明确用 NSLock 保护——同一份状态两套纪律。QQPlayerMac target
//  当时是 SWIFT_VERSION 5.0，并发检查降级为警告 → 缺陷被编译器静默放行，
//  升到 Swift 6 语言模式会直接编译失败。
//
//  设计：DSP 状态（FFT setup / smoothed / 节流时间戳）全部收进这个 **无隔离** 类型，
//  由一把锁统一保护；音频线程只碰本类型，`levels` 落表仍由 MacSpectrumAnalyzer
//  在主 actor 上完成——单一隔离域，不再有跨隔离状态访问。
//
//  注意：本文件与 MacSpectrumAnalyzer 的算法逐字一致（含 2026-09-05 修过的
//  `i1 = max(i0+1, …)` + `guard i1 > i0` 防「Range requires lowerBound <= upperBound」）。
//

import Accelerate
import AVFoundation
import Foundation

/// 音频线程专用的频谱 DSP（无隔离域；内部锁保护全部可变状态）。
final class MacSpectrumDSP: @unchecked Sendable {
    /// 频段数（视觉条数）
    static let binCount = 32
    /// FFT 窗口
    static let fftSize = 1024

    private let fftSetup: FFTSetup?
    private let binCount = MacSpectrumDSP.binCount
    private let fftSize = MacSpectrumDSP.fftSize

    /// 每回调衰减量：mainMixer tap 按 IO 周期回调（实测 buffer ~4800 帧 ≈ 9-10Hz），
    /// 0.05/回调 ≈ 0.45/s，从满到零约 2s——跟随音乐有活力又不闪跳。
    private let decayPerFrame: Float = 0.05
    /// 发布节流（~30fps，SwiftUI 绘制频率）
    private let mainUpdateInterval: TimeInterval = 1.0 / 30.0

    /// 锁保护：smoothed + lastMainUpdate（音频线程写、主线程 removeTap 置零）
    private let lock = NSLock()
    private var smoothed: [Float]
    private var lastMainUpdate = Date.distantPast

    init() {
        let log2n = vDSP_Length(log2(Float(fftSize)))
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        smoothed = Array(repeating: 0, count: binCount)
    }

    deinit {
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    /// 清空平滑状态（removeTap / 停止可视化时调用；主线程与音频线程可并发调用）。
    func reset() {
        lock.lock()
        smoothed = Array(repeating: 0, count: binCount)
        lastMainUpdate = .distantPast
        lock.unlock()
    }

    /// 处理一帧音频：返回需要发布的快照；nil = 本帧被节流或无数据。
    /// - Note: 在音频线程调用（调用方不得持有任何主 actor 状态）。
    func process(buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let fftSetup,
              let channelData = buffer.floatChannelData,
              buffer.frameLength > 0 else { return nil }

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

        // 前向 FFT（zrip 原地：输出仍在这两个数组）。DSPSplitComplex 的
        // realp/imagp 指针须存活到调用结束——用 withUnsafeMutableBufferPointer
        // 圈定作用域（不能直接传 &array：inout 临时指针不保证存活）
        let log2n = vDSP_Length(log2(Float(fftSize)))
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        realp.withUnsafeMutableBufferPointer { realBuf in
            imagp.withUnsafeMutableBufferPointer { imagBuf in
                guard let realBase = realBuf.baseAddress, let imagBase = imagBuf.baseAddress else { return }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

                // |X|² 取前半有效 bin（0...N/2-1），再除 N 开方得幅度
                magnitudes.withUnsafeMutableBufferPointer { mp in
                    guard let mpBase = mp.baseAddress else { return }
                    var splitOut = DSPSplitComplex(realp: realBase, imagp: imagBase)
                    vDSP_zvmags(&splitOut, 1, mpBase, 1, vDSP_Length(fftSize / 2))
                }
            }
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

        // 峰值保持平滑 + 发布节流（同一把锁保护，removeTap 可能并发置零）
        lock.lock()
        for i in 0 ..< binCount {
            if bins[i] > smoothed[i] {
                smoothed[i] = bins[i]
            } else {
                smoothed[i] = max(0, smoothed[i] - decayPerFrame)
            }
        }
        let now = Date()
        guard now.timeIntervalSince(lastMainUpdate) >= mainUpdateInterval else {
            lock.unlock()
            return nil
        }
        lastMainUpdate = now
        let snapshot = smoothed
        lock.unlock()

        return snapshot
    }
}
