//
//  MacSearchAnythingLayer.swift
//  QQPlayer
//
//  search anything（web 版 SearchAnything 对齐，2026-09 C 组②；QQPlayerMac only）。
//  Spotlight 式主窗内全屏浮层：⌘K 唤起（QQPlayerMacApp .commands 切换本层开关），
//  Esc/点空白收起。分组结果：本地歌曲 / 在线（下载）/ 歌手 / 专辑 / 设置——
//  与侧栏 MacSearchView（库内检索含歌单）共存，本层为全局超集（web 语义：歌单不入）。
//  250ms 防抖（web useSearchAnything 对齐）；本地多路 DB 搜索 + 在线网易云异步追尾。
//  用户 2026-09-04 拍板：在线行动作 = 下载落盘入曲库（v1，无试听/网络登记）。
//

import AppKit
import Observation
import SwiftUI

/// ⌘K 开关共享单例（QQPlayerMacApp commands 与 MacLibraryView overlay 共用）
///
/// 2026-09-18 批 1「叶子」：ObservableObject → @Observable（部署目标同日提到 14.0，解锁）。
/// 本类型无跨对象订阅、无显式 objectWillChange 依赖，唯一状态 `isOpen` 只被视图 body 读——
/// 按属性追踪后刷新路径不变。
@MainActor
@Observable
final class MacSearchAnythingState {
    static let shared = MacSearchAnythingState()
    var isOpen = false
    private init() {}
}

/// 主窗内 Spotlight 式全屏搜索浮层
struct MacSearchAnythingLayer: View {
    let onPlayLocal: (Track, [Track]) -> Void
    let onPlayArtist: (Artist, [Track]) -> Void
    let onPlayAlbum: (Album, [Track]) -> Void
    let onOpenSettings: (MacSettingsCatalog.Match) -> Void
    let artistNameResolver: (Track) -> String?

    // 2026-09-18 批 1：@ObservedObject → 普通 let（@Observable 类型不需要包装器）。
    private let state = MacSearchAnythingState.shared

    @State private var query = ""
    @State private var localSongs: [Track] = []
    @State private var artists: [Artist] = []
    @State private var albums: [Album] = []
    @State private var onlineSongs: [NeteaseOnlineSong] = []
    /// 防抖窗口 + 本地多路检索中（本地同步，通常一帧内结束）
    @State private var isSearchPending = false
    /// 在线（网易云）追尾中——**与本地无关**，不得用来遮本地结果
    @State private var isOnlineSearching = false
    @State private var searchSeq = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var downloadingIDs: Set<Int> = []
    @State private var downloadedIDs: Set<Int> = []
    @State private var failedIDs: Set<Int> = []
    @State private var statusMessage: String?
    /// 在线行下载进度（song.id → 0-1 或 nil=不确定；B2 进度圆环）
    @State private var downloadProgress: [Int: Double?] = [:]
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.0001)
                .ignoresSafeArea()
                .onTapGesture { state.isOpen = false }

            VStack {
                panel
                    .padding(.top, DesignTokens.space64)
                Spacer()
            }
            .padding(.horizontal, DesignTokens.space120)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 打开面板即可直接打字（用户要求）。两层都走公开 API，各管一个时序：
        //  ① `.defaultFocus` —— macOS 原生「默认焦点」，管「窗口刚成为 key」这一刻；
        //  ② `.task` —— 管「视图进窗口 + 首帧布局完成」这一刻。
        // 为什么不在 `onAppear` 里直接设：那一刻输入框还没进窗口响应链，写 @FocusState
        // 会被静默丢弃（实测「面板打开后打字进不去」的根因就是这个时序，不是绑定写错）。
        .defaultFocus($focused, true)
        .task {
            // 诊断（仅 Debug，落 ~/Library/Logs/QQPlayerMac/stdout.log）：面板出现这一刻的
            // 第一响应者 = 焦点问题的根因证据（真机取证用，验完可删）
            #if DEBUG
                print("[SearchAnything] 面板出现 firstResponder=\(Self.describeFirstResponder())")
            #endif
            // 浮层有 0.12s 转场，等一次布局再设（单次 DispatchQueue.main.async 仍在转场中间，不可靠）
            try? await Task.sleep(nanoseconds: 80_000_000)
            focused = true
            // 校验 + AppKit 兜底。决策仍在 `@FocusState`（谁该有焦点）；这里只在它没落地时
            // 把 first responder 交过去（执行层），避免「静默无焦点 → 打开面板打不了字」。
            for attempt in 1 ... 3 {
                try? await Task.sleep(nanoseconds: 60_000_000)
                if Self.isTextInputFocused {
                    #if DEBUG
                        print("[SearchAnything] 设焦点后 firstResponder=\(Self.describeFirstResponder())（第 \(attempt) 次校验）")
                    #endif
                    return
                }
                let fixed = Self.makeSearchFieldFirstResponder()
                #if DEBUG
                    print("[SearchAnything] SwiftUI 焦点未落地 → AppKit 兜底 attempt=\(attempt) ok=\(fixed) firstResponder=\(Self.describeFirstResponder())")
                #endif
                if fixed { return }
            }
        }
        // Esc 的唯一处理点（AppKit 本地监听；为什么不挂在 panel 上见 SearchAnythingEscapeMonitor）
        .modifier(SearchAnythingEscapeMonitor { state.isOpen = false })
    }

    // MARK: - 面板

    private var panel: some View {
        VStack(spacing: DesignTokens.space0) {
            searchRow
            Divider()
            resultsView
        }
        .frame(width: 600)
        .frame(maxHeight: 560)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DesignTokens.radius12))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.radius12).strokeBorder(Color.gray.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 24, y: 8)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius12))
        // ⚠️ Esc 不在这里处理：`.onExitCommand` 依赖键盘事件沿响应链走到浮层，而浮层弹出后
        // 第一响应者是输入框的 field editor（NSTextView），Esc 先被它按「取消编辑」吃掉，
        // `cancelOperation:` 到不了浮层 → 实测「Esc 基本收不起来」。唯一入口 = 下面的
        // `SearchAnythingEscapeMonitor`（与焦点无关，见其注释）。
    }

    private var searchRow: some View {
        HStack(spacing: DesignTokens.space8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField(Self.searchPlaceholder, text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($focused)
                .onSubmit {
                    if let first = localSongs.first {
                        onPlayLocal(first, localSongs)
                        state.isOpen = false
                    }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            Text("⌘K")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, DesignTokens.space16)
        .padding(.vertical, DesignTokens.space12)
        .onChange(of: query) { _, _ in
            scheduleSearch()
        }
    }

    // MARK: - 结果

    @ViewBuilder
    private var resultsView: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            emptyHint
        } else if isSearchPending, !hasAnyResult {
            // 本地还没出、且当前没有任何可显示内容 → 这一刻才允许整块 loading
            // （旧实现拿「在线还在跑」当这个条件，于是本地结果被网络等待整块遮住 =
            //  用户实测「搜设置项特别费时，应该秒出」的根因）
            VStack(spacing: DesignTokens.space10) {
                ProgressView()
                Text("search_any_loading".localized)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if hasNoResults {
            VStack(spacing: DesignTokens.space8) {
                Image(systemName: "magnifyingglass.circle")
                    .font(.system(size: DesignTokens.font40))
                    .foregroundColor(.secondary)
                Text("search_any_no_results".localized)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.space0) {
                    if !localSongs.isEmpty {
                        section("search_badge_song".localized) {
                            ForEach(localSongs, id: \.stableId) { track in
                                songRow(track)
                            }
                        }
                    }
                    if !onlineSongs.isEmpty {
                        section("search_badge_online".localized) {
                            ForEach(onlineSongs) { song in
                                onlineRow(song)
                            }
                        }
                    } else if isOnlineSearching {
                        // 在线还在跑：只在**在线分组内**做行内提示，绝不整块遮罩
                        // （本地结果此刻已经渲染出来了）
                        section("search_badge_online".localized) {
                            onlineSearchingRow
                        }
                    }
                    if !artists.isEmpty {
                        section("search_badge_artist".localized) {
                            ForEach(artists, id: \.id) { artist in
                                artistRow(artist)
                            }
                        }
                    }
                    if !albums.isEmpty {
                        section("search_badge_album".localized) {
                            ForEach(albums, id: \.id) { album in
                                albumRow(album)
                            }
                        }
                    }
                    settingsSection
                }
                .padding(.vertical, DesignTokens.space6)
            }
            .overlay(alignment: .bottom) {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.vertical, DesignTokens.space4)
                        .padding(.horizontal, DesignTokens.space10)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, DesignTokens.space6)
                }
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.space0) {
            Text(title.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.horizontal, DesignTokens.space12)
                .padding(.top, DesignTokens.space8)
                .padding(.bottom, DesignTokens.space2)
            content()
        }
    }

    // MARK: - 行

    private func songRow(_ track: Track) -> some View {
        Button {
            onPlayLocal(track, localSongs)
            state.isOpen = false
        } label: {
            HStack(spacing: DesignTokens.space10) {
                Image(systemName: "music.note")
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                Text(track.displayTitle).lineLimit(1)
                if let artist = artistNameResolver(track) {
                    Text(artist)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, DesignTokens.space12)
            .padding(.vertical, DesignTokens.space4)
        }
        .buttonStyle(.plain)
    }

    private func artistRow(_ artist: Artist) -> some View {
        Button {
            let tracks = (try? LibraryReads.tracks(artistId: artist.id ?? 0)) ?? []
            guard !tracks.isEmpty else { return }
            onPlayArtist(artist, tracks)
            state.isOpen = false
        } label: {
            HStack(spacing: DesignTokens.space10) {
                Image(systemName: "music.mic")
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                Text(ArtistNameNormalizer.displayName(artist.name)).lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, DesignTokens.space12)
            .padding(.vertical, DesignTokens.space4)
        }
        .buttonStyle(.plain)
    }

    private func albumRow(_ album: Album) -> some View {
        Button {
            let tracks = (try? LibraryReads.tracks(albumId: album.id ?? 0)) ?? []
            guard !tracks.isEmpty else { return }
            onPlayAlbum(album, tracks)
            state.isOpen = false
        } label: {
            HStack(spacing: DesignTokens.space10) {
                Image(systemName: "square.stack")
                    .foregroundColor(.secondary)
                    .frame(width: 14)
                Text(album.displayTitle).lineLimit(1)
                if let artist = album.albumArtist, !artist.isEmpty {
                    Text(ArtistNameNormalizer.displayName(artist))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, DesignTokens.space12)
            .padding(.vertical, DesignTokens.space4)
        }
        .buttonStyle(.plain)
    }

    private func onlineRow(_ song: NeteaseOnlineSong) -> some View {
        Button {
            download(song)
        } label: {
            HStack(spacing: DesignTokens.space10) {
                Group {
                    if let coverURL = song.coverURL {
                        AsyncImage(url: coverURL) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                placeholderCover
                            }
                        }
                    } else {
                        placeholderCover
                    }
                }
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius4))

                VStack(alignment: .leading, spacing: DesignTokens.space2) {
                    Text(DisplayScriptNormalizer.display(song.title)).lineLimit(1)
                    Text(DisplayScriptNormalizer.display(onlineSubtitle(song)))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                downloadBadge(for: song)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, DesignTokens.space12)
            .padding(.vertical, DesignTokens.space4)
        }
        .buttonStyle(.plain)
    }

    private func downloadBadge(for song: NeteaseOnlineSong) -> some View {
        Group {
            if downloadedIDs.contains(song.id) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            } else if failedIDs.contains(song.id) {
                Image(systemName: "exclamationmark.circle.fill").foregroundColor(.red)
            } else if downloadingIDs.contains(song.id) {
                // B2：确定进度/不确定转圈（替代系统 ProgressView）
                DownloadProgressRing(progress: downloadProgress[song.id] ?? nil, size: 16)
            } else {
                Image(systemName: "icloud.and.arrow.down").foregroundColor(.secondary)
            }
        }
        .frame(width: 18)
    }

    private var placeholderCover: some View {
        RoundedRectangle(cornerRadius: DesignTokens.radius4)
            .fill(Color.gray.opacity(0.18))
            .overlay {
                Image(systemName: "music.note")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
    }

    /// 设置分组：目录（`MacSettingsCatalog`）按 query 过滤——分类名 + 项标题 + 别名。
    /// 无匹配则整个分组不显示（原实现无条件渲染固定分类列表 = 「⌘K 只是分类快捷入口，
    /// 设置项搜不到」的根因）。
    @ViewBuilder
    private var settingsSection: some View {
        let matches = settingsMatches
        if !matches.isEmpty {
            section("search_badge_setting".localized) {
                ForEach(matches) { match in
                    Button {
                        onOpenSettings(match)
                        state.isOpen = false
                    } label: {
                        HStack(spacing: DesignTokens.space10) {
                            Image(systemName: match.icon)
                                .foregroundColor(.secondary)
                                .frame(width: 14)
                            Text(match.title).lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, DesignTokens.space12)
                        .padding(.vertical, DesignTokens.space4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(spacing: DesignTokens.space8) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.system(size: DesignTokens.font36))
                .foregroundColor(.secondary)
            Text("search_any_empty_hint".localized)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignTokens.space64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 在线检索中的**行内**提示（复用既有 loading 文案，不新增本地化 key）
    private var onlineSearchingRow: some View {
        HStack(spacing: DesignTokens.space10) {
            ProgressView()
                .controlSize(.small)
            Text("search_any_loading".localized)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, DesignTokens.space12)
        .padding(.vertical, DesignTokens.space4)
    }

    /// 设置分组命中（纯函数、随 query 即时得到；空 query → 空）
    private var settingsMatches: [MacSettingsCatalog.Match] {
        MacSettingsCatalog.matches(for: query)
    }

    /// 当前是否有任何可渲染的结果（本地 / 在线 / 设置目录命中）
    private var hasAnyResult: Bool {
        !localSongs.isEmpty || !artists.isEmpty || !albums.isEmpty
            || !onlineSongs.isEmpty || !settingsMatches.isEmpty
    }

    /// 「没有结果」只在线都跑完、且哪儿都空时才成立。
    /// 在线没回来就判定无结果 → 会先闪一下空态、再被在线结果顶掉（用户看到的就是“闪”）。
    private var hasNoResults: Bool {
        !isSearchPending && !isOnlineSearching && !hasAnyResult
    }

    // MARK: - 搜索

    private func scheduleSearch() {
        searchTask?.cancel()
        // 防抖窗口也算「检索中」：否则第一帧会拿旧状态判“无结果”、闪一下空态
        isSearchPending = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await performSearch()
        }
    }

    @MainActor
    private func performSearch() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            searchSeq += 1
            localSongs = []
            artists = []
            albums = []
            onlineSongs = []
            isSearchPending = false
            isOnlineSearching = false
            return
        }
        searchSeq += 1
        let seq = searchSeq
        statusMessage = nil

        // 阶段 1：本地多路（同步、快）——**先出结果**，不等在线
        #if DEBUG
            let localStarted = DispatchTime.now().uptimeNanoseconds
        #endif
        do {
            localSongs = Array(try LibraryReads.searchTracks(query: q, limit: 8))
            artists = try LibraryReads.searchArtists(query: q, limit: 5)
            albums = try LibraryReads.searchAlbums(query: q, limit: 5)
        } catch {
            localSongs = []
            artists = []
            albums = []
        }
        #if DEBUG
            let localMs = Double(DispatchTime.now().uptimeNanoseconds - localStarted) / 1_000_000
            print(String(
                format: "[SearchAnything] 本地检索 %.1fms（tracks=%d artists=%d albums=%d，防抖另计 250ms）",
                localMs, localSongs.count, artists.count, albums.count
            ))
        #endif
        guard seq == searchSeq else { return } // 已被更新的查询取代：本地结果不落
        isSearchPending = false // 本地已就绪 → 立即渲染（不再等在线）

        // 阶段 2：在线（异步追尾，失败静默降级不打断本地结果）
        onlineSongs = []
        isOnlineSearching = true
        do {
            let songs = try await NeteaseOnlineClient.shared.search(query: q, limit: 20)
            guard seq == searchSeq, !Task.isCancelled else { return }
            onlineSongs = songs
        } catch {
            guard seq == searchSeq, !Task.isCancelled else { return }
        }
        if seq == searchSeq {
            isOnlineSearching = false
        }
    }

    private func download(_ song: NeteaseOnlineSong) {
        guard !downloadingIDs.contains(song.id) else { return }
        downloadingIDs.insert(song.id)
        failedIDs.remove(song.id)
        downloadProgress[song.id] = nil // 刚开始（total 未知）→ 不确定态
        statusMessage = nil
        Task {
            do {
                _ = try await MacOnlineDownloadService.download(
                    song: song,
                    progress: { done, total in
                        // 进度回调可能在后台线程 → hop 主线程落 @State（B2）
                        let p: Double? = total > 0 ? Double(done) / Double(total) : nil
                        DispatchQueue.main.async {
                            downloadProgress[song.id] = p
                        }
                    }
                )
                downloadedIDs.insert(song.id)
                failedIDs.remove(song.id)
            } catch {
                failedIDs.insert(song.id)
                downloadedIDs.remove(song.id)
                statusMessage = "online_download_failed_prefix".localized(with: DisplayScriptNormalizer.display(song.title))
            }
            downloadingIDs.remove(song.id)
            downloadProgress.removeValue(forKey: song.id) // 下载结束清进度（B2）
        }
    }

    // MARK: - 小工具

    /// 输入框 placeholder（唯一来源：输入框与 AppKit 兜底定位共用，避免兜底指错别的搜索框）
    private static let searchPlaceholder = "search_any_placeholder".localized

    /// 焦点是否已经在文本输入上（编辑中的 field editor = NSTextView，或文本框本身）
    private static var isTextInputFocused: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if let textView = responder as? NSTextView { return textView.isEditable }
        return responder is NSTextField
    }

    /// AppKit 兜底：把浮层输入框设成第一响应者。
    /// 调用方先校验 `isTextInputFocused`——只有在 SwiftUI 的 `@FocusState` **没落地**时才走到这里，
    /// 所以不会出现两套焦点来源：决策仍在 `@FocusState`，本方法只执行「交权」这一动作。
    @MainActor
    private static func makeSearchFieldFirstResponder() -> Bool {
        guard let window = NSApp.keyWindow,
              let field = editableTextField(in: window.contentView, placeholder: searchPlaceholder)
        else { return false }
        return window.makeFirstResponder(field)
    }

    /// 视图树里定位浮层输入框：可编辑、且 placeholder 等于本面板 placeholder 的 NSTextField
    private static func editableTextField(in view: NSView?, placeholder: String) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable, field.placeholderString == placeholder {
            return field
        }
        for subview in view.subviews {
            if let found = editableTextField(in: subview, placeholder: placeholder) { return found }
        }
        return nil
    }

    /// 诊断用（仅 Debug 打印）：当前 key window 的第一响应者是谁（组字中会标出来）。
    /// 用户报「打开面板打不了字 / Esc 收不起来」时，日志里这一行就是直接证据。
    private static func describeFirstResponder() -> String {
        guard let responder = NSApp.keyWindow?.firstResponder else { return "nil（无 key window）" }
        let marked = (responder as? NSTextView)?.hasMarkedText() ?? false
        return "\(type(of: responder))\(marked ? "（组字中）" : "")"
    }

    private func onlineSubtitle(_ song: NeteaseOnlineSong) -> String {
        var parts: [String] = [song.artist]
        if let album = song.album, !album.isEmpty {
            parts.append(album)
        }
        if let duration = song.durationDisplay {
            parts.append(duration)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

}

// MARK: - Esc（唯一入口）

/// Esc 的**唯一处理点**：浮层可见期间的 AppKit 本地事件监听（keyCode 53）。
///
/// 为什么不用 `.onExitCommand`（本文件原来就挂在 panel 上）：它靠响应链把 `cancelOperation:`
/// 送达浮层。而面板弹出后第一响应者是输入框的 field editor（NSTextView），Esc 先被它按
/// 「取消编辑」语义吃掉，事件根本到不了浮层的 SwiftUI 响应链 → 用户实测「Esc 基本收不起来，
/// 点空白能收」（点空白走鼠标路径，不经键盘响应链）。
/// 为什么不用 `.onKeyPress(.escape)`：同属 SwiftUI 键盘事件路径，前置条件仍是焦点在浮层的
/// 焦点域内；焦点被输入框/输入法持有时事件到不了（同一个坑换了个写法）。
/// 本地监听装在 App 事件分发**之前**、与焦点无关：只要浮层在，Esc 一定先到我们手里。
///
/// 行为（用户 2026-09-18 拍板方案 a）：
///  - 输入法**组字中**（field editor `hasMarkedText()`）：**不拦截**，事件原样放给输入法——
///    第一次 Esc 只取消组字、浮层不关（macOS 习惯）；
///  - 其余情况：关浮层，且**只有真处理了才吞事件**（`nil`），否则原样 `return event`。
///
/// 生命周期：随浮层出现安装、消失立刻移除——否则浮层关了监听还在，会把别的界面的 Esc 一起吞掉。
private struct SearchAnythingEscapeMonitor: ViewModifier {
    /// 关浮层动作（调用方唯一入口：`state.isOpen = false`）
    let onEscape: @MainActor () -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
    }

    /// 安装（幂等：先移除再装，重复出现不会装出第二个）
    private func install() {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 本地监听由主线程分发（AppKit 同一 @MainActor 域）→ 直接同步处理；
            // 不用 `MainActor.assumeIsolated`：NSEvent 非 Sendable，跨域捕获会触发警告
            Self.handle(event, onEscape: onEscape)
        }
    }

    private func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// nil = 已处理（吞掉）；原样返回 = 放行
    @MainActor
    private static func handle(_ event: NSEvent, onEscape: @MainActor () -> Void) -> NSEvent? {
        guard event.keyCode == Self.escapeKeyCode else { return event }
        // 组字中：放给输入法（第一次 Esc 只取消组字，不关浮层）
        let composing = isComposingMarkedText
        #if DEBUG
            print("[SearchAnything] Esc：组字中=\(composing) → \(composing ? "放行给输入法" : "关浮层")")
        #endif
        guard !composing else { return event }
        onEscape()
        return nil
    }

    /// Esc 的 keyCode（AppKit 与输入法都用 53）
    private static let escapeKeyCode: UInt16 = 53

    /// 是否正在输入法组字：编辑中的第一响应者是 field editor（NSTextView），
    /// 有未上屏的标记文本（拼音/假名候选）时 `hasMarkedText()` 为真。
    @MainActor
    private static var isComposingMarkedText: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true
    }
}
