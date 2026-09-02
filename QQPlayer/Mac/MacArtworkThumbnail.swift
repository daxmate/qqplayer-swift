//
//  MacArtworkThumbnail.swift
//  QQPlayer
//
//  macOS reusable artwork views: async thumbnail loading with placeholder
//  fallback, plus representative-track resolution for album / playlist /
//  smart-playlist cards. QQPlayerMac target only.
//

import SwiftUI

/// 解析「卡片代表曲目」：专辑取第一首、歌单取第一首（按 position 排序）。
enum MacArtworkResolver {
    static func representativeTrack(forAlbum album: Album) -> Track? {
        guard let albumId = album.id else { return nil }
        return (try? DatabaseManager.shared.getTracksByAlbumId(albumId))?.first
    }

    static func representativeTrack(forPlaylist playlist: Playlist) -> Track? {
        guard let playlistId = playlist.id else { return nil }
        guard let item = (try? DatabaseManager.shared.getPlaylistItems(playlistId: playlistId))?.first else {
            return nil
        }
        return try? DatabaseManager.shared.getTrack(byStableId: item.trackStableId)
    }
}

/// 固定尺寸封面缩略图：异步加载 + 占位图标兜底。
struct MacArtworkThumbnail: View {
    let track: Track?
    let size: CGFloat
    var cornerRadius: CGFloat = 8
    var placeholderIcon: String = "music.note"

    @State private var image: ArtworkImage?

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.gray.opacity(0.18))
            .frame(width: size, height: size)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                } else {
                    Image(systemName: placeholderIcon)
                        .font(.system(size: max(size * 0.3, 10)))
                        .foregroundColor(.secondary)
                }
            }
            .task(id: track?.stableId) {
                guard let track else {
                    image = nil
                    return
                }
                image = await ArtworkManager.shared.getThumbnail(for: track, maxPixelSize: max(size * 2, 80))
            }
    }
}

/// 宽度自适应正方形封面（网格卡片用）：撑满父容器宽度。
struct MacArtworkThumbnailFill: View {
    let track: Track?
    var cornerRadius: CGFloat = 8
    var placeholderIcon: String = "music.note"

    var body: some View {
        GeometryReader { geo in
            MacArtworkThumbnail(
                track: track,
                size: geo.size.width,
                cornerRadius: cornerRadius,
                placeholderIcon: placeholderIcon
            )
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// 智能歌单卡片封面：最多 4 张曲目封面 2x2 拼贴（对齐 web 版/iOS 拼贴），
/// 单曲退化为单图，无图显示占位图标。
struct MacArtworkCollage: View {
    let tracks: [Track]
    let size: CGFloat
    var cornerRadius: CGFloat = 8
    var placeholderIcon: String = "music.note"

    @State private var images: [ArtworkImage?] = []

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color.gray.opacity(0.18))
            .frame(width: size, height: size)
            .overlay {
                if images.isEmpty {
                    Image(systemName: placeholderIcon)
                        .font(.system(size: max(size * 0.26, 10)))
                        .foregroundColor(.secondary)
                } else {
                    collageContent
                }
            }
            .task(id: tracks.map(\.stableId)) {
                images = await Self.load(tracks: tracks, size: size)
            }
    }

    private var collageContent: some View {
        let available = images.compactMap { $0 }
        let cell = size / 2
        return Group {
            if available.count == 1, let first = available.first {
                Image(nsImage: first)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
            } else {
                LazyVGrid(
                    columns: [GridItem(.fixed(cell), spacing: 1), GridItem(.fixed(cell), spacing: 1)],
                    spacing: 1
                ) {
                    ForEach(available.prefix(4).indices, id: \.self) { index in
                        Image(nsImage: available[index])
                            .resizable()
                            .scaledToFill()
                            .frame(width: cell, height: cell)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private static func load(tracks: [Track], size: CGFloat) async -> [ArtworkImage?] {
        let pixelSize = max(size, 80)
        var result: [ArtworkImage?] = []
        for track in tracks.prefix(4) {
            result.append(await ArtworkManager.shared.getThumbnail(for: track, maxPixelSize: pixelSize))
        }
        return result
    }
}
