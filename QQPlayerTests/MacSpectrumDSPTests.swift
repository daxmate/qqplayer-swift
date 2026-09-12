//
//  MacSpectrumDSPTests.swift
//  QQPlayerTests
//
//  实时频谱 DSP 核（MacSpectrumDSP）语义回归用例
//  —— 2026-09-12 审计批次 B4 · M3。
//
//  修复前 DSP 写在 `@MainActor final class MacSpectrumAnalyzer` 内部，
//  `process(buffer:)` 由 mainMixer tap 在音频线程直接调用：可见的 `smoothed` 有锁、
//  `lastMainUpdate`/`fftSetup` 却无锁跨隔离访问（QQPlayerMac 当时 SWIFT_VERSION 5.0，
//  并发检查降级为警告 → 缺陷被编译器静默放行）。
//  本次状态收敛进无隔离的 MacSpectrumDSP（一把锁 + 音频线程专用），本文件锁定契约：
//  1) 快照长度 = 32 且值域 0...1（视觉条直接消费）；
//  2) 静音 → 全零、单频信号 → 有非零频段（DSP 真的在算）；
//  3) 发布节流：连续两帧只发布一次（~30fps）；
//  4) `reset()` 清空平滑状态（removeTap 语义）；
//  5) 多线程并发处理不崩（锁保护——修复前无锁状态正是竞态来源）。
//  修复前这些用例写不出来：DSP 没有可注入的缝，且无法在非主 actor 上被调用。
//

@preconcurrency import AVFoundation
import Foundation
import Testing

@testable import QQPlayer

/// 生成单通道测试缓冲（amplitude = 0 即静音）。
private func makeBuffer(
    frames: Int = MacSpectrumDSP.fftSize,
    amplitude: Float = 0,
    frequency: Float = 1000,
    sampleRate: Double = 44100
) -> AVAudioPCMBuffer {
    // 标准 float 格式在模拟器/真机都可用；format 与 buffer 创建失败即夹具问题
    let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    if let channel = buffer.floatChannelData?[0] {
        for i in 0 ..< frames {
            channel[i] = amplitude * sinf(2 * .pi * frequency * Float(i) / Float(sampleRate))
        }
    }
    return buffer
}

struct MacSpectrumDSPTests {
    @Test("静音：快照长度 = 32 且全零")
    func silenceProducesZeroBins() throws {
        let dsp = MacSpectrumDSP()
        let levels = try #require(dsp.process(buffer: makeBuffer()))
        #expect(levels.count == MacSpectrumDSP.binCount)
        #expect(levels.allSatisfy { $0 == 0 })
    }

    @Test("单频信号：有非零频段且全部落在 0...1")
    func toneProducesLevelsInRange() throws {
        let dsp = MacSpectrumDSP()
        let levels = try #require(dsp.process(buffer: makeBuffer(amplitude: 0.5, frequency: 1000)))
        #expect(levels.contains { $0 > 0 })
        #expect(levels.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("发布节流：连续两帧只发布一次（~30fps）")
    func throttlesPublication() {
        let dsp = MacSpectrumDSP()
        #expect(dsp.process(buffer: makeBuffer(amplitude: 0.5)) != nil)
        // 同一瞬间的第二帧被节流（间隔 < 1/30s）
        #expect(dsp.process(buffer: makeBuffer(amplitude: 0.5)) == nil)
    }

    @Test("reset 清空平滑状态（removeTap 语义：再来帧不会带出旧峰值）")
    func resetClearsSmoothedState() throws {
        let dsp = MacSpectrumDSP()
        _ = dsp.process(buffer: makeBuffer(amplitude: 0.5, frequency: 1000))
        dsp.reset()

        let levels = try #require(dsp.process(buffer: makeBuffer()))
        #expect(levels.allSatisfy { $0 == 0 })
    }

    @Test("不足一窗的缓冲也能处理（末段补零）")
    func shortBufferIsPadded() throws {
        let dsp = MacSpectrumDSP()
        let levels = try #require(dsp.process(buffer: makeBuffer(frames: 128, amplitude: 0.5)))
        #expect(levels.count == MacSpectrumDSP.binCount)
    }

    @Test("多线程并发处理不崩（状态由锁保护）")
    func concurrentProcessingIsSafe() {
        let dsp = MacSpectrumDSP()
        // GCD 并发（不引入 Sendable 诊断）：修复前同类状态无锁，正是竞态来源。
        // 缓冲在闭包内新建（AVAudioPCMBuffer 非 Sendable，捕获会触发 @Sendable 警告）
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            _ = dsp.process(buffer: makeBuffer(amplitude: 0.3))
        }
        // 并发本身不崩即达标；随后要断言「还能正常出帧」必须避开发布节流——
        // 并发帧可能刚发布过（间隔 < 1/30s 会返回 nil，与锁无关，CI 上必现）→
        // 先 reset()（清空节流时间戳），再断言本帧必发布
        dsp.reset()
        let levels = dsp.process(buffer: makeBuffer())
        #expect(levels?.count == MacSpectrumDSP.binCount)
    }
}
