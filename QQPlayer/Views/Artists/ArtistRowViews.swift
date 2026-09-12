import GRDB
import SwiftUI
struct ArtistTrackRowView: View {
    let track: Track
    let onTap: () -> Void
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var showDeleteConfirmation = false
    @State private var deleteSettings = DeleteSettings.load()
    @State private var artworkImage: UIImage?
    @State private var isMenuInteracting = false

    var body: some View {
        HStack {
            // Album artwork thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 60, height: 60)

                if let image = artworkImage {
                    Image(uiImage: image)
                        .resizable().scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "music.note")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.title3)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if let duration = track.durationMs {
                    Text(formatDuration(duration))
                        .font(.body)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

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
                            .foregroundColor(isFavorite ? .red : .primary)
                        Text(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs)
                            .foregroundColor(.primary)
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
                    .frame(width: 30, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        isMenuInteracting = true
                    }
                    .onEnded { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            isMenuInteracting = false
                        }
                    }
            )
        }
        .frame(height: 80)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            // isPressed 已于 2026-09-12 审计 B5 删除：它只写不读，按下反馈从未生效（死状态）
            if !isMenuInteracting {
                onTap()
            }
        }
        .onAppear {
            checkFavoriteStatus()
            loadArtwork()
        }
        .sheet(isPresented: $showPlaylistDialog) {
            PlaylistSelectionView(track: track)
                .accentColor(deleteSettings.backgroundColorChoice.color)
        }
        .alert(Localized.deleteFile, isPresented: $showDeleteConfirmation) {
            Button(Localized.delete, role: .destructive) {
                deleteFile()
            }
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            Text(Localized.deleteFileConfirmation(track.title))
        }
    }

    private func checkFavoriteStatus() {
        do {
            isFavorite = try DatabaseManager.shared.isFavorite(trackStableId: track.stableId)
        } catch {
            print("Failed to check favorite status: \(error)")
        }
    }

    private func loadArtwork() {
        Task {
            artworkImage = await ArtworkManager.shared.getThumbnail(for: track)
        }
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func deleteFile() {
        Task {
            do {
                let settings = DeleteSettings.load()
                if settings.deleteFromLibraryOnly {
                    DeleteSettings.addExcludedTrack(track.stableId)
                } else {
                    do {
                        try FileManager.default.removeItem(at: URL(fileURLWithPath: track.path))
                    } catch {
                        print("⚠️ Could not remove file from disk: \(error.localizedDescription)")
                    }
                }

                try DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
                NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            } catch {
                print("❌ Failed to delete track: \(error)")
            }
        }
    }
}

struct ArtistAlbumCardView: View {
    let album: Album
    let tracks: [Track]
    @State private var artworkImage: UIImage?

    private var albumTracks: [Track] {
        tracks.filter { $0.albumId == album.id }
    }

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .frame(width: 120, height: 120)
                .overlay {
                    if let image = artworkImage {
                        Image(uiImage: image)
                            .resizable().scaledToFill()
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }
                }

            Text(album.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 120)
                .frame(minHeight: 32) // Min height for 2 lines alignment
                .foregroundColor(.primary)
        }
        .onAppear {
            loadAlbumArtwork()
        }
    }

    private func loadAlbumArtwork() {
        guard let firstTrack = albumTracks.first else { return }

        Task {
            let image = await ArtworkManager.shared.getThumbnail(for: firstTrack, maxPixelSize: 384)
            await MainActor.run {
                self.artworkImage = image
            }
        }
    }
}
