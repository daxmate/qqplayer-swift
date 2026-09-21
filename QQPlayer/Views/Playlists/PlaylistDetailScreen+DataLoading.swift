//
//  PlaylistDetailScreen+DataLoading.swift
//  QQPlayer
//
//  歌单详情页的**数据加载**分区：曲目/歌手名缓存加载：
//  loadPlaylistTracks（曲目 + 封面 + 歌手名缓存） · loadArtworks（前 4 首封面缩略图） ·
//  loadArtistNameCache（歌手名正名/显示名缓存） · buildArtistCache（按歌手排序用的批量查询）。
//
//  2026-09-21 从 PlaylistDetailScreen.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Playlists/PlaylistDetailScreen.swift — 主片：stored property + body
//    · Views/Playlists/PlaylistDetailScreen+DataLoading.swift — 曲目/歌手名缓存加载
//    · Views/Playlists/PlaylistDetailScreen+PlaybackActions.swift — 播放引擎门面 + 行操作反馈
//    · Views/Playlists/PlaylistDetailScreen+Sorting.swift — 排序求值 + 排序偏好持久化
//    · Views/Playlists/PlaylistDetailScreen+CustomCover.swift — 封面小图 + 自定义封面读写
//
// target: ios-only（PlaylistDetailScreen 分片：与原文件归属一致）
//

import SwiftUI

extension PlaylistDetailScreen {
    /// 分片：跨文件可见（原 private）
    func buildArtistCache(for tracks: [Track]) -> [Int64: String] {
        // Get unique artist IDs
        let artistIds = Set(tracks.compactMap { $0.artistId })

        // Fetch all artists in one query
        var cache: [Int64: String] = [:]
        do {
            let artists = try LibraryReads.artists(ids: Array(artistIds))
            for artist in artists {
                if let id = artist.id {
                    // 简繁归一：行副标题按当前 UI 语言显示同一字形
                    cache[id] = ArtistNameNormalizer.displayName(artist.name)
                }
            }
        } catch {
            AppLog.error(.ui, "Failed to build artist cache: \(error)")
        }
        return cache
    }

    /// 分片：跨文件可见（原 private）
    func loadPlaylistTracks() {
        guard let playlistId = playlist.id else { return }

        do {
            let playlistItems = try appCoordinator.databaseManager.getPlaylistItems(playlistId: playlistId)
            let trackIds = playlistItems.map { $0.trackStableId }
            tracks = try appCoordinator.databaseManager.getTracksByStableIdsPreservingOrder(trackIds)
            loadArtistNameCache()

            // Load artworks for the first 4 tracks
            Task {
                await loadArtworks()
            }
        } catch {
            AppLog.error(.ui, "Failed to load playlist tracks: \(error)")
        }
    }

    private func loadArtworks() async {
        var loadedArtworks: [UIImage] = []
        let tracksToLoad = Array(tracks.prefix(4))

        for track in tracksToLoad {
            if let artwork = await services.artworkManager.getThumbnail(for: track, maxPixelSize: 256) {
                loadedArtworks.append(artwork)
            }
        }

        await MainActor.run {
            artworks = loadedArtworks
        }
    }

    /// 分片：跨文件可见（原 private）
    func loadArtistNameCache() {
        do {
            artistNameCache = try LibraryReads.artistNamesById()
            let fallbackArtistIds = tracks.reduce(into: [String: Int64]()) { result, track in
                if let artistId = track.artistId {
                    result[track.stableId] = artistId
                }
            }
            artistDisplayNameCache = try LibraryReads.artistDisplayNames(
                forTrackStableIds: tracks.map(\.stableId),
                fallbackArtistIdsByStableId: fallbackArtistIds
            )
        } catch {
            AppLog.error(.ui, "Failed to load playlist artist cache: \(error)")
        }
    }
}
