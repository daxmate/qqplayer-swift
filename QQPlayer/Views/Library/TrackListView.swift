import GRDB
import SwiftUI

struct TrackListView: View {
    let tracks: [Track]
    let playlist: Playlist?
    let isEditMode: Bool
    let listIdentifier: String?
    let isLikedSongsScreen: Bool

    @EnvironmentObject private var appCoordinator: AppCoordinator

    // Local State
    @State private var sortOption: TrackSortOption = .dateNewest
    @State private var recentlyActedTracks: Set<String> = []
    /// 按歌手排序时的歌手名缓存（.task 按需加载，替代 sortedTracks 每次求值全表查询）
    @State private var artistSortCache: [Int64: String] = [:]

    // Bulk selection state
    @State private var isBulkMode = false
    @State private var selectedTracks: Set<String> = []
    @State private var showBulkPlaylistDialog = false
    @State private var showBulkDeleteConfirmation = false
    @State private var settings = DeleteSettings.load()

    init(tracks: [Track], playlist: Playlist? = nil, isEditMode: Bool = false, listIdentifier: String? = nil, isLikedSongsScreen: Bool = false) {
        self.tracks = tracks
        self.playlist = playlist
        self.isEditMode = isEditMode
        self.listIdentifier = listIdentifier
        self.isLikedSongsScreen = isLikedSongsScreen
    }

    // Sorting logic stays here
    private var sortedTracks: [Track] {
        let filteredTracks: [Track]
        if SFBAudioEngineManager.shared.isCarPlayEnvironment {
            filteredTracks = tracks.filter { track in
                let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
                return !["ogg", "opus", "dsf", "dff"].contains(ext)
            }
        } else {
            filteredTracks = tracks
        }

        switch sortOption {
        case .playlistOrder: return filteredTracks
        case .dateNewest: return filteredTracks.sorted { ($0.id ?? 0) > ($1.id ?? 0) }
        case .dateOldest: return filteredTracks.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        case .nameAZ: return filteredTracks.sorted { $0.title.lowercased() < $1.title.lowercased() }
        case .nameZA: return filteredTracks.sorted { $0.title.lowercased() > $1.title.lowercased() }
        case .artistAZ:
            // Pre-fetch all artist names for performance
            return filteredTracks.sorted { track1, track2 in
                let artist1 = artistSortCache[track1.artistId ?? -1] ?? ""
                let artist2 = artistSortCache[track2.artistId ?? -1] ?? ""
                return artist1.lowercased() < artist2.lowercased()
            }
        case .artistZA:
            // Pre-fetch all artist names for performance
            return filteredTracks.sorted { track1, track2 in
                let artist1 = artistSortCache[track1.artistId ?? -1] ?? ""
                let artist2 = artistSortCache[track2.artistId ?? -1] ?? ""
                return artist1.lowercased() > artist2.lowercased()
            }
        case .sizeLargest: return filteredTracks.sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        case .sizeSmallest: return filteredTracks.sorted { ($0.fileSize ?? 0) < ($1.fileSize ?? 0) }
        }
    }

    private func buildArtistCache(for tracks: [Track]) -> [Int64: String] {
        // Get unique artist IDs
        let artistIds = Set(tracks.compactMap { $0.artistId })

        // Fetch all artists in one query
        var cache: [Int64: String] = [:]
        do {
            try DatabaseManager.shared.read { db in
                let artists = try Artist.filter(artistIds.contains(Column("id"))).fetchAll(db)
                for artist in artists {
                    if let id = artist.id {
                        // 简繁归一：同一歌手的繁/简两行归一到同一字形
                        cache[id] = ArtistNameNormalizer.displayName(artist.name)
                    }
                }
            }
        } catch {
            print("Failed to build artist cache: \(error)")
        }
        return cache
    }

    // Bulk Helpers
    private func enterBulkMode(initialSelection: String? = nil) {
        isBulkMode = true
        if let trackId = initialSelection { selectedTracks.insert(trackId) }
    }

    private func exitBulkMode() {
        isBulkMode = false
        selectedTracks.removeAll()
    }

    private func selectAll() {
        selectedTracks = Set(sortedTracks.map { $0.stableId })
    }

    /// 批量收藏：文案即目标状态（「加入喜欢」= 全部设为已喜欢），幂等，不是逐曲取反（审计 B5 · 🔴-1）。
    private func bulkAddToLikedSongs() {
        let desired = FavoriteBatchLogic.desiredState(isLikedContext: isLikedSongsScreen)
        _ = try? appCoordinator.setFavorites(trackStableIds: selectedTracksInListOrder(), isFavorite: desired)
        exitBulkMode()
    }

    /// 选中曲目按列表顺序（selectedTracks 是 Set，顺序不稳定；顺便消灭逐个 O(n) first(where:)）
    private func selectedTracksInListOrder() -> [String] {
        sortedTracks.map(\.stableId).filter { selectedTracks.contains($0) }
    }

    private func bulkDelete() {
        Task {
            let deleteSettings = DeleteSettings.load()
            // 先建 stableId → Track 字典，避免对每个选中曲目 O(n) first(where:)（总 O(n²)）
            let tracksByStableId = Dictionary(uniqueKeysWithValues: sortedTracks.map { ($0.stableId, $0) })
            for trackId in selectedTracks {
                if let track = tracksByStableId[trackId] {
                    if deleteSettings.deleteFromLibraryOnly {
                        DeleteSettings.addExcludedTrack(track.stableId)
                    } else {
                        try? FileManager.default.removeItem(at: URL(fileURLWithPath: track.path))
                    }
                    try? DatabaseManager.shared.deleteTrack(byStableId: track.stableId)
                }
            }
            NotificationCenter.default.post(name: NSNotification.Name("LibraryNeedsRefresh"), object: nil)
            exitBulkMode()
        }
    }

    // Persistence
    private func loadSortPreference() {
        guard let identifier = listIdentifier else { return }
        if let savedRawValue = UserDefaults.standard.string(forKey: "sortPreference_\(identifier)"),
           let saved = TrackSortOption(rawValue: savedRawValue) {
            sortOption = saved
        }
    }

    private func saveSortPreference() {
        guard let identifier = listIdentifier else { return }
        UserDefaults.standard.set(sortOption.rawValue, forKey: "sortPreference_\(identifier)")
    }

    var body: some View {
        // We pass the sorted tracks and state bindings to the Inner View.
        // The Inner View observes PlayerEngine, so IT updates, but THIS view (and the Toolbar) remains stable.
        TrackListContentView(
            tracks: sortedTracks,
            playlist: playlist,
            isEditMode: isEditMode,
            isBulkMode: $isBulkMode,
            selectedTracks: $selectedTracks,
            recentlyActedTracks: $recentlyActedTracks,
            onEnterBulkMode: { id in enterBulkMode(initialSelection: id) }
        )
        // MARK: - TOOLBAR
        // Since PlayerEngine is not observed in this view, this Toolbar will not rebuild on every frame.
        .toolbar {
            if isBulkMode {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(Localized.cancel) { exitBulkMode() }
                        .foregroundColor(settings.backgroundColorChoice.color)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { selectAll() }) {
                            Label(Localized.selectAll, systemImage: "checkmark.circle")
                        }
                        Divider()
                        Button(action: { bulkAddToLikedSongs() }) {
                            Label(isLikedSongsScreen ? Localized.removeFromLiked : Localized.addToLiked, systemImage: "heart.fill")
                        }
                        .disabled(selectedTracks.isEmpty)

                        Button(action: { showBulkPlaylistDialog = true }) {
                            Label(Localized.addToPlaylist, systemImage: "music.note.list")
                        }
                        .disabled(selectedTracks.isEmpty)
                        Divider()
                        Button(role: .destructive, action: { showBulkDeleteConfirmation = true }) {
                            Label(Localized.deleteFiles, systemImage: "trash")
                        }
                        .disabled(selectedTracks.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.title3)
                            .foregroundColor(settings.backgroundColorChoice.color)
                            // Increase hit area
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                }
            } else {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        ForEach(TrackSortOption.allCases, id: \.self) { option in
                            Button(action: {
                                sortOption = option
                                saveSortPreference()
                            }) {
                                HStack {
                                    Text(option.localizedString)
                                    if sortOption == option { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .font(.title3)
                            .foregroundColor(settings.backgroundColorChoice.color)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
        .sheet(isPresented: $showBulkPlaylistDialog) {
            BulkPlaylistSelectionView(trackIds: Array(selectedTracks), onComplete: { exitBulkMode() })
                .accentColor(settings.backgroundColorChoice.color)
        }
        .alert(Localized.deleteFilesConfirmation, isPresented: $showBulkDeleteConfirmation) {
            Button(Localized.delete, role: .destructive) { bulkDelete() }
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            Text(Localized.deleteFilesConfirmationMessage(selectedTracks.count))
        }
        .onAppear { loadSortPreference() }
        // 歌手名缓存按需加载：仅在歌手排序激活时构建一次（替代 sortedTracks 每次求值全表查询）
        .task(id: sortOption) {
            if sortOption == .artistAZ || sortOption == .artistZA {
                artistSortCache = buildArtistCache(for: tracks)
            }
        }
        .task(id: tracks.count) {
            if sortOption == .artistAZ || sortOption == .artistZA {
                artistSortCache = buildArtistCache(for: tracks)
            }
        }
    }
}

struct TrackListContentView: View {
    let tracks: [Track]
    let playlist: Playlist?
    let isEditMode: Bool

    // Bindings to parent state
    @Binding var isBulkMode: Bool
    @Binding var selectedTracks: Set<String>
    @Binding var recentlyActedTracks: Set<String>
    let onEnterBulkMode: (String?) -> Void

    // Only THIS view updates when the song progresses
    @StateObject private var playerEngine = PlayerEngine.shared
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var settings = DeleteSettings.load()
    @State private var displayLimit = 50
    @State private var artistNameCache: [Int64: String] = [:]
    @State private var artistDisplayNameCache: [String: String] = [:]
    private let pageSize = 50
    private let largeQueueCap = 5000

    private var displayedTracks: [Track] {
        Array(tracks.prefix(displayLimit))
    }

    private var trackDisplaySignature: String {
        "\(tracks.count)-\(tracks.first?.stableId ?? "")-\(tracks.last?.stableId ?? "")"
    }

    private func toggleSelection(for track: Track) {
        if selectedTracks.contains(track.stableId) {
            selectedTracks.remove(track.stableId)
        } else {
            selectedTracks.insert(track.stableId)
        }
    }

    private func markAsActed(_ trackId: String) {
        recentlyActedTracks.insert(trackId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            recentlyActedTracks.remove(trackId)
        }
    }

    private func queueForPlayback(startingAt selectedTrack: Track) -> [Track] {
        guard tracks.count > largeQueueCap,
              let selectedIndex = tracks.firstIndex(where: { $0.stableId == selectedTrack.stableId }) else {
            return tracks
        }

        let endIndex = min(selectedIndex + largeQueueCap, tracks.count)
        return Array(tracks[selectedIndex ..< endIndex])
    }

    private func loadArtistNameCache() {
        do {
            artistNameCache = try DatabaseManager.shared.getAllArtistNamesById()
            let fallbackArtistIds = tracks.reduce(into: [String: Int64]()) { result, track in
                if let artistId = track.artistId {
                    result[track.stableId] = artistId
                }
            }
            artistDisplayNameCache = try DatabaseManager.shared.getArtistDisplayNames(
                forTrackStableIds: tracks.map(\.stableId),
                fallbackArtistIdsByStableId: fallbackArtistIds
            )
        } catch {
            print("Failed to load artist name cache: \(error)")
        }
    }

    private func updateArtworkWindow() {
        let visibleWindowIds = Array(displayedTracks.suffix(120)).map { $0.stableId }
        let prefetchIds = Array(tracks.dropFirst(displayLimit).prefix(20)).map { $0.stableId }
        ArtworkManager.shared.updateVisibleArtworkWindow(
            visibleTrackIds: visibleWindowIds,
            prefetchTrackIds: prefetchIds
        )
    }

    private func loadNextPageIfNeeded() {
        guard displayLimit < tracks.count else { return }

        // Scroll geometry only reaches this point when the user is actually
        // near the bottom. Unlike a List row's onAppear, it is not fired by
        // UICollectionView prefetching every newly appended page.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayLimit = min(displayLimit + pageSize, tracks.count)
        }
    }

    var body: some View {
        if tracks.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "music.note").font(.system(size: 40)).foregroundColor(.secondary)
                Text(Localized.noSongsFound).font(.headline)
                Text(Localized.yourMusicWillAppearHere).font(.subheadline).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(displayedTracks, id: \.stableId) { track in
                    ZStack(alignment: .leading) {
                        HStack(spacing: 0) {
                            if isBulkMode {
                                Image(systemName: selectedTracks.contains(track.stableId) ? "checkmark.circle.fill" : "circle")
                                    .font(.title2)
                                    .foregroundColor(selectedTracks.contains(track.stableId) ? settings.backgroundColorChoice.color : .secondary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                                    .onTapGesture { toggleSelection(for: track) }
                            }

                            TrackRowView(
                                track: track,
                                activeTrackId: playerEngine.currentTrack?.stableId,
                                isAudioPlaying: playerEngine.isPlaying,
                                artistName: artistDisplayNameCache[track.stableId] ?? track.artistId.flatMap { artistNameCache[$0] },
                                onTap: {
                                    if isBulkMode {
                                        toggleSelection(for: track)
                                    } else {
                                        Task {
                                            if let playlist = playlist, let playlistId = playlist.id {
                                                try? appCoordinator.updatePlaylistAccessed(playlistId: playlistId)
                                                try? appCoordinator.updatePlaylistLastPlayed(playlistId: playlistId)
                                            }
                                            await appCoordinator.playTrack(track, queue: queueForPlayback(startingAt: track))
                                        }
                                    }
                                },
                                playlist: playlist,
                                showDirectDeleteButton: playlist != nil && isEditMode,
                                onEnterBulkMode: { onEnterBulkMode(track.stableId) }
                            )
                            .equatable() // Crucial for performance
                            .onLongPressGesture(minimumDuration: 0.5) {
                                if !isBulkMode { onEnterBulkMode(track.stableId) }
                            }
                        }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: true) {
                        if !isBulkMode && !recentlyActedTracks.contains(track.stableId) {
                            Button {
                                playerEngine.insertNext(track)
                                markAsActed(track.stableId)
                            } label: { Label(Localized.playNext, systemImage: "text.line.first.and.arrowtriangle.forward") }
                                .tint(settings.backgroundColorChoice.color)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        if !isBulkMode && !recentlyActedTracks.contains(track.stableId) {
                            Button {
                                playerEngine.addToQueue(track)
                                markAsActed(track.stableId)
                            } label: { Label(Localized.addToQueue, systemImage: "text.append") }
                                .tint(.blue)
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial).opacity(0.7))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .listRowSeparator(.hidden).listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(PlainListStyle())
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 100, for: .scrollContent)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                guard displayLimit < tracks.count,
                      geometry.containerSize.height > 0,
                      geometry.contentSize.height > geometry.containerSize.height else {
                    return false
                }

                let visibleBottom = max(0, geometry.contentOffset.y) + geometry.containerSize.height
                return visibleBottom >= geometry.contentSize.height - 500
            } action: { wasNearBottom, isNearBottom in
                guard isNearBottom, !wasNearBottom else { return }
                loadNextPageIfNeeded()
            }
            .onAppear {
                displayLimit = min(pageSize, tracks.count)
                if artistNameCache.isEmpty {
                    loadArtistNameCache()
                }
                updateArtworkWindow()
            }
            .onChange(of: trackDisplaySignature) { _, _ in
                displayLimit = min(pageSize, tracks.count)
                loadArtistNameCache()
                updateArtworkWindow()
            }
            .onChange(of: displayLimit) { _, _ in
                updateArtworkWindow()
            }
        }
    }
}
