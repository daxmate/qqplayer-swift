//
//  MacSmartPlaylistViews.swift
//  QQPlayer
//
//  macOS automatic playlists (自动歌单): a pinned card strip at the top of
//  the playlist page plus a detail sheet (track list for recentAdded /
//  recentPlayed / topPlayed; decade bucket list that pushes into a per-decade
//  track list inside the same sheet). QQPlayerMac target only.
//
//  Icon/subtitle decisions mirror the iOS SmartPlaylistUILogic so both
//  platforms stay visually consistent; the iOS file is not compiled into the
//  Mac target, hence the local copy.
//

import SwiftUI

// MARK: - Card strip

/// Pure UI decisions for the pinned cards (mirrors iOS SmartPlaylistUILogic).
enum MacSmartPlaylistUILogic {
    /// SF Symbol shown on the pinned card for each kind.
    static func iconName(for kind: SmartPlaylistKind) -> String {
        switch kind {
        case .recentAdded: return "clock"
        case .recentPlayed: return "history"
        case .topPlayed: return "flame"
        case .decades: return "calendar"
        }
    }

    /// Card badge: song count for track-based kinds, decade count for decades.
    /// Formatting is injected so the decision stays testable.
    static func cardSubtitle(
        kind: SmartPlaylistKind,
        count: Int,
        songsFormat: (Int) -> String,
        decadesFormat: (Int) -> String
    ) -> String {
        switch kind {
        case .decades:
            return decadesFormat(count)
        default:
            return songsFormat(count)
        }
    }
}

/// Horizontal pinned-card strip (4 cards) at the top of the playlist page.
/// Artwork collage is intentionally not rendered here — the macOS artwork
/// pipeline is not wired up yet (album/artist pages use placeholder icons
/// too); the card keeps the MacAlbumGridView placeholder style.
struct MacSmartPlaylistCardStrip: View {
    let cards: [SmartPlaylistCardInfo]
    let onSelect: (SmartPlaylistKind) -> Void

    private let cardWidth: CGFloat = 116

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(cards, id: \.kind) { info in
                    Button {
                        onSelect(info.kind)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.gray.opacity(0.18))
                                .frame(width: cardWidth, height: cardWidth)
                                .overlay(
                                    Image(systemName: MacSmartPlaylistUILogic.iconName(for: info.kind))
                                        .font(.system(size: 30))
                                        .foregroundColor(.secondary)
                                )
                            Text(Localized.smartPlaylistTitle(info.kind))
                                .font(.callout)
                                .fontWeight(.medium)
                                .lineLimit(1)
                            Text(MacSmartPlaylistUILogic.cardSubtitle(
                                kind: info.kind,
                                count: info.count,
                                songsFormat: Localized.smartSongsCount,
                                decadesFormat: Localized.smartDecadeCount
                            ))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        }
                        .frame(width: cardWidth, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(Localized.smartPlaylistTitle(info.kind))
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 12)
    }
}

// MARK: - Detail sheet

/// Detail sheet for one automatic playlist. The decades kind first shows the
/// bucket list; tapping a bucket swaps the content to that decade's tracks
/// (back button in the header returns to the bucket list).
struct MacSmartPlaylistDetailSheet: View {
    let kind: SmartPlaylistKind

    @StateObject private var player = PlayerEngine.shared
    @Environment(\.dismiss) private var dismiss

    @State private var tracks: [Track] = []
    @State private var buckets: [DecadeBucketInfo] = []
    @State private var selectedBucket: DecadeBucketInfo?
    @State private var bucketTracks: [Track] = []
    @State private var isLoading = true
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding()
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { loadData() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if selectedBucket != nil {
                Button {
                    self.selectedBucket = nil
                } label: {
                    Label("back".localized, systemImage: "chevron.left")
                }
            }
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .lineLimit(1)
            Spacer()
            Button("close".localized) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var title: String {
        if let selectedBucket {
            return selectedBucket.label
        }
        return Localized.smartPlaylistTitle(kind)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let loadError {
            MacSmartPlaylistEmptyView(message: loadError, systemImage: "exclamationmark.triangle", retry: { loadData() })
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if kind == .decades {
            if selectedBucket != nil {
                bucketTrackList
            } else {
                decadeBucketList
            }
        } else if tracks.isEmpty {
            MacSmartPlaylistEmptyView(message: emptyMessage, retry: nil)
        } else {
            trackList(tracks)
        }
    }

    private var decadeBucketList: some View {
        List(buckets, id: \.key) { bucket in
            Button {
                selectedBucket = bucket
                loadBucketTracks(bucket)
            } label: {
                HStack {
                    Text(bucket.label)
                        .lineLimit(1)
                    Spacer()
                    Text(Localized.smartSongsCount(bucket.count))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var bucketTrackList: some View {
        if bucketTracks.isEmpty {
            MacSmartPlaylistEmptyView(message: Localized.smartEmptyDecade, retry: nil)
        } else {
            trackList(bucketTracks)
        }
    }

    private func trackList(_ queue: [Track]) -> some View {
        MacTrackListView(
            tracks: queue,
            activeTrackId: player.currentTrack?.stableId,
            isPlaying: player.isPlaying,
            artistNameResolver: resolveArtistName,
            onPlay: { track in play(track, queue: queue) },
            onSelect: { _ in }
        )
    }

    private var emptyMessage: String {
        switch kind {
        case .recentPlayed: return Localized.smartEmptyRecentPlayed
        case .topPlayed: return Localized.smartEmptyTopPlayed
        default: return Localized.noSongsFound
        }
    }

    // MARK: Data

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
                tracks = try SmartPlaylistStore.topPlayedTracks().map(\.track)
            case .decades:
                buckets = try SmartPlaylistStore.decadeBuckets()
            }
            isLoading = false
        } catch {
            loadError = Localized.smartLoadFailed
            isLoading = false
        }
    }

    private func loadBucketTracks(_ bucket: DecadeBucketInfo) {
        do {
            bucketTracks = try SmartPlaylistStore.tracks(inDecade: bucket.key)
        } catch {
            loadError = Localized.smartLoadFailed
        }
    }

    private func play(_ track: Track, queue: [Track]) {
        Task {
            await player.playTrack(track, queue: queue)
        }
    }

    private func resolveArtistName(for track: Track) -> String? {
        try? DatabaseManager.shared.getArtistDisplayName(
            forTrackStableId: track.stableId,
            fallbackArtistId: track.artistId
        )
    }
}

/// Empty/error state shared by the automatic-playlist screens.
struct MacSmartPlaylistEmptyView: View {
    let message: String
    var systemImage: String = "music.note"
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if let retry {
                Button("retry".localized, action: retry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
