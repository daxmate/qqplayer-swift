//
//  LibraryView.swift
//  QQPlayer
//
//  音乐库主页面视图壳：stored property 装配 + `body` 分区装配 + 导入面板消费唯一入口
//  （`importMusicFiles`——守卫 `LibraryImportOutcomeTests` 钉住 `processExternalFileOutcome(` 须留本文件）。
//  2026-09-21 拆分（纯搬家，无逻辑变更），同族分片：
//    LibraryView+ImportSupport / +SectionRendering / +SyncFeedback / +SectionRow / +ResponsiveFonts
// target: ios-only（消费端全在 iOS；Mac 侧为 MacLibraryView）
//
import Combine
import GRDB
import SwiftUI

struct LibraryView: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    /// 分片：跨文件可见（原 private）
    @Environment(\.appAccentColor) var accentColor
    let tracks: [Track]
    @Binding var showTutorial: Bool
    @Binding var showPlaylistManagement: Bool
    @Binding var showSettings: Bool
    let onRefresh: () async -> (before: Int, after: Int)
    let onManualSync: (() async -> (before: Int, after: Int))?
    @Environment(AppCoordinator.self) private var appCoordinator
    /// 分片：跨文件可见（原 private）
    @Environment(LibraryIndexer.self) var libraryIndexer
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
    /// 分片：跨文件可见（原 private）
    @State var isRefreshing = false
    /// 分片：跨文件可见（原 private）
    @State var showSyncToast = false
    /// 分片：跨文件可见（原 private）
    @State var syncToastMessage = ""
    /// 分片：跨文件可见（原 private）
    @State var syncToastIcon = "checkmark.circle.fill"
    /// 分片：跨文件可见（原 private）
    @State var syncToastColor = Color.green
    /// 分片：跨文件可见（原 private）
    @State var showMusicPicker = false

    /// 分片：跨文件可见（原 private）
    func importMusicFiles(_ urls: [URL]) {
        Task {
            var tally = ImportOutcomeTally()

            for url in urls {
                // 网络 URL 不在这里自行判定：唯一判定入口是 LibraryIndexer
                // （它会返回 .failed(.unsupportedLocation)）。
                // 安全作用域打不开 = 真的导入不了，计入失败（以前是 print 完静默丢弃）。
                guard url.startAccessingSecurityScopedResource() else {
                    AppLog.error(.ui, "❌ Cannot read file (security scope denied): \(url.lastPathComponent)")
                    tally.failed += 1
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
                    let outcome = await libraryIndexer.processExternalFileOutcome(
                        url,
                        allowExcludedReimport: true
                    )
                    tally.record(outcome)
                    if AppLog.isEnabled(.debug, .ui) { AppLog.debug(.ui, "📥 Import outcome for \(url.lastPathComponent): \(outcome)") }

                } catch {
                    // 书签建不出来：文件以后可能打不开。以前这条只 print 就吞了 → 计入 failed。
                    AppLog.error(.ui, "❌ Failed to create bookmark for \(url.lastPathComponent): \(error)")
                    tally.failed += 1

                    // Still try to process the file even if bookmark creation fails
                    let outcome = await libraryIndexer.processExternalFileOutcome(
                        url,
                        allowExcludedReimport: true
                    )
                    tally.record(outcome)
                    if AppLog.isEnabled(.debug, .ui) { AppLog.debug(.ui, "📥 Import outcome for \(url.lastPathComponent) (no bookmark): \(outcome)") }
                }
            }

            // Show feedback
            await MainActor.run {
                guard !tally.isEmpty else { return }

                syncToastIcon = tally.icon
                syncToastColor = tally.color
                syncToastMessage = tally.summary

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

            // Trigger library refresh to update UI
            if tally.changedLibrary, let onManualSync = onManualSync {
                _ = await onManualSync()
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScreenSpecificBackgroundView(screen: .library)

                VStack(spacing: DesignTokens.space0) {
                    // Compact processing status at the top of library
                    if libraryIndexer.isIndexing && !libraryIndexer.currentlyProcessing.isEmpty {
                        HStack(spacing: DesignTokens.space8) {
                            ProgressView()
                                .scaleEffect(0.6)
                                .frame(width: 12, height: 12)

                            Text("\(Localized.processing): \(libraryIndexer.currentlyProcessing)")
                                .font(.caption2)
                                .foregroundColor(accentColor)
                                .lineLimit(1)

                            Spacer()
                        }
                        .padding(.horizontal, DesignTokens.space16)
                        .padding(.vertical, DesignTokens.space6)
                        .background(accentColor.opacity(0.05))
                    }

                    // Large section rows
                    ScrollView {
                        VStack(spacing: DesignTokens.space16) {
                            // Library title with icons that scrolls with content
                            HStack(alignment: .center) {
                                HStack(spacing: DesignTokens.space10) {
                                    Image("AppLogo")
                                        .resizable()
                                        .scaledToFit()
                                        .frame(width: 32, height: 32)
                                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius8))

                                    Text(Localized.library)
                                        .responsiveLibraryTitleFont()
                                        .foregroundColor(.primary)
                                }

                                Spacer()

                                HStack(spacing: DesignTokens.space20) {
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
                                                        .progressViewStyle(CircularProgressViewStyle(tint: accentColor))
                                                } else {
                                                    Image(systemName: "arrow.clockwise")
                                                        .font(.system(size: DesignTokens.font26, weight: .medium))
                                                        .foregroundColor(accentColor)
                                                }
                                            }
                                            .padding(.bottom, DesignTokens.space4)
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
                                            .font(.system(size: DesignTokens.font26, weight: .medium))
                                            .foregroundColor(accentColor)
                                    }

                                    // Settings button
                                    Button(action: {
                                        showSettings = true
                                    }) {
                                        Image(systemName: "gearshape")
                                            .font(.system(size: DesignTokens.font26, weight: .medium))
                                            .foregroundColor(accentColor)
                                    }
                                }
                            }
                            .padding(.leading, DesignTokens.space4)
                            .padding(.trailing, DesignTokens.space4)
                            ForEach(settings.homeSections.filter(\.isVisible)) { section in
                                homeSectionView(for: section.id)
                            }
                        }
                        .padding(DesignTokens.space16)
                        .padding(.bottom, DesignTokens.space100) // Add padding for mini player
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
        .onReceive(NotificationCenter.default.publisher(for: .navigateToArtistFromPlayer)) { notification in
            if let userInfo = notification.userInfo,
               let artist = userInfo["artist"] as? Artist,
               let allTracks = userInfo["allTracks"] as? [Track] {
                artistToNavigate = artist
                artistAllTracks = allTracks
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToAlbumFromPlayer)) { notification in
            if let userInfo = notification.userInfo,
               let album = userInfo["album"] as? Album,
               let allTracks = userInfo["allTracks"] as? [Track] {
                albumToNavigate = album
                albumAllTracks = allTracks
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToPlaylist)) { notification in
            if let userInfo = notification.userInfo,
               let playlistId = userInfo["playlistId"] as? Int64 {
                do {
                    let playlists = try appCoordinator.databaseManager.getAllPlaylists()
                    if let playlist = playlists.first(where: { $0.id == playlistId }) {
                        playlistToNavigate = playlist
                        AppLog.info(.ui, "✅ LibraryView: Navigating to playlist \(playlist.title)")
                    }
                } catch {
                    AppLog.error(.ui, "❌ LibraryView: Failed to find playlist: \(error)")
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
                                .font(.system(size: DesignTokens.font16, weight: .medium))
                            Text(syncToastMessage)
                                .font(.system(size: DesignTokens.font14, weight: .medium))
                                .foregroundColor(.primary)
                        }
                        .padding(.horizontal, DesignTokens.space16)
                        .padding(.vertical, DesignTokens.space12)
                        .background(
                            RoundedRectangle(cornerRadius: DesignTokens.radius12)
                                .fill(.regularMaterial)
                                .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 6)
                        )
                        .padding(.horizontal, DesignTokens.space20)
                        .padding(.bottom, DesignTokens.space120) // Space above mini player
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
            .accentColor(accentColor)
        }
        .sheet(isPresented: $showMusicPicker) {
            MusicFilePicker { urls in
                importMusicFiles(urls)
            }
        }
    }

}
