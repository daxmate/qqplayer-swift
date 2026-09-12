import GRDB
import SwiftUI
struct ArtistDetailScreen: View {
    /// 归一后的一组歌手（同名简繁两行归并后传入）；primaryArtist 用于专辑/网络信息
    let artists: [Artist]
    let allTracks: [Track]
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var hybridAPI = HybridMusicAPIService.shared
    @State private var unifiedArtist: UnifiedArtist?
    @State private var isLoading = false
    @State private var artistImage: UIImage?
    @State private var showFullProfile = false
    @State private var settings = DeleteSettings.load()
    @State private var isBulkMode = false
    @State private var selectedTracks: Set<String> = []
    /// artistTracks 缓存：一次查询入库，LibraryNeedsRefresh 时刷新（替代 body 每次访问查 5 次 DB）
    @State private var cachedArtistTracks: [Track] = []
    @State private var artistTracksLoaded = false
    /// artistAlbums 缓存：同 artistTracks（修前是计算属性，单次渲染最多 4 次同步 DB 查询）
    @State private var cachedArtistAlbums: [Album] = []

    private var playerEngine: PlayerEngine {
        appCoordinator.playerEngine
    }

    /// 组内首位歌手（专辑/艺术家信息等用）
    private var artist: Artist {
        artists.first ?? Artist(id: nil, name: "")
    }

    /// 归一显示名（标题 + 网络艺术家信息搜索用）
    private var displayName: String {
        ArtistNameNormalizer.displayName(for: artists.map(\.name))
    }

    private var artistTracks: [Track] {
        // 已缓存：直接返回（body 多次访问不再触发 DB 查询）
        if artistTracksLoaded { return cachedArtistTracks }
        // 未加载（首次渲染前）：先用内存过滤兜底，避免空列表闪烁
        return allTracks.filter { track in
            artists.contains { $0.id == track.artistId }
        }
    }

    private func loadArtistTracks() {
        let tracks: [Track]
        let artistIds = artists.compactMap(\.id)
        if !artistIds.isEmpty,
           let databaseTracks = try? appCoordinator.databaseManager.getTracksByArtistIds(artistIds) {
            tracks = databaseTracks
        } else {
            tracks = allTracks.filter { track in
                artists.contains { $0.id == track.artistId }
            }
        }

        // Filter out incompatible formats when connected to CarPlay
        if SFBAudioEngineManager.shared.isCarPlayEnvironment {
            cachedArtistTracks = tracks.filter { track in
                let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
                let incompatibleFormats = ["ogg", "opus", "dsf", "dff"]
                return !incompatibleFormats.contains(ext)
            }
        } else {
            cachedArtistTracks = tracks
        }
        artistTracksLoaded = true
    }

    private var artistAlbums: [Album] {
        // 已缓存：直接返回（body 不再触发 DB 查询）
        cachedArtistAlbums
    }

    private func loadArtistAlbums() {
        guard let artistId = artist.id else {
            cachedArtistAlbums = []
            return
        }
        cachedArtistAlbums = (try? appCoordinator.databaseManager.getAlbumsByArtistId(artistId)) ?? []
    }

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .artistDetail)

            Group {
                if let unifiedArtist = unifiedArtist, !isLoading {
                    richArtistView(unifiedArtist)
                } else {
                    simpleView
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .trackBulkActions(
            tracks: artistTracks,
            isBulkMode: $isBulkMode,
            selectedTracks: $selectedTracks
        )
        .onAppear {
            loadArtistData()
            loadArtistTracks()
            loadArtistAlbums()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            // 曲库刷新后重建曲目/专辑缓存（替代计算属性每次访问查库）
            loadArtistTracks()
            loadArtistAlbums()
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
        }
    }

    private func toggleSelection(_ track: Track) {
        if selectedTracks.contains(track.stableId) {
            selectedTracks.remove(track.stableId)
        } else {
            selectedTracks.insert(track.stableId)
        }
    }

    @ViewBuilder
    private func richArtistView(_ unifiedArtist: UnifiedArtist) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    headerSection(geometry: geometry)
                    VStack(spacing: 20) {
                        if !artistAlbums.isEmpty { albumsSection }
                        if !artistTracks.isEmpty { songsSection }
                    }
                    .padding(.top, 20)
                    .padding(.bottom, 100) // Add padding for mini player
                }
            }
        }
        .ignoresSafeArea(.all, edges: .top)
    }

    @ViewBuilder
    private var simpleView: some View {
        ScrollView {
            VStack(spacing: 20) {
                simpleHeader
                if !artistAlbums.isEmpty { albumsSection }
                if !artistTracks.isEmpty { songsSection }
            }
            .padding(.bottom, 100) // Add padding for mini player
        }
    }

    // MARK: - Subsections

    @ViewBuilder
    private func headerSection(geometry: GeometryProxy) -> some View {
        let safeAreaTop = geometry.safeAreaInsets.top
        let imageHeight: CGFloat = 300 + safeAreaTop

        VStack(spacing: 16) {
            ZStack {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: geometry.size.width, height: imageHeight)
                    .clipped()
                    .overlay {
                        if let image = artistImage {
                            Image(uiImage: image)
                                .resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: imageHeight)
                                .clipped()
                        } else {
                            Image(systemName: "person.circle")
                                .font(.system(size: 60))
                                .foregroundColor(.secondary)
                        }
                    }
                    .overlay(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.clear,
                                Color.black.opacity(0.3),
                                Color.black.opacity(0.6),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                VStack {
                    HStack {
                        Spacer()
                        if let unifiedArtist = unifiedArtist, unifiedArtist.source == .spotify {
                            Image("SpotifyWhite")
                                .resizable().scaledToFit()
                                .frame(width: 21, height: 21)
                                .padding(.top, 16)
                                .padding(.trailing, 20)
                        }
                    }
                    Spacer()
                    HStack {
                        Text(displayName)
                            .font(.title)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                            .padding(.leading, 20)
                            .padding(.bottom, 20)
                        Spacer()
                    }
                }
            }
            .overlay(
                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color(UIColor.systemBackground).opacity(0.3),
                            Color(UIColor.systemBackground).opacity(0.7),
                            Color(UIColor.systemBackground),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 20)
                }
            )
            .frame(maxWidth: .infinity)

            VStack(spacing: 16) {
                if let unifiedArtist = unifiedArtist, !unifiedArtist.profile.isEmpty {
                    profileSection(unifiedArtist)
                }

                playButtons
            }
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var simpleHeader: some View {
        VStack(spacing: 16) {
            Text(displayName)
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            if isLoading {
                ProgressView("fetching_artist_info".localized)
            }
            playButtons
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func profileSection(_ unifiedArtist: UnifiedArtist) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if unifiedArtist.source == .spotify {
                // Spotify content with attribution
                Text(unifiedArtist.profile)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .lineLimit(showFullProfile ? nil : 3)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) { showFullProfile.toggle() }
                    }

                if showFullProfile {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            Text(Localized.dataProvidedBy("Spotify"))
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if let spotifyArtist = unifiedArtist.spotifyArtist,
                               let spotifyURL = spotifyArtist.externalUrls.spotify {
                                Button(Localized.openSpotify) {
                                    if let url = URL(string: spotifyURL) {
                                        #if os(macOS)
                                            NSWorkspace.shared.open(url)
                                        #else
                                            UIApplication.shared.open(url)
                                        #endif
                                    }
                                }
                                .font(.caption)
                                .foregroundColor(settings.backgroundColorChoice.color)
                            }
                        }

                        // Show "Wrong artist?" button in expanded profile
                        Button(action: {
                            Task {
                                await searchAlternativeArtistAutomatically()
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "questionmark.circle")
                                Text(Localized.wrongArtist)
                            }
                            .font(.caption)
                            .foregroundColor(.orange)
                        }
                    }
                    .padding(.top, 4)
                }
            } else {
                // Discogs or other source content
                Text(unifiedArtist.profile)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .lineLimit(showFullProfile ? nil : 3)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.3)) { showFullProfile.toggle() }
                    }

                if showFullProfile {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Localized.dataProvidedBy(unifiedArtist.source.rawValue.capitalized))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // Show "Wrong artist?" button in expanded profile
                        Button(action: {
                            Task {
                                await searchAlternativeArtistAutomatically()
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "questionmark.circle")
                                Text(Localized.wrongArtist)
                            }
                            .font(.caption)
                            .foregroundColor(.orange)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var playButtons: some View {
        HStack(spacing: 20) {
            Button {
                guard let first = artistTracks.first else { return }
                Task { await playerEngine.playTrack(first, queue: artistTracks) }
            } label: {
                HStack { Image(systemName: "play.fill"); Text(Localized.play).lineLimit(1).minimumScaleFactor(0.6) }
                    .font(.title3).fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(settings.backgroundColorChoice.color)
                    .cornerRadius(25)
            }
            Button {
                let shuffled = artistTracks.shuffled()
                guard let first = shuffled.first else { return }
                Task { await playerEngine.playTrack(first, queue: shuffled) }
            } label: {
                HStack { Image(systemName: "shuffle"); Text(Localized.shuffle).lineLimit(1).minimumScaleFactor(0.6) }
                    .font(.title3).fontWeight(.semibold)
                    .foregroundColor(settings.backgroundColorChoice.color)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(settings.backgroundColorChoice.color.opacity(0.1))
                    .cornerRadius(25)
            }
        }
    }

    private var songsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Localized.songs).font(.title3).fontWeight(.bold)
                Spacer()
                Text(Localized.songsCount(artistTracks.count))
                    .font(.body).foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
            LazyVStack(spacing: 0) {
                ForEach(artistTracks.indices, id: \.self) { index in
                    let track = artistTracks[index]
                    HStack(spacing: 12) {
                        if isBulkMode {
                            TrackSelectionIndicator(
                                isSelected: selectedTracks.contains(track.stableId),
                                accentColor: settings.backgroundColorChoice.color,
                                onTap: { toggleSelection(track) }
                            )
                            .padding(.leading)
                        }

                        ArtistTrackRowView(track: track) {
                            // While selecting, a tap toggles instead of playing.
                            if isBulkMode {
                                toggleSelection(track)
                            } else {
                                Task { await playerEngine.playTrack(track, queue: artistTracks) }
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 0.5) {
                        guard !isBulkMode else { return }
                        isBulkMode = true
                        selectedTracks.insert(track.stableId)
                    }

                    if index < artistTracks.count - 1 {
                        Divider().padding(.leading, 20)
                    }
                }
            }
        }
    }

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(Localized.albums).font(.title3).fontWeight(.bold)
                Spacer()
                Text(Localized.albumsCount(artistAlbums.count))
                    .font(.body).foregroundColor(.secondary)
            }
            .padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(artistAlbums, id: \.id) { album in
                        NavigationLink {
                            AlbumDetailScreen(album: album, allTracks: allTracks)
                        } label: {
                            ArtistAlbumCardView(album: album, tracks: allTracks)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Data Loading
    private func loadArtistData() {
        guard unifiedArtist == nil && !isLoading else { return }
        isLoading = true
        Task { @MainActor in
            do {
                let fetchedArtist = try await HybridMusicAPIService.shared.searchArtist(name: displayName)
                self.unifiedArtist = fetchedArtist
                self.isLoading = false
                if let fetchedArtist = fetchedArtist { await loadArtistImage(from: fetchedArtist.images) }
            } catch {
                self.isLoading = false
                print("❌ Failed to load artist data: \(error)")
            }
        }
    }

    private func searchAlternativeArtistAutomatically() async {
        isLoading = true

        Task { @MainActor in
            do {
                let currentSource = unifiedArtist?.source

                // First try different source with same name
                print("🔄 Trying different source for: \(displayName)")
                var fetchedArtist = try await HybridMusicAPIService.shared.searchAlternativeArtist(name: displayName, currentSource: currentSource)

                // If that fails, try similar names with different sources
                if fetchedArtist == nil {
                    print("🔄 Trying similar names for: \(displayName)")
                    fetchedArtist = try await HybridMusicAPIService.shared.searchSimilarArtist(originalName: displayName, currentSource: currentSource)
                }

                if let fetchedArtist = fetchedArtist {
                    self.unifiedArtist = fetchedArtist
                    self.artistImage = nil // Clear old image
                    await loadArtistImage(from: fetchedArtist.images)
                    print("✅ Found alternative artist: \(fetchedArtist.name) from \(fetchedArtist.source.rawValue)")
                } else {
                    print("❌ No alternative artist found with different source or similar names")
                }

                self.isLoading = false
            } catch {
                self.isLoading = false
                print("❌ Failed to find alternative artist: \(error)")
            }
        }
    }

    private func loadArtistImage(from images: [UnifiedImage]) async {
        let sortedImages = images.sorted { a, b in
            let aSize = (a.width ?? 0) * (a.height ?? 0)
            let bSize = (b.width ?? 0) * (b.height ?? 0)
            return aSize > bSize
        }
        guard let best = sortedImages.first, let url = URL(string: best.url) else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let img = UIImage(data: data) {
                await MainActor.run { self.artistImage = img }
            }
        } catch {
            print("❌ Failed to load artist image: \(error)")
        }
    }
}
