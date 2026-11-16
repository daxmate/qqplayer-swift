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
///   也不能把 PCM 逐块塞进 AsyncStream（Apple 内部 preRunRecognition 处
///   EXC_BREAKPOINT，macOS 26.6 实测必崩）；统一先转 16k 单声道 Int16 WAV，
///   再交给 `start(inputAudioFile:finishAfterFile:)`；
/// - 首次使用某语言要自动下载模型（20–40s，需联网）。
@available(iOS 26.0, macOS 26.0, *)
struct AppleSpeechLyricsEngine: LyricsSpeechEngine {
    /// 模型资产安装占用的进度区间（0…assetProgressShare）。
    private static let assetProgressShare = 0.15
    /// 转临时 WAV 占用的进度区间（0.15…0.25）。
    private static let conversionProgressShare = 0.10
    /// 识别阶段起点（0.25…0.9）。
    private static let recognitionProgressStart = 0.25
    /// 识别阶段占用的进度区间。
    private static let recognitionProgressShare = 0.65

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

        // 3. 源音频 → 临时 16k 单声道 Int16 WAV（进度 0.15…0.25）。
        //    逐块喂 PCM 会让 Speech 在内部崩（不可捕获）或挂住，必须走文件；
        //    解码用 AVAssetReader（AVAudioFile 逐块读真实歌曲会 -39 / nilError）。
        let converted: LyricsAlignmentAudioFile
        do {
            converted = try await LyricsAlignmentAudioFile.makeTemporaryWav(from: fileURL) { fraction in
                progress(Self.assetProgressShare + fraction * Self.conversionProgressShare)
            }
        } catch is CancellationError {
            throw LyricAlignmentError.cancelled
        } catch {
            throw LyricAlignmentError.audioUnreadable
        }
        defer { converted.remove() }
        try Task.checkCancellation()

        // 4. 读回临时 WAV，交给分析器自己按文件推进（进度 0.25…0.9）。
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: converted.url)
        } catch {
            throw LyricAlignmentError.audioUnreadable
        }
        let duration = Double(audioFile.length) / max(audioFile.processingFormat.sampleRate, 1)

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        var tokens: [AsrToken] = []
        do {
            try await withTaskCancellationHandler {
                try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }

            for try await result in transcriber.results {
                try Task.checkCancellation()
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
                if duration > 0, let recognizedEnd = tokens.last?.end {
                    let fraction = min(max(recognizedEnd / duration, 0), 1)
                    progress(Self.recognitionProgressStart + fraction * Self.recognitionProgressShare)
                }
            }
        } catch is CancellationError {
            await analyzer.cancelAndFinishNow()
            throw LyricAlignmentError.cancelled
        } catch {
            await analyzer.cancelAndFinishNow()
            if Task.isCancelled {
                throw LyricAlignmentError.cancelled
            }
            // 取消或收尾异常：已产出的 run 仍是有效结果，保留半成品。
            if tokens.isEmpty {
                throw Self.startFailure(error, tokens: tokens)
            }
            AppLog.warn(.general, "🎤 Speech results ended early: " + String(describing: error))
        }

        try Task.checkCancellation()
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

    // MARK: - 错误归类

    private static func startFailure(_ error: Error, tokens: [AsrToken]) -> LyricAlignmentError {
        if tokens.isEmpty {
            AppLog.warn(.general, "🎤 SpeechAnalyzer start failed: " + String(describing: error))
        }
        return .audioUnreadable
    }
}
