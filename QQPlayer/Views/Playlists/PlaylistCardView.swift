import GRDB
import PhotosUI
import SwiftUI
import WidgetKit

struct PlaylistCardView: View {
    @Environment(AppCoordinator.self) private var appCoordinator
    let playlist: Playlist
    let allTracks: [Track]
    let isEditMode: Bool
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    @Environment(AppServices.self) private var services
    @State private var artworks: [UIImage] = []
    @State private var customCoverImage: UIImage?
    @State private var showingImagePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    /// 歌单自定义封面读取失败的登记（INV-22 另一半：读不到必须申报）。
    /// 2026-09-19 批 2：由组合根（`QQPlayerApp`）环境注入，不再直连 `.shared`。
    @Environment(PlaylistCoverLoadFailuresStore.self) private var coverFailures

    init(playlist: Playlist, allTracks: [Track], isEditMode: Bool = false, onEdit: (() -> Void)? = nil, onDelete: (() -> Void)? = nil) {
        self.playlist = playlist
        self.allTracks = allTracks
        self.isEditMode = isEditMode
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space8) {
            // Artwork area
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.radius12)
                    .fill(Color.gray.opacity(0.2))
                    .aspectRatio(1, contentMode: .fit)

                // Edit mode overlay with buttons - always on top
                if isEditMode {
                    VStack {
                        HStack {
                            Button(action: {
                                onEdit?()
                            }) {
                                Image(systemName: "pencil")
                                    .font(.title2)
                                    .foregroundColor(.black)
                                    .frame(width: 36, height: 36)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .overlay(
                                        Circle()
                                            .stroke(.black.opacity(0.3), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())

                            Spacer()

                            Button(action: {
                                onDelete?()
                            }) {
                                Image(systemName: "trash")
                                    .font(.title2)
                                    .foregroundColor(.red)
                                    .frame(width: 36, height: 36)
                                    .background(.ultraThinMaterial, in: Circle())
                                    .overlay(
                                        Circle()
                                            .stroke(.red.opacity(0.3), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        Spacer()

                        // Centered photo icon for changing cover
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            Image(systemName: "photo")
                                .font(.system(size: DesignTokens.font32, weight: .light))
                                .foregroundColor(.white)
                                .frame(width: 64, height: 64)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Circle())
                        }
                        .buttonStyle(PlainButtonStyle())

                        Spacer()
                    }
                    .padding(DesignTokens.space8)
                    .zIndex(1000)
                }

                // Artwork content - same in both edit and normal mode
                // Show custom cover if available, otherwise show auto-generated mashup
                if let customCover = customCoverImage {
                    Image(uiImage: customCover)
                        .resizable().scaledToFill()
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .clipped()
                } else if allTracks.count >= 4 {
                    // 2x2 mashup for 4+ songs
                    GeometryReader { geometry in
                        let size = (geometry.size.width - 2) / 2
                        VStack(spacing: DesignTokens.space2) {
                            HStack(spacing: DesignTokens.space2) {
                                artworkView(at: 0, size: size)
                                artworkView(at: 1, size: size)
                            }
                            HStack(spacing: DesignTokens.space2) {
                                artworkView(at: 2, size: size)
                                artworkView(at: 3, size: size)
                            }
                        }
                    }
                } else if !allTracks.isEmpty {
                    // Single artwork for 1-3 songs
                    GeometryReader { geometry in
                        artworkView(at: 0, size: geometry.size.width)
                    }
                } else {
                    // Default icon for empty playlist
                    Image(systemName: "music.note.list")
                        .font(.system(size: DesignTokens.font40))
                        .foregroundColor(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius12))
            .contentShape(RoundedRectangle(cornerRadius: DesignTokens.radius12))

            // Text info
            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(playlist.title)
                    .font(.headline)
                    .lineLimit(1)

                Text(Localized.songsCount(allTracks.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .task {
            await loadCustomCover()
            await loadArtworks()
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await saveCustomCover(image)
                }
            }
        }
    }

    @ViewBuilder
    private func artworkView(at index: Int, size: CGFloat?) -> some View {
        if index < artworks.count {
            Image(uiImage: artworks[index])
                .resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: index < 4 && allTracks.count >= 4 ? DesignTokens.radius6 : DesignTokens.radius12))
        } else if index < allTracks.count {
            RoundedRectangle(cornerRadius: index < 4 && allTracks.count >= 4 ? DesignTokens.radius6 : DesignTokens.radius12)
                .fill(Color.gray.opacity(0.3))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .foregroundColor(.secondary)
                        .font(.system(size: size != nil ? size! / 4 : DesignTokens.font40))
                )
        }
    }

    private func loadArtworks() async {
        var loadedArtworks: [UIImage] = []
        let tracksToLoad = Array(allTracks.prefix(4))

        for track in tracksToLoad {
            if let artwork = await services.artworkManager.getThumbnail(for: track, maxPixelSize: 256) {
                loadedArtworks.append(artwork)
            }
        }

        await MainActor.run {
            artworks = loadedArtworks
        }
    }

    private func loadCustomCover() async {
        // 路径解析只有一处入口（`PlaylistCoverResolver`）：**读不到必须申报**（INV-22 另一半）。
        // 别再在这里自己 `guard … else { return }`——那正是「封面没了但没人说得清为什么」的形状。
        let key = PlaylistCoverResolver.playlistKey(id: playlist.id, slug: playlist.slug)
        switch PlaylistCoverResolver.resolve(customCoverImagePath: playlist.customCoverImagePath) {
        case .none:
            // 没配自定义封面（正常路径）：清掉可能残留的失败登记
            await MainActor.run { coverFailures.clear(playlistKey: key) }
        case let .unavailable(reason):
            let path = playlist.customCoverImagePath ?? ""
            await MainActor.run {
                coverFailures.record(playlistKey: key, path: path, reason: reason)
            }
        case let .available(fileURL):
            guard let data = try? Data(contentsOf: fileURL),
                  let image = UIImage(data: data) else {
                let path = playlist.customCoverImagePath ?? ""
                await MainActor.run {
                    coverFailures.record(
                        playlistKey: key,
                        path: path,
                        reason: PlaylistCoverResolver.Reason.decodeFailed
                    )
                }
                return
            }
            await MainActor.run { coverFailures.clear(playlistKey: key) }
            await MainActor.run { customCoverImage = image }
        }
    }

    @MainActor
    private func saveCustomCover(_ image: UIImage) async {
        guard let playlistId = playlist.id else { return }

        // Get shared container
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.daxmate.qqplayer.ios"
        ) else {
            AppLog.error(.ui, "❌ Failed to get shared container URL")
            return
        }

        // Create unique filename for this playlist cover
        let filename = "playlist_cover_\(playlistId).jpg"
        let fileURL = containerURL.appendingPathComponent(filename)
        let coverImage = image.squarePlaylistCover()

        // Save a normalized square image so all playlist covers match standard artwork sizing.
        guard let jpegData = coverImage.jpegData(compressionQuality: 0.85) else {
            AppLog.error(.ui, "❌ Failed to convert image to JPEG")
            return
        }

        do {
            // Save image to shared container
            try jpegData.write(to: fileURL)
            AppLog.info(.ui, "✅ Saved custom cover to \(filename)")

            // Update database with custom cover path（写操作唯一入口：AppCoordinator）
            try appCoordinator.updatePlaylistCustomCover(
                playlistId: playlistId,
                imagePath: filename
            )

            // Update UI
            customCoverImage = coverImage

            // Notify widgets to refresh
            WidgetCenter.shared.reloadAllTimelines()

            // Refresh the playlist list
            NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)

            AppLog.info(.ui, "✅ Custom cover saved and database updated")
        } catch {
            AppLog.error(.ui, "❌ Failed to save custom cover: \(error)")
        }
    }
}
