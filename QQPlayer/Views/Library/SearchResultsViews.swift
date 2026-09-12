import GRDB
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
    let results: SearchResults
    let selectedCategory: SearchCategory
    let allTracks: [Track]
    /// 关闭搜索 sheet（同步发起，不等收起动画）：`dismiss()` 本身不提供"已收起"回调，
    /// 修前声明成 `() async -> Void` + `await` 是假等待（await 立即返回）。
    /// 需要"真等待"的地方不要在视图层猜，改用状态驱动的导航（本仓既有做法）。
    let onDismiss: () -> Void
    let onNavigateToArtist: (Artist, [Track]) -> Void
    let onNavigateToAlbum: (Album, [Track]) -> Void
    let onNavigateToPlaylist: (Playlist) -> Void
    @State private var settings = DeleteSettings.load()
    @State private var artistNameCache: [Int64: String] = [:]
    @State private var artistDisplayNameCache: [String: String] = [:]

    private func loadArtistCache() {
        do {
            artistNameCache = try DatabaseManager.shared.getAllArtistNamesById()
            let fallbackArtistIds = results.songs.reduce(into: [String: Int64]()) { result, track in
                if let artistId = track.artistId {
                    result[track.stableId] = artistId
                }
            }
            artistDisplayNameCache = try DatabaseManager.shared.getArtistDisplayNames(
                forTrackStableIds: results.songs.map(\.stableId),
                fallbackArtistIdsByStableId: fallbackArtistIds
            )
        } catch {
            print("Failed to load search artist cache: \(error)")
        }
    }

    var body: some View {
        if results.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 40))
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
                LazyVStack(alignment: .leading, spacing: 16) {
                    // Songs
                    if selectedCategory == .all || selectedCategory == .songs, !results.songs.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Localized.songs)
                                .font(.title3)
                                .fontWeight(.bold)
                                .padding(.horizontal, 16)

                            ForEach(results.songs, id: \.stableId) { track in
                                SearchSongRowView(
                                    track: track,
                                    allTracks: allTracks,
                                    artistName: artistDisplayNameCache[track.stableId] ?? track.artistId.flatMap { artistNameCache[$0] },
                                    onDismiss: onDismiss
                                )
                                .shadow(color: settings.backgroundColorChoice.color.opacity(0.15), radius: 4, x: 0, y: 2)
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    // Albums (also shown when Artists category is selected, grouped by artist)
                    if selectedCategory == .all || selectedCategory == .albums, !results.albums.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Localized.albums)
                                .font(.title3)
                                .fontWeight(.bold)
                                .padding(.horizontal, 16)

                            ForEach(results.albums, id: \.id) { album in
                                SearchAlbumRowView(
                                    album: album,
                                    albumArtistName: album.albumArtist.flatMap { ArtistNameNormalizer.displayName($0) } ?? album.artistId.flatMap { artistNameCache[$0] },
                                    onDismiss: onDismiss,
                                    onNavigate: onNavigateToAlbum
                                )
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.7)
                                )
                                .shadow(color: settings.backgroundColorChoice.color.opacity(0.15), radius: 4, x: 0, y: 2)
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    // Artists - show artist row + their albums underneath
                    if selectedCategory == .all || selectedCategory == .artists, !results.artists.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Localized.artists)
                                .font(.title3)
                                .fontWeight(.bold)
                                .padding(.horizontal, 16)

                            ForEach(ArtistNameNormalizer.groupedArtists(results.artists), id: \.id) { group in
                                VStack(alignment: .leading, spacing: 0) {
                                    SearchArtistRowView(
                                        artist: group.primaryArtist,
                                        onDismiss: onDismiss,
                                        onNavigate: onNavigateToArtist
                                    )
                                    .background(
                                        RoundedRectangle(cornerRadius: 12)
                                            .fill(.ultraThinMaterial)
                                            .opacity(0.7)
                                    )
                                    .shadow(color: settings.backgroundColorChoice.color.opacity(0.15), radius: 4, x: 0, y: 2)
                                    .padding(.horizontal, 16)

                                    // Show this artist's albums below
                                    SearchArtistAlbumsRow(
                                        artist: group.primaryArtist,
                                        onDismiss: onDismiss,
                                        onNavigateToAlbum: onNavigateToAlbum
                                    )
                                }
                                .padding(.bottom, 4)
                            }
                        }
                    }

                    // Playlists
                    if selectedCategory == .all || selectedCategory == .playlists, !results.playlists.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Localized.playlists)
                                .font(.title3)
                                .fontWeight(.bold)
                                .padding(.horizontal, 16)

                            ForEach(results.playlists, id: \.id) { playlist in
                                SearchPlaylistRowView(
                                    playlist: playlist,
                                    onDismiss: onDismiss,
                                    onNavigate: onNavigateToPlaylist
                                )
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(.ultraThinMaterial)
                                        .opacity(0.7)
                                )
                                .shadow(color: settings.backgroundColorChoice.color.opacity(0.15), radius: 4, x: 0, y: 2)
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                }
                .padding(.vertical, 16)
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 100) // Space for mini player
            }
            .onAppear {
                if artistNameCache.isEmpty {
                    loadArtistCache()
                }
                let visibleIds = Array(results.songs.prefix(20)).map { $0.stableId }
                ArtworkManager.shared.updateVisibleArtworkWindow(visibleTrackIds: visibleIds)
            }
            .onChange(of: results.songs.map(\.stableId)) { _, _ in
                loadArtistCache()
            }
        }
    }
}

struct SearchSongRowView: View {
    let track: Track
    let allTracks: [Track]
    let artistName: String?
    let onDismiss: () -> Void
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var playerEngine = PlayerEngine.shared
    @State private var settings = DeleteSettings.load()
    @State private var artworkImage: UIImage?
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeAction: SwipeAction = .none
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var showDeleteConfirmation = false
    private let swipeThreshold: CGFloat = 80

    private enum SwipeAction {
        case none, playNext, addToQueue
    }

    private var isCurrentlyPlaying: Bool {
        playerEngine.currentTrack?.stableId == track.stableId
    }

    var body: some View {
        ZStack {
            // Swipe bubble icons
            HStack {
                // Left side - Play Next bubble (appears on right swipe)
                if swipeOffset > 0 {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(settings.backgroundColorChoice.color)
                        .clipShape(Circle())
                        .opacity(min(Double(swipeOffset) / swipeThreshold, 1.0))
                        .scaleEffect(min(Double(swipeOffset) / swipeThreshold, 1.0))
                        .padding(.leading, 8)
                }

                Spacer()

                // Right side - Add to Queue bubble (appears on left swipe)
                if swipeOffset < 0 {
                    Image(systemName: "text.append")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(.blue)
                        .clipShape(Circle())
                        .opacity(min(Double(-swipeOffset) / swipeThreshold, 1.0))
                        .scaleEffect(min(Double(-swipeOffset) / swipeThreshold, 1.0))
                        .padding(.trailing, 8)
                }
            }

            // Main content
            HStack(spacing: 12) {
                // Album artwork
                ZStack {
                    Group {
                        if let artworkImage = artworkImage {
                            Image(uiImage: artworkImage)
                                .resizable().scaledToFill()
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 16))
                                .foregroundColor(settings.backgroundColorChoice.color)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .background(Color(.systemGray5))

                    if isCurrentlyPlaying {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(settings.backgroundColorChoice.color, lineWidth: 1.5)
                            .frame(width: 40, height: 40)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(isCurrentlyPlaying ? settings.backgroundColorChoice.color : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.leading)

                    if let artistName, !artistName.isEmpty {
                        Text(artistName)
                            .font(.caption)
                            .foregroundColor(isCurrentlyPlaying ? settings.backgroundColorChoice.color.opacity(0.8) : .secondary)
                    }
                }

                Spacer()

                // Currently playing indicator
                if isCurrentlyPlaying {
                    let eqKey = "\(playerEngine.isPlaying && isCurrentlyPlaying)-\(playerEngine.currentTrack?.stableId ?? "")"

                    EqualizerBarsExact(
                        color: settings.backgroundColorChoice.color,
                        isActive: playerEngine.isPlaying && isCurrentlyPlaying,
                        isLarge: false,
                        trackId: playerEngine.currentTrack?.stableId
                    )
                    .id(eqKey)
                }

                if let duration = track.durationMs {
                    Text(formatDuration(duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(.ultraThinMaterial)
                    .opacity(0.7)
            )
            .offset(x: swipeOffset)
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        swipeOffset = value.translation.width
                        if swipeOffset > swipeThreshold {
                            swipeAction = .playNext
                        } else if swipeOffset < -swipeThreshold {
                            swipeAction = .addToQueue
                        } else {
                            swipeAction = .none
                        }
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.3)) {
                            switch swipeAction {
                            case .playNext:
                                playerEngine.insertNext(track)
                            case .addToQueue:
                                playerEngine.addToQueue(track)
                            case .none:
                                break
                            }
                            swipeOffset = 0
                            swipeAction = .none
                        }
                    }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onDismiss()
                Task {
                    // Only queue the selected song from search
                    await appCoordinator.playTrack(track, queue: [track])
                }
            }
            .contextMenu {
                Button(action: {
                    do {
                        try appCoordinator.toggleFavorite(trackStableId: track.stableId)
                        isFavorite.toggle()
                    } catch {
                        print("Failed to toggle favorite: \(error)")
                    }
                }) {
                    Label(
                        isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs,
                        systemImage: isFavorite ? "heart.slash" : "heart"
                    )
                }

                Button(action: {
                    playerEngine.insertNext(track)
                }) {
                    Label(Localized.playNext, systemImage: "text.line.first.and.arrowtriangle.forward")
                }

                Button(action: {
                    playerEngine.addToQueue(track)
                }) {
                    Label(Localized.addToQueue, systemImage: "text.append")
                }

                Button(action: {
                    showPlaylistDialog = true
                }) {
                    Label(Localized.addToPlaylistEllipsis, systemImage: "rectangle.stack.badge.plus")
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

                Button(role: .destructive, action: {
                    showDeleteConfirmation = true
                }) {
                    Label(Localized.deleteFile, systemImage: "trash")
                }
            }
        }
        .onAppear {
            loadArtwork()
            checkFavoriteStatus()
        }
        .sheet(isPresented: $showPlaylistDialog) {
            PlaylistSelectionView(track: track)
                .accentColor(settings.backgroundColorChoice.color)
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

    private func formatDuration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

}

struct SearchArtistRowView: View {
    let artist: Artist
    let onDismiss: () -> Void
    let onNavigate: (Artist, [Track]) -> Void

    var body: some View {
        Button(action: {
            let artistTracks: [Track]
            if let artistId = artist.id {
                artistTracks = (try? DatabaseManager.shared.getTracksByArtistId(artistId)) ?? []
            } else {
                artistTracks = []
            }
            onDismiss()
            onNavigate(artist, artistTracks)
        }) {
            HStack(spacing: 12) {
                Image(systemName: "person.circle.fill")
                    .font(.title2)
                    .foregroundColor(.purple)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(ArtistNameNormalizer.displayName(artist.name))
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(Localized.artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct SearchArtistAlbumsRow: View {
    let artist: Artist
    let onDismiss: () -> Void
    let onNavigateToAlbum: (Album, [Track]) -> Void
    @State private var artistAlbums: [Album] = []
    @State private var artistTracks: [Track] = []

    var body: some View {
        Group {
            if !artistAlbums.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(artistAlbums, id: \.id) { album in
                            let albumTracks = artistTracks.filter { $0.albumId == album.id }
                            Button {
                                onDismiss()
                                onNavigateToAlbum(album, albumTracks)
                            } label: {
                                SearchArtistAlbumCard(album: album, tracks: artistTracks)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }
        }
        .onAppear { loadArtistData() }
    }

    private func loadArtistData() {
        guard let artistId = artist.id else { return }
        Task {
            let tracks = (try? DatabaseManager.shared.getTracksByArtistId(artistId)) ?? []
            let albums = (try? DatabaseManager.shared.getAlbumsByArtistId(artistId)) ?? []
            await MainActor.run {
                artistTracks = tracks
                artistAlbums = albums
            }
        }
    }

    struct SearchArtistAlbumCard: View {
        let album: Album
        let tracks: [Track]
        @State private var artworkImage: UIImage?

        var body: some View {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.systemGray5))
                        .frame(width: 80, height: 80)

                    if let image = artworkImage {
                        Image(uiImage: image)
                            .resizable().scaledToFill()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "opticaldisc.fill")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }

                Text(album.title)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(width: 80)
                    .foregroundColor(.primary)
            }
            .onAppear { loadArtwork() }
        }

        private func loadArtwork() {
            let albumTracks = tracks.filter { $0.albumId == album.id }
            guard let firstTrack = albumTracks.first else { return }
            Task {
                let image = await ArtworkManager.shared.getThumbnail(for: firstTrack, maxPixelSize: 320)
                await MainActor.run { artworkImage = image }
            }
        }
    }

}

struct SearchAlbumRowView: View {
    let album: Album
    let albumArtistName: String?
    let onDismiss: () -> Void
    let onNavigate: (Album, [Track]) -> Void
    @State private var settings = DeleteSettings.load()
    @State private var artworkImage: UIImage?
    @State private var albumTracks: [Track] = []

    var body: some View {
        Button(action: {
            onDismiss()
            onNavigate(album, albumTracks)
        }) {
            HStack(spacing: 12) {
                // Album artwork
                Group {
                    if let artworkImage = artworkImage {
                        Image(uiImage: artworkImage)
                            .resizable().scaledToFill()
                    } else {
                        Image(systemName: "opticaldisc.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.orange)
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .background(Color(.systemGray5))

                VStack(alignment: .leading, spacing: 4) {
                    Text(album.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    HStack(spacing: 4) {
                        if let albumArtistName, !albumArtistName.isEmpty {
                            Text(albumArtistName)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Text("• \(Localized.album)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                Text(Localized.songsCountOnly(albumTracks.count))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onAppear {
            loadAlbumData()
        }
    }

    private func loadAlbumData() {
        guard let albumId = album.id else { return }

        Task {
            let tracks = (try? DatabaseManager.shared.getTracksByAlbumId(albumId)) ?? []
            await MainActor.run {
                albumTracks = tracks
            }

            guard let firstTrack = tracks.first else { return }
            let artwork = await ArtworkManager.shared.getThumbnail(for: firstTrack)
            await MainActor.run {
                artworkImage = artwork
            }
        }
    }
}

struct SearchPlaylistRowView: View {
    let playlist: Playlist
    let onDismiss: () -> Void
    let onNavigate: (Playlist) -> Void
    @State private var settings = DeleteSettings.load()

    var body: some View {
        Button(action: {
            onDismiss()
            onNavigate(playlist)
        }) {
            HStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.title2)
                    .foregroundColor(.green)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(playlist.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    Text(Localized.playlist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}
