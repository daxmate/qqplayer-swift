//
//  MacSearchView.swift
//  QQPlayer
//
//  macOS search: sidebar-top search field + grouped results view
//  (歌曲 / 专辑 / 艺术家 / 播放列表) for the library content column.
//  QQPlayerMac target only — kept out of the iOS target via pbxproj
//  membership exceptions.
//

import SwiftUI

// MARK: - Search results model

/// Result buckets returned by the shared `DatabaseManager` search APIs.
struct MacSearchResults {
    var songs: [Track] = []
    var artists: [Artist] = []
    var albums: [Album] = []
    var playlists: [Playlist] = []

    var isEmpty: Bool {
        songs.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty
    }
}

// MARK: - Search field (sidebar top)

/// macOS-style search field: magnifier icon + text field + clear button.
struct MacSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("search_placeholder".localized, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("search_clear".localized)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.gray.opacity(0.15)))
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}

// MARK: - Search results (content column)

/// Grouped search results: 歌曲 / 专辑 / 艺术家 / 播放列表 sections in a List.
struct MacSearchResultsView: View {
    let results: MacSearchResults
    let activeTrackId: String?
    let isPlaying: Bool
    let artistNameResolver: (Track) -> String?
    let onPlaySong: (Track, [Track]) -> Void
    let onPlayAlbum: (Album, [Track]) -> Void
    let onPlayArtist: (Artist, [Track]) -> Void
    let onOpenPlaylist: (Playlist) -> Void

    @State private var selectedAlbum: Album?
    @State private var selectedArtist: Artist?
    @State private var albumTracks: [Track] = []
    @State private var artistTracks: [Track] = []
    @State private var showAlbumSheet = false
    @State private var showArtistSheet = false

    var body: some View {
        Group {
            if results.isEmpty {
                emptyView
            } else {
                List {
                    if !results.songs.isEmpty {
                        Section("search_section_songs".localized) {
                            ForEach(results.songs, id: \.stableId) { track in
                                MacSearchSongRow(
                                    track: track,
                                    artistName: artistNameResolver(track),
                                    isActive: track.stableId == activeTrackId,
                                    isPlaying: isPlaying,
                                    onPlay: { onPlaySong(track, results.songs) }
                                )
                            }
                        }
                    }

                    if !results.albums.isEmpty {
                        Section("search_section_albums".localized) {
                            ForEach(results.albums, id: \.id) { album in
                                MacSearchAlbumRow(album: album) { openAlbum(album) }
                            }
                        }
                    }

                    if !results.artists.isEmpty {
                        Section("search_section_artists".localized) {
                            ForEach(results.artists, id: \.id) { artist in
                                MacSearchArtistRow(artist: artist) { openArtist(artist) }
                            }
                        }
                    }

                    if !results.playlists.isEmpty {
                        Section("search_section_playlists".localized) {
                            ForEach(results.playlists, id: \.id) { playlist in
                                MacSearchPlaylistRow(playlist: playlist) { onOpenPlaylist(playlist) }
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAlbumSheet) {
            if let album = selectedAlbum {
                MacAlbumDetailSheet(
                    album: album,
                    tracks: albumTracks,
                    artistNameResolver: artistNameResolver,
                    onPlay: { onPlayAlbum(album, albumTracks) }
                )
            }
        }
        .sheet(isPresented: $showArtistSheet) {
            if let artist = selectedArtist {
                MacArtistDetailSheet(
                    artist: artist,
                    tracks: artistTracks,
                    artistNameResolver: artistNameResolver,
                    onPlay: { onPlayArtist(artist, artistTracks) }
                )
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("search_no_results".localized)
                .font(.title3)
            Text("search_no_results_hint".localized)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func openAlbum(_ album: Album) {
        do {
            albumTracks = try DatabaseManager.shared.getTracksByAlbumId(album.id ?? 0)
            selectedAlbum = album
            showAlbumSheet = true
        } catch {
            print("❌ macOS search openAlbum failed: \(error)")
        }
    }

    private func openArtist(_ artist: Artist) {
        do {
            artistTracks = try DatabaseManager.shared.getTracksByArtistId(artist.id ?? 0)
            selectedArtist = artist
            showArtistSheet = true
        } catch {
            print("❌ macOS search openArtist failed: \(error)")
        }
    }
}

// MARK: - Result rows

private struct MacSearchSongRow: View {
    let track: Track
    let artistName: String?
    let isActive: Bool
    let isPlaying: Bool
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 8) {
                Group {
                    if isActive {
                        Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                            .foregroundColor(.accentColor)
                    } else {
                        Image(systemName: "music.note")
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 16)

                Text(track.title)
                    .lineLimit(1)
                    .fontWeight(isActive ? .semibold : .regular)

                Spacer()

                if let artistName, !artistName.isEmpty {
                    Text(artistName)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Text(MacTimeFormat.format(duration(for: track)))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func duration(for track: Track) -> TimeInterval {
        guard let ms = track.durationMs else { return 0 }
        return Double(ms) / 1000.0
    }
}

private struct MacSearchAlbumRow: View {
    let album: Album
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                MacArtworkThumbnail(
                    track: MacArtworkResolver.representativeTrack(forAlbum: album),
                    size: 28,
                    cornerRadius: 4,
                    placeholderIcon: "square.stack"
                )

                Text(album.title)
                    .lineLimit(1)

                Spacer()

                if let albumArtist = album.albumArtist, !albumArtist.isEmpty {
                    Text(ArtistNameNormalizer.displayName(albumArtist))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MacSearchArtistRow: View {
    let artist: Artist
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "music.mic")
                    .foregroundColor(.secondary)
                    .frame(width: 16)

                Text(ArtistNameNormalizer.displayName(artist.name))
                    .lineLimit(1)

                Spacer()

                Text(String(format: "track_count".localized, artistTrackCount()))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func artistTrackCount() -> Int {
        (try? DatabaseManager.shared.getTracksByArtistId(artist.id ?? 0).count) ?? 0
    }
}

private struct MacSearchPlaylistRow: View {
    let playlist: Playlist
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                MacArtworkThumbnail(
                    track: MacArtworkResolver.representativeTrack(forPlaylist: playlist),
                    size: 28,
                    cornerRadius: 4,
                    placeholderIcon: "list.bullet.rectangle"
                )

                Text(playlist.title)
                    .lineLimit(1)

                Spacer()

                if let itemCount = try? DatabaseManager.shared.getPlaylistItems(playlistId: playlist.id ?? 0).count {
                    Text(String(format: "track_count".localized, itemCount))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
