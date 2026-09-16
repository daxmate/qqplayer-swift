//
//  CarPlay+Playback.swift
//  QQPlayer
//
//  CarPlay 播放相关：播放队列构建、曲目格式兼容过滤、NowPlaying 按钮与模板。
//
import CarPlay
import Foundation
import UIKit

extension CarPlaySceneDelegate {
    // MARK: - Helpers

    func addNowPlayingButton(to template: CPListTemplate) {
        guard let nowPlayingImage = UIImage(systemName: "play.circle.fill") else { return }

        let nowPlayingButton = CPBarButton(image: nowPlayingImage) { [weak self] _ in
            self?.showNowPlaying()
        }
        template.trailingNavigationBarButtons = [nowPlayingButton]
    }

    /// 右上角「正在播放」按钮：推**自建的播放页**（封面 + 歌名/歌手 + 控制键 + 三行歌词）。
    /// 系统的「正在播放」屏不接受 App 注入歌词（文字位只有 title/artist 两行），所以这里
    /// 不再推 CPNowPlayingTemplate.shared；系统屏仍由车机自身入口/方向盘唤起，播放控制命令
    /// 走 MPRemoteCommandCenter，不受影响。
    private func showNowPlaying() {
        guard let playerPage = playerPageController else {
            interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
            return
        }
        interfaceController?.pushTemplate(playerPage.template, animated: true, completion: nil)
    }

    func queueForAllSongs(startingAt index: Int) -> [Track] {
        if let paginatedQueue = try? DatabaseManager.shared.getTracksPaginated(
            limit: maxQueueItems,
            offset: index,
            excludingFormats: incompatibleFormats
        ), !paginatedQueue.isEmpty {
            return paginatedQueue
        }

        return forwardQueue(from: allSongsTracks, startingAt: index)
    }

    func forwardQueue(from tracks: [Track], startingAt index: Int) -> [Track] {
        guard !tracks.isEmpty else { return [] }
        let safeIndex = max(0, min(index, tracks.count - 1))
        let endIndex = min(safeIndex + maxQueueItems, tracks.count)
        return Array(tracks[safeIndex ..< endIndex])
    }

    func isCompatible(track: Track) -> Bool {
        let ext = URL(fileURLWithPath: track.path).pathExtension.lowercased()
        return !incompatibleFormats.contains(ext)
    }

    func getCompatibleTracks(for playlist: Playlist) -> [Track] {
        guard let playlistId = playlist.id else { return [] }

        let playlistItems = (try? AppCoordinator.shared.databaseManager.getPlaylistItems(playlistId: playlistId)) ?? []
        let trackIds = playlistItems.map { $0.trackStableId }
        let allPlaylistTracks = (try? AppCoordinator.shared.databaseManager.getTracksByStableIdsPreservingOrder(trackIds)) ?? []
        return allPlaylistTracks.filter(isCompatible)
    }
}
