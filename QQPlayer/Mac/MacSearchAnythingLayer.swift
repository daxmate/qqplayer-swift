//
//  MacSearchAnythingLayer.swift
//  QQPlayer
//
//  search anything（web 版 SearchAnything 对齐，2026-09 C 组②；QQPlayerMac only）。
//  Spotlight 式主窗内全屏浮层：⌘K 唤起（QQPlayerMacApp .commands 切换本层开关），
//  Esc/点空白收起。分组结果：本地歌曲 / 在线（下载）/ 歌手 / 专辑 / 设置——
//  与侧栏 MacSearchView（库内检索含歌单）共存，本层为全局超集（web 语义：歌单不入）。
//  250ms 防抖（web useSearchAnything 对齐）；本地多路 DB 搜索 + 在线网易云异步追尾。
//  用户 2026-09-04 拍板：在线行动作 = 下载落盘入曲库（v1，无试听/网络登记）。
//

import AppKit
import SwiftUI

/// ⌘K 开关共享单例（QQPlayerMacApp commands 与 MacLibraryView overlay 共用）
@MainActor
final class MacSearchAnythingState: ObservableObject {
    static let shared = MacSearchAnythingState()
    @Published var isOpen = false
    private init() {}
}

/// 主窗内 Spotlight 式全屏搜索浮层
struct MacSearchAnythingLayer: View {
    let onPlayLocal: (Track, [Track]) -> Void
    let onPlayArtist: (Artist, [Track]) -> Void
    let onPlayAlbum: (Album, [Track]) -> Void
    let onOpenSettings: (String) -> Void
    let artistNameResolver: (Track) -> String?

    @ObservedObject private var state = MacSearchAnythingState.shared

    @State private var query = ""
    @State private var localSongs: [Track] = []
    @State private var artists: [Artist] = []
    @State private var albums: [Album] = []
    @State private var onlineSongs: [NeteaseOnlineSong] = []
    @State private var isSearching = false
    @State private var searchSeq = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var downloadingIDs: Set<Int> = []
    @State private var downloadedIDs: Set<Int> = []
    @State private var failedIDs: Set<Int> = []
    @State private var statusMessage: String?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.0001)
                .ignoresSafeArea()
                .onTapGesture { state.isOpen = false }

            VStack {
                panel
                    .padding(.top, 60)
                Spacer()
            }
            .padding(.horizontal, 120)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { focused = true }
    }

    // MARK: - 面板

    private var panel: some View {
        VStack(spacing: 0) {
            searchRow
            Divider()
            resultsView
        }
        .frame(width: 600)
        .frame(maxHeight: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.gray.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onExitCommand { state.isOpen = false }
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("search_any_placeholder".localized, text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit {
                    if let first = localSongs.first {
                        onPlayLocal(first, localSongs)
                        state.isOpen = false
                    }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text("⌘K")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onChange(of: query) { _ in
            scheduleSearch()
        }
    }

    // MARK: - 结果

    @ViewBuilder
    private var resultsView: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyHint
        } else if isSearching {
            VStack(spacing: 10) {
                ProgressView()
                Text("search_any_loading".localized)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hasNoResults {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("search_any_no_results".localized)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !localSongs.isEmpty {
                        section("search_badge_song".localized) {
                            ForEach(localSongs, id: \.stableId) { track in
                                songRow(track)
                            }
                        }
                    }
                    if !onlineSongs.isEmpty {
                        section("search_badge_online".localized) {
                            ForEach(onlineSongs) { song in
                                onlineRow(song)
                            }
                        }
                    }
                    if !artists.isEmpty {
                        section("search_badge_artist".localized) {
                            ForEach(artists, id: \.id) { artist in
                                artistRow(artist)
                            }
                        }
                    }
                    if !albums.isEmpty {
                        section("search_badge_album".localized) {
                            ForEach(albums, id: \.id) { album in
                                albumRow(album)
                            }
                        }
                    }
                    settingsSection
                }
                .padding(.vertical, 6)
            }
            .overlay(alignment: .bottom) {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 6)
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 2)
            content()
        }
    }

    // MARK: - 行

    private func songRow(_ track: Track) -> some View {
        Button {
            onPlayLocal(track, localSongs)
            state.isOpen = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                Text(track.title).lineLimit(1)
                if let artist = artistNameResolver(track) {
                    Text(artist)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    private func artistRow(_ artist: Artist) -> some View {
        Button {
            let tracks = (try? DatabaseManager.shared.getTracksByArtistId(artist.id ?? 0)) ?? []
            guard !tracks.isEmpty else { return }
            onPlayArtist(artist, tracks)
            state.isOpen = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "music.mic")
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                Text(ArtistNameNormalizer.displayName(artist.name)).lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    private func albumRow(_ album: Album) -> some View {
        Button {
            let tracks = (try? DatabaseManager.shared.getTracksByAlbumId(album.id ?? 0)) ?? []
            guard !tracks.isEmpty else { return }
            onPlayAlbum(album, tracks)
            state.isOpen = false
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.stack")
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                Text(album.title).lineLimit(1)
                if let artist = album.albumArtist, !artist.isEmpty {
                    Text(ArtistNameNormalizer.displayName(artist))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    private func onlineRow(_ song: NeteaseOnlineSong) -> some View {
        Button {
            download(song)
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let coverURL = song.coverURL {
                        AsyncImage(url: coverURL) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                placeholderCover
                            }
                        }
                    } else {
                        placeholderCover
                    }
                }
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 1) {
                    Text(song.title).lineLimit(1)
                    Text(onlineSubtitle(song))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                downloadBadge(for: song)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }

    private func downloadBadge(for song: NeteaseOnlineSong) -> some View {
        Group {
            if downloadedIDs.contains(song.id) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            } else if failedIDs.contains(song.id) {
                Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red)
            } else if downloadingIDs.contains(song.id) {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "icloud.and.arrow.down").foregroundColor(.secondary)
            }
        }
        .frame(width: 18)
    }

    private var placeholderCover: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.gray.opacity(0.18))
            .overlay {
                Image(systemName: "music.note")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
    }

    private var settingsSection: some View {
        section("search_badge_setting".localized) {
            ForEach(MacSearchAnythingLayer.settingCategories, id: \.self) { category in
                Button {
                    onOpenSettings(category)
                    state.isOpen = false
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "gearshape")
                            .foregroundColor(.secondary)
                            .frame(width: 14)
                        Text(categoryTitle(category)).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("search_any_empty_hint".localized)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var hasNoResults: Bool {
        localSongs.isEmpty && artists.isEmpty && albums.isEmpty && onlineSongs.isEmpty
    }

    // MARK: - 搜索

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await performSearch()
        }
    }

    @MainActor
    private func performSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchSeq += 1
            localSongs = []
            artists = []
            albums = []
            onlineSongs = []
            isSearching = false
            return
        }
        searchSeq += 1
        let seq = searchSeq
        isSearching = true
        statusMessage = nil

        // 本地多路（同步快，先出）
        do {
            localSongs = Array(try DatabaseManager.shared.searchTracks(query: q, limit: 8))
            artists = try DatabaseManager.shared.searchArtists(query: q, limit: 5)
            albums = try DatabaseManager.shared.searchAlbums(query: q, limit: 5)
        } catch {
            localSongs = []
            artists = []
            albums = []
        }

        // 在线（异步追尾，失败静默降级不打断本地结果）
        onlineSongs = []
        do {
            let songs = try await NeteaseOnlineClient.shared.search(query: q, limit: 20)
            guard seq == searchSeq, !Task.isCancelled else { return }
            onlineSongs = songs
        } catch {
            guard seq == searchSeq, !Task.isCancelled else { return }
        }
        if seq == searchSeq {
            isSearching = false
        }
    }

    private func download(_ song: NeteaseOnlineSong) {
        guard !downloadingIDs.contains(song.id) else { return }
        downloadingIDs.insert(song.id)
        failedIDs.remove(song.id)
        statusMessage = nil
        Task {
            do {
                _ = try await MacOnlineDownloadService.download(song: song)
                downloadedIDs.insert(song.id)
                failedIDs.remove(song.id)
            } catch {
                failedIDs.insert(song.id)
                downloadedIDs.remove(song.id)
                statusMessage = "online_download_failed_prefix".localized(with: song.title)
            }
            downloadingIDs.remove(song.id)
        }
    }

    // MARK: - 小工具

    private func onlineSubtitle(_ song: NeteaseOnlineSong) -> String {
        var parts: [String] = [song.artist]
        if let album = song.album, !album.isEmpty {
            parts.append(album)
        }
        if let duration = song.durationDisplay {
            parts.append(duration)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: - 设置分类注册表（MacSettingsView 左导航分类，顺序一致）

    static let settingCategories: [String] = ["playback", "library", "download", "appearance", "about"]

    private func categoryTitle(_ category: String) -> String {
        switch category {
        case "playback": return "settings_category_playback".localized
        case "library": return "settings_category_library".localized
        case "download": return "settings_category_download".localized
        case "appearance": return "settings_category_appearance".localized
        case "about": return "settings_category_about".localized
        default: return category
        }
    }
}
