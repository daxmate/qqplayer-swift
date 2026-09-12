import GRDB
import SwiftUI

struct AlbumsScreen: View {
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var albums: [Album] = []
    /// albumId → 曲目索引：卡片渲染不再对全库做线性 filter（修前每张卡片每次重绘一次 O(n) 扫描）
    @State private var tracksByAlbumId: [Int64: [Track]] = [:]
    @State private var settings = DeleteSettings.load()

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .albums)

            VStack {
                if albums.isEmpty {
                    EmptyAlbumsView()
                } else {
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: 20),
                                GridItem(.flexible()),
                            ],
                            spacing: 16
                        ) {
                            ForEach(albums, id: \.id) { album in
                                NavigationLink {
                                    AlbumDetailScreen(album: album, allTracks: allTracks)
                                } label: {
                                    AlbumCardView(album: album,
                                                  tracks: albumTracks(album))
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 100) // Add padding for mini player
                    }
                }
            }
        }
        .navigationTitle(Localized.albums)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: loadAlbums)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("LibraryNeedsRefresh"))) { _ in
            loadAlbums()
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
        }
    }

    /// 预取索引：一次遍历建好 albumId → tracks（替代每张卡片的 allTracks.filter）
    private func rebuildAlbumTrackIndex() {
        tracksByAlbumId = Dictionary(grouping: allTracks.compactMap { track in
            track.albumId.map { ($0, track) }
        }, by: { $0.0 }).mapValues { $0.map(\.1) }
    }

    private func albumTracks(_ album: Album) -> [Track] {
        guard let albumId = album.id else { return [] }
        return tracksByAlbumId[albumId] ?? []
    }

    private func loadAlbums() {
        do {
            albums = try appCoordinator.getAllAlbums()
        } catch {
            print("Failed to load albums: \(error)")
        }
        rebuildAlbumTrackIndex()
    }
}

private struct EmptyAlbumsView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "opticaldisc")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(Localized.noAlbumsFound).font(.headline)
            Text(Localized.albumsWillAppear)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Album card with artwork loading
private struct AlbumCardView: View {
    let album: Album
    let tracks: [Track]
    @State private var artworkImage: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Album artwork area with fixed aspect ratio
            GeometryReader { geometry in
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.gray.opacity(0.15))
                    .overlay {
                        if let image = artworkImage {
                            Image(uiImage: image)
                                .resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.width)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                        }
                    }
            }
            .aspectRatio(1, contentMode: .fit)

            VStack(alignment: .leading, spacing: 4) {
                Text(album.title)
                    .font(.headline)
                    .lineLimit(2)

                Text(Localized.songsCount(tracks.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(minHeight: 60, alignment: .topLeading)
        }
        .task {
            loadAlbumArtwork()
        }
    }

    private func loadAlbumArtwork() {
        // Use the first track in the album to get artwork
        guard let firstTrack = tracks.first else { return }
        Task {
            artworkImage = await ArtworkManager.shared.getThumbnail(for: firstTrack, maxPixelSize: 512)
        }
    }
}

// Album detail view reconstructed
struct AlbumDetailScreen: View {
    let album: Album
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var artworkImage: UIImage?
    @State private var settings = DeleteSettings.load()
    @State private var albumTracks: [Track] = []
    @State private var artistNameCache: [Int64: String] = [:]
    @State private var isBulkMode = false
    @State private var selectedTracks: Set<String> = []

    private var playerEngine: PlayerEngine {
        appCoordinator.playerEngine
    }

    private var filteredAlbumTracks: [Track] {
        // Filter out incompatible formats when connected to CarPlay
        if SFBAudioEngineManager.shared.isCarPlayEnvironment {
            return albumTracks.filter { track in
                let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
                let incompatibleFormats = ["ogg", "opus", "dsf", "dff"]
                return !incompatibleFormats.contains(ext)
            }
        } else {
            return albumTracks
        }
    }

    private var groupedByDisc: [(discNumber: Int, tracks: [Track])] {
        let grouped = Dictionary(grouping: filteredAlbumTracks) { track in
            track.discNo ?? 1
        }
        return grouped.sorted(by: { $0.key < $1.key }).map { (discNumber: $0.key, tracks: $0.value) }
    }

    private var hasMultipleDiscs: Bool {
        return groupedByDisc.count > 1
    }

    private var albumArtist: String {
        if let albumArtist = album.albumArtist, !albumArtist.isEmpty {
            // 简繁归一：专辑页歌手名按当前 UI 语言显示（如 "周杰倫" → "周杰伦"）
            return ArtistNameNormalizer.displayName(albumArtist)
        }
        if let artistId = album.artistId,
           let artistName = artistNameCache[artistId] {
            return artistName
        }
        return Localized.unknownArtist
    }

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .albumDetail)

            ScrollView {
                VStack(spacing: 24) {
                    // Artwork + info
                    VStack(spacing: 16) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 250, height: 250)
                            .overlay {
                                if let image = artworkImage {
                                    Image(uiImage: image)
                                        .resizable().scaledToFill()
                                        .frame(width: 250, height: 250)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.system(size: 50))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)

                        VStack(spacing: 8) {
                            Text(album.title)
                                .font(.title2)
                                .fontWeight(.bold)
                                .multilineTextAlignment(.center)

                            NavigationLink {
                                ArtistDetailScreenWrapper(artistName: albumArtist, allTracks: allTracks)
                            } label: {
                                Text(albumArtist)
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .buttonStyle(.plain)
                        }

                        HStack(spacing: 12) {
                            Button {
                                if let first = filteredAlbumTracks.first {
                                    Task {
                                        await playerEngine.playTrack(first, queue: filteredAlbumTracks)
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text(Localized.play)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                }
                                .font(.title3.weight(.semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(settings.backgroundColorChoice.color)
                                .cornerRadius(28)
                            }

                            Button {
                                guard !filteredAlbumTracks.isEmpty else { return }
                                let shuffled = filteredAlbumTracks.shuffled()
                                Task {
                                    await playerEngine.playTrack(shuffled[0], queue: shuffled)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "shuffle")
                                    Text(Localized.shuffle)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.6)
                                }
                                .font(.title3.weight(.semibold))
                                .foregroundColor(settings.backgroundColorChoice.color)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(settings.backgroundColorChoice.color.opacity(0.1))
                                .cornerRadius(28)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .padding(.horizontal)

                    // Track list
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(Localized.songs)
                                .font(.title3.weight(.bold))
                            Spacer()
                            Text(Localized.songsCount(filteredAlbumTracks.count))
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 12)

                        LazyVStack(spacing: 0) {
                            ForEach(groupedByDisc, id: \.discNumber) { disc in
                                // Disc header (only show if multiple discs)
                                if hasMultipleDiscs {
                                    HStack {
                                        Text("disc_number".localized(with: disc.discNumber))
                                            .font(.headline)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal)
                                    .padding(.top, disc.discNumber > 1 ? 16 : 0)
                                    .padding(.bottom, 8)
                                }

                                // Tracks for this disc
                                ForEach(Array(disc.tracks.enumerated()), id: \.element.stableId) { index, track in
                                    HStack(spacing: 12) {
                                        if isBulkMode {
                                            TrackSelectionIndicator(
                                                isSelected: selectedTracks.contains(track.stableId),
                                                accentColor: settings.backgroundColorChoice.color,
                                                onTap: { toggleSelection(track) }
                                            )
                                            .padding(.leading)
                                        }

                                        AlbumTrackRowView(
                                            track: track,
                                            trackNumber: track.trackNo ?? (index + 1),
                                            artistName: (try? DatabaseManager.shared.getArtistDisplayName(forTrackStableId: track.stableId, fallbackArtistId: track.artistId)) ?? track.artistId.flatMap { artistNameCache[$0] },
                                            onTap: {
                                                // While selecting, a tap toggles instead of playing.
                                                if isBulkMode {
                                                    toggleSelection(track)
                                                } else {
                                                    Task {
                                                        await playerEngine.playTrack(track, queue: filteredAlbumTracks)
                                                    }
                                                }
                                            },
                                            onEnterBulkMode: { beginSelection(with: track) }
                                        )
                                    }
                                    .contentShape(Rectangle())
                                    // simultaneousGesture rather than
                                    // onLongPressGesture: this row's root is a
                                    // Button, whose own press recogniser wins an
                                    // ordinary long press, so selection could
                                    // never be entered by holding a track.
                                    .simultaneousGesture(
                                        LongPressGesture(minimumDuration: 0.5)
                                            .onEnded { _ in beginSelection(with: track) }
                                    )

                                    // Add divider between tracks (not after last track of last disc)
                                    let isLastTrackOfDisc = index == disc.tracks.count - 1
                                    let isLastDisc = disc.discNumber == groupedByDisc.last?.discNumber
                                    if !isLastTrackOfDisc || !isLastDisc {
                                        Divider().padding(.leading, 60)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 100) // Add padding for mini player
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .trackBulkActions(
            tracks: filteredAlbumTracks,
            isBulkMode: $isBulkMode,
            selectedTracks: $selectedTracks
        )
        .onAppear {
            loadArtistNameCache()
            loadAlbumTracks()
            loadAlbumArtwork()
        }
        // albumTracks is @State loaded once, so without this a bulk delete left
        // the removed tracks on screen until the view was revisited.
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            loadAlbumTracks()
        }
        .task {
            // Ensure data loads even if onAppear doesn't trigger
            if albumTracks.isEmpty {
                loadAlbumTracks()
            }
            if artworkImage == nil {
                loadAlbumArtwork()
            }
        }
    }

    private func toggleSelection(_ track: Track) {
        if selectedTracks.contains(track.stableId) {
            selectedTracks.remove(track.stableId)
        } else {
            selectedTracks.insert(track.stableId)
        }
    }

    private func beginSelection(with track: Track) {
        guard !isBulkMode else { return }
        isBulkMode = true
        selectedTracks.insert(track.stableId)
    }

    private func loadAlbumTracks() {
        guard let albumId = album.id else { return }
        do {
            albumTracks = try appCoordinator.databaseManager.getTracksByAlbumId(albumId)
        } catch {
            print("Failed to load album tracks: \(error)")
        }
    }

    private func loadAlbumArtwork() {
        guard let first = filteredAlbumTracks.first else { return }
        Task {
            do {
                let image = await ArtworkManager.shared.getArtwork(for: first)
                await MainActor.run {
                    artworkImage = image
                }
            }
        }
    }

    private func loadArtistNameCache() {
        do {
            artistNameCache = try DatabaseManager.shared.getAllArtistNamesById()
        } catch {
            print("Failed to load album artist cache: \(error)")
        }
    }
}

struct AlbumTrackRowView: View {
    let track: Track
    let trackNumber: Int
    let artistName: String?
    let onTap: () -> Void
    /// Menu entry point into multi-select. The long press is unreliable over
    /// this row's Button root, so the menu is the dependable route.
    let onEnterBulkMode: (() -> Void)?
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var showDeleteConfirmation = false
    @State private var deleteSettings = DeleteSettings.load()
    /// Menu 交互中标记（仿 ArtistTrackRowView）：菜单点开时抑制行点击，避免菜单手势与行 tap 竞争
    @State private var isMenuInteracting = false

    var body: some View {
        HStack(spacing: 8) {
            // Track number
            Text("\(trackNumber)")
                .font(.body)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .frame(width: 22, alignment: .leading)

            // Track info
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)

                // Artist name and duration with dot separator
                HStack(spacing: 0) {
                    if let artistName, !artistName.isEmpty {
                        Text(artistName)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if track.durationMs != nil {
                            Text(" • ")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let duration = track.durationMs {
                        Text(formatDuration(duration))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Menu button - independent sibling of the row's tap gesture
            // (原实现把 Menu 嵌在根 Button 的 label 内，父 Button 手势与子 Menu 竞争，
            // 省略号菜单点不出；仿 ArtistTrackRowView 改为 HStack + onTapGesture + 独立 Menu)
            Menu {
                if let onEnterBulkMode {
                    Button(action: { onEnterBulkMode() }) {
                        Label(Localized.select, systemImage: "checkmark.circle")
                    }
                    Divider()
                }

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
                    .frame(width: 24, height: 30)
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
        .padding(.horizontal)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isMenuInteracting {
                onTap()
            }
        }
        .onAppear {
            checkFavoriteStatus()
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

struct ArtistDetailScreenWrapper: View {
    let artistName: String
    let allTracks: [Track]
    @State private var artists: [Artist] = []

    var body: some View {
        Group {
            if !artists.isEmpty {
                ArtistDetailScreen(artists: artists, allTracks: allTracks)
            } else {
                VStack(spacing: 16) {
                    ProgressView()
                    Text(Localized.loadingArtist)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear(perform: loadArtist)
    }

    private func loadArtist() {
        do {
            // searchArtists 已做简繁归一：输"周杰伦"也能命中"周傑倫"行；
            // 同名简繁两行归为一组，组内全部 artist 传入详情聚合曲目
            let matched = try DatabaseManager.shared.searchArtists(query: artistName, limit: 100)
            let grouped = ArtistNameNormalizer.groupedArtists(matched)
            let target = grouped.first { $0.artists.contains { $0.name == artistName } } ?? grouped.first
            artists = target?.artists ?? [Artist(id: nil, name: artistName)]
        } catch {
            print("Failed to load artist: \(error)")
            artists = [Artist(id: nil, name: artistName)]
        }
    }
}
