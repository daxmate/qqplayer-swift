import Combine
import GRDB
import SwiftUI

// MARK: - Search View

struct SearchView: View {
    let allTracks: [Track]
    let onNavigateToArtist: (Artist, [Track]) -> Void
    let onNavigateToAlbum: (Album, [Track]) -> Void
    let onNavigateToPlaylist: (Playlist) -> Void
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var selectedCategory = SearchCategory.all
    @State private var settings = DeleteSettings.load()
    @FocusState private var isSearchFocused: Bool
    @State private var debounceTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?
    @State private var searchResults = SearchResults()
    @State private var isSearching = false

    private func performSearch(query: String) {
        // Cancel any existing search task
        searchTask?.cancel()

        guard !query.isEmpty else {
            searchResults = SearchResults()
            isSearching = false
            return
        }

        isSearching = true

        searchTask = Task {
            // Normalize query for better matching
            let normalizedQuery = query
                .lowercased()
                .folding(options: .diacriticInsensitive, locale: .current)

            // Run database queries on background thread
            let results = await Task.detached(priority: .userInitiated) {
                var songs: [Track] = []
                var artists: [Artist] = []
                var albums: [Album] = []
                var playlists: [Playlist] = []

                do {
                    // Use optimized database-level search
                    songs = try DatabaseManager.shared.searchTracks(query: normalizedQuery, limit: 50)
                    artists = try DatabaseManager.shared.searchArtists(query: normalizedQuery, limit: 20)
                    albums = try DatabaseManager.shared.searchAlbums(query: normalizedQuery, limit: 30)
                    playlists = try DatabaseManager.shared.searchPlaylists(query: normalizedQuery, limit: 15)

                    // Also include songs and albums from matched artists
                    let matchedArtistIds = artists.compactMap { $0.id }
                    if !matchedArtistIds.isEmpty {
                        let existingSongIds = Set(songs.map { $0.stableId })
                        let existingAlbumIds = Set(albums.compactMap { $0.id })

                        for artistId in matchedArtistIds {
                            let artistTracks = try DatabaseManager.shared.getTracksByArtistId(artistId)
                            for track in artistTracks where !existingSongIds.contains(track.stableId) {
                                songs.append(track)
                            }

                            let artistAlbums = try DatabaseManager.shared.getAlbumsByArtistId(artistId)
                            for album in artistAlbums {
                                guard let albumId = album.id, !existingAlbumIds.contains(albumId) else { continue }
                                albums.append(album)
                            }
                        }
                    }
                } catch {
                    print("Search error: \(error)")
                }

                return SearchResults(
                    songs: songs,
                    artists: artists,
                    albums: albums,
                    playlists: playlists
                )
            }.value

            // Check if task was cancelled
            guard !Task.isCancelled else { return }

            // Update UI on main thread
            await MainActor.run {
                self.searchResults = results
                self.isSearching = false
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenSpecificBackgroundView(screen: .library)

                VStack(spacing: 0) {
                    // Search bar
                    HStack {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)

                            TextField("search_placeholder".localized, text: $searchText)
                                .textFieldStyle(PlainTextFieldStyle())
                                .autocorrectionDisabled()
                                .focused($isSearchFocused)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray6))
                        .cornerRadius(10)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                    // Category filters
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(SearchCategory.allCases, id: \.self) { category in
                                Button(action: {
                                    selectedCategory = category
                                }) {
                                    Text(category.localizedString)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(
                                            selectedCategory == category ?
                                                settings.backgroundColorChoice.color :
                                                Color(.systemGray6)
                                        )
                                        .foregroundColor(
                                            selectedCategory == category ?
                                                .white :
                                                .primary
                                        )
                                        .cornerRadius(20)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .padding(.top, 12)

                    // Results
                    if debouncedSearchText.isEmpty {
                        VStack(spacing: 16) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)

                            Text(Localized.searchYourMusicLibrary)
                                .font(.headline)

                            Text(Localized.findSongsArtistsAlbumsPlaylists)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if isSearching {
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.2)
                                .progressViewStyle(CircularProgressViewStyle(tint: settings.backgroundColorChoice.color))

                            Text("search_any_loading".localized)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        SearchResultsView(
                            results: searchResults,
                            selectedCategory: selectedCategory,
                            allTracks: allTracks,
                            onDismiss: { dismiss() },
                            onNavigateToArtist: onNavigateToArtist,
                            onNavigateToAlbum: onNavigateToAlbum,
                            onNavigateToPlaylist: onNavigateToPlaylist
                        )
                    }
                }
                .navigationTitle(Localized.search)
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarBackButtonHidden()
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button(Localized.done) {
                            dismiss()
                        }
                        .foregroundColor(settings.backgroundColorChoice.color)
                    }
                }
            }
            .onChange(of: searchText) { _, newValue in
                // Cancel any existing debounce task
                debounceTask?.cancel()

                // Create new debounce task
                debounceTask = Task {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                    if !Task.isCancelled {
                        debouncedSearchText = newValue
                        performSearch(query: newValue)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
                settings = DeleteSettings.load()
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isSearchFocused = true
                }
            }
            .onDisappear {
                debounceTask?.cancel()
                searchTask?.cancel()
            }
        }
    }
}
