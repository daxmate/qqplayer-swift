//  PlayerEngine+NowPlaying+Widget.swift
//  QQPlayer
//
//  Home-screen widget bridge for PlayerEngine (iOS): push the current track,
//  its artwork and the accent colour into the widget snapshot.
//
//  2026-09-21 从 PlayerEngine+NowPlaying.swift 原样搬出（纯搬家，无逻辑变更）。
#if os(iOS)
    import Foundation
    import GRDB
    import UIKit
    import WidgetKit
    extension PlayerEngine {
        // MARK: - Widget Integration

        func updateWidgetData() {
            guard let track = currentTrack else {
                WidgetDataManager.shared.clearCurrentTrack()
                return
            }
            let trackId = track.stableId

            Task {
                // Get artwork
                let artwork = await ArtworkManager.shared.getArtwork(for: track)

                // pngData 编码 + 写盘下沉后台线程（主 actor 编码/同步 IO 卡 UI，
                // 2026-08-29 审计 #9）：值拷贝 UIImage 引用后离线处理。
                let artworkData: Data?
                if let artwork {
                    artworkData = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            continuation.resume(returning: artwork.pngData())
                        }
                    }
                } else {
                    artworkData = nil
                }

                // Get artist name
                let artistName: String
                if let artistId = track.artistId,
                   let artist = try? DatabaseManager.shared.read({ db in
                       try Artist.fetchOne(db, key: artistId)
                   }) {
                    artistName = ArtistNameNormalizer.displayName(artist.name)
                } else {
                    artistName = Localized.unknownArtist
                }

                // Get theme color（唯一取数 = IOSAppearance 名单；字段 = accentColorName，2026-09-17 收口）
                let settings = DeleteSettings.load()
                let colorHex = IOSAppearance.accentHex(forKey: settings.accentColorName)

                // 同曲校验（2026-09-12 审计 P5）：上面两次 await（封面 / 后台编码）期间可能已切歌，
                // 旧曲写进去会一直留在小组件（saveCurrentTrack 同步写盘 + reloadAllTimelines）。
                guard PlaybackTrackGate.isStillCurrent(trackId: trackId, currentTrackId: currentTrack?.stableId) else {
                    AppLog.warn(.general, "↩️ widget 更新丢弃：\(track.title) 已不是当前曲目")
                    return
                }

                let widgetData = WidgetTrackData(
                    trackId: track.stableId,
                    title: track.displayTitle,
                    artist: artistName,
                    isPlaying: isPlaying,
                    backgroundColorHex: colorHex
                )

                // 写盘 + 小组件刷新下沉后台（saveCurrentTrack 内部有 UserDefaults.synchronize
                // 与文件写入，均为同步 IO，2026-08-29 审计 #9）
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        WidgetDataManager.shared.saveCurrentTrack(widgetData, artworkData: artworkData)
                        WidgetCenter.shared.reloadAllTimelines()
                        continuation.resume()
                    }
                }
            }
        }

    }
#endif
