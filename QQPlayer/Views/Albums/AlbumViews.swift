//
//  AlbumViews.swift
//  QQPlayer
//
//  专辑**列表 / 网格主体**：`AlbumsScreen`（专辑网格 + 曲目索引预取 + 刷新）、
//  空态 `EmptyAlbumsView`、专辑卡片 `AlbumCardView`（封面缩略图 + 曲目数）。
//  详情页与曲目行按职责分片（2026-09-21 拆分，纯搬家、无逻辑变更）：
//    · Views/Albums/AlbumViews+AlbumDetail.swift — 专辑详情页（封面/信息头 + 播放/随机 + 多碟分组曲目列表 + 批量选择）
//    · Views/Albums/AlbumViews+TrackRow.swift    — 专辑曲目行 + 歌手页包装（ArtistDetailScreenWrapper）
//
import SwiftUI

struct AlbumsScreen: View {
    let allTracks: [Track]
    @Environment(AppCoordinator.self) private var appCoordinator
    @State private var albums: [Album] = []
    /// albumId → 曲目索引：卡片渲染不再对全库做线性 filter（修前每张卡片每次重绘一次 O(n) 扫描）
    @State private var tracksByAlbumId: [Int64: [Track]] = [:]
    @State private var settings = DeleteSettings.load()

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .albums)

            VStack {
                if albums.isEmpty {
                    EmptyAlbumsView()
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: DesignTokens.space20),
                                GridItem(.flexible()),
                            ],
                            spacing: DesignTokens.space16
                        ) {
                            ForEach(albums, id: \.id) { album in
                                NavigationLink {
                                    AlbumDetailScreen(album: album, allTracks: allTracks)
                                } label: {
                                    AlbumCardView(album: album,
                                                  tracks: albumTracks(album))
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(DesignTokens.space16)
                        .padding(.bottom, DesignTokens.space100) // Add padding for mini player
                    }
                }
            }
        }
        .navigationTitle(Localized.albums)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadAlbums)
        .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
            loadAlbums()
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
        }
    }

    /// 预取索引：一次遍历建好 albumId → tracks（替代每张卡片的 allTracks.filter）
    private func rebuildAlbumTrackIndex() {
        tracksByAlbumId = Dictionary(grouping: allTracks.compactMap { track in
            track.albumId.map { ($0, track) }
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
    }

    private func albumTracks(_ album: Album) -> [Track] {
        guard let albumId = album.id else { return [] }
        return tracksByAlbumId[albumId] ?? []
    }

    private func loadAlbums() {
        do {
            albums = try appCoordinator.getAllAlbums()
        } catch {
            AppLog.error(.ui, "Failed to load albums: \(error)")
        }
        rebuildAlbumTrackIndex()
    }
}

private struct EmptyAlbumsView: View {
    var body: some View {
        VStack(spacing: DesignTokens.space16) {
            Image(systemName: "opticaldisc")
                .font(.system(size: DesignTokens.font40))
                .foregroundColor(.secondary)
            Text(Localized.noAlbumsFound).font(.headline)
            Text(Localized.albumsWillAppear)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Album card with artwork loading
private struct AlbumCardView: View {
    @Environment(AppServices.self) private var services
    let album: Album
    let tracks: [Track]
    @State private var artworkImage: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space8) {
            // Album artwork area with fixed aspect ratio
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: DesignTokens.radius12)
                    .fill(Color.gray.opacity(0.15))
                    .overlay {
                        if let image = artworkImage {
                            Image(uiImage: image)
                                .resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.width)
                                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius12))
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: DesignTokens.font36))
                                .foregroundColor(.secondary)
                        }
                    }
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: DesignTokens.space4) {
                Text(album.displayTitle)
                    .font(.headline)
                    .lineLimit(2)

                Text(Localized.songsCount(tracks.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(minHeight: 60, alignment: .topLeading)
        }
        .task {
            loadAlbumArtwork()
        }
    }

    private func loadAlbumArtwork() {
        // Use the first track in the album to get artwork
        guard let firstTrack = tracks.first else { return }
        Task {
            artworkImage = await services.artworkManager.getThumbnail(for: firstTrack, maxPixelSize: 512)
        }
    }
}
