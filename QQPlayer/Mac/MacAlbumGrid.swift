//
//  MacAlbumGrid.swift
//  QQPlayer
//
//  macOS「歌曲」列表的专辑封面网格（视图模式 = albums）。QQPlayerMac target only.
//
//  为什么单独成文件：MacTrackListView.swift 已接近结构预算（单文件 > 600 行属超长，
//  基线只减不增），所以把「归组纯函数 + 卡片 + 网格」整块外移，视图文件只留模式
//  开关与筛选接线；Table 的定义与交互契约完全不动。
//
//  归组口径（2026-11-16）：歌曲列表只拿得到 [Track]，没有 Album 模型 →
//  按 (专辑标题, 艺人) 归组；同专辑不同艺人必须分开（合辑场景），组内保持输入
//  顺序，组间按专辑标题 localizedStandardCompare 升序。归组是纯函数，不读 DB。
//

import SwiftUI

/// 「歌曲」内容的呈现模式（纯呈现层开关，不改 Table 定义）。
enum MacTrackListMode: String {
    case list
    case albums
    /// 分组折叠列表（2026-11-16 C：专辑 / 艺人 / A–Z 三种分组维度）
    case grouped
}

/// 专辑筛选键：只按显示口径（专辑标题 + 艺人）匹配，不依赖 Album 模型。
struct MacAlbumFilterKey: Hashable {
    let albumTitle: String
    let artistName: String
}

/// 一张专辑卡的数据：同 (专辑标题, 艺人) 的曲目集合。
struct MacAlbumGroup: Identifiable {
    let key: MacAlbumFilterKey
    let tracks: [Track]

    var id: MacAlbumFilterKey { key }
    var albumTitle: String { key.albumTitle }
    var artistName: String { key.artistName }
    /// 封面代表曲目：组内第一首（与专辑/歌单卡片代表曲目口径一致）
    var representativeTrack: Track? { tracks.first }
}

/// [Track] → [MacAlbumGroup] 的纯函数（无 DB、无 store 依赖，便于单测）。
enum MacAlbumGrouping {
    /// - Parameters:
    ///   - albumTitle: 专辑标题显示口径（调用方注入，通常 = facts 标题 + 字形归一）
    ///   - artistName: 艺人显示口径（调用方注入，通常 = 列表的 artistNameResolver）
    /// - Returns: 组顺序稳定——按专辑标题 localizedStandardCompare 升序，标题相同再按艺人；
    ///   组内曲目顺序 = 输入顺序（不重排）。
    static func groups(
        from tracks: [Track],
        albumTitle: (Track) -> String,
        artistName: (Track) -> String
    ) -> [MacAlbumGroup] {
        var order: [MacAlbumFilterKey] = []
        var buckets: [MacAlbumFilterKey: [Track]] = [:]
        for track in tracks {
            let key = MacAlbumFilterKey(albumTitle: albumTitle(track), artistName: artistName(track))
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(track)
        }
        let groups = order.compactMap { key -> MacAlbumGroup? in
            guard let groupTracks = buckets[key] else { return nil }
            return MacAlbumGroup(key: key, tracks: groupTracks)
        }
        return groups.sorted { lhs, rhs in
            let byTitle = lhs.albumTitle.localizedStandardCompare(rhs.albumTitle)
            if byTitle != .orderedSame { return byTitle == .orderedAscending }
            return lhs.artistName.localizedStandardCompare(rhs.artistName) == .orderedAscending
        }
    }
}

/// 专辑封面网格：LazyVGrid 自适应列 + 复用 MacArtworkThumbnail 既有异步缩略图。
struct MacTrackAlbumGridView: View {
    let groups: [MacAlbumGroup]
    let onSelect: (MacAlbumGroup) -> Void

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: DesignTokens.space20)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: DesignTokens.space20) {
                ForEach(groups) { group in
                    MacTrackAlbumCard(group: group) {
                        onSelect(group)
                    }
                }
            }
            .padding(DesignTokens.space20)
        }
    }
}

/// 专辑卡：封面（150 方形、radius8）→ 专辑名（2 行）→ 艺人（1 行、secondary）。
/// 悬停：封面轻微提亮 + 右下角浮出「N 首」徽标（music.note + 纯数字，不加文案）。
private struct MacTrackAlbumCard: View {
    let group: MacAlbumGroup
    let onSelect: () -> Void

    @State private var isHovered = false

    /// 卡片量值（与列表量值同样集中声明，改尺寸只改这里）
    private enum Metrics {
        static let artworkSize: CGFloat = 150
        static let hoverBrightness: Double = 0.06
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: DesignTokens.space6) {
                artwork
                Text(group.albumTitle)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(group.artistName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(width: Metrics.artworkSize, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            isHovered = inside
        }
    }

    private var artwork: some View {
        MacArtworkThumbnail(
            track: group.representativeTrack,
            size: Metrics.artworkSize,
            cornerRadius: DesignTokens.radius8
        )
        .brightness(isHovered ? Metrics.hoverBrightness : 0)
        .overlay(alignment: .bottomTrailing) {
            if isHovered {
                trackCountBadge
            }
        }
    }

    private var trackCountBadge: some View {
        HStack(spacing: DesignTokens.space2) {
            Image(systemName: "music.note")
            Text("\(group.tracks.count)")
                .monospacedDigit()
        }
        .font(.caption2)
        .foregroundColor(.white)
        .padding(.horizontal, DesignTokens.space6)
        .padding(.vertical, DesignTokens.space2)
        .background(Color.black.opacity(0.55), in: Capsule())
        .padding(DesignTokens.space6)
    }
}
