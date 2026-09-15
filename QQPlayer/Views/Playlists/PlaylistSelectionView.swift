import GRDB
import SwiftUI
struct PlaylistSelectionView: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var playlists: [Playlist] = []
    /// 本曲所在歌单 id 集合（loadPlaylists 时一次性查出，替代排序比较器/每行逐次同步 DB 读）
    @State private var playlistsContainingTrack: Set<Int64> = []
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var showDeleteConfirmation = false
    @State private var playlistToDelete: Playlist?
    @State private var settings = DeleteSettings.load()

    var sortedPlaylists: [Playlist] {
        // Sort playlists: first those where song is NOT in playlist (sorted by most recent played),
        // then those where song IS in playlist (also sorted by most recent played)
        return playlists.sorted { playlist1, playlist2 in
            let isInPlaylist1 = playlistsContainingTrack.contains(playlist1.id ?? 0)
            let isInPlaylist2 = playlistsContainingTrack.contains(playlist2.id ?? 0)

            // If one is not in playlist and the other is, prioritize the one not in playlist
            if !isInPlaylist1 && isInPlaylist2 {
                return true
            } else if isInPlaylist1 && !isInPlaylist2 {
                return false
            } else {
                // Both are in same category, sort by most recent played (lastPlayedAt desc, then by title)
                if playlist1.lastPlayedAt != playlist2.lastPlayedAt {
                    return playlist1.lastPlayedAt > playlist2.lastPlayedAt
                } else {
                    return playlist1.title.localizedCaseInsensitiveCompare(playlist2.title) == .orderedAscending
                }
            }
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Text(Localized.addToPlaylist)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(track.displayTitle)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if playlists.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "music.note.list")
                            .font(.system(size: DesignTokens.font40))
                            .foregroundColor(.secondary)

                        Text(Localized.noPlaylistsYet)
                            .font(.headline)

                        Text(Localized.createFirstPlaylist)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(sortedPlaylists, id: \.id) { playlist in
                            let isInPlaylist = playlistsContainingTrack.contains(playlist.id ?? 0)

                            HStack(spacing: 8) {
                                // Main clickable area for add/remove
                                HStack {
                                    Image(systemName: "music.note.list")
                                        .foregroundColor(accentColor)

                                    Text(playlist.title)
                                        .foregroundColor(.primary)

                                    Spacer()

                                    // Status indicator (not clickable, just visual feedback)
                                    if isInPlaylist {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                    } else {
                                        Image(systemName: "plus.circle")
                                            .foregroundColor(accentColor)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if isInPlaylist {
                                        removeFromPlaylist(playlist)
                                    } else {
                                        addToPlaylist(playlist)
                                    }
                                }

                                // Separator line
                                Divider()
                                    .frame(height: 30)

                                // Delete button - clearly separated
                                Button(action: {
                                    playlistToDelete = playlist
                                    showDeleteConfirmation = true
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                        .frame(width: 32, height: 32)
                                        .background(Color.red.opacity(0.1))
                                        .cornerRadius(DesignTokens.radius8)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Button(Localized.createNewPlaylist) {
                    showCreatePlaylist = true
                }
                .buttonStyle(.borderedProminent)
                .padding()
            }
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Localized.cancel) {
                        dismiss()
                    }
                }
            }
        }
        .alert(Localized.createPlaylist, isPresented: $showCreatePlaylist) {
            TextField(Localized.playlistNamePlaceholder, text: $newPlaylistName)
            Button(Localized.create) {
                createPlaylist()
            }
            .disabled(newPlaylistName.isEmpty)
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            Text(Localized.enterPlaylistName)
        }
        .alert(Localized.deletePlaylist, isPresented: $showDeleteConfirmation) {
            Button(Localized.delete, role: .destructive) {
                deletePlaylistInSelection()
            }
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            if let playlist = playlistToDelete {
                Text(Localized.deletePlaylistConfirmation(playlist.title))
            }
        }
        .onAppear {
            loadPlaylists()
        }
    }

    private func loadPlaylists() {
        do {
            playlists = try DatabaseManager.shared.getAllPlaylists()
            // 一次性查出本曲所在歌单 id 集合（替代排序比较器/ForEach 内逐次同步 DB 读）
            let containingIds = try DatabaseManager.shared.read { db in
                try PlaylistItem
                    .filter(Column("track_stable_id") == track.stableId)
                    .fetchAll(db)
                    .map(\.playlistId)
            }
            playlistsContainingTrack = Set(containingIds)
        } catch {
            print("Failed to load playlists: \(error)")
        }
    }

    private func createPlaylist() {
        guard !newPlaylistName.isEmpty else { return }

        do {
            let playlist = try appCoordinator.createPlaylist(title: newPlaylistName)
            playlists.append(playlist)
            newPlaylistName = ""

            // Automatically add the track to the new playlist
            guard let playlistId = playlist.id else {
                print("Error: Created playlist has no ID")
                return
            }
            try appCoordinator.addToPlaylist(playlistId: playlistId, trackStableId: track.stableId)
            dismiss()
        } catch {
            print("Failed to create playlist: \(error)")
        }
    }

    private func addToPlaylist(_ playlist: Playlist) {
        do {
            guard let playlistId = playlist.id else {
                print("Error: Playlist has no ID")
                return
            }
            try appCoordinator.addToPlaylist(playlistId: playlistId, trackStableId: track.stableId)
            dismiss()
        } catch {
            print("Failed to add to playlist: \(error)")
        }
    }

    private func removeFromPlaylist(_ playlist: Playlist) {
        do {
            guard let playlistId = playlist.id else {
                print("Error: Playlist has no ID")
                return
            }
            try appCoordinator.removeFromPlaylist(playlistId: playlistId, trackStableId: track.stableId)
            dismiss()
        } catch {
            print("Failed to remove from playlist: \(error)")
        }
    }

    private func deletePlaylistInSelection() {
        guard let playlist = playlistToDelete,
              let playlistId = playlist.id else { return }

        do {
            try appCoordinator.deletePlaylist(playlistId: playlistId)
            playlists.removeAll { $0.id == playlistId }
            playlistToDelete = nil
        } catch {
            print("Failed to delete playlist: \(error)")
        }
    }
}
