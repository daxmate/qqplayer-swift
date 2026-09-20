import SwiftUI

// MARK: - Bulk Selection Components

struct BulkPlaylistSelectionView: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    let trackIds: [String]
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppCoordinator.self) private var appCoordinator
    @State private var playlists: [Playlist] = []
    @State private var showCreatePlaylist = false
    @State private var newPlaylistName = ""
    @State private var settings = DeleteSettings.load()

    var body: some View {
        NavigationView {
            VStack(spacing: DesignTokens.space20) {
                VStack(spacing: DesignTokens.space8) {
                    Text(Localized.addToPlaylist)
                        .font(.title2)
                        .fontWeight(.semibold)

                    Text(Localized.songsCountOnly(trackIds.count))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                if playlists.isEmpty {
                    VStack(spacing: DesignTokens.space16) {
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
                        ForEach(playlists, id: \.id) { playlist in
                            Button(action: {
                                addToPlaylist(playlist)
                            }) {
                                HStack {
                                    Image(systemName: "music.note.list")
                                        .foregroundColor(accentColor)

                                    Text(playlist.title)
                                        .foregroundColor(.primary)

                                    Spacer()

                                    Image(systemName: "plus.circle")
                                        .foregroundColor(accentColor)
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
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
        .onAppear {
            loadPlaylists()
        }
    }

    private func loadPlaylists() {
        do {
            playlists = try LibraryReads.playlists()
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

            // Automatically add the tracks to the new playlist
            if let playlistId = playlist.id {
                for trackId in trackIds {
                    try? appCoordinator.addToPlaylist(playlistId: playlistId, trackStableId: trackId)
                }
            }

            onComplete()
            dismiss()
        } catch {
            print("Failed to create playlist: \(error)")
        }
    }

    private func addToPlaylist(_ playlist: Playlist) {
        guard let playlistId = playlist.id else {
            print("Error: Playlist has no ID")
            return
        }

        // 循环内已是 try?，无抛错操作 → 去掉 do/catch（2026-08-30 警告清理）
        for trackId in trackIds {
            try? appCoordinator.addToPlaylist(playlistId: playlistId, trackStableId: trackId)
        }

        onComplete()
        dismiss()
    }
}
