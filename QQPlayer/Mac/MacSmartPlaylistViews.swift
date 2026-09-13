//
//  MacSmartPlaylistViews.swift
//  QQPlayer
//
//  macOS automatic playlists (自动歌单): a pinned card grid at the top of
//  the playlist page plus a detail sheet (track list for recentAdded /
//  recentPlayed / topPlayed; decade bucket list that pushes into a per-decade
//  track list inside the same sheet). QQPlayerMac target only.
//
//  Icon/subtitle decisions mirror the iOS SmartPlaylistUILogic so both
//  platforms stay visually consistent; the iOS file is not compiled into the
//  Mac target, hence the local copy. Card artwork uses MacArtworkCollage
//  (2x2 cover collage, mirroring the iOS SmartPlaylistCardView).
//

import SwiftUI

// MARK: - Card strip

/// Pure UI decisions for the pinned cards (mirrors iOS SmartPlaylistUILogic).
enum MacSmartPlaylistUILogic {
    /// SF Symbol shown on the pinned card for each kind.
    static func iconName(for kind: SmartPlaylistKind) -> String {
        switch kind {
        case .recentAdded: return "clock"
        case .recentPlayed: return "history"
        case .topPlayed: return "flame"
        case .decades: return "calendar"
        }
    }

    /// Card badge: song count for track-based kinds, decade count for decades.
    /// Formatting is injected so the decision stays testable.
    static func cardSubtitle(
        kind: SmartPlaylistKind,
        count: Int,
        songsFormat: (Int) -> String,
        decadesFormat: (Int) -> String
    ) -> String {
        switch kind {
        case .decades:
            return decadesFormat(count)
        default:
            return songsFormat(count)
        }
    }

    /// 卡片条列数：先算「卡宽不低于 minCardWidth」时能放几列，再在这个上限内挑
    /// 一个能把最后一行也填满的列数（4 张卡 → 4 或 2 列，避免 3+1 这种半空行）。
    /// availableWidth <= 0 表示本帧还没量到宽度，先按一行排，量到后立即重排。
    static func stripColumnCount(
        cardCount: Int,
        availableWidth: CGFloat,
        minCardWidth: CGFloat,
        spacing: CGFloat
    ) -> Int {
        guard cardCount > 0 else { return 1 }
        guard availableWidth > 0 else { return cardCount }
        let fitting = Int((availableWidth + spacing) / (minCardWidth + spacing))
        let bounded = max(1, min(cardCount, fitting))
        guard bounded > 1 else { return 1 }
        for candidate in stride(from: bounded, through: 2, by: -1) where cardCount % candidate == 0 {
            return candidate
        }
        return bounded
    }

    /// 卡片宽度：行内均分可用宽度，夹在 [minCardWidth, maxCardWidth] 之间。
    static func stripCardWidth(
        columns: Int,
        availableWidth: CGFloat,
        minCardWidth: CGFloat,
        maxCardWidth: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        guard columns > 0, availableWidth > 0 else { return minCardWidth }
        let evenly = (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return min(max(evenly, minCardWidth), maxCardWidth)
    }
}

/// 置顶自动歌单卡片网格（4 张，铺在播放列表页顶部）。
///
/// 2026-09-13 用户反馈：以前是固定 116pt 卡宽的横向 `ScrollView`（4 卡共 532pt），
/// 而歌单列宽只有 320–600pt —— 列一窄就必须左右滚动才能看到「常听排行 / 年代」。
/// 改成按可用宽度算列数/卡宽的网格后：窄列 2×2、宽列一行 4 张，封面拼贴随列宽
/// 缩放，永远不需要横向滚动。列数/卡宽的计算在 `MacSmartPlaylistUILogic` 里
/// （纯函数，便于以后 macOS 有测试 target 时单测）。
struct MacSmartPlaylistCardStrip: View {
    let cards: [SmartPlaylistCardInfo]
    let coverTracks: [SmartPlaylistKind: [Track]]
    let onSelect: (SmartPlaylistKind) -> Void

    /// 卡宽区间：下限保证封面拼贴与标题可读，上限避免宽列下单卡过大。
    private static let minCardWidth: CGFloat = 104
    private static let maxCardWidth: CGFloat = 168
    /// 卡间距 / 条带左右内边距（列数与卡宽计算共用）。
    private static let spacing: CGFloat = 12
    private static let horizontalPadding: CGFloat = 16

    /// 条带可用宽度（含左右内边距；0 = 本帧还没量到）→ 决定列数与卡宽。
    @State private var stripWidth: CGFloat = 0

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: Self.spacing) {
            ForEach(cards, id: \.kind) { info in
                Button {
                    onSelect(info.kind)
                } label: {
                    card(info)
                }
                .buttonStyle(.plain)
                .help(Localized.smartPlaylistTitle(info.kind))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 12)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: MacSmartCardStripWidthKey.self, value: geometry.size.width)
        })
        .onPreferenceChange(MacSmartCardStripWidthKey.self) { width in
            stripWidth = width
        }
    }

    // MARK: 卡片

    /// 单卡：封面拼贴（跟随列宽）+ 标题 + 计数。
    private func card(_ info: SmartPlaylistCardInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MacArtworkCollageFill(
                tracks: coverTracks[info.kind] ?? [],
                cornerRadius: 8,
                placeholderIcon: MacSmartPlaylistUILogic.iconName(for: info.kind)
            )
            Text(Localized.smartPlaylistTitle(info.kind))
                .font(.callout)
                .fontWeight(.medium)
                .lineLimit(1)
            Text(MacSmartPlaylistUILogic.cardSubtitle(
                kind: info.kind,
                count: info.count,
                songsFormat: Localized.smartSongsCount,
                decadesFormat: Localized.smartDecadeCount
            ))
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    // MARK: 布局

    private var columns: [GridItem] {
        let usable = stripWidth - Self.horizontalPadding * 2
        let columnCount = MacSmartPlaylistUILogic.stripColumnCount(
            cardCount: cards.count,
            availableWidth: usable,
            minCardWidth: Self.minCardWidth,
            spacing: Self.spacing
        )
        let cardWidth = MacSmartPlaylistUILogic.stripCardWidth(
            columns: columnCount,
            availableWidth: usable,
            minCardWidth: Self.minCardWidth,
            maxCardWidth: Self.maxCardWidth,
            spacing: Self.spacing
        )
        return Array(
            repeating: GridItem(.fixed(cardWidth), spacing: Self.spacing, alignment: .topLeading),
            count: columnCount
        )
    }
}

/// 卡片条宽度回传（宽度 → 列数/卡宽）。容器被 `frame(maxWidth:)` 钉住宽度，
/// 网格内容不会反过来影响它，因此不存在布局反馈回路。
private struct MacSmartCardStripWidthKey: PreferenceKey {
    static var defaultValue: CGFloat { 0 }

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Detail content (in-column, 2026-09-05)

/// Inline detail for one automatic playlist, displayed in the content column
/// (no popup sheet). A leading back button returns to the playlists page. The
/// decades kind first shows the bucket list; tapping a bucket swaps the content
/// to that decade's tracks (back returns to the bucket list).
struct MacSmartPlaylistDetailView: View {
    let kind: SmartPlaylistKind
    /// Pop one level: decade bucket → bucket list; root → playlists home page.
    let onBack: () -> Void

    @StateObject private var player = PlayerEngine.shared

    @State private var tracks: [Track] = []
    @State private var buckets: [DecadeBucketInfo] = []
    @State private var selectedBucket: DecadeBucketInfo?
    @State private var bucketTracks: [Track] = []
    @State private var isLoading = true
    @State private var loadError: String?
    /// 重算任务句柄（审计 M2：全量重算移出主线程后可取消）
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { loadData() }
        .onDisappear { loadTask?.cancel() }
        // 刮削保存/批量刮削/重扫后：自动歌单曲目与年代分组都要重算
        // （2026-09-06：单曲刮削后自动歌单不刷新修复；decade 详情内也重载）
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("LibraryNeedsRefresh"))) { _ in
            reloadAll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("PlaylistsChanged"))) { _ in
            reloadAll()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                if selectedBucket != nil {
                    selectedBucket = nil
                } else {
                    onBack()
                }
            } label: {
                Label(Localized.back, systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .help(Localized.back)
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var title: String {
        if let selectedBucket {
            return selectedBucket.label
        }
        return Localized.smartPlaylistTitle(kind)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let loadError {
            MacSmartPlaylistEmptyView(message: loadError, systemImage: "exclamationmark.triangle", retry: { loadData() })
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if kind == .decades {
            if selectedBucket != nil {
                bucketTrackList
            } else {
                decadeBucketList
            }
        } else if tracks.isEmpty {
            MacSmartPlaylistEmptyView(message: emptyMessage, retry: nil)
        } else {
            trackList(tracks)
        }
    }

    private var decadeBucketList: some View {
        List(buckets, id: \.key) { bucket in
            Button {
                selectedBucket = bucket
                loadBucketTracks(bucket)
            } label: {
                HStack {
                    Text(bucket.label)
                        .lineLimit(1)
                    Spacer()
                    Text(Localized.smartSongsCount(bucket.count))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var bucketTrackList: some View {
        if bucketTracks.isEmpty {
            MacSmartPlaylistEmptyView(message: Localized.smartEmptyDecade, retry: nil)
        } else {
            trackList(bucketTracks)
        }
    }

    private func trackList(_ queue: [Track]) -> some View {
        MacTrackListView(
            tracks: queue,
            activeTrackId: player.currentTrack?.stableId,
            isPlaying: player.isPlaying,
            artistNameResolver: resolveArtistName,
            onPlay: { track, sortedQueue in play(track, queue: sortedQueue) },
            onSelect: { _ in },
            onPlayNext: { player.insertNext($0) }
        )
    }

    private var emptyMessage: String {
        switch kind {
        case .recentPlayed: return Localized.smartEmptyRecentPlayed
        case .topPlayed: return Localized.smartEmptyTopPlayed
        default: return Localized.noSongsFound
        }
    }

    // MARK: Data

    private func loadData() {
        loadTask?.cancel()
        isLoading = true
        loadError = nil
        let kind = self.kind
        let bucket = kind == .decades ? selectedBucket : nil
        loadTask = Task { @MainActor in
            // 审计 M2：全量重算（recentAdded/topPlayed/decadeBuckets）以前在
            // 通知回调里同步跑在主线程 → 现在在全局执行器上取数
            let payload = await MacSmartPlaylistLoader.load(kind: kind)
            guard !Task.isCancelled else { return }
            switch payload {
            case .success(.tracks(let loaded)):
                tracks = loaded
                isLoading = false
            case .success(.buckets(let loaded)):
                buckets = loaded
                isLoading = false
                // 年代内层：同步重拉该年代曲目；原年代分组已消失 → 退回年代列表
                if let bucket {
                    if loaded.contains(where: { $0.key == bucket.key }) {
                        await refreshBucketTracks(bucket)
                    } else {
                        selectedBucket = nil
                        bucketTracks = []
                    }
                }
            case .failure:
                loadError = Localized.smartLoadFailed
                isLoading = false
            }
        }
    }

    private func loadBucketTracks(_ bucket: DecadeBucketInfo) {
        Task { @MainActor in
            await refreshBucketTracks(bucket)
        }
    }

    /// 单年代曲目取数（审计 M2：同上，非主线程）
    private func refreshBucketTracks(_ bucket: DecadeBucketInfo) async {
        let loaded = await MacSmartPlaylistLoader.bucketTracks(key: bucket.key)
        guard !Task.isCancelled else { return }
        if let loaded {
            bucketTracks = loaded
        } else {
            loadError = Localized.smartLoadFailed
        }
    }

    /// 外部数据变化（刮削保存/批量刮削/重扫/歌单变更）后统一重载：
    /// 普通自动歌单重拉曲目；年代歌单重拉分组，且在年代内层时同步重拉该年代曲目。
    private func reloadAll() {
        loadData()
    }

    private func play(_ track: Track, queue: [Track]) {
        Task {
            await player.playTrack(track, queue: queue)
        }
    }

    private func resolveArtistName(for track: Track) -> String? {
        try? DatabaseManager.shared.getArtistDisplayName(
            forTrackStableId: track.stableId,
            fallbackArtistId: track.artistId
        )
    }
}

/// 自动歌单取数（nonisolated async → 全量重算在全局执行器上，不占主线程）。
/// 审计 M2：这些 `SmartPlaylistStore` 调用以前直接跑在 body/通知回调里。
enum MacSmartPlaylistLoader {
    enum Payload {
        case tracks([Track])
        case buckets([DecadeBucketInfo])
    }

    /// 卡片条数据（计数 + 封面代表曲目）
    struct CardStripPayload {
        var cards: [SmartPlaylistCardInfo]
        var covers: [SmartPlaylistKind: [Track]]
    }

    static func load(kind: SmartPlaylistKind) async -> Result<Payload, Error> {
        do {
            switch kind {
            case .recentAdded:
                return .success(.tracks(try SmartPlaylistStore.recentAddedTracks()))
            case .recentPlayed:
                return .success(.tracks(try SmartPlaylistStore.recentPlayedTracks()))
            case .topPlayed:
                return .success(.tracks(try SmartPlaylistStore.topPlayedTracks().map(\.track)))
            case .decades:
                return .success(.buckets(try SmartPlaylistStore.decadeBuckets()))
            }
        } catch {
            return .failure(error)
        }
    }

    static func bucketTracks(key: String) async -> [Track]? {
        try? SmartPlaylistStore.tracks(inDecade: key)
    }

    /// 卡片条（一次取数：5 次查询集中在后台）
    static func cardStrip() async -> CardStripPayload? {
        do {
            let cards = try SmartPlaylistStore.cardInfos()
            var covers: [SmartPlaylistKind: [Track]] = [:]
            for kind in SmartPlaylistKind.allCases {
                covers[kind] = try SmartPlaylistStore.coverTracks(for: kind, limit: 4)
            }
            return CardStripPayload(cards: cards, covers: covers)
        } catch {
            return nil
        }
    }
}

/// Empty/error state shared by the automatic-playlist screens.
struct MacSmartPlaylistEmptyView: View {
    let message: String
    var systemImage: String = "music.note"
    let retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if let retry {
                Button("retry".localized, action: retry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
