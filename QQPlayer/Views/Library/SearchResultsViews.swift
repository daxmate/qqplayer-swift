//
//  SearchResultsViews.swift
//  QQPlayer
//
//  搜索结果**结果页主体**：`SearchCategory`（分类枚举）、`SearchResults`（结果集）、
//  `SearchResultsView`（按分类分区装配歌曲 / 专辑 / 歌手 / 歌单）。
//  行视图按职责分片（2026-09-21 拆分，纯搬家、无逻辑变更）：
//    · Views/Library/SearchResultsViews+SongRow.swift     — 歌曲行（滑动操作 + 右键菜单）
//    · Views/Library/SearchResultsViews+ArtistRows.swift  — 歌手行 + 歌手专辑横滑
//    · Views/Library/SearchResultsViews+AlbumRow.swift    — 专辑行
//    · Views/Library/SearchResultsViews+PlaylistRow.swift — 歌单行

import SwiftUI

enum SearchCategory: String, CaseIterable {
    case all = "All"
    case songs = "Songs"
    case artists = "Artists"
    case albums = "Albums"
    case playlists = "Playlists"

    var localizedString: String {
        switch self {
        case .all: return Localized.all
        case .songs: return Localized.songs
        case .artists: return Localized.artists
        case .albums: return Localized.albums
        case .playlists: return Localized.playlists
        }
    }
}
struct SearchResults {
    let songs: [Track]
    let artists: [Artist]
    let albums: [Album]
    let playlists: [Playlist]

    init(songs: [Track] = [], artists: [Artist] = [], albums: [Album] = [], playlists: [Playlist] = []) {
        self.songs = songs
        self.artists = artists
        self.albums = albums
        self.playlists = playlists
    }

    var isEmpty: Bool {
        songs.isEmpty && artists.isEmpty && albums.isEmpty && playlists.isEmpty
    }
}

struct SearchResultsView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.appAccentColor) private var accentColor // App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    let results: SearchResults
    let selectedCategory: SearchCategory
    let allTracks: [Track]
    /// 关闭搜索 sheet（同步发起，不等收起动画）：`dismiss()` 本身不提供"已收起"回调；修前声明成
    /// `() async -> Void` + `await` 是假等待——需要"真等待"的地方改用状态驱动的导航（本仓既有做法）。
    let onDismiss: () -> Void
    let onNavigateToArtist: (Artist, [Track]) -> Void
    let onNavigateToAlbum: (Album, [Track]) -> Void
    let onNavigateToPlaylist: (Playlist) -> Void
    @State private var settings = DeleteSettings.load()
    @State private var artistNameCache: [Int64: String] = [:]
    @State private var artistDisplayNameCache: [String: String] = [:]

    private func loadArtistCache() {
        do {
            artistNameCache = try LibraryReads.artistNamesById()
            let fallbackArtistIds = results.songs.reduce(into: [String: Int64]()) { result, track in
                if let artistId = track.artistId {
                    result[track.stableId] = artistId
                }
            }
            artistDisplayNameCache = try LibraryReads.artistDisplayNames(
                forTrackStableIds: results.songs.map(\.stableId),
                fallbackArtistIdsByStableId: fallbackArtistIds
            )
        } catch {
            AppLog.error(.ui, "Failed to load search artist cache: \(error)")
        }
    }

    var body: some View {
        if results.isEmpty {
            VStack(spacing: DesignTokens.space16) {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: DesignTokens.font40))
                    .foregroundColor(.secondary)

                Text(Localized.noResultsFound)
                    .font(.headline)

                Text(Localized.tryDifferentKeywords)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: DesignTokens.space16) {
                    // Songs
                    if selectedCategory == .all || selectedCategory == .songs, !results.songs.isEmpty {
                        VStack(alignment: .leading, spacing: DesignTokens.space8) {
                            Text(Localized.songs)
                                .font(.title3)
                                .fontWeight(.bold)
                                .padding(.horizontal, DesignTokens.space16)

                            ForEach(results.songs, id: \.stableId) { track in
                                SearchSongRowView(
                                    track: track,
                                    allTracks: allTracks,
                                    artistName: artistDisplayNameCache[track.stableId] ?? track.artistId.flatMap { artistNameCache[$0] },
                                    onDismiss: onDismiss
                                )
                                .shadow(color: accentColor.opacity(0.15), radius: 4, x: 0, y: 2)
                                .padding(.horizontal, DesignTokens.space16)
                            }
                        }
                    }

                    // Albums (also shown when Artists category is selected, grouped by artist)
                    if selectedCategory == .all || selectedCategory == .albums, !results.albums.isEmpty {
                        VStack(alignment: .leading, spacing: DesignTokens.space8) {
                            Text(Localized.albums)
                                .font(.title3)
                                .fontWeight(.bold)
                                .padding(.horizontal, DesignTokens.space16)

                            ForEach(results.albums, id: \.id) { album in
                                SearchAlbumRowView(
                                    album: album,
                                    albumArtistName: album.albumArtist.flatMap { ArtistNameNormalizer.displayName($0) } ?? album.artistId.flatMap { artistNameCache[$0] },
                                    onDismiss: onDismiss,
                                    onNavigate: onNavigateToAlbum
                                )
                                .background(
                                    RoundedRectangle(cornerRadius: DesignTokens.radius12)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.7)
                                )
                                .shadow(color: accentColor.opacity(0.15), radius: 4, x: 0, y: 2)
                                .padding(.horizontal, DesignTokens.space16)
                            }
                        }
                    }

                    // Artists - show artist row + their albums underneath
                    if selectedCategory == .all || selectedCategory == .artists, !results.artists.isEmpty {
                        VStack(alignment: .leading, spacing: DesignTokens.space8) {
                            Text(Localized.artists)
                                .font(.title3)
                                .fontWeight(.bold)
                                .padding(.horizontal, DesignTokens.space16)

                            ForEach(ArtistNameNormalizer.groupedArtists(results.artists), id: \.id) { group in
                                VStack(alignment: .leading, spacing: DesignTokens.space0) {
                                    SearchArtistRowView(
                                        artist: group.primaryArtist,
                                        onDismiss: onDismiss,
                                        onNavigate: onNavigateToArtist
                                    )
                                    .background(
                                        RoundedRectangle(cornerRadius: DesignTokens.radius12)
                                            .fill(.ultraThinMaterial)
                                            .opacity(0.7)
                                    )
                                    .shadow(color: accentColor.opacity(0.15), radius: 4, x: 0, y: 2)
                                    .padding(.horizontal, DesignTokens.space16)

                                    // Show this artist's albums below
                                    SearchArtistAlbumsRow(
                                        artist: group.primaryArtist,
                                        onDismiss: onDismiss,
                                        onNavigateToAlbum: onNavigateToAlbum
                                    )
                                }
                                .padding(.bottom, DesignTokens.space4)
                            }
                        }
                    }

                    // Playlists
                    if selectedCategory == .all || selectedCategory == .playlists, !results.playlists.isEmpty {
                        VStack(alignment: .leading, spacing: DesignTokens.space8) {
                            Text(Localized.playlists)
                                .font(.title3)
                                .fontWeight(.bold)
                                .padding(.horizontal, DesignTokens.space16)

                            ForEach(results.playlists, id: \.id) { playlist in
                                SearchPlaylistRowView(
                                    playlist: playlist,
                                    onDismiss: onDismiss,
                                    onNavigate: onNavigateToPlaylist
                                )
                                .background(
                                    RoundedRectangle(cornerRadius: DesignTokens.radius12)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.7)
                                )
                                .shadow(color: accentColor.opacity(0.15), radius: 4, x: 0, y: 2)
                                .padding(.horizontal, DesignTokens.space16)
                            }
                        }
                    }
                }
                .padding(.vertical, DesignTokens.space16)
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 100) // Space for mini player
            }
            .onAppear {
                if artistNameCache.isEmpty {
                    loadArtistCache()
                }
                let visibleIds = Array(results.songs.prefix(20)).map { $0.stableId }
                services.artworkManager.updateVisibleArtworkWindow(visibleTrackIds: visibleIds)
            }
            .onChange(of: results.songs.map(\.stableId)) { _, _ in
                loadArtistCache()
            }
        }
    }
}
