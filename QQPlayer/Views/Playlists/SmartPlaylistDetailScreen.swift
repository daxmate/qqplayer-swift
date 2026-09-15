//
//  SmartPlaylistDetailScreen.swift
//  QQPlayer
//
//  Detail screens for automatic playlists (自动歌单):
//  - SmartPlaylistDetailScreen: track list for recentAdded/recentPlayed/
//    topPlayed; decade bucket list for decades (pushes SmartPlaylistDecadeScreen)
//  - SmartPlaylistDecadeScreen: one decade bucket's track list
//
//  Track rows reuse PlaylistTrackRowView (same as PlaylistDetailScreen) so the
//  playing highlight, artwork and context menu behave identically everywhere.
//

import SwiftUI

struct SmartPlaylistDetailScreen: View {
    let kind: SmartPlaylistKind

    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var tracks: [Track] = []
    @State private var buckets: [DecadeBucketInfo] = []
    @State private var artistNameCache: [Int64: String] = [:]
    @State private var artistDisplayNameCache: [String: String] = [:]
    @State private var isLoading = true
    @State private var loadError: String?

    private var playerEngine: PlayerEngine {
        appCoordinator.playerEngine
    }

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .playlistDetail)

            Group {
                if let loadError {
                    SmartPlaylistErrorView(message: loadError) {
                        loadData()
                    }
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if kind == .decades {
                    decadeBucketList
                } else if tracks.isEmpty {
                    SmartPlaylistEmptyView(message: emptyMessage)
                } else {
                    SmartPlaylistTrackList(
                        tracks: tracks,
                        artistNameCache: artistNameCache,
                        artistDisplayNameCache: artistDisplayNameCache
                    ) { track, queue in
                        Task {
                            await playerEngine.playTrack(track, queue: queue)
                        }
                    }
                }
            }
        }
        .navigationTitle(Localized.smartPlaylistTitle(kind))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadData()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            loadData()
        }
    }

    // MARK: - Content

    private var decadeBucketList: some View {
        List {
            Section {
                ForEach(buckets, id: \.key) { bucket in
                    NavigationLink {
                        SmartPlaylistDecadeScreen(key: bucket.key, label: bucket.label)
                    } label: {
                        HStack {
                            Text(bucket.label)
                                .font(.body)
                            Spacer()
                            Text(Localized.smartSongsCount(bucket.count))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(PlainListStyle())
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 100, for: .scrollContent)
    }

    private var emptyMessage: String {
        switch kind {
        case .recentPlayed: return Localized.smartEmptyRecentPlayed
        case .topPlayed: return Localized.smartEmptyTopPlayed
        default: return Localized.noSongsFound
        }
    }

    // MARK: - Data Loading

    private func loadData() {
        isLoading = true
        loadError = nil
        do {
            switch kind {
            case .recentAdded:
                tracks = try SmartPlaylistStore.recentAddedTracks()
            case .recentPlayed:
                tracks = try SmartPlaylistStore.recentPlayedTracks()
            case .topPlayed:
                tracks = try SmartPlaylistStore.topPlayedTracks().map { $0.track }
            case .decades:
                buckets = try SmartPlaylistStore.decadeBuckets()
            }
            let cache = SmartPlaylistArtistCache.load(for: tracks)
            artistNameCache = cache.byId
            artistDisplayNameCache = cache.byStableId
            isLoading = false
        } catch {
            loadError = Localized.smartLoadFailed
            isLoading = false
        }
    }
}

/// One decade bucket's track list, pushed from the decades screen.
struct SmartPlaylistDecadeScreen: View {
    let key: String
    let label: String

    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var tracks: [Track] = []
    @State private var artistNameCache: [Int64: String] = [:]
    @State private var artistDisplayNameCache: [String: String] = [:]
    @State private var isLoading = true
    @State private var loadError: String?

    private var playerEngine: PlayerEngine {
        appCoordinator.playerEngine
    }

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .playlistDetail)

            Group {
                if let loadError {
                    SmartPlaylistErrorView(message: loadError) {
                        loadTracks()
                    }
                } else if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if tracks.isEmpty {
                    SmartPlaylistEmptyView(message: Localized.smartEmptyDecade)
                } else {
                    SmartPlaylistTrackList(
                        tracks: tracks,
                        artistNameCache: artistNameCache,
                        artistDisplayNameCache: artistDisplayNameCache
                    ) { track, queue in
                        Task {
                            await playerEngine.playTrack(track, queue: queue)
                        }
                    }
                }
            }
        }
        .navigationTitle(label)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadTracks()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            loadTracks()
        }
    }

    private func loadTracks() {
        isLoading = true
        loadError = nil
        do {
            tracks = try SmartPlaylistStore.tracks(inDecade: key)
            let cache = SmartPlaylistArtistCache.load(for: tracks)
            artistNameCache = cache.byId
            artistDisplayNameCache = cache.byStableId
            isLoading = false
        } catch {
            loadError = Localized.smartLoadFailed
            isLoading = false
        }
    }
}

/// Empty state shared by the smart playlist screens.
struct SmartPlaylistEmptyView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "music.note")
                .font(.system(size: DesignTokens.font40))
                .foregroundColor(.secondary)

            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Error state shared by the smart playlist screens, with a retry button.
struct SmartPlaylistErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: DesignTokens.font40))
                .foregroundColor(.secondary)

            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button(Localized.retry, action: onRetry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Track list reusing PlaylistTrackRowView, shared by every smart track screen.
struct SmartPlaylistTrackList: View {
    let tracks: [Track]
    let artistNameCache: [Int64: String]
    let artistDisplayNameCache: [String: String]
    let onPlay: (Track, [Track]) -> Void

    var body: some View {
        List {
            Section {
                ForEach(tracks.uniquelyIdentifiedRows(), id: \.rowId) { row in
                    let index = row.index
                    let track = row.track
                    PlaylistTrackRowView(
                        track: track,
                        playlist: nil,
                        isEditMode: false,
                        artistName: artistDisplayNameCache[track.stableId] ?? track.artistId.flatMap { artistNameCache[$0] },
                        onTap: {
                            onPlay(track, tracks)
                        }
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(index < tracks.count - 1 ? .visible : .hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
            }
        }
        .listStyle(PlainListStyle())
        .scrollContentBackground(.hidden)
        .contentMargins(.bottom, 100, for: .scrollContent)
    }
}

/// Artist display-name resolution shared by the smart playlist screens
/// (简繁归一 via ArtistNameNormalizer inside DatabaseManager).
enum SmartPlaylistArtistCache {
    static func load(for tracks: [Track]) -> (byId: [Int64: String], byStableId: [String: String]) {
        do {
            let byId = try DatabaseManager.shared.getAllArtistNamesById()
            let fallbackArtistIds = tracks.reduce(into: [String: Int64]()) { result, track in
                if let artistId = track.artistId {
                    result[track.stableId] = artistId
                }
            }
            let byStableId = try DatabaseManager.shared.getArtistDisplayNames(
                forTrackStableIds: tracks.map(\.stableId),
                fallbackArtistIdsByStableId: fallbackArtistIds
            )
            return (byId, byStableId)
        } catch {
            print("Failed to load smart playlist artist cache: \(error)")
            return ([:], [:])
        }
    }
}
