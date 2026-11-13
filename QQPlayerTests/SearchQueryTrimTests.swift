//
//  SearchQueryTrimTests.swift
//  QQPlayerTests
//
//  搜索串首尾空白收口（2026-11-13）：
//  - 「 abc 」/「\tabc\n」/「　abc」（全角空格 U+3000）与「abc」结果一致
//  - 只有空白的查询 = **空查询** → 空结果（不得返回「整库」或「所有含空格的歌」）
//  - 中间空格保持原样（多词搜索语义不变）
//  - 歌手 / 专辑 / 歌单搜索走同一条 trim 口径
//
//  夹具打真实 DB：`DatabaseManager(dbWriter: DatabaseQueue())` 内存库 + 真实模型 API，
//  不做「假实现自证」的形状测试。
//

import Foundation
import GRDB

import Testing

@testable import QQPlayer

struct SearchQueryTrimTests {
    // MARK: - 夹具

    private func makeManager() throws -> DatabaseManager {
        let manager = DatabaseManager(dbWriter: try DatabaseQueue())
        try manager.createTables()
        return manager
    }

    private func insertTrack(_ manager: DatabaseManager, stableId: String, title: String) throws {
        try manager.upsertTrack(
            Track(
                stableId: stableId,
                title: title,
                path: "/library/\(stableId).flac",
                contentHash: nil
            )
        )
    }

    /// 曲库含：普通曲目、带空格曲名、多词曲名 + 对应歌手 / 专辑 / 歌单。
    private func seedLibrary(_ manager: DatabaseManager) throws {
        try insertTrack(manager, stableId: "t-abc", title: "abc song")
        try insertTrack(manager, stableId: "t-space", title: "space tune")
        try insertTrack(manager, stableId: "t-mid", title: "ab cd tune")
        _ = try manager.upsertArtist(name: "Cure")
        _ = try manager.upsertArtist(name: "Space Artist")
        _ = try manager.upsertAlbum(title: "Blueprint", artistId: nil, year: nil, albumArtist: nil)
        _ = try manager.upsertAlbum(title: "Space Album", artistId: nil, year: nil, albumArtist: nil)
        _ = try manager.createPlaylist(title: "Focus")
        _ = try manager.createPlaylist(title: "Space Playlist")
    }

    private func trackTitles(_ manager: DatabaseManager, query: String) throws -> [String] {
        try manager.searchTracks(query: query, limit: 50).map(\.title).sorted()
    }

    private func artistNames(_ manager: DatabaseManager, query: String) throws -> [String] {
        try manager.searchArtists(query: query, limit: 20).map(\.name).sorted()
    }

    private func albumTitles(_ manager: DatabaseManager, query: String) throws -> [String] {
        try manager.searchAlbums(query: query, limit: 30).map(\.title).sorted()
    }

    private func playlistTitles(_ manager: DatabaseManager, query: String) throws -> [String] {
        try manager.searchPlaylists(query: query, limit: 15).map(\.title).sorted()
    }

    // MARK: - 曲目搜索

    @Test("首尾空白（半角 / Tab / 换行 / 全角空格）与无空白查询结果一致")
    func trackSearchIgnoresSurroundingWhitespace() throws {
        let manager = try makeManager()
        try seedLibrary(manager)

        let baseline = try trackTitles(manager, query: "abc")
        #expect(!baseline.isEmpty, "夹具应能搜到 abc song")
        #expect(baseline.contains("abc song"))

        let padded = try trackTitles(manager, query: " abc ")
        let tabbed = try trackTitles(manager, query: "\tabc\n")
        let fullWidth = try trackTitles(manager, query: "\u{3000}abc\u{3000}")
        let upperCased = try trackTitles(manager, query: "ABC")

        #expect(padded == baseline)
        #expect(tabbed == baseline)
        #expect(fullWidth == baseline)
        #expect(upperCased == baseline)
    }

    @Test("只有空白的查询 = 空查询：不返回整库，也不返回含空格的歌")
    func whitespaceOnlyQueryReturnsNoResults() throws {
        let manager = try makeManager()
        try seedLibrary(manager)

        // 先立证据：空库以外确实有「含空格的歌」可被误命中
        #expect(try trackTitles(manager, query: "space").contains("space tune"))

        for blank in [" ", "\t", "\n", "\u{3000}", " \t\n\u{3000} "] {
            let tracks = try trackTitles(manager, query: blank)
            #expect(tracks.isEmpty, "曲目：空白查询「\(blank.debugDescription)」应无结果，实际 \(tracks)")

            let artists = try artistNames(manager, query: blank)
            #expect(artists.isEmpty, "歌手：空白查询「\(blank.debugDescription)」应无结果，实际 \(artists)")

            let albums = try albumTitles(manager, query: blank)
            #expect(albums.isEmpty, "专辑：空白查询「\(blank.debugDescription)」应无结果，实际 \(albums)")

            let playlists = try playlistTitles(manager, query: blank)
            #expect(playlists.isEmpty, "歌单：空白查询「\(blank.debugDescription)」应无结果，实际 \(playlists)")
        }
    }

    @Test("中间空格保持原样：多词查询仍命中，且与带首尾空白的写法一致")
    func middleWhitespacePreserved() throws {
        let manager = try makeManager()
        try seedLibrary(manager)

        let baseline = try trackTitles(manager, query: "ab cd")
        #expect(baseline.contains("ab cd tune"))

        let padded = try trackTitles(manager, query: "  ab cd  ")
        let fullWidthPadded = try trackTitles(manager, query: "\u{3000}ab cd\u{3000}")
        #expect(padded == baseline)
        #expect(fullWidthPadded == baseline)
    }

    // MARK: - 歌手 / 专辑 / 歌单

    @Test("歌手 / 专辑 / 歌单搜索同样忽略首尾空白")
    func entitySearchesIgnoreSurroundingWhitespace() throws {
        let manager = try makeManager()
        try seedLibrary(manager)

        let artists = try artistNames(manager, query: "Cure")
        #expect(artists.contains("Cure"))
        #expect(try artistNames(manager, query: " Cure ") == artists)
        #expect(try artistNames(manager, query: "\u{3000}Cure\t") == artists)

        let albums = try albumTitles(manager, query: "Blueprint")
        #expect(albums.contains("Blueprint"))
        #expect(try albumTitles(manager, query: " Blueprint ") == albums)
        #expect(try albumTitles(manager, query: "\nBlueprint\u{3000}") == albums)

        let playlists = try playlistTitles(manager, query: "Focus")
        #expect(playlists.contains("Focus"))
        #expect(try playlistTitles(manager, query: " Focus ") == playlists)
        #expect(try playlistTitles(manager, query: "\u{3000}Focus\t") == playlists)
    }

    // MARK: - 归一工具契约

    @Test("SearchQuery：trim / isEmpty / normalized 口径")
    func searchQueryNormalizerContract() {
        #expect(SearchQuery.trimmed("  abc  ") == "abc")
        #expect(SearchQuery.trimmed("\u{3000}abc\u{3000}") == "abc")
        #expect(SearchQuery.trimmed("\tabc\n") == "abc")
        #expect(SearchQuery.trimmed("a b") == "a b", "中间空格不得被去掉")
        #expect(SearchQuery.trimmed("").isEmpty)

        #expect(SearchQuery.isEmpty(" \t\n\u{3000}"))
        #expect(SearchQuery.isEmpty(""))
        #expect(!SearchQuery.isEmpty(" a "))

        #expect(SearchQuery.normalized("  ABC ") == "abc")
        #expect(SearchQuery.normalized(" \u{3000} ").isEmpty)
    }
}
