//
//  PlaylistDetailScreen+CustomCover.swift
//  QQPlayer
//
//  歌单详情页的**自定义封面**分区：封面小图 + 自定义封面读写：
//  artworkView（封面小图，含自定义封面优先） · customCoverFailure（读取失败登记查询） ·
//  loadCustomCover / saveCustomCover / removeCustomCover（读写 + WidgetCenter 刷新）。
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
import WidgetKit

extension PlaylistDetailScreen {
    /// 分片：跨文件可见（原 private）
    @ViewBuilder
    func artworkView(at index: Int, size: CGFloat) -> some View {
        if index < artworks.count {
            Image(uiImage: artworks[index])
                .resizable().scaledToFill()
                .frame(width: size, height: size)
                .clipped()
        } else if index < tracks.count {
            RoundedRectangle(cornerRadius: DesignTokens.radius0)
                .fill(Color.gray.opacity(0.3))
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "music.note")
                        .foregroundColor(.secondary)
                        .font(.system(size: size / 4))
                )
        }
    }

    /// 分片：跨文件可见（原 private）
    /// 当前歌单的自定义封面是否读取失败（nil = 没配封面或读到）。
    var customCoverFailure: PlaylistCoverLoadFailuresStore.Failure? {
        let key = PlaylistCoverResolver.playlistKey(id: playlist.id, slug: playlist.slug)
        return coverFailures.failures.first { $0.playlistKey == key }
    }

    /// 分片：跨文件可见（原 private）
    @MainActor
    func loadCustomCover() {
        // 路径解析只有一处入口（`PlaylistCoverResolver`）：读不到**申报 + 上屏**
        // （详情页封面下方会出橙色说明；INV-22 另一半）。
        let key = PlaylistCoverResolver.playlistKey(id: playlist.id, slug: playlist.slug)
        switch PlaylistCoverResolver.resolve(customCoverImagePath: playlist.customCoverImagePath) {
        case .none:
            coverFailures.clear(playlistKey: key)
        case let .unavailable(reason):
            coverFailures.record(
                playlistKey: key,
                path: playlist.customCoverImagePath ?? "",
                reason: reason
            )
        case let .available(fileURL):
            guard let data = try? Data(contentsOf: fileURL),
                  let image = UIImage(data: data) else {
                coverFailures.record(
                    playlistKey: key,
                    path: playlist.customCoverImagePath ?? "",
                    reason: PlaylistCoverResolver.Reason.decodeFailed
                )
                return
            }
            coverFailures.clear(playlistKey: key)
            customCoverImage = image
            AppLog.info(.ui, "✅ Loaded custom playlist cover from \(playlist.customCoverImagePath ?? "")")
        }
    }

    /// 分片：跨文件可见（原 private）
    @MainActor
    func saveCustomCover(_ image: UIImage) async {
        guard let playlistId = playlist.id else { return }

        // Get shared container
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.daxmate.qqplayer.ios"
        ) else {
            AppLog.error(.ui, "❌ Failed to get shared container URL")
            return
        }

        // Create unique filename for this playlist cover
        let filename = "playlist_cover_\(playlistId).jpg"
        let fileURL = containerURL.appendingPathComponent(filename)
        let coverImage = image.squarePlaylistCover()

        // Save a normalized square image so all playlist covers match standard artwork sizing.
        guard let jpegData = coverImage.jpegData(compressionQuality: 0.85) else {
            AppLog.error(.ui, "❌ Failed to convert image to JPEG")
            return
        }

        do {
            // Save image to shared container
            try jpegData.write(to: fileURL)
            AppLog.info(.ui, "✅ Saved custom cover to \(filename)")

            // Update database with custom cover path
            try appCoordinator.databaseManager.updatePlaylistCustomCover(
                playlistId: playlistId,
                imagePath: filename
            )

            // Update UI
            customCoverImage = coverImage

            // Notify widgets to refresh
            WidgetCenter.shared.reloadAllTimelines()

            AppLog.info(.ui, "✅ Custom cover saved and database updated")
        } catch {
            AppLog.error(.ui, "❌ Failed to save custom cover: \(error)")
        }
    }

    /// 分片：跨文件可见（原 private）
    func removeCustomCover() {
        guard let playlistId = playlist.id else { return }

        // Remove from database
        do {
            try appCoordinator.databaseManager.updatePlaylistCustomCover(
                playlistId: playlistId,
                imagePath: nil
            )

            // Remove file from shared container if it exists
            if let customPath = playlist.customCoverImagePath,
               !customPath.isEmpty,
               let containerURL = FileManager.default.containerURL(
                   forSecurityApplicationGroupIdentifier: "group.com.daxmate.qqplayer.ios"
               ) {
                let fileURL = containerURL.appendingPathComponent(customPath)
                try? FileManager.default.removeItem(at: fileURL)
                AppLog.info(.ui, "✅ Removed custom cover file")
            }

            // Update UI
            customCoverImage = nil

            // Notify widgets to refresh
            WidgetCenter.shared.reloadAllTimelines()

            AppLog.info(.ui, "✅ Custom cover removed")
        } catch {
            AppLog.error(.ui, "❌ Failed to remove custom cover: \(error)")
        }
    }
}
