import PhotosUI
import SwiftUI
import WidgetKit

struct PlaylistDetailScreen: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    let playlist: Playlist
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var tracks: [Track] = []
    @State private var isEditMode: Bool = false
    @State private var artworks: [UIImage] = []
    @State private var settings = DeleteSettings.load()
    @State private var sortOption: TrackSortOption = .playlistOrder
    @State private var showSortMenu = false
    @State private var recentlyActedTracks: Set<String> = []
    @StateObject private var artworkManager = ArtworkManager.shared
    @State private var showingImagePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var customCoverImage: UIImage?
    /// 歌单自定义封面读取失败的登记（INV-22 另一半：读不到必须计数 + 就地说明）。
    /// 2026-09-19 批 2：由组合根（`QQPlayerApp`）环境注入，不再直连 `.shared`。
    @Environment(PlaylistCoverLoadFailuresStore.self) private var coverFailures
    @State private var showCoverOptions = false
    @State private var artistNameCache: [Int64: String] = [:]
    @State private var artistDisplayNameCache: [String: String] = [:]
    /// 按歌手排序时的歌手名缓存（.task 按需加载，替代 sortedTracks 每次求值全表查询）
    @State private var artistSortCache: [Int64: String] = [:]

    private var playerEngine: PlayerEngine {
        appCoordinator.playerEngine
    }

    private func markAsActed(_ trackId: String) {
        recentlyActedTracks.insert(trackId)
        // Remove after 1 second so user can swipe again if needed
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            recentlyActedTracks.remove(trackId)
        }
    }

    private var sortedTracks: [Track] {
        // Filter out incompatible formats when connected to CarPlay
        let filteredTracks: [Track]
        if SFBAudioEngineManager.shared.isCarPlayEnvironment {
            filteredTracks = tracks.filter { track in
                let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
                let incompatibleFormats = ["ogg", "opus", "dsf", "dff"]
                return !incompatibleFormats.contains(ext)
            }
        } else {
            filteredTracks = tracks
        }

        switch sortOption {
        case .playlistOrder:
            // Respect the playlist position order (tracks are already loaded in position order)
            return filteredTracks
        case .dateNewest:
            return filteredTracks.sorted { ($0.id ?? 0) > ($1.id ?? 0) }
        case .dateOldest:
            return filteredTracks.sorted { ($0.id ?? 0) < ($1.id ?? 0) }
        case .nameAZ:
            return filteredTracks.sorted { $0.title.lowercased() < $1.title.lowercased() }
        case .nameZA:
            return filteredTracks.sorted { $0.title.lowercased() > $1.title.lowercased() }
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
        case .sizeLargest:
            return filteredTracks.sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
        case .sizeSmallest:
            return filteredTracks.sorted { ($0.fileSize ?? 0) < ($1.fileSize ?? 0) }
        }
    }

    private func buildArtistCache(for tracks: [Track]) -> [Int64: String] {
        // Get unique artist IDs
        let artistIds = Set(tracks.compactMap { $0.artistId })

        // Fetch all artists in one query
        var cache: [Int64: String] = [:]
        do {
            let artists = try LibraryReads.artists(ids: Array(artistIds))
            for artist in artists {
                if let id = artist.id {
                    // 简繁归一：行副标题按当前 UI 语言显示同一字形
                    cache[id] = ArtistNameNormalizer.displayName(artist.name)
                }
            }
        } catch {
            print("Failed to build artist cache: \(error)")
        }
        return cache
    }

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .playlistDetail)

            List {
                // Header section with artwork and buttons
                Section {
                    VStack(spacing: DesignTokens.space16) {
                        // Four-song grid artwork
                        ZStack {
                            RoundedRectangle(cornerRadius: DesignTokens.radius12)
                                .fill(Color.gray.opacity(0.2))
                                .frame(width: 250, height: 250)

                            // Show custom cover if available, otherwise show auto-generated mashup
                            if let customCover = customCoverImage {
                                Image(uiImage: customCover)
                                    .resizable().scaledToFill()
                                    .frame(width: 250, height: 250)
                                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius12))
                            } else if tracks.count >= 4 {
                                // 2x2 mashup for 4+ songs
                                VStack(spacing: DesignTokens.space2) {
                                    HStack(spacing: DesignTokens.space2) {
                                        artworkView(at: 0, size: 124)
                                        artworkView(at: 1, size: 124)
                                    }
                                    HStack(spacing: DesignTokens.space2) {
                                        artworkView(at: 2, size: 124)
                                        artworkView(at: 3, size: 124)
                                    }
                                }
                                .frame(width: 250, height: 250)
                                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius12))
                            } else if !tracks.isEmpty {
                                // Single artwork for 1-3 songs
                                artworkView(at: 0, size: 250)
                            } else {
                                // Default icon for empty playlist
                                Image(systemName: "music.note.list")
                                    .font(.system(size: DesignTokens.font50))
                                    .foregroundColor(.secondary)
                            }

                            // Edit mode: Show large centered photo icon
                            if isEditMode {
                                VStack {
                                    Spacer()
                                    HStack {
                                        Spacer()
                                        Button(action: {
                                            showCoverOptions = true
                                        }) {
                                            Image(systemName: "photo")
                                                .font(.system(size: DesignTokens.font40, weight: .light))
                                                .foregroundColor(.white)
                                                .frame(width: 80, height: 80)
                                                .background(Color.black.opacity(0.6))
                                                .clipShape(Circle())
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        Spacer()
                                    }
                                    Spacer()
                                }
                                .frame(width: 250, height: 250)
                            }
                        }
                        .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                        .frame(maxWidth: .infinity, alignment: .center)

                        // 自定义封面读不到（INV-22 另一半，2026-09-16）：**就地**说明
                        // （用户是在这里看到封面没了的），而不是只在设置页里计数。
                        // 文案 key 与同步面板共用一处声明。
                        if customCoverFailure != nil {
                            Text("playlist_cover_unavailable".localized)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                        }

                        VStack(spacing: DesignTokens.space8) {
                            Text(playlist.title)
                                .font(.title2)
                                .fontWeight(.bold)
                                .multilineTextAlignment(.center)

                            Text(Localized.songsCount(tracks.count))
                                .font(.title3)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)

                        // Play and Shuffle buttons
                        HStack(spacing: DesignTokens.space12) {
                            Button {
                                if let first = sortedTracks.first {
                                    Task {
                                        await playerEngine.playTrack(first, queue: sortedTracks)
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
                                .padding(.horizontal, DesignTokens.space8)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(accentColor)
                                .cornerRadius(DesignTokens.radius28)
                            }
                            .disabled(tracks.isEmpty)

                            Button {
                                guard !sortedTracks.isEmpty else { return }
                                let shuffled = sortedTracks.shuffled()
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
                                .foregroundColor(accentColor)
                                .padding(.horizontal, DesignTokens.space8)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(accentColor.opacity(0.1))
                                .cornerRadius(DesignTokens.radius28)
                            }
                            .disabled(tracks.isEmpty)
                        }
                        // This row sits in a list row with zeroed insets, so it
                        // needs its own horizontal margin. Without it the two
                        // pills ran edge to edge and single-word translations
                        // that cannot wrap ("Lecture", "Aléatoire",
                        // "Воспроизвести") pushed them off screen.
                        .padding(.horizontal)
                    }
                    .padding(.vertical)
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())

                // Track list section
                if !sortedTracks.isEmpty {
                    Section {
                        ForEach(sortedTracks.uniquelyIdentifiedRows(), id: \.rowId) { row in
                            let index = row.index
                            let track = row.track
                            PlaylistTrackRowView(
                                track: track,
                                playlist: playlist,
                                isEditMode: isEditMode,
                                artistName: artistDisplayNameCache[track.stableId] ?? track.artistId.flatMap { artistNameCache[$0] },
                                onTap: {
                                    Task {
                                        guard let playlistId = playlist.id else { return }
                                        try? appCoordinator.updatePlaylistAccessed(playlistId: playlistId)
                                        try? appCoordinator.updatePlaylistLastPlayed(playlistId: playlistId)
                                        await playerEngine.playTrack(track, queue: sortedTracks)
                                    }
                                }
                            )
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if !recentlyActedTracks.contains(track.stableId) {
                                    Button {
                                        playerEngine.insertNext(track)
                                        markAsActed(track.stableId)
                                    } label: {
                                        Label(Localized.playNext, systemImage: "text.line.first.and.arrowtriangle.forward")
                                    }
                                    .tint(accentColor)
                                }
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if !recentlyActedTracks.contains(track.stableId) {
                                    Button {
                                        playerEngine.addToQueue(track)
                                        markAsActed(track.stableId)
                                    } label: {
                                        Label(Localized.addToQueue, systemImage: "text.append")
                                    }
                                    .tint(.blue)
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(index < sortedTracks.count - 1 ? .visible : .hidden)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        }
                        .onMove(perform: sortOption == .playlistOrder ? { source, destination in
                            guard let playlistId = playlist.id else { return }
                            do {
                                // Calculate actual destination index
                                let sourceIndex = source.first ?? 0
                                let destinationIndex = sourceIndex < destination ? destination - 1 : destination

                                try appCoordinator.reorderPlaylistItems(
                                    playlistId: playlistId,
                                    from: sourceIndex,
                                    to: destinationIndex
                                )

                                // Reload tracks from database to reflect new order
                                loadPlaylistTracks()
                            } catch {
                                print("Failed to reorder tracks: \(error)")
                            }
                        } : nil)
                    } header: {
                        HStack {
                            Text(Localized.songs)
                                .font(.title3.weight(.bold))
                                .foregroundColor(.primary)
                            Spacer()

                            // Sort menu button
                            Menu {
                                ForEach(TrackSortOption.allCases, id: \.self) { option in
                                    Button(action: {
                                        sortOption = option
                                        saveSortPreference()
                                    }) {
                                        HStack {
                                            Text(option.localizedString)
                                            if sortOption == option {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "arrow.up.arrow.down")
                                    .foregroundColor(accentColor)
                            }
                        }
                        .textCase(nil)
                        .padding(.horizontal, DesignTokens.space16)
                    }
                } else {
                    Section {
                        VStack(spacing: DesignTokens.space16) {
                            Image(systemName: "music.note")
                                .font(.system(size: DesignTokens.font40))
                                .foregroundColor(.secondary)

                            Text(Localized.noSongsFound)
                                .font(.headline)

                            Text(Localized.yourMusicWillAppearHere)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.space40)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
            }
            .listStyle(PlainListStyle())
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 100, for: .scrollContent)
            .environment(\.editMode, .constant(isEditMode ? .active : .inactive))
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(isEditMode ? Localized.done : Localized.edit) {
                    withAnimation {
                        isEditMode.toggle()
                    }
                }
                .disabled(tracks.isEmpty)
            }
        }
        .onAppear {
            loadPlaylistTracks()
            loadSortPreference()
            loadCustomCover()
            loadArtistNameCache()
        }
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
        .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
            loadPlaylistTracks()
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
        }
        .confirmationDialog(NSLocalizedString("playlist_cover", value: "Playlist Cover", comment: ""), isPresented: $showCoverOptions) {
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Text(NSLocalizedString("change_cover_image", value: "Change Cover Image", comment: ""))
            }

            if customCoverImage != nil {
                Button(NSLocalizedString("remove_custom_cover", value: "Remove Custom Cover", comment: ""), role: .destructive) {
                    removeCustomCover()
                }
            }

            Button(Localized.cancel, role: .cancel) { }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    await saveCustomCover(image)
                }
            }
        }
    }

    @ViewBuilder
    private func artworkView(at index: Int, size: CGFloat) -> some View {
        if index < artworks.count {
            Image(uiImage: artworks[index])
                .resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipped()
        } else if index < tracks.count {
            RoundedRectangle(cornerRadius: DesignTokens.radius0)
                .fill(Color.gray.opacity(0.3))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .foregroundColor(.secondary)
                        .font(.system(size: size / 4))
                )
        }
    }

    private func loadPlaylistTracks() {
        guard let playlistId = playlist.id else { return }

        do {
            let playlistItems = try appCoordinator.databaseManager.getPlaylistItems(playlistId: playlistId)
            let trackIds = playlistItems.map { $0.trackStableId }
            tracks = try appCoordinator.databaseManager.getTracksByStableIdsPreservingOrder(trackIds)
            loadArtistNameCache()

            // Load artworks for the first 4 tracks
            Task {
                await loadArtworks()
            }
        } catch {
            print("Failed to load playlist tracks: \(error)")
        }
    }

    private func loadArtworks() async {
        var loadedArtworks: [UIImage] = []
        let tracksToLoad = Array(tracks.prefix(4))

        for track in tracksToLoad {
            if let artwork = await artworkManager.getThumbnail(for: track, maxPixelSize: 256) {
                loadedArtworks.append(artwork)
            }
        }

        await MainActor.run {
            artworks = loadedArtworks
        }
    }

    private func loadSortPreference() {
        guard let playlistId = playlist.id else { return }
        let key = "sortPreference_playlist_\(playlistId)"
        if let savedRawValue = UserDefaults.standard.string(forKey: key),
           let saved = TrackSortOption(rawValue: savedRawValue) {
            sortOption = saved
        }
    }

    private func loadArtistNameCache() {
        do {
            artistNameCache = try LibraryReads.artistNamesById()
            let fallbackArtistIds = tracks.reduce(into: [String: Int64]()) { result, track in
                if let artistId = track.artistId {
                    result[track.stableId] = artistId
                }
            }
            artistDisplayNameCache = try LibraryReads.artistDisplayNames(
                forTrackStableIds: tracks.map(\.stableId),
                fallbackArtistIdsByStableId: fallbackArtistIds
            )
        } catch {
            print("Failed to load playlist artist cache: \(error)")
        }
    }

    private func saveSortPreference() {
        guard let playlistId = playlist.id else { return }
        let key = "sortPreference_playlist_\(playlistId)"
        UserDefaults.standard.set(sortOption.rawValue, forKey: key)
    }

    /// 当前歌单的自定义封面是否读取失败（nil = 没配封面或读到）。
    private var customCoverFailure: PlaylistCoverLoadFailuresStore.Failure? {
        let key = PlaylistCoverResolver.playlistKey(id: playlist.id, slug: playlist.slug)
        return coverFailures.failures.first { $0.playlistKey == key }
    }

    @MainActor
    private func loadCustomCover() {
        // 路径解析只有一处入口（`PlaylistCoverResolver`）：读不到**申报 + 上屏**
        // （详情页封面下方会出橙色说明；INV-22 另一半）。
        let key = PlaylistCoverResolver.playlistKey(id: playlist.id, slug: playlist.slug)
        switch PlaylistCoverResolver.resolve(customCoverImagePath: playlist.customCoverImagePath) {
        case .none:
            coverFailures.clear(playlistKey: key)
        case let .unavailable(reason):
            coverFailures.record(
                playlistKey: key,
                path: playlist.customCoverImagePath ?? "",
                reason: reason
            )
        case let .available(fileURL):
            guard let data = try? Data(contentsOf: fileURL),
                  let image = UIImage(data: data) else {
                coverFailures.record(
                    playlistKey: key,
                    path: playlist.customCoverImagePath ?? "",
                    reason: PlaylistCoverResolver.Reason.decodeFailed
                )
                return
            }
            coverFailures.clear(playlistKey: key)
            customCoverImage = image
            print("✅ Loaded custom playlist cover from \(playlist.customCoverImagePath ?? "")")
        }
    }

    @MainActor
    private func saveCustomCover(_ image: UIImage) async {
        guard let playlistId = playlist.id else { return }

        // Get shared container
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.daxmate.qqplayer.ios"
        ) else {
            print("❌ Failed to get shared container URL")
            return
        }

        // Create unique filename for this playlist cover
        let filename = "playlist_cover_\(playlistId).jpg"
        let fileURL = containerURL.appendingPathComponent(filename)
        let coverImage = image.squarePlaylistCover()

        // Save a normalized square image so all playlist covers match standard artwork sizing.
        guard let jpegData = coverImage.jpegData(compressionQuality: 0.85) else {
            print("❌ Failed to convert image to JPEG")
            return
        }

        do {
            // Save image to shared container
            try jpegData.write(to: fileURL)
            print("✅ Saved custom cover to \(filename)")

            // Update database with custom cover path
            try appCoordinator.databaseManager.updatePlaylistCustomCover(
                playlistId: playlistId,
                imagePath: filename
            )

            // Update UI
            customCoverImage = coverImage

            // Notify widgets to refresh
            WidgetCenter.shared.reloadAllTimelines()

            print("✅ Custom cover saved and database updated")
        } catch {
            print("❌ Failed to save custom cover: \(error)")
        }
    }

    private func removeCustomCover() {
        guard let playlistId = playlist.id else { return }

        // Remove from database
        do {
            try appCoordinator.databaseManager.updatePlaylistCustomCover(
                playlistId: playlistId,
                imagePath: nil
            )

            // Remove file from shared container if it exists
            if let customPath = playlist.customCoverImagePath,
               !customPath.isEmpty,
               let containerURL = FileManager.default.containerURL(
                   forSecurityApplicationGroupIdentifier: "group.com.daxmate.qqplayer.ios"
               ) {
                let fileURL = containerURL.appendingPathComponent(customPath)
                try? FileManager.default.removeItem(at: fileURL)
                print("✅ Removed custom cover file")
            }

            // Update UI
            customCoverImage = nil

            // Notify widgets to refresh
            WidgetCenter.shared.reloadAllTimelines()

            print("✅ Custom cover removed")
        } catch {
            print("❌ Failed to remove custom cover: \(error)")
        }
    }
}
