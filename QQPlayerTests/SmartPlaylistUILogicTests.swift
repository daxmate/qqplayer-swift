//
//  SmartPlaylistUILogicTests.swift
//  QQPlayerTests
//
//  自动歌单 UI 层纯逻辑测试：置顶卡片的图标映射 + 副标题格式选择。
//  SmartPlaylistCardView 的视觉决策抽成 SmartPlaylistUILogic，可脱离
//  本地化/数据库单独验证（视图本身是 SwiftUI 声明，不做单元测试）。
//

import Testing
import UIKit

@testable import QQPlayer

struct SmartPlaylistUILogicTests {
    @Test func iconMappingCoversAllKinds() {
        #expect(SmartPlaylistUILogic.iconName(for: .recentAdded) == "clock")
        #expect(SmartPlaylistUILogic.iconName(for: .recentPlayed) == "clock.arrow.circlepath")
        #expect(SmartPlaylistUILogic.iconName(for: .topPlayed) == "flame")
        #expect(SmartPlaylistUILogic.iconName(for: .decades) == "calendar")
    }

    /// 守卫：iconName 必须是真实存在的 SF Symbol。
    /// 用 UIImage(systemName:) 解析失败时 Image(systemName:) 会渲染成空白，
    /// 图标名笔误在视觉上几乎无法发现（曾经的 "history" 即非合法符号）。
    @Test func iconNamesResolveToRealSymbols() {
        for kind in SmartPlaylistKind.allCases {
            let name = SmartPlaylistUILogic.iconName(for: kind)
            #expect(
                UIImage(systemName: name) != nil,
                "SmartPlaylistKind.\(kind) 的图标名 \(name) 不是合法 SF Symbol"
            )
        }
    }

    @Test func cardSubtitleUsesSongsFormatForTrackKinds() {
        for kind in [SmartPlaylistKind.recentAdded, .recentPlayed, .topPlayed] {
            let subtitle = SmartPlaylistUILogic.cardSubtitle(
                kind: kind,
                count: 7,
                songsFormat: { "\($0) songs" },
                decadesFormat: { "\($0) decades" }
            )
            #expect(subtitle == "7 songs")
        }
    }

    @Test func cardSubtitleUsesDecadesFormatForDecades() {
        let subtitle = SmartPlaylistUILogic.cardSubtitle(
            kind: .decades,
            count: 9,
            songsFormat: { "\($0) songs" },
            decadesFormat: { "\($0) decades" }
        )
        #expect(subtitle == "9 decades")
    }
}

// MARK: - 封面拼贴布局决策

@Test func coverLayoutByArtworkCount() {
    #expect(SmartPlaylistUILogic.coverLayout(artworkCount: 0) == .icon)
    #expect(SmartPlaylistUILogic.coverLayout(artworkCount: 1) == .single)
    #expect(SmartPlaylistUILogic.coverLayout(artworkCount: 2) == .single)
    #expect(SmartPlaylistUILogic.coverLayout(artworkCount: 3) == .single)
    #expect(SmartPlaylistUILogic.coverLayout(artworkCount: 4) == .grid2x2)
    #expect(SmartPlaylistUILogic.coverLayout(artworkCount: 5) == .grid2x2)
}
