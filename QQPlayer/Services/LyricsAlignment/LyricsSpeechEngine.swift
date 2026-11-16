//
//  LyricsSpeechEngine.swift
//  QQPlayer
//
//  ASR 引擎抽象 + Apple SpeechAnalyzer 实现。
//  - 协议只有「给文件 + 语言，回 [AsrToken]」一件事，便于单测注入假引擎。
//  - 真实现依赖 iOS 26 / macOS 26；低于该版本功能不可用，但**不崩**。
//

import AVFoundation
import Foundation
import Speech

/// 语音识别引擎（歌词对齐专用）。
protocol LyricsSpeechEngine: Sendable {
    /// 转写整段音频，progress 为 0…1 的整体进度。
    func transcribe(
        fileURL: URL,
        locale: Locale,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [AsrToken]
}

/// Apple SpeechAnalyzer 实现。
///
/// 关键约束（探针实测，见 docs/lyrics-alignment.md）：
/// - 必须 attributeOptions 含 .audioTimeRange，否则 run 没有时间；
/// - 不能把 mp3/aac 直接喂 analyzer（约 80s 处 _GenericObjCError），
///   统一先转 16k 单声道 Float32 PCM；
/// - 首次使用某语言要自动下载模型（20–40s，需联网）。
@available(iOS 26.0, macOS 26.0, *)
struct AppleSpeechLyricsEngine: LyricsSpeechEngine {
    /// 分析采样率：16k 单声道是 SpeechAnalyzer 的稳定格式。
    static let analysisSampleRate: Double = 16_000

    /// 模型安装进度占整体进度的比例上限（0…0.15）。
    private static let assetProgressShare = 0.15

    func transcribe(
        fileURL: URL,
        locale: Locale,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> [AsrToken] {
        try Task.checkCancellation()

        // 1. BCP-47 → SpeechTranscriber 支持的语言（下划线标识符由系统换算）。
        guard let resolvedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw LyricAlignmentError.localeUnavailable
        }
        let transcriber = SpeechTranscriber(
            locale: resolvedLocale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        // 2. 模型资产：没装就装（进度 0…0.15）。
        try await installAssetsIfNeeded(for: transcriber, progress: progress)

        // 3. 音频 → 16k 单声道 PCM 的转换器。
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            throw LyricAlignmentError.audioUnreadable
        }
        guard let analysisFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.analysisSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: audioFile.processingFormat, to: analysisFormat) else {
            throw LyricAlignmentError.audioUnreadable
        }

        // 4. 转写：分析器吃 AsyncStream<AnalyzerInput>，结果流单独收集。
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)

        let collector = Task { () -> [AsrToken] in
            var tokens: [AsrToken] = []
            do {
                for try await result in transcriber.results {
                    let attributed = result.text
                    for run in attributed.runs {
                        guard let timeRange = run.audioTimeRange else { continue }
                        let text = String(attributed[run.range].characters)
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            continue
                        }
                        tokens.append(
                            AsrToken(
                                text: text,
                                start: timeRange.start.seconds,
                                end: timeRange.end.seconds
                            )
                        )
                    }
                }
            } catch {
                // 取消或收尾异常：已产出的 run 仍是有效结果，保留半成品。
                AppLog.warn(.general, "🎤 Speech results ended early: " + String(describing: error))
            }
            return tokens
        }

        let producer = Task { () -> LyricAlignmentError? in
            do {
                try Self.pump(
                    file: audioFile,
                    converter: converter,
                    analysisFormat: analysisFormat,
                    continuation: continuation,
                    progress: { value in
                        progress(Self.assetProgressShare + value * (1 - Self.assetProgressShare))
                    }
                )
            } catch is CancellationError {
                continuation.finish()
                return LyricAlignmentError.cancelled
            } catch {
                continuation.finish()
                AppLog.warn(.general, "🎤 Audio conversion failed: " + String(describing: error))
                return LyricAlignmentError.audioUnreadable
            }
            continuation.finish()
            return nil
        }

        do {
            try await withTaskCancellationHandler {
                try await analyzer.start(inputSequence: stream)
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            producer.cancel()
            await analyzer.cancelAndFinishNow()
            let tokens = await collector.value
            throw Task.isCancelled ? LyricAlignmentError.cancelled : Self.startFailure(error, tokens: tokens)
        }

        let producerFailure = await producer.value
        let tokens = await collector.value
        if Task.isCancelled {
            throw LyricAlignmentError.cancelled
        }
        if let producerFailure {
            throw producerFailure
        }
        progress(1)
        return tokens
    }

    // MARK: - 模型资产

    private func installAssetsIfNeeded(
        for transcriber: SpeechTranscriber,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let status = await AssetInventory.status(forModules: [transcriber])
        if status == .installed {
            progress(Self.assetProgressShare)
            return
        }
        guard let request = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            throw LyricAlignmentError.assetInstallFailed
        }
        let share = Self.assetProgressShare
        let reporter = Task { [request] in
            while !Task.isCancelled {
                let fraction = request.progress.fractionCompleted
                progress(min(max(fraction, 0), 1) * share)
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { reporter.cancel() }
        do {
            try await request.downloadAndInstall()
        } catch {
            throw LyricAlignmentError.assetInstallFailed
        }
        progress(share)
    }

    // MARK: - 音频泵

    /// 逐块读文件 → 转 16k 单声道 → 塞进 analyzer 的输入流。
    private static func pump(
        file: AVAudioFile,
        converter: AVAudioConverter,
        analysisFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation,
        progress: (Double) -> Void
    ) throws {
        let inputFormat = file.processingFormat
        let chunkFrames = AVAudioFrameCount(max(inputFormat.sampleRate, 1))
        let capacity = AVAudioFrameCount(
            Double(chunkFrames) * analysisFormat.sampleRate / max(inputFormat.sampleRate, 1)
        ) + 64
        let totalFrames = Double(max(file.length, 1))
        var sampleOffset: Int64 = 0

        while true {
            try Task.checkCancellation()
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkFrames) else {
                throw LyricAlignmentError.audioUnreadable
            }
            do {
                try file.read(into: inputBuffer, frameCount: chunkFrames)
            } catch {
                throw LyricAlignmentError.audioUnreadable
            }
            if inputBuffer.frameLength == 0 { break }

            var provided = false
            conversionLoop: while true {
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: analysisFormat, frameCapacity: capacity) else {
                    throw LyricAlignmentError.audioUnreadable
                }
                var conversionError: NSError?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { _, statusPointer in
                    if provided {
                        statusPointer.pointee = .noDataNow
                        return nil
                    }
                    provided = true
                    statusPointer.pointee = .haveData
                    return inputBuffer
                }
                if let conversionError {
                    AppLog.warn(.general, "🎤 AVAudioConverter: " + conversionError.localizedDescription)
                    throw LyricAlignmentError.audioUnreadable
                }
                if outputBuffer.frameLength > 0 {
                    let startTime = CMTime(
                        value: sampleOffset,
                        timescale: CMTimeScale(analysisFormat.sampleRate)
                    )
                    continuation.yield(AnalyzerInput(buffer: outputBuffer, bufferStartTime: startTime))
                    sampleOffset += Int64(outputBuffer.frameLength)
                }
                switch status {
                case .haveData:
                    if outputBuffer.frameLength == 0 { break conversionLoop }
                default:
                    break conversionLoop
                }
            }
            progress(min(Double(file.framePosition) / totalFrames, 1))
        }
    }

    // MARK: - 错误归类

    private static func startFailure(_ error: Error, tokens: [AsrToken]) -> LyricAlignmentError {
        if tokens.isEmpty {
            AppLog.warn(.general, "🎤 SpeechAnalyzer start failed: " + String(describing: error))
        }
        return .audioUnreadable
    }
}
