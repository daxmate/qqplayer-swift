//
//  SearchResultsViews+SongRow.swift
//  QQPlayer
//
//  搜索结果**歌曲行**：滑动「下一首播放 / 加入队列」气泡、封面缩略图、
//  播放中标记（均衡器条）、时长，以及右键菜单（收藏 / 播放 / 队列 / 删除 / 歌手页）。
//
//  2026-09-21 从 SearchResultsViews.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Library/SearchResultsViews.swift             — 结果页主体：SearchCategory / SearchResults / SearchResultsView 分区装配
//    · Views/Library/SearchResultsViews+ArtistRows.swift  — 歌手行 + 歌手专辑横滑
//    · Views/Library/SearchResultsViews+AlbumRow.swift    — 专辑行
//    · Views/Library/SearchResultsViews+PlaylistRow.swift — 歌单行
//
// target: ios-only（SearchResultsViews 分片：消费端全在 iOS）
import SwiftUI

struct SearchSongRowView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.appAccentColor) private var accentColor // App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    let track: Track
    let allTracks: [Track]
    let artistName: String?
    let onDismiss: () -> Void
    @Environment(AppCoordinator.self) private var appCoordinator
    @Environment(PlayerEngine.self) private var playerEngine
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
                        .font(.system(size: DesignTokens.font14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(accentColor)
                        .clipShape(Circle())
                        .opacity(min(Double(swipeOffset) / swipeThreshold, 1.0))
                        .scaleEffect(min(Double(swipeOffset) / swipeThreshold, 1.0))
                        .padding(.leading, DesignTokens.space8)
                }

                Spacer()

                // Right side - Add to Queue bubble (appears on left swipe)
                if swipeOffset < 0 {
                    Image(systemName: "text.append")
                        .font(.system(size: DesignTokens.font14, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 36, height: 36)
                        .background(.blue)
                        .clipShape(Circle())
                        .opacity(min(Double(-swipeOffset) / swipeThreshold, 1.0))
                        .scaleEffect(min(Double(-swipeOffset) / swipeThreshold, 1.0))
                        .padding(.trailing, DesignTokens.space8)
                }
            }

            // Main content
            HStack(spacing: DesignTokens.space12) {
                // Album artwork
                ZStack {
                    Group {
                        if let artworkImage = artworkImage {
                            Image(uiImage: artworkImage)
                                .resizable().scaledToFill()
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: DesignTokens.font16))
                                .foregroundColor(accentColor)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius6))
                    .background(Color(.systemGray5))

                    if isCurrentlyPlaying {
                        RoundedRectangle(cornerRadius: DesignTokens.radius6)
                            .stroke(accentColor, lineWidth: 1.5)
                            .frame(width: 40, height: 40)
                    }
                }

                VStack(alignment: .leading, spacing: DesignTokens.space4) {
                    Text(track.displayTitle)
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(isCurrentlyPlaying ? accentColor : .primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.leading)

                    if let artistName, !artistName.isEmpty {
                        Text(artistName)
                            .font(.caption)
                            .foregroundColor(isCurrentlyPlaying ? accentColor.opacity(0.8) : .secondary)
                    }
                }

                Spacer()

                // Currently playing indicator
                if isCurrentlyPlaying {
                    let eqKey = "\(playerEngine.isPlaying && isCurrentlyPlaying)-\(playerEngine.currentTrack?.stableId ?? "")"

                    EqualizerBarsExact(
                        color: accentColor,
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
            .padding(.horizontal, DesignTokens.space16)
            .padding(.vertical, DesignTokens.space12)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.radius12)
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
                        AppLog.error(.ui, "Failed to toggle favorite: \(error)")
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
                   let artist = try? LibraryReads.artist(id: artistId),
                   let allArtistTracks = try? LibraryReads.tracks(artistId: artistId) {
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
                .accentColor(accentColor)
        }
        .alert(Localized.deleteFile, isPresented: $showDeleteConfirmation) {
            Button(Localized.delete, role: .destructive) {
                deleteFile()
            }
            Button(Localized.cancel, role: .cancel) { }
        } message: {
            Text(Localized.deleteFileConfirmation(track.displayTitle))
        }
    }

    private func checkFavoriteStatus() {
        do {
            isFavorite = try LibraryReads.isFavorite(trackStableId: track.stableId)
        } catch {
            AppLog.error(.ui, "Failed to check favorite status: \(error)")
        }
    }

    private func loadArtwork() {
        Task {
            artworkImage = await services.artworkManager.getThumbnail(for: track)
        }
    }

    private func deleteFile() {
        Task {
            // 删除仪式（设置分支 / 删文件 / 删 DB 引用 / 通知刷新）见 TrackDeletionService
            TrackDeletionService.delete(items: [TrackDeletionService.Item(track: track)])
        }
    }

    private func formatDuration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

}
