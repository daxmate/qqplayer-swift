//
//  MacTrackListView.swift
//  QQPlayer
//
//  macOS track list (content column for the 歌曲 section). QQPlayerMac target only.
//
//  2026-09-02 三修：回归 SwiftUI Table——macOS 平台惯例「单击选中、双击播放」
//  由 Table 原生 primaryAction 保证（AppKit NSTableView 底层），不再用手势模拟
//  （List + onTapGesture 与选中手势冲突导致双击失效，教训：平台基础交互交给
//  原生控件）。保留：列头原生排序（sortOrder）、右键菜单补全（contextMenu
//  forSelectionType）、定位当前播放（选中 + 尽量滚动可见）、播放队列跟随排序。
//  2026-11-16 视觉增强：行内封面缩略图 / 时长列 / 当前播放行高亮 / 悬停收藏
//  （只改呈现，单击选中·双击播放·列头排序·右键菜单等交互契约不变）。
//  2026-11-23 精简：删除「#」序号列（该列同时承载当前播放喇叭图标，整列一并移除）
//  并隐藏表头；sortOrder 排序状态 / 整行播放底色 / 右键菜单等交互契约不变。
//  2026-11-23 排序入口补回：表头隐藏后由工具条「排序」菜单写 sortOrder
//  （视图在 MacTrackSortMenu.swift，排序链路原样复用）。
//

import AppKit
import SwiftUI

/// Table 行包装：携带排序字段（artist 显示名经 resolver 解析）。
/// macOS 13+/26 SDK 的排序 TableColumn(value:) 与 SortDescriptor 都要求行类型
/// 继承 NSObject 且排序 KeyPath 指向 @objc 存储属性（OC runtime 内省）——
/// 用计算属性/纯 Swift 属性会运行时 fatal："must be introspectable by the
/// objective-c runtime"（2026-09-02 用户实测）。
/// 非 private：工具条排序菜单（MacTrackSortMenu.swift）也要构造
/// `SortDescriptor<MacTrackTableRow>`，故行类型需跨文件可见。
final class MacTrackTableRow: NSObject, Identifiable {
    let id: String
    let track: Track
    /// 排序/显示字段：@objc 存储属性（title/artistName/albumName/durationMs）。
    /// ⚠️ 必须是存储属性：计算属性能过编译，但 Table 排序运行期 fatal（见文件头注释）。
    @objc let title: String
    @objc let artistName: String
    /// 专辑排序键（与专辑列同口径：facts 缓存标题 + 字形归一）。
    /// 每行一次缓存命中（O(1) 字典读，非 DB 查询），数千行量级的重建开销可忽略。
    @objc let albumName: String
    /// 时长排序键（毫秒；未知 = -1，让未知排在最短之前）
    @objc let durationMs: Int
    /// 时长展示文案（m:ss；未知为空串）——只用于显示，不参与排序
    let durationText: String

    init(id: String, track: Track, artistName: String, albumName: String) {
        self.id = id
        self.track = track
        self.title = track.title
        self.artistName = artistName
        self.albumName = albumName
        let milliseconds = track.durationMs ?? -1
        self.durationMs = milliseconds
        self.durationText = milliseconds > 0 ? MacTimeFormat.format(Double(milliseconds) / 1000) : ""
    }
}

// MARK: - 列表右键弹窗（2026-09-08 白框修复：.sheet(isPresented:) 的 content 闭包
// 读另一个 @State（tagEditorTrack）存在时序竞态——present 瞬间可能读到 nil →
// 弹出空内容 sheet（白框）且不自动刷新。改用 .sheet(item:) 由 SwiftUI 保证
// item 非空时才 present、content 直接拿 item，消除竞态。

/// 批量刮削请求（paths 数组的 Identifiable 包装，供 .sheet(item:) 使用）
private struct BatchScrapeRequest: Identifiable {
    let id = UUID()
    let paths: [String]
}

/// 歌曲列表的视觉量值（集中声明，避免魔法数字散进各列；改尺寸只改这一处）。
private enum MacTrackListMetrics {
    /// 行内封面边长（任务要求 34；若真机确认行高不足导致裁切，把这里改成 22 即可回退）
    static let artworkSize: CGFloat = 34
    /// 封面圆角（DesignTokens 圆角档位里的 4）
    static let artworkCornerRadius: CGFloat = DesignTokens.radius4
    /// 封面列宽 = 封面 34 + 左右各 6
    static let artworkColumnWidth: CGFloat = 46
    /// 时长列宽（固定，不可拉伸）
    static let durationColumnWidth: CGFloat = 56
    /// 行尾操作列宽（悬停 ♥ 槽位）
    static let actionColumnWidth: CGFloat = 40
    /// 当前播放行底色不透明度（accent 8%）
    static let activeRowTintOpacity: Double = 0.08
    /// 专辑列在 secondary 基础上压暗一档
    static let albumSecondaryOpacity: Double = 0.85
}

struct MacTrackListView: View {
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    @Environment(\.appAccentColor) private var appAccentColor
    let tracks: [Track]
    let activeTrackId: String?
    let isPlaying: Bool
    let artistNameResolver: (Track) -> String?
    /// 双击/播放回调：队列 = 当前排序后显示列表（web 版「以当前视图为队列」语义）
    let onPlay: (Track, [Track]) -> Void
    let onSelect: (Track) -> Void
    /// Non-nil inside a playlist detail sheet: the context menu additionally
    /// offers "remove from playlist" for the owning playlist.
    var playlistId: Int64?
    /// 「下一首播放」：插入当前播放曲目之后（不播放）
    var onPlayNext: ((Track) -> Void)?
    /// 「进歌手 / 进专辑」：切到对应分组并打开详情
    var onShowArtist: ((Track) -> Void)?
    var onShowAlbum: ((Track) -> Void)?

    /// 曲库卡片事实缓存（审计 M2：body 里的同步全量 DB 查询→缓存/异步）
    @Environment(MacLibraryFactsStore.self) private var facts
    // 行尾 ♥ 收藏切换唯一入口；行内容 hosting 不继承环境 → 本视图取到后显式传参
    @Environment(AppCoordinator.self) private var appCoordinator
    @State private var selectedRows = Set<String>()
    /// 批量刮削（右键多选 >1）——.sheet(item:) 直接驱动，见文件头注释
    @State private var batchScrapeRequest: BatchScrapeRequest?
    /// 曲目右键菜单状态：菜单内容 / 弹窗 / 删除执行都在 MacTrackContextMenu.swift
    /// （曲库与两个搜索面共用同一份实现），这里只持有状态
    @State private var menu = MacTrackMenuModel()
    /// 当前悬停行：由父视图唯一持有，单元格只上报（不把 hover 状态散进各格 @State）
    @State private var hoveredTrackId: String?
    @State private var columnWidths = MacTrackColumnWidthStore().load()  // 唯一真相源；启动取回上次宽度（MacTrackColumnWidthStore.swift）
    /// Table 排序状态（表头已隐藏；显示与播放队列都按 sortOrder 跟随）。
    /// macOS 26 SDK 的 Table sortOrder 使用 SortDescriptor。
    @State private var sortOrder: [SortDescriptor<MacTrackTableRow>] = []
    /// 当前显示的排序后行（播放队列跟随，与 Table 显示一致）
    @State private var displayedRows: [MacTrackTableRow] = []
    /// 呈现模式（列表 / 专辑网格）：只影响呈现层，重启保持上次选择
    @AppStorage("macTrackListViewMode") private var viewMode: MacTrackListMode = .list
    /// 分组维度（专辑 / 艺人 / A–Z）：仅 grouped 模式使用，重启保持上次选择
    @AppStorage("macTrackListGroupDimension") private var groupDimension: MacTrackGroupDimension = .album
    /// 专辑网格分组缓存（tracks 变化 / 进入网格时重建，body 只读缓存）
    @State private var albumGroups: [MacAlbumGroup] = []
    /// 从网格点进某张专辑后的筛选键（nil = 不筛选；面包屑可清除）
    @State private var albumFilter: MacAlbumFilterKey?

    var body: some View {
        if tracks.isEmpty {
            VStack(spacing: DesignTokens.space12) {
                Image(systemName: "music.note.list")
                    .font(.system(size: DesignTokens.font44))
                    .foregroundColor(.secondary)
                Text("library_empty".localized)
                    .font(.title3)
                Text("library_empty_hint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: DesignTokens.space0) {
                toolbarRow
                if let filter = albumFilter {
                    albumFilterBar(filter)
                }
                Divider()
                if viewMode == .albums {
                    albumGrid
                } else if viewMode == .grouped {
                    groupedList
                } else {
                    table
                }
            }
            // 右键菜单弹窗宿主（新建歌单 / 编辑标签 / 删除确认）——与两个搜索面同一份实现
            .macTrackMenu(menu) { deletedIds in
                // 本地即时移除（不等父级通知链）：当前列表立即消失
                // （父级 reloadLibrary 随后全量重拉对齐歌单/专辑等其它视图）
                selectedRows.removeAll()
                guard !deletedIds.isEmpty else { return }
                displayedRows.removeAll { deletedIds.contains($0.id) }
            }
            .onAppear {
                syncDisplayedRows(album: albumFilter)
                rebuildAlbumGroups()
            }
            .onChange(of: viewMode) { _, newMode in
                // 网格是全库总览：进入网格即退出专辑筛选（列表模式行为不变）
                if newMode == .albums {
                    albumFilter = nil
                    rebuildAlbumGroups()
                }
            }
            .onChange(of: sortOrder) { _, newSort in
                // 用 onChange 传入的新排序重建，不用旧闭包捕获的 self.sortOrder
                syncDisplayedRows(sort: newSort, album: albumFilter)
            }
            .onChange(of: tracks) { _, newTracks in
                // 关键修复（2026-09-03 现场探针定位）：onChange 闭包捕获的是变化前的
                // 旧 self，读 self.tracks 会拿到删除前的旧数组 → 用旧数据重建会把刚
                // 删掉的行“复活”，且后续重载不再触发 onChange，幽灵行直到重启才消失。
                // 必须用 onChange 传入的 newTracks（新数据）重建。
                // 筛选的专辑整张被删 / 改名 → 自动清除筛选，避免停在空列表
                var filter = albumFilter
                if let current = filter,
                   !newTracks.contains(where: { albumFilterKey(for: $0) == current }) {
                    albumFilter = nil
                    filter = nil
                }
                rebuildAlbumGroups(for: newTracks)
                syncDisplayedRows(tracks: newTracks, album: filter)
            }
            // 批量刮削 sheet（多选右键；单曲编辑 sheet 在 .macTrackMenu 宿主里）
            .sheet(item: $batchScrapeRequest) { request in
                MacScrapeBatchProgressView(paths: request.paths, libraryMode: false)
            }
        }
    }

    // MARK: - Toolbar（定位当前播放；2026-09-02 用户拍板：去掉顶部批量条，
    // 多选操作全部走右键菜单——单击选中是 macOS 常态，选中 1 行弹批量条很突兀）

    private var toolbarRow: some View {
        HStack {
            Button {
                locateActiveTrack()
            } label: {
                Label(Localized.locatePlayingTrack, systemImage: "location")
                    .font(.callout)
            }
            .buttonStyle(.borderless)
            .disabled(activeTrackId == nil)
            Spacer()
            // 批量删除进度 + 取消（审计 H1：修复前磁盘/DB 逐首同步跑在主线程、
            // 窗口卡死且无法取消——现在执行在后台，主线程只显示进度并允许取消）
            if let progress = menu.trashProgress {
                HStack(spacing: DesignTokens.space8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(progress.done)/\(progress.total)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                    Button("cancel".localized) {
                        menu.trashTask?.cancel()
                    }
                    .controlSize(.small)
                }
            }
            if viewMode == .grouped {
                MacTrackGroupDimensionPicker(dimension: $groupDimension)
            }
            // 列表 / 分组都以 displayedRows 的顺序呈现（专辑网格是全库总览，排序无意义）
            if viewMode != .albums {
                MacTrackSortMenu(sortOrder: $sortOrder)
            }
            viewModePicker
        }
        .padding(.horizontal, DesignTokens.space12)
        .padding(.vertical, DesignTokens.space4)
    }

    // MARK: - Table

    private var table: some View {
        Table(displayedRows, selection: $selectedRows, sortOrder: $sortOrder) {
            // 行内封面：无列头、不可排序；加载统一走 MacArtworkThumbnail（全项目唯一入口）
            TableColumn("") { row in
                cellChrome(row) {
                    MacArtworkThumbnail(
                        track: row.track,
                        size: MacTrackListMetrics.artworkSize,
                        cornerRadius: MacTrackListMetrics.artworkCornerRadius
                    )
                }
                // 当前播放行的整行底色：写到所在 NSTableRowView 上（跨列连续），
                // 不再逐格铺（列间距会把底色切成几段）。找不到行视图时没有底色。
                .background(
                    MacTableRowHighlight(
                        isActive: row.track.stableId == activeTrackId,
                        tint: appAccentColor.opacity(MacTrackListMetrics.activeRowTintOpacity)
                    )
                )
            }
            .width(MacTrackListMetrics.artworkColumnWidth)

            TableColumn("title".localized, value: \.title) { row in
                cellChrome(row) {
                    Text(row.track.displayTitle)
                        .fontWeight(row.track.stableId == activeTrackId ? .semibold : .medium)
                        .foregroundColor(row.track.stableId == activeTrackId ? appAccentColor : .primary)
                        .lineLimit(1)
                }
            }
            .width(min: MacTrackColumnLayout.titleMinWidth, ideal: columnWidths.title, max: .infinity)

            TableColumn("artist".localized, value: \.artistName) { row in
                cellChrome(row) {
                    Text(row.artistName)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: MacTrackColumnLayout.artistMinWidth, ideal: columnWidths.artist, max: .infinity)

            TableColumn("album".localized) { row in
                cellChrome(row) {
                    Text(albumTitle(for: row.track))
                        .foregroundColor(.secondary.opacity(MacTrackListMetrics.albumSecondaryOpacity))
                        .lineLimit(1)
                }
            }
            .width(min: MacTrackColumnLayout.albumMinWidth, ideal: columnWidths.album, max: .infinity)

            // 2026-09-06 用户拍板曾去掉时长列（播放区进度条已有时长信息）；
            // 2026-11-16 视觉增强按新需求恢复：右对齐 + 等宽数字 + 固定 56 不可拉伸。
            // 排序值取 @objc 存储属性 durationMs（数值排序，未知 -1 靠前）。
            TableColumn("duration".localized, value: \.durationMs) { row in
                cellChrome(row, alignment: .trailing) {
                    Text(row.durationText)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }
            }
            .width(MacTrackListMetrics.durationColumnWidth)

            // 行尾悬停操作：♥ 收藏切换（动作 = AppCoordinator.toggleFavorite）
            TableColumn("") { row in
                cellChrome(row, alignment: .trailing) {
                    favoriteToggle(for: row)
                }
            }
            .width(MacTrackListMetrics.actionColumnWidth)
        }
        // macOS 惯例：单击选中、双击播放（Table primaryAction 原生实现，
        // AppKit NSTableView 底层；勿改手势模拟）
        .contextMenu(forSelectionType: String.self) { selectedIDs in
            if selectedIDs.count > 1 {
                // 多选：批量刮削 + 批量移到废纸篓（web 版多选批量对齐，歌单详情内同样可用）
                let tracks = displayedRows
                    .filter { selectedIDs.contains($0.id) }
                    .map(\.track)
                if !tracks.isEmpty {
                    Button {
                        let paths = tracks.map(\.path)
                        presentAfterMenuDismisses {
                            batchScrapeRequest = BatchScrapeRequest(paths: paths)
                        }
                    } label: {
                        Label("context_batch_scrape".localized, systemImage: "tag")
                    }
                    Menu(Localized.addToPlaylist) { MacAddToPlaylistMenu(tracks: tracks, model: menu) }
                    Divider()
                    Button(role: .destructive) {
                        presentAfterMenuDismisses {
                            menu.requestTrash(tracks)
                        }
                    } label: {
                        Label(Localized.moveToTrash, systemImage: "trash")
                    }
                }
            } else if let id = selectedIDs.first,
                      let row = displayedRows.first(where: { $0.id == id }) {
                // 单选：与两个搜索面同一份菜单实现（MacTrackContextMenu.swift）
                MacTrackContextMenuContent(
                    track: row.track,
                    model: menu,
                    playlistId: playlistId,
                    onPlay: { play(row.track) },
                    onPlayNext: onPlayNext,
                    onShowArtist: onShowArtist,
                    onShowAlbum: onShowAlbum
                )
            }
        } primaryAction: { selectedIDs in
            if let id = selectedIDs.first,
               let row = displayedRows.first(where: { $0.id == id }) {
                play(row.track)
            }
        }
        // 表头整条隐藏（用户要求：列表不显示列名；「#」序号列已删）
        .tableColumnHeaders(.hidden)
        .macTrackColumnWidthDrag(widths: $columnWidths)  // 拖拽结束（mouseUp）才写盘，见 MacTrackColumnResizer.swift
        // 定位当前播放：先选中（下表 onChange 设 selection），再滚到可视区垂直居中
        // （Table 无公开 scrollTo ⇒ AppKit 桥接；滚动唯一入口 MacTableScroll）
        .background(MacTableLocateScroller(request: locateRequestID, row: locateRow).allowsHitTesting(false)).macGlassListBackground()
        // ⌘I：打开选中曲目的「歌曲详情」（与右键菜单同一 sheet 宿主：菜单状态 model）。
        // 用 SwiftUI 键盘快捷键注册（仓库既有做法，见 MacAlbumArtistViews 的
        // .keyboardShortcut(.return/.cancelAction)）；全局快捷键表 MacKeyboardShortcuts
        // 的默认组合不含 ⌘I，无冲突。隐藏按钮只承载快捷键，不占布局/不可点。
        .background(
            Button("track_detail_title".localized) {
                openSelectedTrackDetail()
            }
            .keyboardShortcut("i", modifiers: .command)
            .hidden()
        )
        .onChange(of: locateRequestID) { _, _ in
            // 定位当前播放：选中当前行（滚动由上面的 MacTableLocateScroller 随后触发）
            if let activeTrackId {
                selectedRows = [activeTrackId]
            }
        }
    }

    /// 定位请求信号：按钮点击自增触发 onChange
    @State private var locateRequestID = 0

    /// 「定位当前播放」的滚动目标行（**显示行序**，因 Table 显示的是排序后的 displayedRows）；
    /// nil = 当前播放曲不在本列表（被过滤/切了列表）→ 不滚，静默 no-op。
    private var locateRow: Int? {
        guard let activeTrackId else { return nil }
        return displayedRows.firstIndex { $0.id == activeTrackId }
    }

    /// 打开选中曲目的歌曲详情（仅单选；多选无「选中曲目」语义 → 静默 no-op）。
    private func openSelectedTrackDetail() {
        guard selectedRows.count == 1,
              let id = selectedRows.first,
              let row = displayedRows.first(where: { $0.id == id }) else { return }
        menu.detailTrack = row.track
    }

    private func locateActiveTrack() {
        // 网格没有「行」可定位 → 先切回列表再定位；grouped 自带行，留在本模式内定位
        if viewMode == .albums {
            viewMode = .list
        }
        locateRequestID += 1
    }

    // MARK: - 行内视觉（2026-11-16 视觉增强）

    /// 单元格公共外壳：铺满单元格 + 悬停上报。
    /// 当前播放行的整行底色不在这里铺（逐格 `.background` 会被列间距切成几段），
    /// 改由封面列挂 `MacTableRowHighlight` 写到所在 `NSTableRowView` 上。
    private func cellChrome<Content: View>(
        _ row: MacTrackTableRow,
        alignment: Alignment = .leading,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .onHover { inside in
                reportHover(row.id, inside: inside)
            }
    }

    /// 悬停上报：单元格各有独立 hover 区，父视图只认唯一「当前悬停行」。
    /// 离开时仅在「仍是本行」时清除——相邻格 enter/exit 先后顺序不同也不会误清新行。
    private func reportHover(_ id: String, inside: Bool) {
        if inside {
            hoveredTrackId = id
        } else if hoveredTrackId == id {
            hoveredTrackId = nil
        }
    }

    /// 行尾收藏按钮：状态读 MacTrackMenuModel.favoriteIds（.favoritesChanged 由
    /// .macTrackMenu 宿主重载）；本体是共享实现 MacTrackFavoriteButton（禁止双实现）。
    @ViewBuilder
    private func favoriteToggle(for row: MacTrackTableRow) -> some View {
        let isFavorite = menu.favoriteIds.contains(row.track.stableId)
        if isFavorite || hoveredTrackId == row.id {
            MacTrackFavoriteButton(appCoordinator: appCoordinator, track: row.track, isFavorite: isFavorite)
        }
    }

    // MARK: - Playback

    private func play(_ track: Track) {
        onPlay(track, displayedRows.map(\.track))
        onSelect(track)
    }

    /// 让显示行与排序状态同步（Table 内部按 sortOrder 重排，此处镜像供播放队列用）。
    /// 重要：从 onChange 事件调用时必须把「新值」作为参数传入（freshTracks/freshSort）。
    /// onChange 闭包捕获的是变化前的旧 self，直接读 self.tracks/self.sortOrder 会拿到
    /// 旧数据，导致刚删除的行被旧数组重建复活（2026-09-03 现场探针定位的幽灵行根因）。
    private func syncDisplayedRows(
        tracks freshTracks: [Track]? = nil,
        sort freshSort: [SortDescriptor<MacTrackTableRow>]? = nil,
        album filter: MacAlbumFilterKey?
    ) {
        let candidates = freshTracks ?? tracks
        let sourceTracks: [Track]
        if let filter {
            sourceTracks = candidates.filter { albumFilterKey(for: $0) == filter }
        } else {
            sourceTracks = candidates
        }
        let sourceSort = freshSort ?? sortOrder
        let sorted = sourceTracks
            .map {
                MacTrackTableRow(
                    id: $0.stableId,
                    track: $0,
                    artistName: artistNameResolver($0) ?? "",
                    albumName: albumTitle(for: $0)
                )
            }
            .sorted(using: sourceSort)
        displayedRows = sorted
    }

    // MARK: - Data helpers

    private func albumTitle(for track: Track) -> String {
        // 审计 M2：以前每个可见行每帧一次 `Album.fetchOne` → 读缓存（预取已就位）
        // 专辑列是显示文本 → 按 UI 语言归一字形（facts 内部仍是原始值，排序/匹配不受影响）
        DisplayScriptNormalizer.display(facts.albumTitle(forTrack: track))
    }

    // MARK: - 视图模式（列表 / 专辑网格，2026-11-16）

    /// 列表 / 专辑网格 切换（分段控件；图标用 SF Symbols，无障碍标签复用现有 key）
    private var viewModePicker: some View {
        Picker("", selection: $viewMode) {
            Image(systemName: "list.bullet")
                .tag(MacTrackListMode.list)
                .accessibilityLabel(Localized.songs)
            Image(systemName: "square.grid.2x2")
                .tag(MacTrackListMode.albums)
                .accessibilityLabel(Localized.albums)
            Image(systemName: "list.bullet.indent")
                .tag(MacTrackListMode.grouped)
                .accessibilityLabel(Text("\(Localized.album) / \(Localized.artist) / A–Z"))
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    /// 专辑封面网格（albums 模式）：分组走缓存，body 不重算
    private var albumGrid: some View {
        MacTrackAlbumGridView(groups: albumGroups) { group in
            openAlbum(group)
        }
    }

    /// 分组折叠列表（grouped 模式）：归组纯函数 / 折叠状态 / 行交互都在 MacTrackGroupedView.swift
    private var groupedList: some View {
        MacTrackGroupedListView(
            tracks: displayedRows.map(\.track), dimension: groupDimension,
            activeTrackId: activeTrackId, favoriteIds: menu.favoriteIds,
            locateRequestID: locateRequestID, albumTitle: { albumTitle(for: $0) },
            artistName: { artistName(for: $0) },
            onPlay: { track, queue in onPlay(track, queue); onSelect(track) }
        )
    }

    /// 专辑筛选面包屑（专辑名 + 清除）：文案直接用专辑名字符串，不新增本地化 key
    private func albumFilterBar(_ filter: MacAlbumFilterKey) -> some View {
        HStack(spacing: DesignTokens.space8) {
            Image(systemName: "square.grid.2x2")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(filter.albumTitle)
                .font(.callout)
                .lineLimit(1)
            Button {
                albumFilter = nil
                syncDisplayedRows(album: nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Localized.cancel)
            Spacer()
        }
        .padding(.horizontal, DesignTokens.space12)
        .padding(.vertical, DesignTokens.space4)
    }

    /// 点专辑卡：只显示这张专辑的曲目并切回列表（sortOrder 原样保留）
    private func openAlbum(_ group: MacAlbumGroup) {
        albumFilter = group.key
        viewMode = .list
        // 显式传筛选键：不依赖 @State 写入与读取的时序
        syncDisplayedRows(album: group.key)
    }

    /// 行内艺人显示口径（artist 列 / 专辑归组 / 筛选共用）
    private func artistName(for track: Track) -> String {
        artistNameResolver(track) ?? ""
    }

    /// 专辑筛选键：与专辑列同一口径（facts 标题 + 字形归一 + 艺人解析）
    private func albumFilterKey(for track: Track) -> MacAlbumFilterKey {
        MacAlbumFilterKey(albumTitle: albumTitle(for: track), artistName: artistName(for: track))
    }

    /// 重建专辑网格分组缓存（tracks 变化 / 进入网格时重建，body 只读缓存）
    private func rebuildAlbumGroups(for freshTracks: [Track]? = nil) {
        albumGroups = MacAlbumGrouping.groups(
            from: freshTracks ?? tracks,
            albumTitle: { albumTitle(for: $0) },
            artistName: { artistName(for: $0) }
        )
    }

    // MARK: - Context-menu modal 延迟呈现（macOS SwiftUI 已知 bug workaround）

    /// 右键菜单（context menu）自身以 modal 形式呈现，点击菜单项时菜单仍在收起动画
    /// 中；此刻若同步触发 sheet/alert，会与菜单 dismiss 冲突 → 弹窗卡成空白小窗。
    /// 所有从右键菜单触发的弹窗统一延迟到菜单完全收起后再呈现（~0.15s 无感）。
    /// 注：白框根因另有其因（.sheet(isPresented:) 的 item 竞态，2026-09-08 已改
    /// .sheet(item:)）；此延迟仍保留——菜单 tracking 冲突独立存在，两类叠加才致“永久卡”。
    /// 实现收口在 MacTrackContextMenu.swift（与搜索面同一份），此处只保留调用名。
    private func presentAfterMenuDismisses(_ action: @escaping () -> Void) {
        presentAfterTrackMenuDismisses(action)
    }
}
