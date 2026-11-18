//
//  MacTrackGroupedView.swift
//  QQPlayer
//
//  macOS「歌曲」第三种视图模式：分组折叠列表（grouped）。QQPlayerMac target only.
//
//  为什么单独成文件（2026-11-16 C 阶段）：MacTrackListView.swift 已 593 行、逼近
//  600 行结构预算，所以「分组纯函数 + 折叠列表 + 维度切换器」整块外移，列表文件只
//  保留模式分流与接线；Table 的定义与交互契约完全不动。
//
//  归组口径与 B 阶段（专辑网格）一致，且**直接复用** MacAlbumGrouping.groups：
//  专辑 = (专辑标题, artistNameResolver 艺人)，同专辑不同艺人分开；组内保持输入
//  （= 当前排序）顺序。本文件不另立一套键口径。
//

import SwiftUI

// MARK: - [harness] 分组纯函数起点（harness 切片：不含 SwiftUI / 本地化依赖）

/// 分组维度（持久化在 macTrackListGroupDimension；rawValue 是持久化契约，勿改）。
enum MacTrackGroupDimension: String, CaseIterable {
    case album
    case artist
    case initial
}

/// 一个折叠分组：id = 稳定折叠 key（维度前缀 + 分组键，不含序号），title = 展示标题。
struct MacTrackGroupSection: Identifiable, Equatable {
    let id: String
    let title: String
    let tracks: [Track]
}

/// 分组纯函数：输入**已按当前排序排好的曲目数组**，输出 [(title, rows)]。
///
/// - 组内顺序 = 输入顺序（不重排）；
/// - 组顺序：album / artist 按 localizedStandardCompare 升序（album 由 B 的归组函数
///   定义，标题相同再按艺人）；initial 按 A→Z，非拉丁开头归入最后一组 "#"。
enum MacTrackGrouping {
    static func sections(
        tracks: [Track],
        dimension: MacTrackGroupDimension,
        albumTitle: (Track) -> String,
        artistName: (Track) -> String
    ) -> [MacTrackGroupSection] {
        switch dimension {
        case .album:
            return albumSections(tracks: tracks, albumTitle: albumTitle, artistName: artistName)
        case .artist:
            return artistSections(tracks: tracks, artistName: artistName)
        case .initial:
            return initialSections(tracks: tracks)
        }
    }

    // MARK: 专辑维度（复用 B 的归组实现，不复制口径）

    private static func albumSections(
        tracks: [Track],
        albumTitle: (Track) -> String,
        artistName: (Track) -> String
    ) -> [MacTrackGroupSection] {
        let groups = MacAlbumGrouping.groups(
            from: tracks,
            albumTitle: albumTitle,
            artistName: artistName
        )
        // 同名专辑不同艺人（合辑）会被 B 的归组拆成多组：标题相同时补艺人后缀，
        // 否则两条 header 文字完全一样、无法分辨（折叠 key 仍是 id，不受影响）。
        let titleCounts = groups.reduce(into: [String: Int]()) { counts, group in
            counts[group.albumTitle, default: 0] += 1
        }
        return groups.map { group in
            MacTrackGroupSection(
                id: "album:\(group.albumTitle)\u{1}\(group.artistName)",
                title: albumSectionTitle(group, titleCounts: titleCounts),
                tracks: group.tracks
            )
        }
    }

    private static func albumSectionTitle(_ group: MacAlbumGroup, titleCounts: [String: Int]) -> String {
        guard !group.albumTitle.isEmpty else { return group.artistName }
        guard (titleCounts[group.albumTitle] ?? 0) > 1, !group.artistName.isEmpty else {
            return group.albumTitle
        }
        return "\(group.albumTitle) · \(group.artistName)"
    }

    // MARK: 艺人维度

    private static func artistSections(
        tracks: [Track],
        artistName: (Track) -> String
    ) -> [MacTrackGroupSection] {
        var order: [String] = []
        var buckets: [String: [Track]] = [:]
        for track in tracks {
            let name = artistName(track)
            if buckets[name] == nil {
                buckets[name] = []
                order.append(name)
            }
            buckets[name]?.append(track)
        }
        return order
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                MacTrackGroupSection(id: "artist:\(name)", title: name, tracks: buckets[name] ?? [])
            }
    }

    // MARK: A–Z 维度

    private static func initialSections(tracks: [Track]) -> [MacTrackGroupSection] {
        var order: [String] = []
        var buckets: [String: [Track]] = [:]
        for track in tracks {
            let letter = initialLetter(of: track.displayTitle)
            if buckets[letter] == nil {
                buckets[letter] = []
                order.append(letter)
            }
            buckets[letter]?.append(track)
        }
        // "#"（非拉丁 / 非字母开头）固定排最后；其余按字母序。
        let letters = order
            .filter { $0 != "#" }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let ordered = order.contains("#") ? letters + ["#"] : letters
        return ordered.map { letter in
            MacTrackGroupSection(id: "initial:\(letter)", title: letter, tracks: buckets[letter] ?? [])
        }
    }

    /// 分组首字母：去变音符号 + 大小写折叠后取首字符；非 A–Z → "#"。
    private static func initialLetter(of title: String) -> String {
        let folded = title
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .uppercased()
        guard let first = folded.first, first.isASCII, first.isLetter else { return "#" }
        return String(first)
    }
}

// MARK: - [harness] 分组纯函数终点

// MARK: - 维度展示文案（视图层；复用既有本地化 key，A–Z 用字面量）

extension MacTrackGroupDimension {
    var title: String {
        switch self {
        case .album: return Localized.album
        case .artist: return Localized.artist
        case .initial: return "A–Z"
        }
    }
}

/// 维度切换器（segmented；只在 grouped 模式显示，位置在主切换器左侧）。
struct MacTrackGroupDimensionPicker: View {
    @Binding var dimension: MacTrackGroupDimension

    var body: some View {
        Picker("", selection: $dimension) {
            ForEach(MacTrackGroupDimension.allCases, id: \.self) { item in
                Text(item.title).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

// MARK: - 分组折叠列表

/// 分组折叠列表（grouped 模式）：吸顶 header + 折叠/展开 + 单击选中 + 双击播放。
///
/// 分组缓存：sections 只在 onAppear / tracks 变化 / 维度切换时重建，body 只读缓存
/// （与 B 阶段专辑网格同一策略）。折叠状态按 section.id 记，重建后与下标无关地保留。
///
/// 右键菜单：**有意不做**。本视图每行若挂 .macTrackMenu(menu)，会为每行实例化一份
/// 菜单宿主（4 个 sheet/alert host）并各触发一次 onAppear 的
/// reloadPlaylists / reloadFavorites（都是 DB 读）——百行级曲库即 reload 风暴，
/// 且行级 sheet 宿主没有「唯一宿主」语义。替代路径：右键菜单继续只在 list 模式可用，
/// 本模式保留双击播放 + 悬停 ♥（详情 / 标签编辑等从 list 模式进入）。
struct MacTrackGroupedListView: View {
    @Environment(\.appAccentColor) private var appAccentColor
    /// 收藏切换唯一入口：行尾 ♥ 由宿主取环境后显式传入按钮（按钮本身不读环境，见其文件头）
    @Environment(AppCoordinator.self) private var appCoordinator

    /// 已按当前排序排好的曲目（= 列表 displayedRows 的顺序）
    let tracks: [Track]
    let dimension: MacTrackGroupDimension
    let activeTrackId: String?
    /// 收藏状态快照（宿主读 MacTrackMenuModel.favoriteIds；.favoritesChanged 由宿主重载）
    let favoriteIds: Set<String>
    /// 定位当前播放的请求号（与 list 模式同一信号：自增即触发）
    let locateRequestID: Int
    let albumTitle: (Track) -> String
    let artistName: (Track) -> String
    /// 双击播放：队列 = 当前分组显示的完整顺序（扁平化后的实际显示顺序）
    let onPlay: (Track, [Track]) -> Void

    @State private var sections: [MacTrackGroupSection] = []
    @State private var collapsedSections: Set<String> = []
    @State private var selectedTrackId: String?
    @State private var hoveredTrackId: String?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: DesignTokens.space0, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections) { section in
                        Section {
                            if !collapsedSections.contains(section.id) {
                                ForEach(section.tracks, id: \.stableId) { track in
                                    row(track)
                                }
                            }
                        } header: {
                            sectionHeader(section)
                        }
                    }
                }
            }
            .onAppear(perform: rebuildSections)
            .onChange(of: tracks) { _, _ in rebuildSections() }
            .onChange(of: dimension) { _, _ in rebuildSections() }
            .onChange(of: locateRequestID) { _, _ in locateActiveTrack(using: proxy) }
        }
    }

    // MARK: 分组缓存

    private func rebuildSections() {
        sections = MacTrackGrouping.sections(
            tracks: tracks,
            dimension: dimension,
            albumTitle: albumTitle,
            artistName: artistName
        )
        // 已消失的分组（曲目变化 / 维度切换）不保留折叠态；同 id 的保留。
        collapsedSections.formIntersection(Set(sections.map(\.id)))
    }

    private var playbackQueue: [Track] {
        sections.flatMap(\.tracks)
    }

    // MARK: Header（吸顶）

    private func sectionHeader(_ section: MacTrackGroupSection) -> some View {
        let isCollapsed = collapsedSections.contains(section.id)
        return Button {
            if isCollapsed {
                collapsedSections.remove(section.id)
            } else {
                collapsedSections.insert(section.id)
            }
        } label: {
            HStack(spacing: DesignTokens.space8) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: DesignTokens.space12)
                Text(displayTitle(for: section))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: DesignTokens.space8)
                Image(systemName: "music.note")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(section.tracks.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, DesignTokens.space12)
            .padding(.vertical, DesignTokens.space6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(displayTitle(for: section))
    }

    /// 空标题兜底（未入库专辑 / 未知艺人）：只影响展示，不参与分组键。
    private func displayTitle(for section: MacTrackGroupSection) -> String {
        guard section.title.isEmpty else { return section.title }
        switch dimension {
        case .album: return Localized.unknownAlbum
        case .artist: return Localized.unknownArtist
        case .initial: return section.title
        }
    }

    // MARK: 行

    private func row(_ track: Track) -> some View {
        let isActive = track.stableId == activeTrackId
        let isSelected = track.stableId == selectedTrackId
        let isHovered = track.stableId == hoveredTrackId
        let isFavorite = favoriteIds.contains(track.stableId)
        return HStack(spacing: DesignTokens.space10) {
            MacArtworkThumbnail(
                track: track,
                size: Metrics.artworkSize,
                cornerRadius: DesignTokens.radius4
            )
            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(track.displayTitle)
                    .font(.callout)
                    .foregroundColor(isActive ? appAccentColor : .primary)
                    .lineLimit(1)
                Text(artistName(track))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignTokens.space8)
            Text(durationText(for: track))
                .font(.caption)
                .monospacedDigit()
                .foregroundColor(.secondary)
            if isFavorite || isHovered {
                MacTrackFavoriteButton(appCoordinator: appCoordinator, track: track, isFavorite: isFavorite)
            }
        }
        .padding(.horizontal, DesignTokens.space12)
        .padding(.vertical, DesignTokens.space6)
        .background(rowBackground(isActive: isActive, isSelected: isSelected, isHovered: isHovered))
        .contentShape(Rectangle())
        .gesture(rowTapGesture(for: track))
        .onHover { inside in
            if inside {
                hoveredTrackId = track.stableId
            } else if hoveredTrackId == track.stableId {
                hoveredTrackId = nil
            }
        }
    }

    /// 单击选中 / 双击播放：ExclusiveGesture 保证双击不被单击抢先消费。
    /// （本视图没有 NSTableView 原生 primaryAction 可用，只能手势模拟；单击判定会有
    ///  系统双击间隔的延迟，这是自定义列表的固有代价。）
    private func rowTapGesture(for track: Track) -> some Gesture {
        ExclusiveGesture(
            TapGesture(count: 2).onEnded { play(track) },
            TapGesture(count: 1).onEnded { selectedTrackId = track.stableId }
        )
    }

    private func rowBackground(isActive: Bool, isSelected: Bool, isHovered: Bool) -> Color {
        if isSelected {
            return appAccentColor.opacity(Metrics.selectedTintOpacity)
        }
        if isActive {
            return appAccentColor.opacity(Metrics.activeTintOpacity)
        }
        if isHovered {
            return Color.primary.opacity(Metrics.hoverTintOpacity)
        }
        return .clear
    }

    private func durationText(for track: Track) -> String {
        guard let milliseconds = track.durationMs, milliseconds > 0 else { return "" }
        return MacTimeFormat.format(Double(milliseconds) / 1000)
    }

    // MARK: 播放与定位

    private func play(_ track: Track) {
        onPlay(track, playbackQueue)
        selectedTrackId = track.stableId
    }

    /// 定位当前播放：展开其所在组 → 选中 → 滚到该行（滚动走 SwiftUI ScrollViewReader，
    /// 分组视图没有 NSTableView，不需要 AppKit 桥接）。
    private func locateActiveTrack(using proxy: ScrollViewProxy) {
        guard let activeTrackId,
              let section = sections.first(where: { $0.tracks.contains { $0.stableId == activeTrackId } })
        else { return }
        collapsedSections.remove(section.id)
        selectedTrackId = activeTrackId
        // 展开下一帧才生效：等布局落定再滚，否则行还不在视图树里，scrollTo 无效。
        DispatchQueue.main.async {
            proxy.scrollTo(activeTrackId, anchor: .center)
        }
    }

    // MARK: 量值

    private enum Metrics {
        /// 行内封面边长（分组行比列表行紧凑）
        static let artworkSize: CGFloat = 28
        /// 当前播放行底色不透明度（与列表模式一致）
        static let activeTintOpacity: Double = 0.08
        /// 单击选中行底色不透明度（略强于当前播放）
        static let selectedTintOpacity: Double = 0.14
        /// 悬停行底色不透明度
        static let hoverTintOpacity: Double = 0.06
    }
}
