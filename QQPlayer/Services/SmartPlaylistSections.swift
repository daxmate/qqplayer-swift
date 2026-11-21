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
