//
//  MacPlaylistDetailSheet.swift
//  QQPlayer
//
//  macOS manual playlist detail: track list with double-click playback
//  (queue = playlist tracks), play-all, rename (alert), delete (confirmation
//  alert), and per-track context actions (add to playlist / remove from
//  playlist) via MacTrackListView's `playlistId` hook. QQPlayerMac target only.
//

import SwiftUI

struct MacPlaylistDetailSheet: View {
    let playlist: Playlist
    /// Plays the whole playlist (queue = playlist tracks), provided by the host.
    let onPlayAll: () -> Void

    @StateObject private var player = PlayerEngine.shared
    @Environment(\.dismiss) private var dismiss

    @State private var currentTitle: String
    @State private var tracks: [Track] = []
    @State private var isLoading = true
    @State private var showRenameAlert = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false

    init(playlist: Playlist, onPlayAll: @escaping () -> Void) {
        self.playlist = playlist
        self.onPlayAll = onPlayAll
        _currentTitle = State(initialValue: playlist.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding()
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { loadTracks() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PlaylistsChanged"))) { _ in
            loadTracks()
        }
        .alert("playlist_manage_rename".localized, isPresented: $showRenameAlert) {
            TextField("playlist_name_placeholder".localized, text: $renameText)
            Button("save".localized) { renamePlaylist() }
            Button("cancel".localized, role: .cancel) {}
        }
        .alert("delete_playlist".localized, isPresented: $showDeleteConfirm) {
            Button("delete".localized, role: .destructive) { deletePlaylist() }
            Button("cancel".localized, role: .cancel) {}
        } message: {
            Text(Localized.deletePlaylistConfirmation(currentTitle))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            MacArtworkThumbnail(
                track: MacArtworkResolver.representativeTrack(forPlaylist: playlist),
                size: 56,
                cornerRadius: 8,
                placeholderIcon: "list.bullet.rectangle"
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(currentTitle)
                    .font(.title2)
                    .fontWeight(.bold)
                    .lineLimit(1)
                Text(String(format: "track_count".localized, tracks.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("playlist_manage_play_all".localized) { onPlayAll() }
                .keyboardShortcut(.return)
            Button("playlist_manage_rename".localized) {
                renameText = currentTitle
                showRenameAlert = true
            }
            Button(Localized.deletePlaylist, role: .destructive) {
                showDeleteConfirm = true
            }
            Button("close".localized) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if tracks.isEmpty {
            MacSmartPlaylistEmptyView(message: "playlist_manage_empty".localized, retry: nil)
        } else {
            MacTrackListView(
                tracks: tracks,
                activeTrackId: player.currentTrack?.stableId,
                isPlaying: player.isPlaying,
                artistNameResolver: resolveArtistName,
                onPlay: { track, queue in play(track, queue: queue) },
                onSelect: { _ in },
                playlistId: playlist.id,
                onPlayNext: { player.insertNext($0) }
            )
        }
    }

    // MARK: - Actions

    private func play(_ track: Track, queue: [Track]) {
        Task {
            await player.playTrack(track, queue: queue)
        }
    }

    private func renamePlaylist() {
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        do {
            try DatabaseManager.shared.renamePlaylist(playlistId: playlist.id ?? 0, newTitle: title)
            currentTitle = title
            NotificationCenter.default.post(name: NSNotification.Name("PlaylistsChanged"), object: nil)
        } catch {
            print("❌ renamePlaylist failed: \(error)")
        }
    }

    private func deletePlaylist() {
        do {
            try DatabaseManager.shared.deletePlaylist(playlistId: playlist.id ?? 0)
            NotificationCenter.default.post(name: NSNotification.Name("PlaylistsChanged"), object: nil)
            dismiss()
        } catch {
            print("❌ deletePlaylist failed: \(error)")
        }
    }

    private func loadTracks() {
        do {
            let items = try DatabaseManager.shared.getPlaylistItems(playlistId: playlist.id ?? 0)
            let stableIds = items.map { $0.trackStableId }
            tracks = try DatabaseManager.shared.getTracksByStableIdsPreservingOrder(stableIds)
            isLoading = false
        } catch {
            print("❌ MacPlaylistDetailSheet loadTracks failed: \(error)")
            isLoading = false
        }
    }

    private func resolveArtistName(for track: Track) -> String? {
        try? DatabaseManager.shared.getArtistDisplayName(
            forTrackStableId: track.stableId,
            fallbackArtistId: track.artistId
        )
    }
}
