//
//  SearchResultsViews+ArtistRows.swift
//  QQPlayer
//
//  搜索结果**歌手行**（图标 / 名称 / 进入歌手页）与其下的**歌手专辑横滑区**
//  （含专辑卡片 `SearchArtistAlbumCard`：封面加载 + 标题）。两者总是成对渲染。
//
//  2026-09-21 从 SearchResultsViews.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Library/SearchResultsViews.swift             — 结果页主体：SearchCategory / SearchResults / SearchResultsView 分区装配
//    · Views/Library/SearchResultsViews+SongRow.swift     — 歌曲行（滑动操作 + 右键菜单）
//    · Views/Library/SearchResultsViews+AlbumRow.swift    — 专辑行
//    · Views/Library/SearchResultsViews+PlaylistRow.swift — 歌单行
//
// target: ios-only（SearchResultsViews 分片：消费端全在 iOS）
import SwiftUI

struct SearchArtistRowView: View {
    let artist: Artist
    let onDismiss: () -> Void
    let onNavigate: (Artist, [Track]) -> Void

    var body: some View {
        Button(action: {
            let artistTracks: [Track]
            if let artistId = artist.id {
                artistTracks = (try? LibraryReads.tracks(artistId: artistId)) ?? []
            } else {
                artistTracks = []
            }
            onDismiss()
            onNavigate(artist, artistTracks)
        }) {
            HStack(spacing: DesignTokens.space12) {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundColor(.purple)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: DesignTokens.space4) {
                    Text(ArtistNameNormalizer.displayName(artist.name))
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(Localized.artist)
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

struct SearchArtistAlbumsRow: View {
    let artist: Artist
    let onDismiss: () -> Void
    let onNavigateToAlbum: (Album, [Track]) -> Void
    @State private var artistAlbums: [Album] = []
    @State private var artistTracks: [Track] = []

    var body: some View {
        Group {
            if !artistAlbums.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: DesignTokens.space10) {
                        ForEach(artistAlbums, id: \.id) { album in
                            let albumTracks = artistTracks.filter { $0.albumId == album.id }
                            Button {
                                onDismiss()
                                onNavigateToAlbum(album, albumTracks)
                            } label: {
                                SearchArtistAlbumCard(album: album, tracks: artistTracks)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, DesignTokens.space20)
                    .padding(.vertical, DesignTokens.space8)
                }
            }
        }
        .onAppear { loadArtistData() }
    }

    private func loadArtistData() {
        guard let artistId = artist.id else { return }
        Task {
            let tracks = (try? LibraryReads.tracks(artistId: artistId)) ?? []
            let albums = (try? LibraryReads.albums(artistId: artistId)) ?? []
            await MainActor.run {
                artistTracks = tracks
                artistAlbums = albums
            }
        }
    }

    struct SearchArtistAlbumCard: View {
        @Environment(AppServices.self) private var services
        let album: Album
        let tracks: [Track]
        @State private var artworkImage: UIImage?

        var body: some View {
            VStack(spacing: DesignTokens.space4) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.radius6)
                        .fill(Color(.systemGray5))
                        .frame(width: 80, height: 80)

                    if let image = artworkImage {
                        Image(uiImage: image)
                            .resizable().scaledToFill()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius6))
                    } else {
                        Image(systemName: "opticaldisc.fill")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }

                Text(album.displayTitle)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 80)
                    .foregroundColor(.primary)
            }
            .onAppear { loadArtwork() }
        }

        private func loadArtwork() {
            let albumTracks = tracks.filter { $0.albumId == album.id }
            guard let firstTrack = albumTracks.first else { return }
            Task {
                let image = await services.artworkManager.getThumbnail(for: firstTrack, maxPixelSize: 320)
                await MainActor.run { artworkImage = image }
            }
        }
    }

}
