//
//  PlaylistDetailScreen.swift
//  QQPlayer
//
//  歌单**详情页**主体：全部 stored property（曲目/编辑态/封面/排序/歌手名缓存）+ `body`
//  （封面区 + 歌单信息 + 曲目列表 + 滑动操作 + 排序菜单 + 封面选择）。
//  其余按职责分片（2026-09-21 拆分，纯搬家、无逻辑变更）：
//    · Views/Playlists/PlaylistDetailScreen+DataLoading.swift — 曲目/歌手名缓存加载
//    · Views/Playlists/PlaylistDetailScreen+PlaybackActions.swift — 播放引擎门面 + 行操作反馈
//    · Views/Playlists/PlaylistDetailScreen+Sorting.swift — 排序求值 + 排序偏好持久化
//    · Views/Playlists/PlaylistDetailScreen+CustomCover.swift — 封面小图 + 自定义封面读写
//
import PhotosUI
import SwiftUI
import WidgetKit

struct PlaylistDetailScreen: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    let playlist: Playlist
    /// 分片：跨文件可见（原 private）
    @Environment(AppCoordinator.self) var appCoordinator
    /// 分片：跨文件可见（原 private）
    @State var tracks: [Track] = []
    @State private var isEditMode: Bool = false
    /// 分片：跨文件可见（原 private）
    @State var artworks: [UIImage] = []
    @State private var settings = DeleteSettings.load()
    /// 分片：跨文件可见（原 private）
    @State var sortOption: TrackSortOption = .playlistOrder
    @State private var showSortMenu = false
    /// 分片：跨文件可见（原 private）
    @State var recentlyActedTracks: Set<String> = []
    /// 分片：跨文件可见（原 private）
    @Environment(AppServices.self) var services
    @State private var showingImagePicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?
    /// 分片：跨文件可见（原 private）
    @State var customCoverImage: UIImage?
    /// 分片：跨文件可见（原 private）
    /// 歌单自定义封面读取失败的登记（INV-22 另一半：读不到必须计数 + 就地说明）。
    @Environment(PlaylistCoverLoadFailuresStore.self) var coverFailures
    @State private var showCoverOptions = false
    /// 分片：跨文件可见（原 private）
    @State var artistNameCache: [Int64: String] = [:]
    /// 分片：跨文件可见（原 private）
    @State var artistDisplayNameCache: [String: String] = [:]
    /// 分片：跨文件可见（原 private）
    /// 按歌手排序时的歌手名缓存（.task 按需加载，替代 sortedTracks 每次求值全表查询）
    @State var artistSortCache: [Int64: String] = [:]

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
                                AppLog.error(.ui, "Failed to reorder tracks: \(error)")
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

}
