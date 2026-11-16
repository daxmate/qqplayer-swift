//
//  LyricAlignmentServiceTests.swift
//  QQPlayerTests
//
//  编排层：注入假引擎 + 临时目录 store，验证落库/报告/取消路径，以及语言判定纯函数。
//

import Foundation
import Testing

@testable import QQPlayer

struct LyricAlignmentServiceTests {
    // MARK: - 假引擎

    private struct FakeLyricsSpeechEngine: LyricsSpeechEngine {
        let tokens: [AsrToken]
        let failure: LyricAlignmentError?
        let throwsCancellation: Bool

        init(
            tokens: [AsrToken] = [],
            failure: LyricAlignmentError? = nil,
            throwsCancellation: Bool = false
        ) {
            self.tokens = tokens
            self.failure = failure
            self.throwsCancellation = throwsCancellation
        }

        func transcribe(
            fileURL: URL,
            locale: Locale,
            progress: @escaping @Sendable (Double) -> Void
        ) async throws -> [AsrToken] {
            progress(1)
            if throwsCancellation {
                throw CancellationError()
            }
            if let failure {
                throw failure
            }
            return tokens
        }
    }

    // MARK: - 夹具

    private struct Fixture {
        let directory: URL
        let audioURL: URL
        let store: AlignedLyricsStore
        let track: Track

        init(stableId: String = "lyrics-align-test") throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("lyrics-align-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            audioURL = directory.appendingPathComponent("audio.mp3")
            try Data().write(to: audioURL)
            store = AlignedLyricsStore(directory: directory.appendingPathComponent("aligned", isDirectory: true))
            track = Track(
                id: nil,
                stableId: stableId,
                albumId: nil,
                artistId: nil,
                title: "对齐测试",
                genre: nil,
                trackNo: nil,
                discNo: nil,
                durationMs: 20_000,
                sampleRate: nil,
                bitDepth: nil,
                channels: nil,
                path: audioURL.path,
                fileSize: nil,
                modificationDate: nil,
                contentHash: nil,
                replaygainTrackGain: nil,
                replaygainAlbumGain: nil,
                replaygainTrackPeak: nil,
                replaygainAlbumPeak: nil
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private struct FixtureStore: AlignedLyricsWriting {
        let store: AlignedLyricsStore
        func write(_ lyrics: Lyrics, forStableId stableId: String) throws {
            try store.write(lyrics, forStableId: stableId)
        }
    }

    private func makeService(
        fixture: Fixture,
        tokens: [AsrToken] = [],
        failure: LyricAlignmentError? = nil,
        throwsCancellation: Bool = false
    ) -> LyricAlignmentService {
        let engine = FakeLyricsSpeechEngine(
            tokens: tokens,
            failure: failure,
            throwsCancellation: throwsCancellation
        )
        return LyricAlignmentService(
            engineFactory: { _ in engine },
            store: FixtureStore(store: fixture.store)
        )
    }

    private func plainLyrics(_ text: String) -> Lyrics {
        Lyrics(plainLyrics: text, syncedLyrics: [], isInstrumental: false, source: .lrclib)
    }

    // MARK: - 用例

    @Test("对齐结果写进 aligned 库、可读回，时间戳来自 ASR")
    func writesAlignedLyrics() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = makeService(
            fixture: fixture,
            tokens: [
                AsrToken(text: "第一句", start: 0, end: 1.5),
                AsrToken(text: "第二句", start: 1.5, end: 3),
            ]
        )
        let lyrics = plainLyrics("第一句\n第二句")

        let report = try await service.align(track: fixture.track, currentLyrics: lyrics)

        #expect(report.lineCount == 2)
        #expect(report.matchedCount == 2)
        #expect(report.localeIdentifier == "zh")

        let stored = try fixture.store.read(forStableId: fixture.track.stableId)
        let aligned = try #require(stored)
        #expect(aligned.syncedLyrics.count == 2)
        #expect(abs((aligned.syncedLyrics[0].timestamp ?? -1) - 0) < 0.02)
        #expect(abs((aligned.syncedLyrics[1].timestamp ?? -1) - 1.5) < 0.02)
        #expect(aligned.syncedLyrics[0].text == "第一句")
        // 原文不动，只补 syncedLyrics。
        #expect(aligned.plainLyrics == lyrics.plainLyrics)
    }

    @Test("已有 synced 歌词：文本/翻译/罗马音原样保留，只换时间")
    func preservesLineMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = makeService(
            fixture: fixture,
            tokens: [
                AsrToken(text: "ありがとう", start: 1, end: 3),
            ]
        )
        let lyrics = Lyrics(
            plainLyrics: "",
            syncedLyrics: [
                LyricsLine(timestamp: 0.5, text: "ありがとう", translation: "谢谢", roman: "arigatou"),
            ],
            isInstrumental: false,
            source: .netease
        )

        let report = try await service.align(track: fixture.track, currentLyrics: lyrics)

        #expect(report.matchedCount == 1)
        #expect(report.localeIdentifier == "ja")
        let stored = try #require(try fixture.store.read(forStableId: fixture.track.stableId))
        #expect(stored.syncedLyrics.count == 1)
        #expect(abs((stored.syncedLyrics[0].timestamp ?? -1) - 1) < 0.02)
        #expect(stored.syncedLyrics[0].text == "ありがとう")
        #expect(stored.syncedLyrics[0].translation == "谢谢")
        #expect(stored.syncedLyrics[0].roman == "arigatou")
        #expect(stored.source == .netease)
    }

    @Test("引擎取消 → 抛 cancelled，且不写库")
    func cancellationPropagates() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = makeService(fixture: fixture, throwsCancellation: true)

        await #expect(throws: LyricAlignmentError.cancelled) {
            _ = try await service.align(
                track: fixture.track,
                currentLyrics: plainLyrics("第一句")
            )
        }
        let storedAfterCancel: Lyrics? = try? fixture.store.read(forStableId: fixture.track.stableId)
        #expect(storedAfterCancel == nil)
    }

    @Test("没有歌词行 → 抛 lyricsEmpty")
    func emptyLyrics() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = makeService(fixture: fixture, tokens: [AsrToken(text: "x", start: 0, end: 1)])
        let lyrics = Lyrics(plainLyrics: "\n  \n", syncedLyrics: [], isInstrumental: true, source: .none)

        await #expect(throws: LyricAlignmentError.lyricsEmpty) {
            _ = try await service.align(track: fixture.track, currentLyrics: lyrics)
        }
    }

    @Test("按书写系统判定识别语言（纯函数）")
    func detectsLanguage() {
        #expect(LyricAlignmentLanguageDetector.detectLanguageCode(in: "君の名は", systemLanguageCode: "en") == "ja")
        #expect(LyricAlignmentLanguageDetector.detectLanguageCode(in: "사랑해", systemLanguageCode: "en") == "ko")
        #expect(LyricAlignmentLanguageDetector.detectLanguageCode(in: "月亮代表我的心", systemLanguageCode: "en") == "zh")
        #expect(LyricAlignmentLanguageDetector.detectLanguageCode(in: "hello world", systemLanguageCode: "zh") == "en")
        #expect(LyricAlignmentLanguageDetector.detectLanguageCode(in: "♪♪", systemLanguageCode: "fr") == "fr")
    }
}
