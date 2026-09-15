//
//  ModelCodableTests.swift
//  QQPlayerTests
//
//  模型 Codable 兼容性：JSON 编解码 round-trip 与枚举 rawValue 契约。
//  防止数据库/持久化 schema 变更时静默破坏解码（如新增字段、改 key）。
//

import Foundation
import Testing

@testable import QQPlayer

struct ModelCodableTests {
    // MARK: - Track（数据库核心模型，CodingKeys 用 snake_case）

    @Test("Track JSON round-trip 保持全部字段")
    func trackRoundTrip() throws {
        let track = Track(
            id: 42,
            stableId: "abc123",
            albumId: 7,
            artistId: 9,
            title: "Test Song",
            trackNo: 3,
            discNo: 1,
            durationMs: 245_000,
            sampleRate: 44_100,
            bitDepth: 16,
            channels: 2,
            path: "/Music/Test.flac",
            fileSize: 12_345_678,
            modificationDate: 1_700_000_000_000_000,
            replaygainTrackGain: -3.5,
            replaygainAlbumGain: -2.0,
            replaygainTrackPeak: 0.98,
            replaygainAlbumPeak: 0.95,
            hasEmbeddedArt: true
        )

        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(Track.self, from: data)

        #expect(decoded == track)
    }

    @Test("Track 使用 snake_case JSON key（数据库列名契约）")
    func trackSnakeCaseKeys() throws {
        let track = Track(
            stableId: "s1",
            title: "T",
            durationMs: 1000,
            path: "/p.flac",
            replaygainTrackGain: -3.5,
            hasEmbeddedArt: true
        )
        let data = try JSONEncoder().encode(track)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["stable_id"] != nil)
        #expect(json["duration_ms"] != nil)
        #expect(json["replaygain_track_gain"] != nil)
        #expect(json["has_embedded_art"] != nil)
    }

    @Test("缺省可选字段解码为 nil（老版本数据库兼容）")
    func optionalFieldsDecodeNil() throws {
        // has_embedded_art 为非 Optional（Bool 默认 false），必须提供；其余 Optional 字段可缺省
        let json = #"{"stable_id":"s1","title":"T","path":"/p.flac","has_embedded_art":false}"#
        let decoded = try JSONDecoder().decode(Track.self, from: Data(json.utf8))
        #expect(decoded.stableId == "s1")
        #expect(decoded.albumId == nil)
        #expect(decoded.durationMs == nil)
        #expect(decoded.modificationDate == nil)
    }

    @Test("非 Optional 字段缺 key 时解码失败（hasEmbeddedArt 为 Bool 默认值）")
    func nonOptionalFieldRequiresKey() {
        let json = #"{"stable_id":"s1","title":"T","path":"/p.flac"}"#
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Track.self, from: Data(json.utf8))
        }
    }

    // MARK: - LyricsLine（歌词行：新增附轨字段不得破坏旧歌词缓存 / 手动歌词）

    @Test("LyricsLine 旧 JSON（无 roman 键）解码为 nil —— 老缓存向后兼容")
    func lyricsLineLegacyJSONDecodes() throws {
        let json = #"{"timestamp":12.5,"text":"残酷な天使のように","translation":"就像那残酷的天使一样"}"#
        let line = try JSONDecoder().decode(LyricsLine.self, from: Data(json.utf8))
        #expect(line.text == "残酷な天使のように")
        #expect(line.translation == "就像那残酷的天使一样")
        #expect(line.roman == nil)
    }

    @Test("LyricsLine 含 roman 的 JSON round-trip 保持全部字段")
    func lyricsLineRomanRoundTrip() throws {
        let line = LyricsLine(timestamp: 1, text: "原文", translation: "译文", roman: "ge n bu n")
        let decoded = try JSONDecoder().decode(LyricsLine.self, from: try JSONEncoder().encode(line))
        #expect(decoded == line)
        #expect(decoded.roman == "ge n bu n")
    }

    // MARK: - WidgetTrackData（跨进程共享，字段改动会破坏 Widget）

    @Test("WidgetTrackData JSON round-trip")
    func widgetTrackRoundTrip() throws {
        let data = WidgetTrackData(
            trackId: "w1",
            title: "Widget Song",
            artist: "Widget Artist",
            isPlaying: true,
            backgroundColorHex: "#1A1A2E"
        )
        let encoded = try JSONEncoder().encode(data)
        let decoded = try JSONDecoder().decode(WidgetTrackData.self, from: encoded)

        #expect(decoded.trackId == data.trackId)
        #expect(decoded.title == data.title)
        #expect(decoded.artist == data.artist)
        #expect(decoded.isPlaying == data.isPlaying)
        #expect(decoded.backgroundColorHex == data.backgroundColorHex)
    }

    // MARK: - 枚举 rawValue 契约（持久化依赖，去掉显式 rawValue 后防止隐式值漂移）

    @Test("DSDPlaybackMode rawValue 契约")
    func dsdModeRawValues() {
        #expect(DSDPlaybackMode.auto.rawValue == "auto")
        #expect(DSDPlaybackMode.pcm.rawValue == "pcm")
        #expect(DSDPlaybackMode.dop.rawValue == "dop")
        #expect(DSDPlaybackMode(rawValue: "auto") == .auto)
        #expect(DSDPlaybackMode(rawValue: "pcm") == .pcm)
        #expect(DSDPlaybackMode(rawValue: "dop") == .dop)
    }

    @Test("EQPresetType rawValue 契约")
    func eqPresetTypeRawValues() {
        #expect(EQPresetType.imported.rawValue == "imported")
        #expect(EQPresetType.manual.rawValue == "manual")
        #expect(EQPresetType(rawValue: "imported") == .imported)
        #expect(EQPresetType(rawValue: "manual") == .manual)
    }
}
