//
//  LyricsAlignmentAudioFileTests.swift
//  QQPlayerTests
//
//  歌词对齐：源音频 → 16k 单声道 Int16 WAV 的转码契约。
//

import AVFoundation
import Foundation
import Testing

@testable import QQPlayer

@Suite(.serialized)
struct LyricsAlignmentAudioFileTests {
    private static let tempPrefix = "lyric-align-"

    // MARK: - 夹具

    /// 程序化生成 2 秒 44.1k 立体声正弦 WAV（与转码目标格式完全不同，保证真的走转换）。
    private func makeSineSource(
        seconds: Double = 2,
        sampleRate: Double = 44_100,
        channels: AVAudioChannelCount = 2
    ) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(Self.tempPrefix + "source-\(UUID().uuidString).wav")
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(seconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            Issue.record("无法创建源音频 buffer")
            return url
        }
        buffer.frameLength = frameCount
        let isFloat = format.commonFormat == .pcmFormatFloat32
        for channel in 0 ..< Int(format.channelCount) {
            let sampleCount = Int(frameCount)
            for index in 0 ..< sampleCount {
                let value = sin(2 * Double.pi * 440 * Double(index) / sampleRate) * 0.5
                if isFloat {
                    buffer.floatChannelData?[channel][index] = Float(value)
                } else {
                    buffer.int16ChannelData?[channel][index] = Int16(value * Double(Int16.max))
                }
            }
        }
        try file.write(from: buffer)
        return url
    }

    /// 当前 NSTemporaryDirectory 里本特性留下的文件（用于「不留残留」断言）。
    private func temporaryArtifacts() -> Set<String> {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())) ?? []
        return Set(entries.filter { $0.hasPrefix(Self.tempPrefix) })
    }

    // MARK: - 用例

    @Test("44.1k 立体声 → 16k 单声道 Int16，帧数与可解码性正确")
    func convertsToSixteenKiloMono() async throws {
        let source = try makeSineSource()
        defer { try? FileManager.default.removeItem(at: source) }

        var fractions: [Double] = []
        let converted = try await LyricsAlignmentAudioFile.makeTemporaryWav(from: source) { fractions.append($0) }
        defer { converted.remove() }

        #expect(FileManager.default.fileExists(atPath: converted.url.path))
        #expect(converted.url.pathExtension == "wav")

        let output = try AVAudioFile(forReading: converted.url)
        // 落盘格式看 fileFormat（processingFormat 恒为 Float32 解交织，不能代表磁盘格式）。
        let onDisk = output.fileFormat
        #expect(onDisk.sampleRate == 16_000)
        #expect(onDisk.channelCount == 1)
        #expect(onDisk.commonFormat == .pcmFormatInt16)
        #expect(onDisk.isInterleaved)
        #expect(abs(Double(output.length) - 32_000) < 200, "2 秒 16k 应约 32000 帧，实际 \(output.length)")

        // 读得回来 = 文件结构（header + 数据块）完好。
        guard let buffer = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 4_096) else {
            Issue.record("无法创建回读 buffer")
            return
        }
        try output.read(into: buffer, frameCount: 4_096)
        #expect(buffer.frameLength == 4_096)

        #expect(fractions.isEmpty == false)
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted(), "进度必须单调不回退")
    }

    @Test("显式 remove 后临时文件消失，且可重复调用")
    func removeDeletesFile() async throws {
        let source = try makeSineSource(seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: source) }

        let converted = try await LyricsAlignmentAudioFile.makeTemporaryWav(from: source)
        #expect(FileManager.default.fileExists(atPath: converted.url.path))

        converted.remove()
        #expect(!FileManager.default.fileExists(atPath: converted.url.path))

        converted.remove()
        #expect(!FileManager.default.fileExists(atPath: converted.url.path))
    }

    @Test("源文件不存在 → 抛 audioUnreadable 且不留临时文件")
    func missingSourceLeavesNoArtifact() async throws {
        let before = temporaryArtifacts()
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(Self.tempPrefix + "missing-\(UUID().uuidString).mp3")

        await #expect(throws: LyricAlignmentError.self) {
            _ = try await LyricsAlignmentAudioFile.makeTemporaryWav(from: missing)
        }

        let leaked = temporaryArtifacts().subtracting(before)
        #expect(leaked.isEmpty, "不应残留临时文件：\(leaked)")
    }
}
