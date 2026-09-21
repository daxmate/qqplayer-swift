//
//  AlbumViews+AlbumDetail.swift
//  QQPlayer
//
//  专辑**详情页** `AlbumDetailScreen`：封面/信息头 + 播放/随机 + 多碟分组曲目列表 +
//  批量选择（trackBulkActions）+ 收藏状态 / 歌手名缓存加载。
//
//  2026-09-21 从 AlbumViews.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Albums/AlbumViews.swift          — 专辑列表/网格主体：AlbumsScreen + 空态 + 专辑卡片
//    · Views/Albums/AlbumViews+TrackRow.swift — 专辑曲目行 + 歌手页包装
//
// target: ios-only（AlbumViews 分片：消费端全在 iOS，与原文件归属一致）
import SwiftUI

// Album detail view reconstructed
struct AlbumDetailScreen: View {
    @Environment(AppServices.self) private var services
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    let album: Album
    let allTracks: [Track]
    @Environment(AppCoordinator.self) private var appCoordinator
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
        // CarPlay 连接时剔除不兼容格式（名单与判据的唯一入口 = CarPlayTrackFilter）
        CarPlayTrackFilter.filtered(albumTracks)
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
                VStack(spacing: DesignTokens.space24) {
                    // Artwork + info
                    VStack(spacing: DesignTokens.space16) {
                        RoundedRectangle(cornerRadius: DesignTokens.radius12)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 250, height: 250)
                            .overlay {
                                if let image = artworkImage {
                                    Image(uiImage: image)
                                        .resizable().scaledToFill()
                                        .frame(width: 250, height: 250)
                                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius12))
                                } else {
                                    Image(systemName: "music.note")
                                        .font(.system(size: DesignTokens.font50))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)

                        VStack(spacing: DesignTokens.space8) {
                            Text(album.displayTitle)
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

                        HStack(spacing: DesignTokens.space12) {
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
                                .padding(.horizontal, DesignTokens.space8)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(accentColor)
                                .cornerRadius(DesignTokens.radius28)
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
                                .foregroundColor(accentColor)
                                .padding(.horizontal, DesignTokens.space8)
                                .frame(maxWidth: .infinity)
                                .frame(height: 56)
                                .background(accentColor.opacity(0.1))
                                .cornerRadius(DesignTokens.radius28)
                            }
                        }
                        .padding(.horizontal, DesignTokens.space8)
                    }
                    .padding(.horizontal)

                    // Track list
                    VStack(alignment: .leading, spacing: DesignTokens.space0) {
                        HStack {
                            Text(Localized.songs)
                                .font(.title3.weight(.bold))
                            Spacer()
                            Text(Localized.songsCount(filteredAlbumTracks.count))
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.bottom, DesignTokens.space12)

                        LazyVStack(spacing: DesignTokens.space0) {
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
                                    .padding(.top, disc.discNumber > 1 ? DesignTokens.space16 : DesignTokens.space0)
                                    .padding(.bottom, DesignTokens.space8)
                                }

                                // Tracks for this disc
                                ForEach(Array(disc.tracks.enumerated()), id: \.element.stableId) { index, track in
                                    HStack(spacing: DesignTokens.space12) {
                                        if isBulkMode {
                                            TrackSelectionIndicator(
                                                isSelected: selectedTracks.contains(track.stableId),
                                                onTap: { toggleSelection(track) }
                                            )
                                            .padding(.leading)
                                        }

                                        AlbumTrackRowView(
                                            track: track,
                                            trackNumber: track.trackNo ?? (index + 1),
                                            artistName: (try? LibraryReads.artistDisplayName(forTrackStableId: track.stableId, fallbackArtistId: track.artistId)) ?? track.artistId.flatMap { artistNameCache[$0] },
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
                                    // simultaneousGesture rather than onLongPressGesture: this row's root is a
                                    // Button, whose own press recogniser wins an ordinary long press, so
                                    // selection could never be entered by holding a track.
                                    .simultaneousGesture(
                                        LongPressGesture(minimumDuration: 0.5)
                                            .onEnded { _ in beginSelection(with: track) }
                                    )

                                    // Add divider between tracks (not after last track of last disc)
                                    let isLastTrackOfDisc = index == disc.tracks.count - 1
                                    let isLastDisc = disc.discNumber == groupedByDisc.last?.discNumber
                                    if !isLastTrackOfDisc || !isLastDisc {
                                        Divider().padding(.leading, DesignTokens.space64)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, DesignTokens.space100) // Add padding for mini player
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
        .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
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
            AppLog.error(.ui, "Failed to load album tracks: \(error)")
        }
    }

    private func loadAlbumArtwork() {
        guard let first = filteredAlbumTracks.first else { return }
        Task {
            do {
                let image = await services.artworkManager.getArtwork(for: first)
                await MainActor.run {
                    artworkImage = image
                }
            }
        }
    }

    private func loadArtistNameCache() {
        do {
            artistNameCache = try LibraryReads.artistNamesById()
        } catch {
            AppLog.error(.ui, "Failed to load album artist cache: \(error)")
        }
    }
}
