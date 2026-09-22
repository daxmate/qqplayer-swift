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
    /// **任何情况下都不推 CPNowPlayingTemplate.shared**：控制器缺失（场景时序异常/重连竞态）
    /// 就地重建，绝不让「歌词入口」落到一页没有歌词的系统屏上。
    /// 系统屏仍由车机自身入口/方向盘唤起，播放控制命令走 MPRemoteCommandCenter，不受影响。
    private func showNowPlaying() {
        let playerPage = playerPageControllerEnsuring()
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
        let ext = LibraryRoot.absoluteURL(forStoredPath: track.path).pathExtension.lowercased()
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
