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
//

import AppKit
import SwiftUI

/// Table 行包装：携带排序字段（artist 显示名经 resolver 解析）。
/// macOS 13+/26 SDK 的排序 TableColumn(value:) 与 SortDescriptor 都要求行类型
/// 继承 NSObject 且排序 KeyPath 指向 @objc 存储属性（OC runtime 内省）——
/// 用计算属性/纯 Swift 属性会运行时 fatal："must be introspectable by the
/// objective-c runtime"（2026-09-02 用户实测）。
private final class MacTrackTableRow: NSObject, Identifiable {
    let id: String
    let track: Track
    /// 当前列表显示序号（随排序同步刷新；非 @objc——不参与排序比较）
    var displayIndex: Int = 0
    /// 排序/显示字段：@objc 存储属性（title/artist）
    @objc let title: String
    @objc let artistName: String

    init(id: String, track: Track, artistName: String) {
        self.id = id
        self.track = track
        self.title = track.title
        self.artistName = artistName
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
    @State private var selectedRows = Set<String>()
    /// 批量刮削（右键多选 >1）——.sheet(item:) 直接驱动，见文件头注释
    @State private var batchScrapeRequest: BatchScrapeRequest?
    /// 曲目右键菜单状态：菜单内容 / 弹窗 / 删除执行都在 MacTrackContextMenu.swift
    /// （曲库与两个搜索面共用同一份实现），这里只持有状态
    @State private var menu = MacTrackMenuModel()
    /// Table 原生列头排序（点击表头升/降；显示与播放队列都跟随）。
    /// macOS 26 SDK 的 Table sortOrder 使用 SortDescriptor。
    @State private var sortOrder: [SortDescriptor<MacTrackTableRow>] = []
    /// 当前显示的排序后行（播放队列跟随，与 Table 显示一致）
    @State private var displayedRows: [MacTrackTableRow] = []

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
                Divider()
                table
            }
            // 右键菜单弹窗宿主（新建歌单 / 编辑标签 / 删除确认）——与两个搜索面同一份实现
            .macTrackMenu(menu) { deletedIds in
                // 本地即时移除（不等父级通知链）：当前列表立即消失，序号重排
                // （父级 reloadLibrary 随后全量重拉对齐歌单/专辑等其它视图）
                selectedRows.removeAll()
                guard !deletedIds.isEmpty else { return }
                displayedRows.removeAll { deletedIds.contains($0.id) }
                for (index, row) in displayedRows.enumerated() {
                    row.displayIndex = index + 1
                }
            }
            .onAppear {
                syncDisplayedRows()
            }
            .onChange(of: sortOrder) { _, newSort in
                // 用 onChange 传入的新排序重建，不用旧闭包捕获的 self.sortOrder
                syncDisplayedRows(sort: newSort)
            }
            .onChange(of: tracks) { _, newTracks in
                // 关键修复（2026-09-03 现场探针定位）：onChange 闭包捕获的是变化前的
                // 旧 self，读 self.tracks 会拿到删除前的旧数组 → 用旧数据重建会把刚
                // 删掉的行“复活”，且后续重载不再触发 onChange，幽灵行直到重启才消失。
                // 必须用 onChange 传入的 newTracks（新数据）重建。
                syncDisplayedRows(tracks: newTracks)
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
        }
        .padding(.horizontal, DesignTokens.space12)
        .padding(.vertical, DesignTokens.space4)
    }

    // MARK: - Table

    private var table: some View {
        Table(displayedRows, selection: $selectedRows, sortOrder: $sortOrder) {
            TableColumn("#") { row in
                if row.track.stableId == activeTrackId {
                    Image(systemName: isPlaying ? "speaker.wave.2.fill" : "speaker.fill")
                        .foregroundColor(appAccentColor)
                } else {
                    // 显示列表序号（1 起，随排序同步），不显示专辑 trackNo
                    Text("\(row.displayIndex)")
                        .foregroundColor(.secondary)
                }
            }
            .width(40)

            TableColumn("title".localized, value: \.title) { row in
                Text(row.track.displayTitle)
                    .fontWeight(row.track.stableId == activeTrackId ? .semibold : .regular)
                    .lineLimit(1)
            }

            TableColumn("artist".localized, value: \.artistName) { row in
                Text(row.artistName)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            TableColumn("album".localized) { row in
                Text(albumTitle(for: row.track))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            // 2026-09-06 用户拍板：不显示时长列（播放区进度条已有时长信息，
            // 列表行去掉更简洁）——同时移除 durationMs 排序字段/辅助方法
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
        // 定位当前播放：先选中（下表 onChange 设 selection），再滚到可视区垂直居中
        // （Table 无公开 scrollTo ⇒ AppKit 桥接；滚动唯一入口 MacTableScroll）
        .background(MacTableLocateScroller(request: locateRequestID, row: locateRow).allowsHitTesting(false))
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

    private func locateActiveTrack() {
        locateRequestID += 1
    }

    // MARK: - Playback

    private func play(_ track: Track) {
        onPlay(track, displayedRows.map(\.track))
        onSelect(track)
    }

    /// 让显示行与排序状态同步（Table 内部按 sortOrder 重排，此处镜像供播放队列用）
    /// 同时按显示顺序赋 displayIndex（# 列序号随排序刷新）。
    /// 重要：从 onChange 事件调用时必须把「新值」作为参数传入（freshTracks/freshSort）。
    /// onChange 闭包捕获的是变化前的旧 self，直接读 self.tracks/self.sortOrder 会拿到
    /// 旧数据，导致刚删除的行被旧数组重建复活（2026-09-03 现场探针定位的幽灵行根因）。
    private func syncDisplayedRows(
        tracks freshTracks: [Track]? = nil,
        sort freshSort: [SortDescriptor<MacTrackTableRow>]? = nil
    ) {
        let sourceTracks = freshTracks ?? tracks
        let sourceSort = freshSort ?? sortOrder
        let sorted = sourceTracks
            .map { MacTrackTableRow(id: $0.stableId, track: $0, artistName: artistNameResolver($0) ?? "") }
            .sorted(using: sourceSort)
        for (index, row) in sorted.enumerated() {
            row.displayIndex = index + 1
        }
        displayedRows = sorted
    }

    // MARK: - Data helpers

    private func albumTitle(for track: Track) -> String {
        // 审计 M2：以前每个可见行每帧一次 `Album.fetchOne` → 读缓存（预取已就位）
        // 专辑列是显示文本 → 按 UI 语言归一字形（facts 内部仍是原始值，排序/匹配不受影响）
        DisplayScriptNormalizer.display(facts.albumTitle(forTrack: track))
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
