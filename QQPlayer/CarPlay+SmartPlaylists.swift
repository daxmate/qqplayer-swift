//
//  CarPlay+SmartPlaylists.swift
//  QQPlayer
//
//  CarPlay 歌单页「自动歌单」区：快照组装（最近添加 / 最近播放 / 常听排行 / 年代）
//  与二级页推入。条目组装走 SmartPlaylistSections（不依赖 CarPlay，另有单测）。
//
// target: ios-only
//
import CarPlay
import Foundation
import UIKit

extension CarPlaySceneDelegate {
    // MARK: - Smart playlists（自动歌单）

    func makeSmartPlaylistSnapshot() -> SmartPlaylistSnapshot {
        var snapshot = SmartPlaylistSnapshot()

        snapshot.kindTracks[.recentAdded] = ((try? SmartPlaylistStore.recentAddedTracks()) ?? [])
            .filter(isCompatible)
        snapshot.kindTracks[.recentPlayed] = ((try? SmartPlaylistStore.recentPlayedTracks()) ?? [])
            .filter(isCompatible)
        snapshot.kindTracks[.topPlayed] = ((try? SmartPlaylistStore.topPlayedTracks()) ?? [])
            .map(\.track)
            .filter(isCompatible)

        if let buckets = try? SmartPlaylistStore.decadeBuckets() {
            // DecadeBucketInfo.count 是 Int（非 Collection），empty_count 误报
            // swiftlint:disable:next empty_count
            for bucket in buckets where bucket.count > 0 {
                snapshot.decadeTracks[bucket.key] = ((try? SmartPlaylistStore.tracks(inDecade: bucket.key)) ?? [])
                    .filter(isCompatible)
            }
            snapshot.decades = SmartPlaylistSections.decadeItems(
                from: buckets,
                compatibleCounts: snapshot.decadeTracks.mapValues(\.count)
            )
        }

        snapshot.items = SmartPlaylistSections.topLevelItems(
            songCounts: snapshot.kindTracks.mapValues(\.count),
            decadeCount: snapshot.decades.count
        )
        return snapshot
    }

    func smartPlaylistItems(from snapshot: SmartPlaylistSnapshot) -> [CPListItem] {
        snapshot.items.map { entry in
            let detailText: String
            switch entry.countUnit {
            case .songs:
                detailText = Localized.songsCountOnly(entry.count)
            case .decades:
                detailText = Localized.smartDecadeCount(entry.count)
            }

            let item = CPListItem(text: entry.title, detailText: detailText)
            item.setImage(createPlaceholderImage(systemName: smartPlaylistSymbol(for: entry.kind)))
            let coverTracks = SmartPlaylistSections.coverTracks(for: entry.kind, snapshot: snapshot)
            Task { @MainActor in
                if let collage = await loadPlaylistCollageArtwork(from: coverTracks) {
                    item.setImage(collage)
                }
            }
            item.handler = { [weak self] _, completion in
                self?.showSmartPlaylist(entry.kind, snapshot: snapshot)
                completion()
            }
            return item
        }
    }

    private func showSmartPlaylist(_ kind: SmartPlaylistKind, snapshot: SmartPlaylistSnapshot) {
        switch kind {
        case .recentAdded, .recentPlayed, .topPlayed:
            pushTrackList(
                title: Localized.smartPlaylistTitle(kind),
                tracks: snapshot.kindTracks[kind] ?? []
            )
        case .decades:
            pushDecadeList(snapshot)
        }
    }

    private func pushDecadeList(_ snapshot: SmartPlaylistSnapshot) {
        let items: [CPListItem] = snapshot.decades.map { decade in
            let item = CPListItem(text: decade.title, detailText: Localized.songsCountOnly(decade.count))
            item.setImage(createPlaceholderImage(systemName: "calendar"))
            let coverTracks = SmartPlaylistSections.coverTracks(forDecadeKey: decade.key, snapshot: snapshot)
            Task { @MainActor in
                if let collage = await loadPlaylistCollageArtwork(from: coverTracks) {
                    item.setImage(collage)
                }
            }
            item.handler = { [weak self] _, completion in
                self?.pushTrackList(title: decade.title, tracks: snapshot.decadeTracks[decade.key] ?? [])
                completion()
            }
            return item
        }

        interfaceController?.pushTemplate(
            CPListTemplate(
                title: Localized.smartPlaylistTitle(.decades),
                sections: [CPListSection(items: items)]
            ),
            animated: true,
            completion: nil
        )
    }

    private func pushTrackList(title: String, tracks: [Track]) {
        interfaceController?.pushTemplate(
            CPListTemplate(title: title, sections: [CPListSection(items: makeSongItems(from: tracks))]),
            animated: true,
            completion: nil
        )
    }
}

/// 自动歌单行的占位图标（封面异步加载，占位先给语义图标）。
private func smartPlaylistSymbol(for kind: SmartPlaylistKind) -> String {
    switch kind {
    case .recentAdded: return "clock.badge.plus"
    case .recentPlayed: return "clock.arrow.circlepath"
    case .topPlayed: return "chart.bar.fill"
    case .decades: return "calendar"
    }
}
