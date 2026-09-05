//
//  TagRenameLogicTests.swift
//  QQPlayerTests
//
//  重命名模板渲染防回归测试（E1 标签刮削）。
//  期望值全部用 web 版 tag_editor.target_filename 实测锚定（2026-09-05，
//  ~/codes/qqplayer/backend/venv/bin/python），web 为唯一事实源。
//

import Foundation
import Testing

@testable import QQPlayer

struct TagRenameLogicTests {
    private func render(
        _ template: String?,
        artist: String? = nil,
        title: String? = nil,
        album: String? = nil,
        track: Int? = nil,
        year: Int? = nil,
        ext: String = ".mp3"
    ) -> String? {
        TagRenameLogic.renderFileName(
            template: template,
            values: .init(artist: artist, title: title, album: album, track: track, year: year),
            ext: ext
        )
    }

    // MARK: - 默认模板旧分支

    @Test("默认模板：artist + title")
    func defaultArtistTitle() {
        #expect(render(nil, artist: "Artist", title: "Title") == "Artist - Title.mp3")
    }

    @Test("默认模板：仅 title（不留分隔符）")
    func defaultTitleOnly() {
        #expect(render(nil, title: "Title") == "Title.mp3")
    }

    @Test("默认模板：仅 artist")
    func defaultArtistOnly() {
        #expect(render(nil, artist: "Artist") == "Artist.mp3")
    }

    @Test("默认模板：全空 → nil 不改名")
    func defaultAllEmpty() {
        #expect(render(nil) == nil)
        #expect(render(nil, artist: "", title: "") == nil)
    }

    @Test("默认模板：artist 空白串 → 回落仅 title")
    func defaultArtistWhitespace() {
        #expect(render(nil, artist: "  ", title: "Title") == "Title.mp3")
    }

    @Test("默认模板：非法字符清洗（\\/:*?\"<>|）")
    func defaultInvalidChars() {
        #expect(render(nil, artist: "A/B:C*D", title: "Ti?tle") == "ABCD - Title.mp3")
    }

    @Test("默认模板：首尾空白裁剪")
    func defaultTrimsWhitespace() {
        #expect(render(nil, artist: "Artist ", title: " Title ") == "Artist - Title.mp3")
    }

    @Test("默认模板字符串作为自定义模板传入 → 等价默认分支")
    func defaultTemplateString() {
        #expect(render("{artist} - {title}", artist: "Artist", title: "Title") == "Artist - Title.mp3")
    }

    // MARK: - 自定义模板

    @Test("自定义：track 占位符")
    func customTrack() {
        #expect(render("{track}. {artist} - {title}", artist: "Artist", title: "Title", track: 3) == "3. Artist - Title.mp3")
    }

    @Test("自定义：year 占位符（扩展名 flac）")
    func customYear() {
        #expect(render("{artist} ({year})", artist: "Artist", title: "Title", year: 2018, ext: ".flac") == "Artist (2018).flac")
    }

    @Test("自定义：track 空 → 空占位残留清理")
    func customEmptyPlaceholder() {
        #expect(render("{track}. {title}", title: "Song") == "Song.mp3")
    }

    @Test("自定义：未知占位符 → 回落默认模板")
    func customUnknownPlaceholder() {
        #expect(render("{foo} {title}", artist: "Artist", title: "Song") == "Artist - Song.mp3")
    }

    @Test("自定义：子目录（'/' 保留）")
    func customSubdirectory() {
        #expect(render("{artist}/{album}/{title}", artist: "Artist", title: "Title", album: "Album") == "Artist/Album/Title.mp3")
    }

    @Test("自定义：子目录中间段为空 → 过滤不留空段")
    func customSubdirectoryEmptySegment() {
        #expect(render("{artist}/{album}/{title}", artist: "Artist", title: "Title", album: "") == "Artist/Title.mp3")
    }

    @Test("自定义：防穿越（.. 段过滤）→ nil")
    func customPathTraversal() {
        #expect(render("{title}", title: "..") == nil)
    }

    @Test("自定义：占位符值内非法字符清洗")
    func customValueCleaning() {
        #expect(render("{title}", title: "A:B*C?D") == "ABCD.mp3")
    }

    @Test("自定义：全占位符空 → nil")
    func customAllEmpty() {
        #expect(render("{artist}/{title}", artist: "", title: "") == nil)
    }

    @Test("自定义：year 空残留 ' - ' 分隔 → 清理")
    func customResidualSeparator() {
        #expect(render("{year} - {title}", title: "Song") == "Song.mp3")
    }

    @Test("自定义：album 占位")
    func customAlbum() {
        #expect(render("{album} - {title}", artist: "Artist", title: "Title", album: "AlbumX") == "AlbumX - Title.mp3")
    }
}
