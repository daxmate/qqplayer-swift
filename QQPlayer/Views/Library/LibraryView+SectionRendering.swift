//
//  LibraryView+SectionRendering.swift
//  QQPlayer
//
//  音乐库主页**首页分区视图**：按 `HomeSectionId` 装配「全部歌曲 / 专辑 / 歌手 /
//  歌单」等分区入口行（每行都是 `LibrarySectionRowView`，带导航目的页）。
//
//  2026-09-21 从 LibraryView.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Library/LibraryView.swift                     — 视图壳：stored property + `body` + 导入入口
//    · Views/Library/LibraryView+ImportSupport.swift       — 导入结果分桶 + 书签落库
//    · Views/Library/LibraryView+SectionRendering.swift    — 首页分区视图（homeSectionView）
//    · Views/Library/LibraryView+SyncFeedback.swift        — 同步反馈 toast + runSync
//    · Views/Library/LibraryView+SectionRow.swift          — 首页分区行（LibrarySectionRowView）
//    · Views/Library/LibraryView+ResponsiveFonts.swift     — View 响应式字号 helper
//
// target: ios-only（LibraryView 分片：消费端全在 iOS；Mac 侧为 MacLibraryView）

import SwiftUI

extension LibraryView {
    /// 分片：跨文件可见（原 private）
    @ViewBuilder
    func homeSectionView(for sectionId: HomeSectionId) -> some View {
        switch sectionId {
        case .allSongs:
            NavigationLink {
                AllSongsScreen(tracks: tracks)
            } label: {
                LibrarySectionRowView(
                    title: Localized.allSongs,
                    subtitle: Localized.songsCountOnly(tracks.count),
                    icon: "music.note",
                    color: accentColor
                )
            }
            .buttonStyle(PlainButtonStyle())

        case .likedSongs:
            NavigationLink {
                LikedSongsScreen(allTracks: tracks)
            } label: {
                LibrarySectionRowView(
                    title: Localized.likedSongs,
                    subtitle: Localized.yourFavorites,
                    icon: "heart.fill",
                    color: .red
                )
            }
            .buttonStyle(PlainButtonStyle())

        case .playlists:
            NavigationLink {
                PlaylistsScreen()
            } label: {
                LibrarySectionRowView(
                    title: Localized.playlists,
                    subtitle: Localized.yourPlaylists,
                    icon: "music.note.list",
                    color: .green
                )
            }
            .buttonStyle(PlainButtonStyle())

        case .artists:
            NavigationLink {
                ArtistsScreen(allTracks: tracks)
            } label: {
                LibrarySectionRowView(
                    title: Localized.artists,
                    subtitle: Localized.browseByArtist,
                    icon: "person.2.fill",
                    color: .purple
                )
            }
            .buttonStyle(PlainButtonStyle())

        case .albums:
            NavigationLink {
                AlbumsScreen(allTracks: tracks)
            } label: {
                LibrarySectionRowView(
                    title: Localized.albums,
                    subtitle: Localized.browseByAlbum,
                    icon: "opticaldisc.fill",
                    color: .orange
                )
            }
            .buttonStyle(PlainButtonStyle())

        case .addSongs:
            Button(action: {
                showMusicPicker = true
            }) {
                LibrarySectionRowView(
                    title: Localized.addSongs,
                    subtitle: Localized.importMusicFiles,
                    icon: "plus.circle.fill",
                    color: .blue
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }
}
