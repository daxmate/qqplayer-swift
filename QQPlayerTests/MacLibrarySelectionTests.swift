//
//  MacLibrarySelectionTests.swift
//  QQPlayerTests
//
//  macOS 侧栏选中项回退口径（`MacLibrarySelection.resolved`）单测。
//
//  2026-09-27：侧栏在「艺术家」下方直接列出自动歌单与用户自建歌单后，
//  「选中的用户歌单被删除 → 优雅回退」必须有唯一、可测的口径。
//
//  为什么测共享层的纯函数：iOS 单测 target 编不到 `QQPlayer/Mac/**`（在 iOS 例外表里），
//  故选择语义与回退口径上收 `QQPlayer/Services/MacLibrarySelection.swift`（与
//  MacIndexingGate / MacFolderWatchPolicy 同款）。
//

import Foundation
import Testing

@testable import QQPlayer

@Suite("MacLibrarySelection 回退口径")
struct MacLibrarySelectionTests {
    @Test("一级分区恒有效：原样返回")
    func sectionStaysValid() {
        #expect(
            MacLibrarySelection.resolved(.section(.albums), availableUserPlaylistIds: []) == .section(.albums)
        )
    }

    @Test("自动歌单恒有效：原样返回")
    func smartPlaylistStaysValid() {
        let selection = MacLibrarySelection.smartPlaylist(.decades)
        #expect(MacLibrarySelection.resolved(selection, availableUserPlaylistIds: []) == selection)
    }

    @Test("用户歌单仍存在：原样返回")
    func existingUserPlaylistStays() {
        let selection = MacLibrarySelection.userPlaylist(7)
        #expect(MacLibrarySelection.resolved(selection, availableUserPlaylistIds: [3, 7, 9]) == selection)
    }

    @Test("用户歌单被删除：回退到一级分区（歌曲）")
    func missingUserPlaylistFallsBack() {
        let selection = MacLibrarySelection.userPlaylist(7)
        #expect(MacLibrarySelection.resolved(selection, availableUserPlaylistIds: [3, 9]) == .section(.tracks))
        #expect(MacLibrarySelection.resolved(selection, availableUserPlaylistIds: []) == MacLibrarySelection.fallback)
    }
}
