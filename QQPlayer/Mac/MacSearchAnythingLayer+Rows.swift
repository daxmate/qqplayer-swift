//
//  MacSearchAnythingLayer+Rows.swift
//  QQPlayer
//
//  `MacSearchAnythingLayer` 的结果行视图（2026-09-21 从 `MacSearchAnythingLayer.swift` 纯搬家，零行为/UI 变化）。
//
//  ⚠️ 可见性：被主片或其它分区文件引用的成员为 internal（原 `private`）。
//

import SwiftUI

extension MacSearchAnythingLayer {
    // MARK: - 行

    /// 歌手行的唯一分组入口（库里同形两行 → 一行；两边曲目合并播）。
    /// 分片：跨文件可见（原 private）
    var groupedArtists: [ArtistNameNormalizer.NormalizedArtist] {
        ArtistNameNormalizer.groupedArtists(artists)
    }

    /// 分片：跨文件可见（原 private）
    /// 本地歌曲行：单击选中高亮（不播放）、双击播放（macOS 惯例，与曲库 Table 一致）；
    /// 右键菜单与曲库同一份实现（MacTrackContextMenu.swift）。
    func songRow(_ track: Track) -> some View {
        let isSelected = selectedSongId == track.stableId
        return HStack(spacing: DesignTokens.space10) {
            Image(systemName: "music.note")
                .foregroundColor(.secondary)
                .frame(width: 14)
            Text(track.displayTitle).lineLimit(1)
            if let artist = artistNameResolver(track) {
                Text(artist)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, DesignTokens.space12)
        .padding(.vertical, DesignTokens.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius4)
                .fill(isSelected ? appAccentColor.opacity(0.18) : Color.clear)
                .padding(.horizontal, DesignTokens.space6)
        )
        .contentShape(Rectangle())
        // 双击 → 播放；单击 → 仅选中高亮。点行本身不收起浮层：只有播放 / 进歌手 / 进专辑才关。
        // 用 exclusive 组合而不是叠两个 onTapGesture：后者的命中依赖手势优先级（双击可能被
        // 单击先吃掉），这里显式声明「先判双击、双击不成立才判单击」，行为确定。
        // 代价：单击选中最多等一个双击判定窗口（系统双击间隔），macOS 行选择可接受。
        .gesture(
            TapGesture(count: 2)
                .onEnded { playLocalSong(track) }
                .exclusively(
                    before: TapGesture(count: 1)
                        .onEnded { selectedSongId = track.stableId }
                )
        )
        .contextMenu {
            MacTrackContextMenuContent(
                track: track,
                model: menu,
                onPlay: { playLocalSong(track) },
                onPlayNext: { onPlayNext($0) },
                onShowArtist: { track in
                    state.isOpen = false
                    onShowArtist(track)
                },
                onShowAlbum: { track in
                    state.isOpen = false
                    onShowAlbum(track)
                }
            )
        }
        // 去掉 Button 后仍保留可读语义（标题 + 歌手合并朗读，选中态进 trait）
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// 播放本地歌曲（唯一入口：双击 / 右键「播放」共用）：播放并收起浮层
    func playLocalSong(_ track: Track) {
        onPlayLocal(track, localSongs)
        state.isOpen = false
    }

    /// 分片：跨文件可见（原 private）
    func artistRow(_ group: ArtistNameNormalizer.NormalizedArtist) -> some View {
        Button {
            let tracks = group.artistIds.flatMap { (try? LibraryReads.tracks(artistId: $0)) ?? [] }
            guard !tracks.isEmpty else { return }
            onPlayArtist(group.primaryArtist, tracks)
            state.isOpen = false
        } label: {
            HStack(spacing: DesignTokens.space10) {
                Image(systemName: "music.mic")
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                Text(group.displayName).lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, DesignTokens.space12)
            .padding(.vertical, DesignTokens.space4)
        }
        .buttonStyle(.plain)
    }

    /// 分片：跨文件可见（原 private）
    func albumRow(_ album: Album) -> some View {
        Button {
            let tracks = (try? LibraryReads.tracks(albumId: album.id ?? 0)) ?? []
            guard !tracks.isEmpty else { return }
            onPlayAlbum(album, tracks)
            state.isOpen = false
        } label: {
            HStack(spacing: DesignTokens.space10) {
                Image(systemName: "square.stack")
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                Text(album.displayTitle).lineLimit(1)
                if let artist = album.albumArtist, !artist.isEmpty {
                    Text(ArtistNameNormalizer.displayName(artist))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, DesignTokens.space12)
            .padding(.vertical, DesignTokens.space4)
        }
        .buttonStyle(.plain)
    }

    /// 分片：跨文件可见（原 private）
    func onlineRow(_ song: NeteaseOnlineSong) -> some View {
        Button {
            download(song)
        } label: {
            HStack(spacing: DesignTokens.space10) {
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
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius4))

                VStack(alignment: .leading, spacing: DesignTokens.space2) {
                    Text(DisplayScriptNormalizer.display(song.title)).lineLimit(1)
                    Text(DisplayScriptNormalizer.display(onlineSubtitle(song)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                downloadBadge(for: song)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, DesignTokens.space12)
            .padding(.vertical, DesignTokens.space4)
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
                // B2：确定进度/不确定转圈（替代系统 ProgressView）
                DownloadProgressRing(progress: downloadProgress[song.id] ?? nil, size: 16)
            } else {
                Image(systemName: "icloud.and.arrow.down").foregroundColor(.secondary)
            }
        }
        .frame(width: 18)
    }

    private var placeholderCover: some View {
        RoundedRectangle(cornerRadius: DesignTokens.radius4)
            .fill(Color.gray.opacity(0.18))
            .overlay {
                Image(systemName: "music.note")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
    }

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
}
