//
//  ModelsRoundTripTests.swift
//  QQPlayerTests
//
//  模型 Codable round-trip 补全（审计缺口：只测了 Track/WidgetTrackData）。
//  覆盖 Artist/Album/Playlist/EQPreset/EQBand/EQSettings/PlayHistoryEntry。
//

import Foundation
import Testing

@testable import QQPlayer

struct ModelsRoundTripTests {
    @Test("Artist JSON round-trip")
    func artistRoundTrip() throws {
        let model = Artist(id: 1, name: "周杰伦")
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(Artist.self, from: data)
        #expect(decoded.id == 1)
        #expect(decoded.name == "周杰伦")
    }

    @Test("Album JSON round-trip（snake_case 键）")
    func albumRoundTrip() throws {
        let model = Album(id: 2, artistId: 1, title: "叶惠美", year: 2003, albumArtist: "周杰伦")
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(Album.self, from: data)
        #expect(decoded.id == 2)
        #expect(decoded.artistId == 1)
        #expect(decoded.title == "叶惠美")
        #expect(decoded.year == 2003)
        #expect(decoded.albumArtist == "周杰伦")
    }

    @Test("Album 缺失可选字段缺省为 nil（老数据兼容）")
    func albumMissingOptionalFields() throws {
        let json = #"{"id":3,"title":"无歌手专辑"}"#
        let decoded = try JSONDecoder().decode(Album.self, from: Data(json.utf8))
        #expect(decoded.artistId == nil)
        #expect(decoded.year == nil)
        #expect(decoded.albumArtist == nil)
    }

    @Test("Playlist JSON round-trip（snake_case 键）")
    func playlistRoundTrip() throws {
        let model = Playlist(
            id: 4, slug: "my-list", title: "我的歌单",
            createdAt: 1_700_000_000, updatedAt: 1_700_000_100,
            lastPlayedAt: 7, customCoverImagePath: "/covers/my-list.png"
        )
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(Playlist.self, from: data)
        #expect(decoded.slug == "my-list")
        #expect(decoded.lastPlayedAt == 7)
        #expect(decoded.customCoverImagePath == "/covers/my-list.png")
    }

    @Test("EQPreset JSON round-trip（preset_type 枚举 + snake_case）")
    func eqPresetRoundTrip() throws {
        let model = EQPreset(
            id: 5, name: "Rock", isBuiltIn: false, isActive: true,
            presetType: .manual, createdAt: 100, updatedAt: 200
        )
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(EQPreset.self, from: data)
        #expect(decoded.name == "Rock")
        #expect(decoded.isActive == true)
        #expect(decoded.presetType == .manual)
    }

    @Test("EQBand JSON round-trip")
    func eqBandRoundTrip() throws {
        let model = EQBand(id: 6, presetId: 5, frequency: 1000, gain: -3.5, bandwidth: 1.0, bandIndex: 0)
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(EQBand.self, from: data)
        #expect(decoded.presetId == 5)
        #expect(decoded.frequency == 1000)
        #expect(decoded.gain == -3.5)
        #expect(decoded.bandIndex == 0)
    }

    @Test("EQSettings JSON round-trip")
    func eqSettingsRoundTrip() throws {
        let model = EQSettings(id: 7, isEnabled: true, activePresetId: 5, globalGain: 0.0, updatedAt: 300)
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(EQSettings.self, from: data)
        #expect(decoded.isEnabled == true)
        #expect(decoded.activePresetId == 5)
        #expect(decoded.globalGain == 0.0)
    }

    @Test("PlayHistoryEntry JSON round-trip（snake_case 键）")
    func playHistoryEntryRoundTrip() throws {
        let model = PlayHistoryEntry(id: 8, trackStableId: "abc", playedAt: 1_700_000_000, playDurationMs: 45_000)
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(PlayHistoryEntry.self, from: data)
        #expect(decoded.trackStableId == "abc")
        #expect(decoded.playDurationMs == 45_000)
    }
}
