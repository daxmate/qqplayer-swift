import GRDB
import SwiftUI
struct PlaylistTrackRowView: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    let track: Track
    let playlist: Playlist?
    let isEditMode: Bool
    let artistName: String?
    let onTap: () -> Void
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var playerEngine = PlayerEngine.shared
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var showDeleteConfirmation = false
    @State private var deleteSettings = DeleteSettings.load()
    @State private var artworkImage: UIImage?
    @StateObject private var artworkManager = ArtworkManager.shared

    // Check if this track is currently playing
    private var isCurrentlyPlaying: Bool {
        playerEngine.currentTrack?.stableId == track.stableId
    }

    var body: some View {
        HStack(spacing: DesignTokens.space0) {
            // MARK: - Tappable Content Area
            HStack(spacing: DesignTokens.space12) {
                // Album artwork thumbnail (matching TrackRowView exactly)
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

                    // Stroke when playing (matching TrackRowView)
                    if isCurrentlyPlaying {
                        RoundedRectangle(cornerRadius: DesignTokens.radius8)
                            .stroke(accentColor, lineWidth: 2)
                            .frame(width: 60, height: 60)
                    }
                }

                // Track info (matching TrackRowView exactly)
                VStack(alignment: .leading, spacing: DesignTokens.space4) {
                    Text(track.displayTitle)
                        .font(.title3)
                        .fontWeight(.medium)
                        .foregroundColor(isCurrentlyPlaying ? accentColor : .primary)
                        .lineLimit(1)

                    if let artistName, !artistName.isEmpty {
                        Text(artistName)
                            .font(.body)
                            .foregroundColor(isCurrentlyPlaying ? accentColor.opacity(0.8) : .secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Equalizer animation when playing (matching TrackRowView)
                if isCurrentlyPlaying {
                    EqualizerBarsExact(
                        color: accentColor,
                        isActive: playerEngine.isPlaying && isCurrentlyPlaying,
                        isLarge: true,
                        trackId: playerEngine.currentTrack?.stableId
                    )
                    .id("\(playerEngine.isPlaying && isCurrentlyPlaying)-\(playerEngine.currentTrack?.stableId ?? "")")
                    .padding(.trailing, DesignTokens.space8)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if !isEditMode {
                    onTap()
                }
            }

            // MARK: - Menu / Action Area
            // Show delete button in edit mode, otherwise menu
            if isEditMode, playlist != nil {
                Button(action: {
                    removeFromPlaylist()
                }) {
                    Image(systemName: "trash")
                        .font(.title2)
                        .foregroundColor(.red)
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(.red.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, DesignTokens.space8)
            } else {
                Menu {
                    Button(action: {
                        do {
                            try appCoordinator.toggleFavorite(trackStableId: track.stableId)
                            isFavorite.toggle()
                        } catch {
                            print("Failed to toggle favorite: \(error)")
                        }
                    }) {
                        HStack {
                            Image(systemName: isFavorite ? "heart.slash" : "heart")
                            Text(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs)
                        }
                    }

                    if let artistId = track.artistId,
                       let artist = try? DatabaseManager.shared.read({ db in
                           try Artist.fetchOne(db, key: artistId)
                       }),
                       let allArtistTracks = try? DatabaseManager.shared.getTracksByArtistId(artistId) {
                        NavigationLink(destination: ArtistDetailScreenWrapper(artistName: artist.name, allTracks: allArtistTracks)) {
                            Label(Localized.showArtistPage, systemImage: "person.circle")
                        }
                    }

                    Button(action: {
                        showPlaylistDialog = true
                    }) {
                        Label(Localized.addToPlaylistEllipsis, systemImage: "rectangle.stack.badge.plus")
                    }

                    Button(action: {
                        showDeleteConfirmation = true
                    }) {
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
        .sheet(isPresented: $showPlaylistDialog) {
            PlaylistSelectionView(track: track)
                .accentColor(accentColor)
        }
        .alert(Localized.deleteFile, isPresented: $showDeleteConfirmation) {
            Button(Localized.delete, role: .destructive) {
                deleteFile()
            }
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
            artworkImage = await ArtworkManager.shared.getThumbnail(for: track)
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
            } catch {
                print("❌ Failed to remove from playlist: \(error)")
            }
        }
    }
}
