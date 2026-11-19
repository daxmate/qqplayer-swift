//
//  LyricAlignmentFeatureTests.swift
//  QQPlayerTests
//
//  入口判据纯函数：canAlign 的边界（无文件 / 纯音乐 / 单行 / 时长 0 / 正常）
//  与「已对齐」事实源读取。不测 SwiftUI 视图。
//

import Foundation
import Testing

@testable import QQPlayer

struct LyricAlignmentFeatureTests {
    // MARK: - 夹具

    private func makeTrack(durationMs: Int?, path: String) -> Track {
        Track(
            id: nil,
            stableId: "stable-align-feature",
            albumId: nil,
            artistId: nil,
            title: "判据测试",
            genre: nil,
            trackNo: nil,
            discNo: nil,
            durationMs: durationMs,
            sampleRate: nil,
            bitDepth: nil,
            channels: nil,
            path: path,
            fileSize: nil,
            modificationDate: nil,
            contentHash: nil,
            replaygainTrackGain: nil,
            replaygainAlbumGain: nil,
            replaygainTrackPeak: nil,
            replaygainAlbumPeak: nil
        )
    }

    private func makeLyrics(lines: [String], isInstrumental: Bool = false) -> Lyrics {
        Lyrics(
            plainLyrics: lines.joined(separator: "\n"),
            syncedLyrics: lines.map { LyricsLine(timestamp: nil, text: $0, translation: nil, roman: nil) },
            isInstrumental: isInstrumental,
            source: .lrclib
        )
    }

    private func temporaryAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-align-feature-" + UUID().uuidString + ".mp3")
        try Data().write(to: url)
        return url
    }

    // MARK: - canAlign 边界

    @Test("正常曲目：文件存在 + 两行歌词 + 有时长 → 可对齐")
    func normalTrackCanAlign() throws {
        try #require(LyricAlignmentFeature.isSupported, "当前系统不支持时本用例不适用")
        let audio = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let track = makeTrack(durationMs: 20_000, path: audio.path)
        let lyrics = makeLyrics(lines: ["第一句", "第二句"])

        #expect(LyricAlignmentFeature.canAlign(track: track, lyrics: lyrics, fileExists: true))
    }

    @Test("音频文件不存在 → 不可对齐")
    func missingFileCannotAlign() {
        let track = makeTrack(durationMs: 20_000, path: "/tmp/definitely-not-here.mp3")
        let lyrics = makeLyrics(lines: ["第一句", "第二句"])

        #expect(!LyricAlignmentFeature.canAlign(track: track, lyrics: lyrics, fileExists: false))
    }

    @Test("纯音乐 → 不可对齐")
    func instrumentalCannotAlign() {
        let track = makeTrack(durationMs: 20_000, path: "/tmp/a.mp3")
        let lyrics = makeLyrics(lines: ["第一句", "第二句"], isInstrumental: true)

        #expect(!LyricAlignmentFeature.canAlign(track: track, lyrics: lyrics, fileExists: true))
    }

    @Test("只有一行歌词（或全是空行）→ 不可对齐")
    func singleLineCannotAlign() {
        let track = makeTrack(durationMs: 20_000, path: "/tmp/a.mp3")
        let oneLine = makeLyrics(lines: ["只有一句"])
        let blankLines = makeLyrics(lines: ["第一句", "   ", "\n"])

        #expect(!LyricAlignmentFeature.canAlign(track: track, lyrics: oneLine, fileExists: true))
        #expect(!LyricAlignmentFeature.canAlign(track: track, lyrics: blankLines, fileExists: true))
    }

    @Test("时长缺失或为 0 → 不可对齐")
    func zeroDurationCannotAlign() {
        let nilDuration = makeTrack(durationMs: nil, path: "/tmp/a.mp3")
        let zeroDuration = makeTrack(durationMs: 0, path: "/tmp/a.mp3")
        let lyrics = makeLyrics(lines: ["第一句", "第二句"])

        #expect(!LyricAlignmentFeature.canAlign(track: nilDuration, lyrics: lyrics, fileExists: true))
        #expect(!LyricAlignmentFeature.canAlign(track: zeroDuration, lyrics: lyrics, fileExists: true))
    }

    @Test("轻量判据（菜单可见性）不依赖歌词，但要文件与时长")
    func offerAlignmentIgnoresLyrics() {
        let track = makeTrack(durationMs: 20_000, path: "/tmp/a.mp3")
        let noDuration = makeTrack(durationMs: nil, path: "/tmp/a.mp3")

        #expect(LyricAlignmentFeature.canOfferAlignment(track: track, fileExists: true))
        #expect(!LyricAlignmentFeature.canOfferAlignment(track: track, fileExists: false))
        #expect(!LyricAlignmentFeature.canOfferAlignment(track: noDuration, fileExists: true))
    }

    // MARK: - 入口可用性（播放页 / 跟唱控制条，2026-11-19）

    @Test("无同步歌词（nil / 空行 / 纯音乐）→ 入口不可用")
    func canOfferTimelineAnalysisRequiresSyncedLyrics() throws {
        try #require(LyricAlignmentFeature.isSupported, "当前系统不支持时本用例不适用")
        let audio = try temporaryAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        let track = makeTrack(durationMs: 20_000, path: audio.path)

        #expect(!LyricAlignmentFeature.canOfferTimelineAnalysis(track: track, fileExists: true, lyrics: nil))
        #expect(!LyricAlignmentFeature.canOfferTimelineAnalysis(track: track, fileExists: true, lyrics: makeLyrics(lines: [])))
        #expect(!LyricAlignmentFeature.canOfferTimelineAnalysis(track: track, fileExists: true, lyrics: makeLyrics(lines: ["", "   "])))
        #expect(!LyricAlignmentFeature.canOfferTimelineAnalysis(
            track: track,
            fileExists: true,
            lyrics: makeLyrics(lines: ["第一句", "第二句"], isInstrumental: true)
        ))
    }

    @Test("有同步歌词 + 判据满足 → 入口可用；文件缺失 / 时长 0 → 不可用")
    func canOfferTimelineAnalysisMatchesEntryGuards() throws {
        try #require(LyricAlignmentFeature.isSupported, "当前系统不支持时本用例不适用")
        let track = makeTrack(durationMs: 20_000, path: "/tmp/qqplayer-not-exists.mp3")
        let lyrics = makeLyrics(lines: ["第一句", "第二句"])

        #expect(!LyricAlignmentFeature.canOfferTimelineAnalysis(track: track, fileExists: false, lyrics: lyrics))
        #expect(LyricAlignmentFeature.canOfferTimelineAnalysis(track: track, fileExists: true, lyrics: lyrics))

        let noDuration = makeTrack(durationMs: 0, path: "/tmp/qqplayer-not-exists.mp3")
        #expect(!LyricAlignmentFeature.canOfferTimelineAnalysis(track: noDuration, fileExists: true, lyrics: lyrics))
    }

    // MARK: - 非空行计数

    @Test("非空行计数忽略空白行")
    func nonEmptyLineCountSkipsBlankLines() {
        let lyrics = makeLyrics(lines: ["第一句", "  ", "第二句", "\n\n"])

        #expect(LyricAlignmentFeature.nonEmptyLineCount(in: lyrics) == 2)
    }

    // MARK: - 已对齐事实源

    @Test("aligned 库里有文件 = 已对齐；删掉 = 未对齐")
    func isAlignedFollowsStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lyrics-align-feature-store-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = AlignedLyricsStore(directory: directory)
        let stableId = "stable-is-aligned"

        #expect(!LyricAlignmentFeature.isAligned(stableId: stableId, store: store))

        let lyrics = makeLyrics(lines: ["第一句", "第二句"])
        try store.write(lyrics, forStableId: stableId)
        #expect(LyricAlignmentFeature.isAligned(stableId: stableId, store: store))

        try store.delete(forStableId: stableId)
        #expect(!LyricAlignmentFeature.isAligned(stableId: stableId, store: store))
    }

    // MARK: - 存储路径解析（1.8.2 回归：入口判据必须经 LibraryRoot）

    @Test("相对存储路径经 LibraryRoot 解析后落在曲库根（Documents/Music）下")
    func relativeStoredPathResolvesUnderMusicRoot() {
        let resolved = LibraryRoot.absoluteURL(forStoredPath: "某专辑/song.mp3")
        let musicRoot = LibraryRoot.musicRootURL().path

        #expect(resolved.path.hasPrefix(musicRoot + "/"))
        #expect(resolved.path.hasSuffix("/Documents/Music/某专辑/song.mp3"))
    }

    @Test("绝对路径经 LibraryRoot 解析保持幂等")
    func absoluteStoredPathResolutionIsIdempotent() {
        let absolute = "/tmp/qqplayer-outside/song.flac"

        #expect(LibraryRoot.absoluteURL(forStoredPath: absolute).path == absolute)
        #expect(LibraryRoot.absolutePath(forStoredPath: absolute) == absolute)
    }

    // MARK: - 入口点击的即时反馈（2026-11-19）

    @Test("入口反馈判定：已在跑 > 歌词加载中 > 无同步歌词 > 准备中")
    func entryNoticeCoversTapStates() {
        let track = makeTrack(durationMs: 20_000, path: "/tmp/qqplayer-not-exists.mp3")
        let lyrics = makeLyrics(lines: ["第一句", "第二句"])

        // 没有曲目：无话可说（也不开跑）
        #expect(LyricAlignmentFeature.entryNotice(track: nil, lyrics: lyrics, lyricsLoading: false, isRunning: false) == nil)
        // 已在跑优先于一切：再点不静默
        #expect(
            LyricAlignmentFeature.entryNotice(track: track, lyrics: nil, lyricsLoading: true, isRunning: true)
                == .alreadyRunning
        )
        // 歌词没到位且仍在加载 → 加载中
        #expect(
            LyricAlignmentFeature.entryNotice(track: track, lyrics: nil, lyricsLoading: true, isRunning: false)
                == .lyricsLoading
        )
        // 歌词没到位但不在加载 / 纯音乐 / 空行 → 无同步歌词
        #expect(
            LyricAlignmentFeature.entryNotice(track: track, lyrics: nil, lyricsLoading: false, isRunning: false)
                == .noSyncedLyrics
        )
        #expect(
            LyricAlignmentFeature.entryNotice(
                track: track,
                lyrics: makeLyrics(lines: ["第一句"], isInstrumental: true),
                lyricsLoading: false,
                isRunning: false
            ) == .noSyncedLyrics
        )
        #expect(
            LyricAlignmentFeature.entryNotice(track: track, lyrics: makeLyrics(lines: []), lyricsLoading: false, isRunning: false)
                == .noSyncedLyrics
        )
        // 有同步歌词 → 准备中（随后由进度 sheet 接管）
        #expect(
            LyricAlignmentFeature.entryNotice(track: track, lyrics: lyrics, lyricsLoading: false, isRunning: false)
                == .preparing
        )
    }
}
