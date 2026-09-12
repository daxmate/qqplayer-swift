import Combine
import GRDB
import SwiftUI

// MARK: - Responsive Font Helper
extension View {
    func responsiveLibraryTitleFont() -> some View {
        self.font(.title)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .fontWeight(.bold)
    }

    func responsiveSectionTitleFont() -> some View {
        self.font(.title2)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .fontWeight(.semibold)
    }
}

struct LibraryView: View {
    let tracks: [Track]
    @Binding var showTutorial: Bool
    @Binding var showPlaylistManagement: Bool
    @Binding var showSettings: Bool
    let onRefresh: () async -> (before: Int, after: Int)
    let onManualSync: (() async -> (before: Int, after: Int))?
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @StateObject private var libraryIndexer = LibraryIndexer.shared
    @State private var artistToNavigate: Artist?
    @State private var artistAllTracks: [Track] = []
    @State private var albumToNavigate: Album?
    @State private var albumAllTracks: [Track] = []
    @State private var searchArtistToNavigate: Artist?
    @State private var searchArtistTracks: [Track] = []
    @State private var searchAlbumToNavigate: Album?
    @State private var searchAlbumTracks: [Track] = []
    @State private var searchPlaylistToNavigate: Playlist?
    @State private var playlistToNavigate: Playlist?
    @State private var showSearch = false
    @State private var settings = DeleteSettings.load()
    @State private var isRefreshing = false
    @State private var showSyncToast = false
    @State private var syncToastMessage = ""
    @State private var syncToastIcon = "checkmark.circle.fill"
    @State private var syncToastColor = Color.green
    @State private var showMusicPicker = false

    // Helper function to show sync feedback
    private func showSyncFeedback(trackCountBefore: Int, trackCountAfter: Int) {
        let trackDifference = trackCountAfter - trackCountBefore

        // Set appropriate message and icon based on changes
        if trackDifference > 0 {
            // New tracks added
            syncToastIcon = "plus.circle.fill"
            syncToastColor = .green
            if trackDifference == 1 {
                syncToastMessage = NSLocalizedString("sync_one_new_track", value: "1 new song found", comment: "")
            } else {
                syncToastMessage = String(format: NSLocalizedString("sync_multiple_new_tracks", value: "%d new songs found", comment: ""), trackDifference)
            }
        } else if trackDifference < 0 {
            // Tracks removed
            let deletedCount = abs(trackDifference)
            syncToastIcon = "minus.circle.fill"
            syncToastColor = .orange
            if deletedCount == 1 {
                syncToastMessage = NSLocalizedString("sync_one_track_deleted", value: "1 song removed", comment: "")
            } else {
                syncToastMessage = String(format: NSLocalizedString("sync_multiple_tracks_deleted", value: "%d songs removed", comment: ""), deletedCount)
            }
        } else {
            // No changes
            syncToastIcon = "checkmark.circle.fill"
            syncToastColor = .blue
            syncToastMessage = NSLocalizedString("sync_no_changes", value: "Library is up to date", comment: "")
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            showSyncToast = true
        }

        // Auto-hide toast after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeInOut(duration: 0.3)) {
                showSyncToast = false
            }
        }
    }

    private func importMusicFiles(_ urls: [URL]) {
        Task {
            var addedCount = 0
            var skippedCount = 0

            for url in urls {
                // Reject network URLs
                if let scheme = url.scheme?.lowercased(), ["http", "https", "ftp", "sftp"].contains(scheme) {
                    print("❌ Rejected network URL: \(url.absoluteString)")
                    continue
                }

                // Start accessing security-scoped resource
                guard url.startAccessingSecurityScopedResource() else {
                    print("Failed to access security scoped resource for: \(url.lastPathComponent)")
                    continue
                }

                defer {
                    url.stopAccessingSecurityScopedResource()
                }

                do {
                    // Create bookmark data for persistent access
                    let bookmarkData = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)

                    // Store bookmark data for this file
                    await storeBookmarkData(bookmarkData, for: url)

                    // Process the file directly from its original location
                    let imported = await libraryIndexer.processExternalFile(url, allowExcludedReimport: true)
                    if imported {
                        addedCount += 1
                        print("✅ Imported and bookmarked file from original location: \(url.lastPathComponent)")
                    } else {
                        skippedCount += 1
                        print("⏭️ Skipped import (already exists/excluded/error): \(url.lastPathComponent)")
                    }

                } catch {
                    print("Failed to create bookmark for \(url.lastPathComponent): \(error)")

                    // Still try to process the file even if bookmark creation fails
                    let imported = await libraryIndexer.processExternalFile(url, allowExcludedReimport: true)
                    if imported {
                        addedCount += 1
                        print("✅ Imported file from original location (no bookmark): \(url.lastPathComponent)")
                    } else {
                        skippedCount += 1
                        print("⏭️ Skipped import (already exists/excluded/error): \(url.lastPathComponent)")
                    }
                }
            }

            // Show feedback
            await MainActor.run {
                if addedCount > 0 || skippedCount > 0 {
                    syncToastIcon = "plus.circle.fill"
                    syncToastColor = .green
                    if skippedCount == 0 {
                        if addedCount == 1 {
                            syncToastMessage = "1 song imported"
                        } else {
                            syncToastMessage = "\(addedCount) songs imported"
                        }
                    } else if addedCount == 0 {
                        syncToastIcon = "info.circle.fill"
                        syncToastColor = .blue
                        syncToastMessage = "\(skippedCount) already in library"
                    } else {
                        syncToastMessage = "\(addedCount) imported, \(skippedCount) skipped"
                    }

                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSyncToast = true
                    }

                    // Auto-hide toast after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            showSyncToast = false
                        }
                    }
                }
            }

            // Trigger library refresh to update UI
            if addedCount > 0, let onManualSync = onManualSync {
                _ = await onManualSync()
            }
        }
    }

    private func storeBookmarkData(_ bookmarkData: Data, for url: URL) async {
        // 书签唯一入口：原子写（此前是原地截断写，被杀即整份书签不可解析，见审计 🔴-2）
        guard let store = ExternalFileBookmarkStore.default else {
            print("Failed to resolve documents directory")
            return
        }

        do {
            // Generate stableId for this file
            let stableId = try libraryIndexer.generateStableId(for: url)

            // Store bookmark using stableId as key (survives file moves)
            try store.upsert(bookmarkData, forStableId: stableId)

            print("Stored bookmark for external file: \(url.lastPathComponent) with stableId: \(stableId)")
        } catch {
            print("Failed to store bookmark data: \(error)")
        }
    }

    @ViewBuilder
    private func homeSectionView(for sectionId: HomeSectionId) -> some View {
        switch sectionId {
        case .allSongs:
            NavigationLink {
                AllSongsScreen(tracks: tracks)
            } label: {
                LibrarySectionRowView(
                    title: Localized.allSongs,
                    subtitle: Localized.songsCountOnly(tracks.count),
                    icon: "music.note",
                    color: settings.backgroundColorChoice.color
                )
            }
            .buttonStyle(PlainButtonStyle())

        case .likedSongs:
            NavigationLink {
                LikedSongsScreen(allTracks: tracks)
            } label: {
                LibrarySectionRowView(
                    title: Localized.likedSongs,
                    subtitle: Localized.yourFavorites,
                    icon: "heart.fill",
                    color: .red
                )
            }
            .buttonStyle(PlainButtonStyle())

        case .playlists:
            NavigationLink {
                PlaylistsScreen()
            } label: {
                LibrarySectionRowView(
                    title: Localized.playlists,
                    subtitle: Localized.yourPlaylists,
                    icon: "music.note.list",
                    color: .green
                )
            }
            .buttonStyle(PlainButtonStyle())

        case .artists:
            NavigationLink {
                ArtistsScreen(allTracks: tracks)
            } label: {
                LibrarySectionRowView(
                    title: Localized.artists,
                    subtitle: Localized.browseByArtist,
                    icon: "person.2.fill",
                    color: .purple
                )
            }
            .buttonStyle(PlainButtonStyle())

        case .albums:
            NavigationLink {
                AlbumsScreen(allTracks: tracks)
            } label: {
                LibrarySectionRowView(
                    title: Localized.albums,
                    subtitle: Localized.browseByAlbum,
                    icon: "opticaldisc.fill",
                    color: .orange
                )
            }
            .buttonStyle(PlainButtonStyle())

        case .addSongs:
            Button(action: {
                showMusicPicker = true
            }) {
                LibrarySectionRowView(
                    title: Localized.addSongs,
                    subtitle: Localized.importMusicFiles,
                    icon: "plus.circle.fill",
                    color: .blue
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenSpecificBackgroundView(screen: .library)

                VStack(spacing: 0) {
                    // Compact processing status at the top of library
                    if libraryIndexer.isIndexing && !libraryIndexer.currentlyProcessing.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)

                            Text("\(Localized.processing): \(libraryIndexer.currentlyProcessing)")
                                .font(.caption2)
                                .foregroundColor(settings.backgroundColorChoice.color)
                                .lineLimit(1)

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(settings.backgroundColorChoice.color.opacity(0.05))
                    }

                    // Large section rows
                    ScrollView {
                        VStack(spacing: 16) {
                            // Library title with icons that scrolls with content
                            HStack(alignment: .center) {
                                HStack(spacing: 10) {
                                    Image("AppLogo")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 32, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))

                                    Text(Localized.library)
                                        .responsiveLibraryTitleFont()
                                        .foregroundColor(.primary)
                                }

                                Spacer()

                                HStack(spacing: 20) {
                                    // Sync button (if available)
                                    if onManualSync != nil {
                                        Button(action: {
                                            guard !isRefreshing else { return }

                                            // Provide immediate haptic feedback
                                            let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
                                            impactFeedback.impactOccurred()

                                            withAnimation(.easeInOut(duration: 0.1)) {
                                                isRefreshing = true
                                            }

                                            Task {
                                                await runSync()
                                            }
                                        }) {
                                            ZStack {
                                                if isRefreshing {
                                                    ProgressView()
                                                        .scaleEffect(0.8)
                                                        .progressViewStyle(CircularProgressViewStyle(tint: settings.backgroundColorChoice.color))
                                                } else {
                                                    Image(systemName: "arrow.clockwise")
                                                        .font(.system(size: 26, weight: .medium))
                                                        .foregroundColor(settings.backgroundColorChoice.color)
                                                }
                                            }
                                            .padding(.bottom, 4)
                                            .scaleEffect(isRefreshing ? 0.9 : 1.0)
                                            .animation(.easeInOut(duration: 0.2), value: isRefreshing)
                                        }
                                        .disabled(isRefreshing)
                                    }

                                    // Search button (center)
                                    Button(action: {
                                        showSearch = true
                                    }) {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 26, weight: .medium))
                                            .foregroundColor(settings.backgroundColorChoice.color)
                                    }

                                    // Settings button
                                    Button(action: {
                                        showSettings = true
                                    }) {
                                        Image(systemName: "gearshape")
                                            .font(.system(size: 26, weight: .medium))
                                            .foregroundColor(settings.backgroundColorChoice.color)
                                    }
                                }
                            }
                            .padding(.leading, 4)
                            .padding(.trailing, 4)
                            ForEach(settings.homeSections.filter(\.isVisible)) { section in
                                homeSectionView(for: section.id)
                            }
                        }
                        .padding(16)
                        .padding(.bottom, 100) // Add padding for mini player
                    }
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.large)
                .refreshable {
                    // Prevent multiple concurrent refreshes (pull-to-refresh also
                    // takes the isRefreshing mutex so it cannot double-run with
                    // the sync button)
                    guard !isRefreshing else { return }

                    // Provide haptic feedback for pull-to-refresh
                    let impactFeedback = UIImpactFeedbackGenerator(style: .light)
                    impactFeedback.impactOccurred()

                    isRefreshing = true
                    await runSync()
                }

            }
            .navigationDestination(isPresented: Binding(
                get: { searchArtistToNavigate != nil },
                set: { if !$0 { searchArtistToNavigate = nil } }
            )) {
                if let artist = searchArtistToNavigate {
                    ArtistDetailScreenWrapper(artistName: artist.name, allTracks: searchArtistTracks)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { searchAlbumToNavigate != nil },
                set: { if !$0 { searchAlbumToNavigate = nil } }
            )) {
                if let album = searchAlbumToNavigate {
                    AlbumDetailScreen(album: album, allTracks: searchAlbumTracks)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { searchPlaylistToNavigate != nil },
                set: { if !$0 { searchPlaylistToNavigate = nil } }
            )) {
                if let playlist = searchPlaylistToNavigate {
                    PlaylistDetailScreen(playlist: playlist)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { playlistToNavigate != nil },
                set: { if !$0 { playlistToNavigate = nil } }
            )) {
                if let playlist = playlistToNavigate {
                    PlaylistDetailScreen(playlist: playlist)
                }
            }
            // 播放器通知驱动的导航：与上面四个 navigationDestination(isPresented:) 统一
            // （原实现为两个隐藏 NavigationLink(isActive:)，iOS 16 起已废弃）
            .navigationDestination(isPresented: Binding(
                get: { artistToNavigate != nil },
                set: { if !$0 { artistToNavigate = nil } }
            )) {
                if let artist = artistToNavigate {
                    ArtistDetailScreenWrapper(artistName: artist.name, allTracks: artistAllTracks)
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { albumToNavigate != nil },
                set: { if !$0 { albumToNavigate = nil } }
            )) {
                if let album = albumToNavigate {
                    AlbumDetailScreen(album: album, allTracks: albumAllTracks)
                }
            }
        }
        .background(.clear)
        .toolbarBackground(.clear, for: .navigationBar)
        .toolbarBackground(.clear, for: .automatic)
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToArtistFromPlayer"))) { notification in
            if let userInfo = notification.userInfo,
               let artist = userInfo["artist"] as? Artist,
               let allTracks = userInfo["allTracks"] as? [Track] {
                artistToNavigate = artist
                artistAllTracks = allTracks
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToAlbumFromPlayer"))) { notification in
            if let userInfo = notification.userInfo,
               let album = userInfo["album"] as? Album,
               let allTracks = userInfo["allTracks"] as? [Track] {
                albumToNavigate = album
                albumAllTracks = allTracks
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("NavigateToPlaylist"))) { notification in
            if let userInfo = notification.userInfo,
               let playlistId = userInfo["playlistId"] as? Int64 {
                do {
                    let playlists = try appCoordinator.databaseManager.getAllPlaylists()
                    if let playlist = playlists.first(where: { $0.id == playlistId }) {
                        playlistToNavigate = playlist
                        print("✅ LibraryView: Navigating to playlist \(playlist.title)")
                    }
                } catch {
                    print("❌ LibraryView: Failed to find playlist: \(error)")
                }
            }
        }
        .overlay(
            // Sync result toast notification
            Group {
                if showSyncToast {
                    VStack {
                        Spacer()
                        HStack {
                            Image(systemName: syncToastIcon)
                                .foregroundColor(syncToastColor)
                                .font(.system(size: 16, weight: .medium))
                            Text(syncToastMessage)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(.regularMaterial)
                                .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)
                        )
                        .padding(.horizontal, 20)
                        .padding(.bottom, 120) // Space above mini player
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.3), value: showSyncToast)
        )
        .sheet(isPresented: $showSearch) {
            SearchView(
                allTracks: tracks,
                onNavigateToArtist: { artist, tracks in
                    searchArtistToNavigate = artist
                    searchArtistTracks = tracks
                },
                onNavigateToAlbum: { album, tracks in
                    searchAlbumToNavigate = album
                    searchAlbumTracks = tracks
                },
                onNavigateToPlaylist: { playlist in
                    searchPlaylistToNavigate = playlist
                }
            )
            .accentColor(settings.backgroundColorChoice.color)
        }
        .sheet(isPresented: $showMusicPicker) {
            MusicFilePicker { urls in
                importMusicFiles(urls)
            }
        }
    }

    /// 统一同步入口（按钮与下拉刷新共用）：isRefreshing 互斥 + 无忙等等待索引完成。
    /// 等待索引走 IndexingGate（唯一实现，带超时兜底）：索引异常时不会再永久卡住同步按钮。
    private func runSync() async {
        let outcome = await IndexingGate.waitUntilIdle(libraryIndexer)
        if outcome == .timedOut {
            print("⏱️ LibrarySync: indexing wait timed out — proceeding without waiting")
        }

        // For pull-to-refresh, use manual sync if available, otherwise just refresh
        let result: (before: Int, after: Int)
        if let onManualSync = onManualSync {
            result = await onManualSync() // Full sync + refresh
        } else {
            result = await onRefresh()    // Just refresh
        }

        // Show feedback after sync/refresh is complete
        await MainActor.run {
            isRefreshing = false
            showSyncFeedback(trackCountBefore: result.before, trackCountAfter: result.after)
        }
    }
}

struct LibrarySectionRowView: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    @State private var settings = DeleteSettings.load()

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            if settings.minimalistIcons {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 60, height: 60)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(color.opacity(0.2))
                        .frame(width: 60, height: 60)

                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(color)
                }
            }

            // Text content
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .responsiveSectionTitleFont()
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Chevron
            Image(systemName: "chevron.right")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            // Glassy background that reflects gradient
            RoundedRectangle(cornerRadius: 12)
                .fill(.ultraThinMaterial)
                .opacity(0.8)
        )
        .cornerRadius(12)
        .shadow(color: settings.backgroundColorChoice.color.opacity(0.15), radius: 4, x: 0, y: 2)
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
            settings = DeleteSettings.load()
        }
    }
}
