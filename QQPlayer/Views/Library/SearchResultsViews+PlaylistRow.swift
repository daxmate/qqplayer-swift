//
//  SearchResultsViews+PlaylistRow.swift
//  QQPlayer
//
//  搜索结果**歌单行**：图标、歌单名，点击进入歌单详情。
//
//  2026-09-21 从 SearchResultsViews.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Library/SearchResultsViews.swift             — 结果页主体：SearchCategory / SearchResults / SearchResultsView 分区装配
//    · Views/Library/SearchResultsViews+SongRow.swift     — 歌曲行（滑动操作 + 右键菜单）
//    · Views/Library/SearchResultsViews+ArtistRows.swift  — 歌手行 + 歌手专辑横滑
//    · Views/Library/SearchResultsViews+AlbumRow.swift    — 专辑行
//
// target: ios-only（SearchResultsViews 分片：消费端全在 iOS）
import SwiftUI

struct SearchPlaylistRowView: View {
    let playlist: Playlist
    let onDismiss: () -> Void
    let onNavigate: (Playlist) -> Void
    @State private var settings = DeleteSettings.load()

    var body: some View {
        Button(action: {
            onDismiss()
            onNavigate(playlist)
        }) {
            HStack(spacing: DesignTokens.space12) {
                Image(systemName: "music.note.list")
                    .font(.title2)
                    .foregroundColor(.green)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: DesignTokens.space4) {
                    Text(playlist.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(Localized.playlist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, DesignTokens.space16)
            .padding(.vertical, DesignTokens.space12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}
