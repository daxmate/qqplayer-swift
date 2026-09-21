//
//  SearchResultsViews+AlbumRow.swift
//  QQPlayer
//
//  搜索结果**专辑行**：封面缩略图、专辑名 / 专辑歌手、歌曲数，
//  点击进入专辑详情（曲目列表在出现时异步加载）。
//
//  2026-09-21 从 SearchResultsViews.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Library/SearchResultsViews.swift             — 结果页主体：SearchCategory / SearchResults / SearchResultsView 分区装配
//    · Views/Library/SearchResultsViews+SongRow.swift     — 歌曲行（滑动操作 + 右键菜单）
//    · Views/Library/SearchResultsViews+ArtistRows.swift  — 歌手行 + 歌手专辑横滑
//    · Views/Library/SearchResultsViews+PlaylistRow.swift — 歌单行
//
// target: ios-only（SearchResultsViews 分片：消费端全在 iOS）
import SwiftUI

struct SearchAlbumRowView: View {
    @Environment(AppServices.self) private var services
    let album: Album
    let albumArtistName: String?
    let onDismiss: () -> Void
    let onNavigate: (Album, [Track]) -> Void
    @State private var settings = DeleteSettings.load()
    @State private var artworkImage: UIImage?
    @State private var albumTracks: [Track] = []

    var body: some View {
        Button(action: {
            onDismiss()
            onNavigate(album, albumTracks)
        }) {
            HStack(spacing: DesignTokens.space12) {
                Group { // Album artwork
                    if let artworkImage = artworkImage {
                        Image(uiImage: artworkImage)
                            .resizable().scaledToFill()
                    } else {
                        Image(systemName: "opticaldisc.fill")
                            .font(.system(size: DesignTokens.font20))
                            .foregroundColor(.orange)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius6))
                .background(Color(.systemGray5))

                VStack(alignment: .leading, spacing: DesignTokens.space4) {
                    Text(album.displayTitle)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    HStack(spacing: DesignTokens.space4) {
                        if let albumArtistName, !albumArtistName.isEmpty {
                            Text(albumArtistName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Text("• \(Localized.album)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Text(Localized.songsCountOnly(albumTracks.count))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, DesignTokens.space16)
            .padding(.vertical, DesignTokens.space12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            loadAlbumData()
        }
    }

    private func loadAlbumData() {
        guard let albumId = album.id else { return }

        Task {
            let tracks = (try? LibraryReads.tracks(albumId: albumId)) ?? []
            await MainActor.run {
                albumTracks = tracks
            }

            guard let firstTrack = tracks.first else { return }
            let artwork = await services.artworkManager.getThumbnail(for: firstTrack)
            await MainActor.run {
                artworkImage = artwork
            }
        }
    }
}
