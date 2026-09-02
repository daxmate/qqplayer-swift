//
//  MacTrackListView.swift
//  QQPlayer
//
//  macOS track list (content column for the 歌曲 section). QQPlayerMac target only.
//
//  2026-09-02 A3：Table → List 重写——自定义表头支持列头三态排序
//  （升序→降序→默认，web 版语义，TrackListSort 纯逻辑共享）与「定位当前
//  播放」（ScrollViewReader scrollTo）；右键菜单补全：下一首播放 / 进歌手 /
//  进专辑（可选回调，非 nil 才显示，播放列表 sheet 里可裁剪）。
//

import SwiftUI

struct MacTrackListView: View {
    let tracks: [Track]
    let activeTrackId: String?
    let isPlaying: Bool
    let artistNameResolver: (Track) -> String?
    /// 双击/播放回调：队列 = 当前排序后显示列表（web 版「以当前视图为队列」语义）
    let onPlay: (Track, [Track]) -> Void
    let onSelect: (Track) -> Void
    /// Non-nil inside a playlist detail sheet: the context menu additionally
    /// offers "remove from playlist" for the owning playlist.
    var playlistId: Int64?
    /// 「下一首播放」：插入当前播放曲目之后（不播放）
    var onPlayNext: ((Track) -> Void)?
    /// 「进歌手 / 进专辑」：切到对应分组并打开详情
    var onShowArtist: ((Track) -> Void)?
    var onShowAlbum: ((Track) -> Void)?

    /// 单击选中的行（单击=播放+选中，对齐 web/iOS 语义；多选待 A4）
    @State private var selectedRowID: String?
    @State private var favoriteIds: Set<String> = []
    @State private var playlists: [Playlist] = []
    @State private var showNewPlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var pendingTrack: Track?
    /// 列头排序（三态：升 → 降 → 默认）
    @State private var sort = TrackListSort()

    private let trackNoWidth: CGFloat = 26
    private let artistColumnWidth: CGFloat = 130
    private let durationColumnWidth: CGFloat = 54
    private let heartColumnWidth: CGFloat = 30
    private let rowSpacing: CGFloat = 6

    /// 排序后显示列表（默认顺序 = tracks 原序）
    private var displayedTracks: [Track] {
        guard let key = sort.key else { return tracks }
        let direction = sort.direction ?? .ascending
        let sorted = tracks.sorted { lhs, rhs in
            let result: ComparisonResult
            switch key {
            case .title:
                result = lhs.title.localizedStandardCompare(rhs.title)
            case .artist:
                let lhsName = artistNameResolver(lhs) ?? ""
                let rhsName = artistNameResolver(rhs) ?? ""
                result = lhsName.localizedStandardCompare(rhsName)
            case .duration:
                result = (lhs.durationMs ?? 0) < (rhs.durationMs ?? 0) ? .orderedAscending : .orderedDescending
            }
            return direction == .ascending ? result == .orderedAscending : result == .orderedDescending
        }
        return sorted
    }

    var body: some View {
        if tracks.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 44))
                    .foregroundColor(.secondary)
                Text("library_empty".localized)
                    .font(.title3)
                Text("library_empty_hint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                headerRow
                Divider()
                trackList
            }
            .alert("create_new_playlist".localized, isPresented: $showNewPlaylistAlert) {
                TextField("playlist_name_placeholder".localized, text: $newPlaylistName)
                Button("create".localized) { createPlaylistAndAdd() }
                Button("cancel".localized, role: .cancel) {}
            }
            .onAppear {
                reloadFavorites()
                reloadPlaylists()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("FavoritesChanged"))) { _ in
                reloadFavorites()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PlaylistsChanged"))) { _ in
                reloadPlaylists()
            }
        }
    }

    // MARK: - Header（列头：定位当前播放 + 三态排序按钮）

    private var headerRow: some View {
        HStack(spacing: rowSpacing) {
            // 定位当前播放（web 版工具条按钮语义）
            Button {
                locateActiveTrack()
            } label: {
                Image(systemName: "location")
                    .font(.system(size: 11))
                    .frame(width: trackNoWidth)
            }
            .buttonStyle(.borderless)
            .disabled(activeTrackId == nil)
            .help("locate_playing_track".localized)

            sortButton(.title, title: "title".localized, width: nil)

            sortButton(.artist, title: "artist".localized, width: artistColumnWidth)

            sortButton(.duration, title: "duration".localized, width: durationColumnWidth, trailing: true)

            Color.clear.frame(width: heartColumnWidth)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color.gray.opacity(0.06))
    }

    @ViewBuilder
    private func sortButton(_ key: TrackListSort.Key, title: String, width: CGFloat?, trailing: Bool = false) -> some View {
        let isActive = sort.key == key
        Button {
            sort = sort.toggled(by: key)
        } label: {
            HStack(spacing: 3) {
                if trailing { Spacer(minLength: 0) }
                Text(title)
                    .font(.caption)
                    .foregroundColor(isActive ? .accentColor : .secondary)
                    .lineLimit(1)
                if isActive {
                    Image(systemName: sort.direction == .ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.accentColor)
                }
                if !trailing { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: trailing ? .trailing : .leading)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .help(title)
    }

    // MARK: - Track list

    private var trackList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(displayedTracks, id: \.stableId) { track in
                    row(track)
                        .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .environment(\.defaultMinListRowHeight, 26)
            .onChange(of: locateRequestID) { _ in
                // 定位请求（按钮点击后置位），滚动到当前播放行
                if let activeTrackId {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(activeTrackId, anchor: .center)
                    }
                }
            }
        }
    }

    /// 定位请求信号：按钮点击时自增触发 onChange 滚动
    @State private var locateRequestID = 0

    private func locateActiveTrack() {
        locateRequestID += 1
    }

    @ViewBuilder
    private func row(_ track: Track) -> some View {
        let isActive = track.stableId == activeTrackId
        let isSelected = selectedRowID == track.stableId
        HStack(spacing: rowSpacing) {
            // # / 播放指示
            Group {
                if isActive {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundColor(.accentColor)
                } else {
                    Text(track.trackNo.map(String.init) ?? "")
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: trackNoWidth, alignment: .leading)
            .font(.callout)

            Text(track.title)
                .fontWeight(isActive ? .semibold : .regular)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(artistNameResolver(track) ?? "")
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: artistColumnWidth, alignment: .leading)

            Text(MacTimeFormat.format(duration(for: track)))
                .foregroundColor(.secondary)
                .monospacedDigit()
                .frame(width: durationColumnWidth, alignment: .trailing)

            favoriteButton(track)
        }
        .font(.callout)
        .contentShape(Rectangle())
        // 单击 = 播放 + 选中（web/iOS 语义；不用 List(selection:)——选中手势会
        // 吞掉行点击手势导致播放不触发，2026-09-02 用户实测）
        .onTapGesture {
            selectedRowID = track.stableId
            onPlay(track, displayedTracks)
            onSelect(track)
        }
        .contextMenu {
            contextMenuItems(track, isActive: isActive)
        }
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    @ViewBuilder
    private func favoriteButton(_ track: Track) -> some View {
        let isFavorite = favoriteIds.contains(track.stableId)
        Button {
            try? AppCoordinator.shared.toggleFavorite(trackStableId: track.stableId)
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .foregroundColor(isFavorite ? .pink : .secondary)
        }
        .buttonStyle(.plain)
        .frame(width: heartColumnWidth)
        .help(isFavorite ? "remove_from_liked_songs".localized : "add_to_liked_songs".localized)
    }

    // MARK: - Context menu（web 版 7 项对齐：播放/下一首播放/收藏/加歌单/进歌手/进专辑/歌单内移除）

    @ViewBuilder
    private func contextMenuItems(_ track: Track, isActive: Bool) -> some View {
        Button("play".localized) {
            onPlay(track, displayedTracks)
            onSelect(track)
        }

        if let onPlayNext {
            Button("play_next".localized) {
                onPlayNext(track)
            }
        }

        Divider()

        let isFavorite = favoriteIds.contains(track.stableId)
        Button {
            try? AppCoordinator.shared.toggleFavorite(trackStableId: track.stableId)
        } label: {
            Label(isFavorite ? Localized.removeFromLikedSongs : Localized.addToLikedSongs,
                  systemImage: "heart.fill")
        }

        if let playlistId {
            Divider()
            Button("playlist_manage_remove_from_playlist".localized, role: .destructive) {
                try? DatabaseManager.shared.removeFromPlaylist(playlistId: playlistId, trackStableId: track.stableId)
                NotificationCenter.default.post(name: NSNotification.Name("PlaylistsChanged"), object: nil)
            }
        }

        Divider()
        Menu("add_to_playlist".localized) {
            ForEach(playlists, id: \.id) { playlist in
                Button(playlist.title) {
                    try? DatabaseManager.shared.addToPlaylist(playlistId: playlist.id ?? 0, trackStableId: track.stableId)
                    NotificationCenter.default.post(name: NSNotification.Name("PlaylistsChanged"), object: nil)
                }
            }
            Divider()
            Button("create_new_playlist".localized) {
                pendingTrack = track
                newPlaylistName = ""
                showNewPlaylistAlert = true
            }
        }

        if let onShowArtist {
            Divider()
            Button("show_artist".localized) {
                onShowArtist(track)
            }
        }
        if let onShowAlbum {
            Button("show_album".localized) {
                onShowAlbum(track)
            }
        }
    }

    // MARK: - Data helpers

    private func reloadFavorites() {
        favoriteIds = Set((try? AppCoordinator.shared.getFavorites()) ?? [])
    }

    private func reloadPlaylists() {
        playlists = (try? DatabaseManager.shared.getAllPlaylists()) ?? []
    }

    private func createPlaylistAndAdd() {
        let title = newPlaylistName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let track = pendingTrack else { return }
        do {
            let playlist = try DatabaseManager.shared.createPlaylist(title: title)
            try DatabaseManager.shared.addToPlaylist(playlistId: playlist.id ?? 0, trackStableId: track.stableId)
            NotificationCenter.default.post(name: NSNotification.Name("PlaylistsChanged"), object: nil)
        } catch {
            print("❌ MacTrackListView createPlaylistAndAdd failed: \(error)")
        }
    }

    private func duration(for track: Track) -> TimeInterval {
        guard let ms = track.durationMs else { return 0 }
        return Double(ms) / 1000.0
    }
}
