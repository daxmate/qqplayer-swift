//
//  ArtistNameGrouping.swift
//  QQPlayer
//
//  歌手名按「归一 key」分组，供歌手列表/搜索结果/专辑详情做同字形合并显示。
//
//  为什么与 ArtistNameNormalizer.swift 分开：
//  纯字形归一（方向 + 映射 + displayName/searchVariants）只依赖 Foundation，
//  Siri 扩展（SiriIntentsExtension）要编译它来归一 Siri 卡片里的歌手名；
//  而本节要 GRDB 模型 `Artist`，扩展刻意不带模型层（它只读轻量 SimpleTrack）。
//  分开后扩展只编译纯归一部分，行为不变，两边各自拿到需要的东西。
//

import Foundation

extension ArtistNameNormalizer {
    /// 歌手列表显示项：一组同字形歌手（displayName + 组内全部 artist id）
    struct NormalizedArtist: Identifiable {
        /// 归一后的显示名
        let displayName: String
        /// 组内全部 artist id（详情聚合曲目用）
        let artistIds: [Int64]
        /// 组内首位歌手（专辑/网络信息等用）
        let primaryArtist: Artist
        /// 组内全部歌手
        let artists: [Artist]

        /// 组内歌手名互不相同（同名即同组），primaryArtist.name 跨组唯一
        var id: String { primaryArtist.name }
    }

    /// 按归一 key 分组（保持输入顺序，即组内首个名字的字母序位置），
    /// 每组一个显示项。
    static func groupedArtists(_ artists: [Artist], direction: Direction) -> [NormalizedArtist] {
        var groups: [String: [Artist]] = [:]
        var order: [String] = []
        for artist in artists {
            let key = normalizedKey(artist.name, direction: direction)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(artist)
        }
        return order.compactMap { key in
            guard let group = groups[key], let primary = group.first else { return nil }
            return NormalizedArtist(
                displayName: displayName(for: group.map(\.name), direction: direction),
                artistIds: group.compactMap(\.id),
                primaryArtist: primary,
                artists: group
            )
        }
    }

    /// 当前方向下按归一 key 分组
    static func groupedArtists(_ artists: [Artist]) -> [NormalizedArtist] {
        groupedArtists(artists, direction: direction)
    }
}
