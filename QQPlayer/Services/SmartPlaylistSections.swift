//
//  SmartPlaylistSections.swift
//  QQPlayer
//
//  自动歌单区（App 内歌单页 / CarPlay 歌单页共用）的纯数据组装：
//  - 第一层：按 SmartPlaylistKind.allCases 顺序，一条都没有的类别不出现
//  - 第二层（年代）：只保留有曲目的桶，顺序沿用数据层（SmartPlaylistStore）
//  本文件不依赖 CarPlay / SwiftUI，可在 QQPlayerTests 直接单测；
//  曲目本身（Track）不进来，计数和标题由调用方按「本机可播」过滤后传入。
//

import Foundation

/// 自动歌单区第一层的一行。
struct SmartPlaylistSectionItem: Equatable {
    /// 计数的单位：曲目数（track 类歌单）或年代个数（年代歌单）。
    enum CountUnit: Equatable {
        case songs
        case decades
    }

    let kind: SmartPlaylistKind
    let title: String
    let count: Int
    let countUnit: CountUnit
}

/// 年代二级列表的一行。
struct SmartPlaylistDecadeItem: Equatable {
    let key: String
    let title: String
    let count: Int
}

enum SmartPlaylistSections {
    /// 自动歌单条目封面最多拼贴的歌曲数（2×2 拼贴，与用户歌单封面一致）。
    static let maxCoverTracks = 4

    /// 第一层条目封面取哪些歌：顺序沿用数据层，最多 `limit` 首。
    /// 年代条目取「有曲目的年代桶」按数据层顺序摊平后的前几首（空桶不参与）。
    static func coverTracks(
        for kind: SmartPlaylistKind,
        snapshot: SmartPlaylistSnapshot,
        limit: Int = maxCoverTracks
    ) -> [Track] {
        guard limit > 0 else { return [] }

        switch kind {
        case .recentAdded, .recentPlayed, .topPlayed:
            return Array((snapshot.kindTracks[kind] ?? []).prefix(limit))
        case .decades:
            let tracks = snapshot.decades.flatMap { snapshot.decadeTracks[$0.key] ?? [] }
            return Array(tracks.prefix(limit))
        }
    }

    /// 年代二级条目封面取该桶内前 `limit` 首；桶不存在或为空时返回空数组。
    static func coverTracks(
        forDecadeKey key: String,
        snapshot: SmartPlaylistSnapshot,
        limit: Int = maxCoverTracks
    ) -> [Track] {
        guard limit > 0 else { return [] }
        return Array((snapshot.decadeTracks[key] ?? []).prefix(limit))
    }

    /// 自动歌单区第一层条目。
    ///
    /// - Parameters:
    ///   - songCounts: track 类歌单的「本机可播」曲目数（缺省按 0 处理）
    ///   - decadeCount: 「本机可播」年代个数（只算有曲目的桶）
    ///   - title: 标题来源；默认跟随语言（Localized），测试可注入固定值
    static func topLevelItems(
        songCounts: [SmartPlaylistKind: Int],
        decadeCount: Int,
        title: (SmartPlaylistKind) -> String = Localized.smartPlaylistTitle
    ) -> [SmartPlaylistSectionItem] {
        SmartPlaylistKind.allCases.compactMap { kind in
            switch kind {
            case .recentAdded, .recentPlayed, .topPlayed:
                let count = songCounts[kind] ?? 0
                guard count > 0 else { return nil }
                return SmartPlaylistSectionItem(
                    kind: kind,
                    title: title(kind),
                    count: count,
                    countUnit: .songs
                )
            case .decades:
                guard decadeCount > 0 else { return nil }
                return SmartPlaylistSectionItem(
                    kind: kind,
                    title: title(kind),
                    count: decadeCount,
                    countUnit: .decades
                )
            }
        }
    }

    /// 年代二级列表：保持数据层顺序，只保留「本机可播」曲目数 > 0 的桶；计数用可播曲目数。
    ///
    /// - Parameter compatibleCounts: key → 该桶本机可播曲目数（调用方按 isCompatible 过滤后统计）
    static func decadeItems(
        from buckets: [DecadeBucketInfo],
        compatibleCounts: [String: Int]
    ) -> [SmartPlaylistDecadeItem] {
        buckets.compactMap { bucket in
            let count = compatibleCounts[bucket.key] ?? 0
            guard count > 0 else { return nil }
            return SmartPlaylistDecadeItem(key: bucket.key, title: bucket.label, count: count)
        }
    }
}

/// 自动歌单区的一次性快照：列表行 + 点击后要 push 的曲目。
/// CarPlay 歌单页模板只在连接时建一次，调用方顺手把曲目查好（每类 ≤ SmartPlaylistStore.limit），
/// 点击二级页不再查库；所有曲目都按本机可播过滤（isCompatible），顺序沿用数据层。
/// 纯数据（只有 Track / SmartPlaylistKind），不依赖 CarPlay，QQPlayerTests 可直接构造。
struct SmartPlaylistSnapshot {
    var kindTracks: [SmartPlaylistKind: [Track]] = [:]
    var decades: [SmartPlaylistDecadeItem] = []
    var decadeTracks: [String: [Track]] = [:]
    var items: [SmartPlaylistSectionItem] = []
}
