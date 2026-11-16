//
//  LyricsAlignmentAudioFile.swift
//  QQPlayer
//
//  歌词对齐用音频转码：把任意源音频解码成 16 kHz 单声道 Int16 WAV 临时文件。
//  - 为什么落成文件：把 PCM 逐块塞进 SpeechAnalyzer 的 AsyncStream 输入，会在
//    Apple 内部 preRunRecognition 处 EXC_BREAKPOINT（macOS 27.2）或直接挂住
//    （macOS 26.6），必须先落成 WAV 再走 start(inputAudioFile:finishAfterFile:)。
//  - 为什么用 AVAssetReader 而不是 AVAudioFile：AVAudioFile 逐块读真实歌曲会失败——
//    macOS 27.2 抛 NSOSStatusErrorDomain -39 eofErr，macOS 26.6 抛
//    _GenericObjCError.nilError（4 秒短音频能过、4 分钟真实歌曲必挂）。
//    AVAssetReader + AVAssetReaderTrackOutput(16k/1ch/Int16 LPCM) 两端实测稳定。
//  - 临时文件由调用方在结束时 remove()（成功、失败、取消都删）。
//

import AVFoundation
import CoreMedia
import Foundation

/// 临时 16 kHz 单声道 WAV 句柄。
struct LyricsAlignmentAudioFile: Sendable {
    /// SpeechAnalyzer 的稳定分析采样率。
    static let analysisSampleRate: Double = 16_000

    /// 转换产物（临时文件）。
    let url: URL

    /// 删除临时文件（幂等）。
    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    /// 把 source 解码成 16 kHz / 单声道 / Int16 WAV，返回临时文件句柄。
    ///
    /// - Parameter progress: 0…1，按「已解码时长 / 总时长」推进。
    /// - Throws: `LyricAlignmentError.audioUnreadable`（临时文件不会残留），
    ///   或 `CancellationError`（调用方取消）。
    static func makeTemporaryWav(
        from source: URL,
        sampleRate: Double = LyricsAlignmentAudioFile.analysisSampleRate,
        progress: (Double) -> Void = { _ in }
    ) async throws -> LyricsAlignmentAudioFile {
        // 解码用的 AVAssetReader.outputProvider(for:) 是 26.0 起的 API；
        // 低于该版本（本功能整体不可用）按音频不可读处理，不崩。
        guard #available(iOS 26.0, macOS 26.0, *) else {
            throw LyricAlignmentError.audioUnreadable
        }

        let outputURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lyric-align-\(UUID().uuidString).wav")
        // 只有成功返回时才保留文件；任何抛出路径都清掉半成品。
        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw LyricAlignmentError.audioUnreadable
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        let asset = AVURLAsset(url: source)
        let track: AVAssetTrack
        do {
            guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                throw LyricAlignmentError.audioUnreadable
            }
            track = audioTrack
        } catch {
            AppLog.warn(.general, "🎤 Alignment audio open failed: " + error.localizedDescription)
            throw LyricAlignmentError.audioUnreadable
        }

        // AVAudioFile 只在关闭时写 WAV header，所以用 optional 以便提前落盘。
        var writer: AVAudioFile?
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        do {
            reader = try AVAssetReader(asset: asset)
            output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            // 新 API（macOS/iOS 26+）用 outputProvider(for:) 取样本，不再 add(_:)。
            writer = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: .pcmFormatInt16,
                interleaved: true
            )
        } catch {
            AppLog.warn(.general, "🎤 Alignment reader setup failed: " + error.localizedDescription)
            throw LyricAlignmentError.audioUnreadable
        }
        // ⚠️ outputProvider(for:) 内部才做 addOutput，必须在 start() 之前取到。
        let provider = reader.outputProvider(for: output)
        do {
            try reader.start()
        } catch {
            AppLog.warn(.general, "🎤 Alignment reader start failed: " + error.localizedDescription)
            throw LyricAlignmentError.audioUnreadable
        }

        let assetDuration = (try? await asset.load(.duration)) ?? .zero
        let duration = assetDuration.seconds
        var writtenFrames: AVAudioFramePosition = 0
        var decodedSeconds: Double = 0

        while true {
            try Task.checkCancellation()
            guard let ready = try await provider.next() else { break }
            var decoded: AVAudioPCMBuffer?
            ready.withUnsafeSampleBuffer { sampleBuffer in
                let sampleCount = CMSampleBufferGetNumSamples(sampleBuffer)
                guard sampleCount > 0,
                      let buffer = AVAudioPCMBuffer(
                          pcmFormat: targetFormat,
                          frameCapacity: AVAudioFrameCount(sampleCount)
                      ) else {
                    return
                }
                buffer.frameLength = AVAudioFrameCount(sampleCount)

                var bufferList = AudioBufferList()
                var blockBuffer: CMBlockBuffer?
                let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
                    sampleBuffer,
                    bufferListSizeNeededOut: nil,
                    bufferListOut: &bufferList,
                    bufferListSize: MemoryLayout<AudioBufferList>.size,
                    blockBufferAllocator: nil,
                    blockBufferMemoryAllocator: nil,
                    flags: 0,
                    blockBufferOut: &blockBuffer
                )
                guard status == noErr else { return }
                let sources = UnsafeMutableAudioBufferListPointer(&bufferList)
                let destinations = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                guard let sourceBuffer = sources.first,
                      let destinationBuffer = destinations.first,
                      let sourceData = sourceBuffer.mData,
                      let destinationData = destinationBuffer.mData else {
                    return
                }
                let byteCount = min(Int(sourceBuffer.mDataByteSize), Int(destinationBuffer.mDataByteSize))
                if byteCount > 0 {
                    memcpy(destinationData, sourceData, byteCount)
                }
                decoded = buffer
            }

            guard let buffer = decoded else {
                throw LyricAlignmentError.audioUnreadable
            }
            do {
                try writer?.write(from: buffer)
            } catch {
                AppLog.warn(.general, "🎤 Alignment WAV write failed: " + error.localizedDescription)
                throw LyricAlignmentError.audioUnreadable
            }
            writtenFrames += AVAudioFramePosition(buffer.frameLength)
            decodedSeconds += Double(buffer.frameLength) / sampleRate
            if duration > 0 {
                progress(min(max(decodedSeconds / duration, 0), 1))
            }
        }

        writer = nil
        if reader.status == .failed {
            AppLog.warn(.general, "🎤 Alignment decode failed: " + String(describing: reader.error))
            throw LyricAlignmentError.audioUnreadable
        }
        guard writtenFrames > 0 else {
            throw LyricAlignmentError.audioUnreadable
        }
        progress(1)
        completed = true
        return LyricsAlignmentAudioFile(url: outputURL)
    }
}
