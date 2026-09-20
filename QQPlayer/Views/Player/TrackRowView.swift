import SwiftUI

struct TrackRowView: View, @MainActor Equatable {
    @Environment(AppServices.self) private var services
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    // 1. Pass these in instead of observing PlayerEngine
    let track: Track
    let activeTrackId: String?
    let isAudioPlaying: Bool
    let artistName: String?

    let onTap: () -> Void
    let playlist: Playlist?
    let showDirectDeleteButton: Bool
    let onEnterBulkMode: (() -> Void)?

    @Environment(AppCoordinator.self) private var appCoordinator

    // Internal state only (does not trigger external redraws)
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var artworkImage: UIImage?
    @State private var showDeleteConfirmation = false
    @State private var deleteSettings = DeleteSettings.load()

    // 2. Computed property is now based on passed params
    private var isCurrentlyPlaying: Bool {
        activeTrackId == track.stableId
    }

    // 3. Equatable Conformance: Prevents redraws when PlayerEngine updates time
    static func == (lhs: TrackRowView, rhs: TrackRowView) -> Bool {
        return lhs.track.stableId == rhs.track.stableId &&
            lhs.activeTrackId == rhs.activeTrackId &&
            lhs.isAudioPlaying == rhs.isAudioPlaying &&
            lhs.artistName == rhs.artistName &&
            lhs.playlist?.id == rhs.playlist?.id
    }

    private func resolvedArtistName() -> String? {
        if let artistName, !artistName.isEmpty {
            return artistName
        }

        return try? LibraryReads.artistDisplayName(
            forTrackStableId: track.stableId,
            fallbackArtistId: track.artistId
        )
    }

    var body: some View {
        HStack(spacing: DesignTokens.space0) {
            // MARK: - Tappable Content Area
            HStack(spacing: DesignTokens.space12) {
                // Album artwork thumbnail
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.radius8)
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 60, height: 60)

                    if let image = artworkImage {
                        Image(uiImage: image)
                            .resizable().scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius8))
                    } else {
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }

                    if isCurrentlyPlaying {
                        RoundedRectangle(cornerRadius: DesignTokens.radius8)
                            .stroke(accentColor, lineWidth: 2)
                            .frame(width: 60, height: 60)
                    }
                }

                VStack(alignment: .leading, spacing: DesignTokens.space4) {
                    Text(track.displayTitle)
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundColor(isCurrentlyPlaying ? accentColor : .primary)
                        .lineLimit(1)

                    if let resolvedArtistName = resolvedArtistName() {
                        Text(resolvedArtistName)
                            .font(.body)
                            .foregroundColor(isCurrentlyPlaying ? accentColor.opacity(0.8) : .secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Equalizer uses passed params
                if isCurrentlyPlaying {
                    let eqKey = "\(isAudioPlaying && isCurrentlyPlaying)-\(activeTrackId ?? "")"

                    EqualizerBarsExact(
                        color: accentColor,
                        isActive: isAudioPlaying && isCurrentlyPlaying,
                        isLarge: true,
                        trackId: activeTrackId
                    )
                    .id(eqKey)
                    .padding(.trailing, DesignTokens.space8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onTap()
            }

            // MARK: - Menu / Action Area
            if showDirectDeleteButton {
                Button(action: {
                    removeFromPlaylist()
                }) {
                    Image(systemName: "trash")
                        .font(.title2)
                        .foregroundColor(.red)
                        .frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.08), in: Circle())
                        .overlay(Circle().stroke(.red.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, DesignTokens.space8)
            } else {
                Menu {
                    if let onEnterBulkMode = onEnterBulkMode {
                        Button(action: { onEnterBulkMode() }) {
                            Label(Localized.select, systemImage: "checkmark.circle")
                        }
                    }

                    Button(action: {
                        do {
                            try appCoordinator.toggleFavorite(trackStableId: track.stableId)
                            isFavorite.toggle()
                        } catch { print("Failed to toggle favorite: \(error)") }
                    }) {
                        HStack {
                            Image(systemName: isFavorite ? "heart.slash" : "heart")
                            Text(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs)
                        }
                    }

                    if let artistId = track.artistId,
                       let artist = try? LibraryReads.artist(id: artistId),
                       let allArtistTracks = try? LibraryReads.tracks(artistId: artistId) {
                        NavigationLink(destination: ArtistDetailScreenWrapper(artistName: artist.name, allTracks: allArtistTracks)) {
                            Label(Localized.showArtistPage, systemImage: "person.circle")
                        }
                    }

                    Button(action: { showPlaylistDialog = true }) {
                        Label(Localized.addToPlaylistEllipsis, systemImage: "rectangle.stack.badge.plus")
                    }

                    Button(action: { showDeleteConfirmation = true }) {
                        Label(Localized.deleteFile, systemImage: "trash")
                    }
                    .foregroundColor(.red)

                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .frame(height: 80)
        .padding(.horizontal, DesignTokens.space12)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius8)
                .fill(accentColor.opacity(0.12))
        )
        .sheet(isPresented: $showPlaylistDialog) {
            PlaylistSelectionView(track: track)
                .accentColor(accentColor)
        }
        .alert(Localized.deleteFile, isPresented: $showDeleteConfirmation) {
            Button(Localized.delete, role: .destructive) { deleteFile() }
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            Text(Localized.deleteFileConfirmation(track.displayTitle))
        }
        .onAppear {
            isFavorite = (try? appCoordinator.isFavorite(trackStableId: track.stableId)) ?? false
            if artworkImage == nil { loadArtwork() }
        }
    }

    private func loadArtwork() {
        Task {
            artworkImage = await services.artworkManager.getThumbnail(for: track)
        }
    }

    private func deleteFile() {
        Task {
            // 删除仪式（设置分支 / 删文件 / 删 DB 引用 / 通知刷新）见 TrackDeletionService
            TrackDeletionService.delete(items: [TrackDeletionService.Item(track: track)])
        }
    }

    private func removeFromPlaylist() {
        guard let playlist = playlist, let playlistId = playlist.id else { return }
        Task {
            do {
                try appCoordinator.removeFromPlaylist(playlistId: playlistId, trackStableId: track.stableId)
                NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)
            } catch { print("❌ Failed to remove from playlist: \(error)") }
        }
    }
}
