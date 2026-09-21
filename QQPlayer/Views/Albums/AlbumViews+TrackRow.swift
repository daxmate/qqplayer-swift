//
//  AlbumViews+TrackRow.swift
//  QQPlayer
//
//  专辑**曲目行** `AlbumTrackRowView`（序号 / 标题 / 歌手 / 时长 / 收藏菜单 / 批量选择入口）
//  与**歌手页包装** `ArtistDetailScreenWrapper`（按名字查歌手 → ArtistDetailScreen）。
//
//  2026-09-21 从 AlbumViews.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Albums/AlbumViews.swift           — 专辑列表/网格主体：AlbumsScreen + 空态 + 专辑卡片
//    · Views/Albums/AlbumViews+AlbumDetail.swift — 专辑详情页
//
// target: ios-only（AlbumViews 分片：消费端全在 iOS，与原文件归属一致）
import SwiftUI

struct AlbumTrackRowView: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    let track: Track
    let trackNumber: Int
    let artistName: String?
    let onTap: () -> Void
    /// Menu entry point into multi-select. The long press is unreliable over
    /// this row's Button root, so the menu is the dependable route.
    let onEnterBulkMode: (() -> Void)?
    @Environment(AppCoordinator.self) private var appCoordinator
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var showDeleteConfirmation = false
    @State private var deleteSettings = DeleteSettings.load()
    /// Menu 交互中标记（仿 ArtistTrackRowView）：菜单点开时抑制行点击，避免菜单手势与行 tap 竞争
    @State private var isMenuInteracting = false

    var body: some View {
        HStack(spacing: DesignTokens.space8) {
            // Track number
            Text("\(trackNumber)")
                .font(.body)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .frame(width: 22, alignment: .leading)

            // Track info
            VStack(alignment: .leading, spacing: DesignTokens.space4) {
                Text(track.displayTitle)
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)

                // Artist name and duration with dot separator
                HStack(spacing: DesignTokens.space0) {
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
                        AppLog.error(.ui, "Failed to toggle favorite: \(error)")
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
                   let artist = try? LibraryReads.artist(id: artistId),
                   let allArtistTracks = try? LibraryReads.tracks(artistId: artistId) {
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
        .padding(.vertical, DesignTokens.space8)
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

    private func formatDuration(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func deleteFile() {
        Task {
            // 删除仪式（设置分支 / 删文件 / 删 DB 引用 / 通知刷新）见 TrackDeletionService
            TrackDeletionService.delete(items: [TrackDeletionService.Item(track: track)])
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
                VStack(spacing: DesignTokens.space16) {
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
            let matched = try LibraryReads.searchArtists(query: artistName, limit: 100)
            let grouped = ArtistNameNormalizer.groupedArtists(matched)
            let target = grouped.first { $0.artists.contains { $0.name == artistName } } ?? grouped.first
            artists = target?.artists ?? [Artist(id: nil, name: artistName)]
        } catch {
            AppLog.error(.ui, "Failed to load artist: \(error)")
            artists = [Artist(id: nil, name: artistName)]
        }
    }
}
