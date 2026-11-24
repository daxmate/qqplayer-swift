//  MacPlayerView.swift
//  QQPlayer
//
//  macOS player detail page: artwork, track info, playback controls, a
//  draggable progress bar, and a lyrics panel with karaoke controls.
//  QQPlayerMac target only.
//

import AppKit
import SwiftUI

struct MacPlayerView: View {
    /// 分片：跨文件可见（原 private）
    @Environment(AppCoordinator.self) var appCoordinator
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）
    /// 分片：跨文件可见（原 private）
    @Environment(\.appAccentColor) var appAccentColor
    @Environment(AppServices.self) private var services
    let track: Track?
    let artistName: String?
    let isPlaying: Bool
    let duration: TimeInterval
    let playbackTime: TimeInterval
    let onPlayPause: () -> Void
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onSeek: (TimeInterval) -> Void

    /// 分片：跨文件可见（原 private）
    @State var artwork: ArtworkImage?
    @State private var artworkTrackId: String?
    /// 分片：跨文件可见（原 private）
    @State var dragTime: TimeInterval?
    /// 分片：跨文件可见（原 private）
    @State var isDragging = false
    @State private var lyrics: Lyrics?
    @State private var lyricsLoading = false
    /// 分片：跨文件可见（原 private）
    @State var favoriteIds: Set<String> = []
    /// 分片：跨文件可见（原 private）
    @State var sleepTimerEndDate: Date?
    /// 分片：跨文件可见（原 private）
    @State var sleepTimerTask: Task<Void, Never>?
    /// 分片：跨文件可见（原 private）
    @Environment(KaraokeController.self) var karaoke
    /// 分片：跨文件可见（原 private）
    @Environment(PlayerEngine.self) var player

    /// 播放控制按钮可见性（设置页开关，对齐 iOS 默认：睡眠定时器隐藏）
    /// 分片：跨文件可见（原 private）
    @State var showSleepTimerButton: Bool = DeleteSettings.load().showSleepTimerButton
    /// 播放页频谱（D4，web Visualizer 对齐；设置「播放」分类开关，默认开）
    /// 分片：跨文件可见（原 private）
    @State var visualizerEnabled: Bool = DeleteSettings.load().visualizerEnabled
    /// 分片：跨文件可见（原 private）
    @Environment(MacSpectrumAnalyzer.self) var spectrumAnalyzer
    /// 歌词搜索 sheet（手动指定歌词）；由 item 非空驱动，避免 isPresented + 内容判空的空 sheet 竞态
    @State private var lyricsSearchTrack: Track?
    /// 播放队列面板（B 组队列排序持久化：可拖排/删除/点行跳转，重排即持久化）
    /// 分片：跨文件可见（原 private）
    @State var showQueuePanel = false

    /// 歌词大画面（2026-09-06 用户拍板：双击=纯放大，不再绑定跟唱；跟唱经 🎤 按钮）
    @State private var lyricsExpanded = false
    /// 歌词面板高度（普通态 330；可拖分隔条调节，UserDefaults 记忆）
    @State private var lyricsPanelHeight: CGFloat = 330
    /// 分隔条拖动起始高度（拖动中非 nil）
    @State private var dragStartPanelHeight: CGFloat?
    /// 歌词面板高度持久化 key
    private static let lyricsPanelHeightKey = "QQPlayer.lyricsPanelHeight"
    /// 歌词面板布局实测（布局放置子视图时写、居中日志读；见 `LyricsCenterMetrics.PanelGeometry`）
    @State private var panelGeometry = LyricsCenterMetrics.PanelGeometry()
    /// 播放区可用宽度（窄面板降档用；由 `playerSection` 背景几何量一次，2026-11-17）。
    /// 分片：跨文件可见
    @State var playerSectionWidth: CGFloat = 0
    /// 分隔条拖动坐标系：固定在播放页容器上，避免分隔条自身位移污染 translation（拖动抖动）
    private static let lyricsResizeCoordinateSpace = "macPlayerLyricsResize"
    /// 分隔条视觉细条高度（pt）
    private static let lyricsResizeBarHeight: CGFloat = 6
    /// 分隔条可拖命中区高度（pt）：视觉仍 6pt 细条，上下各外扩 6pt 便于抓取（2026-11-17 用户反馈太窄）
    private static let lyricsResizeHitHeight: CGFloat = 18

    /// 当前窗口下面板的**渲染**高度 = min(用户 / 记忆值, 实测可用高度)。
    ///
    /// 拖拽起点用它（2026-11-22）：用户值可能大于当前窗口的可用空间（窗口曾很小 / 记忆值来自大窗口），
    /// 若直接从用户值起拖，面板会在前几十 pt 拖动里毫无反应。用户值本身不被改写。
    private var renderedLyricsPanelHeight: CGFloat {
        let available = panelGeometry.availableHeight
        guard available > 0 else { return lyricsPanelHeight }
        return MacPlaybackGate.effectiveLyricsHeight(
            userHeight: lyricsPanelHeight,
            available: available,
            minHeight: MacPlaybackGate.lyricsPanelMinHeight
        )
    }

    /// 播放区是否隐藏/歌词是否撑满：跟唱或放大（决策上收 MacPlaybackGate，有测试）
    private var isLyricsFullscreen: Bool {
        MacPlaybackGate.shouldExpandLyrics(
            isKaraokeOn: karaoke.isKaraokeOn,
            isLyricsExpanded: lyricsExpanded
        )
    }

    var body: some View {
        GeometryReader { geo in
            // 竖向布局走自定义 Layout（不是 VStack）：面板是固定高度、播放区是弹性高度，
            // VStack 在空间不足时会保住固定高度、让总高溢出容器 → 面板底部被窗口裁掉，
            // 而歌词视图量到的仍是未裁的布局高度 → 居中按「假视口」算，高亮行肉眼偏下。
            MacPlayerVerticalLayout(
                userPanelHeight: lyricsPanelHeight,
                handleHeight: Self.lyricsResizeHitHeight,
                minPanelHeight: MacPlaybackGate.lyricsPanelMinHeight,
                report: panelGeometry
            ) {
                if !MacPlaybackGate.shouldHidePlayerSection(
                    isKaraokeOn: karaoke.isKaraokeOn,
                    isLyricsExpanded: lyricsExpanded
                ) {
                    playerSection
                    lyricsResizeHandle(containerHeight: geo.size.height)
                }
                MacLyricsView(
                    lyrics: lyrics,
                    currentTime: playbackTime,
                    isLoading: lyricsLoading,
                    isFullscreen: isLyricsFullscreen,
                    onToggleExpand: handleLyricsDoubleTap,
                    onLyricsSearch: {
                        // 没有当前曲目就不置状态：避免 present 瞬间读不到 track 弹出空 sheet（白框）
                        guard let track = player.currentTrack else { return }
                        lyricsSearchTrack = track
                    },
                    // 歌词时间轴对齐（macOS 26+；能力不足时整项隐藏）
                    onAlignTimeline: canAlignLyricsTimeline ? { startLyricAlignment() } : nil,
                    onRevertTimeline: hasAlignedLyricsTimeline ? { revertLyricAlignment() } : nil,
                    panelGeometry: panelGeometry
                )
                // 面板实际高度（实测，日志用；布局只上报可用上限）
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: LyricsPanelHeightKey.self, value: proxy.size.height)
                    }
                )
                .onPreferenceChange(LyricsPanelHeightKey.self) { height in
                    panelGeometry.panelHeight = height
                }
                // 保险：面板高度已由布局按实测可用空间算好，万一内容仍要画到窗口外，一律裁掉
                .clipped()
            }
            .coordinateSpace(name: Self.lyricsResizeCoordinateSpace)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            let saved = UserDefaults.standard.double(forKey: Self.lyricsPanelHeightKey)
            lyricsPanelHeight = saved > 0 ? CGFloat(saved) : 330
        }
        // 歌词搜索 sheet 由 item 非空驱动：present 瞬间读 player.currentTrack 可能为 nil ⇒ 空 sheet（白框）。
        // sheet 关闭时 SwiftUI 把 item 置 nil，同一首歌也能再次弹出。
        .sheet(item: $lyricsSearchTrack) { track in
            MacLyricsSearchView(
                track: track,
                onClose: { lyricsSearchTrack = nil },
                onApply: { newLyrics in
                    // 应用搜索结果：更新歌词显示 + 跟唱行注入（nil = 恢复自动）
                    lyrics = newLyrics
                    karaoke.setLyrics(newLyrics?.syncedLyrics ?? [])
                }
            )
        }
        .sheet(isPresented: $showQueuePanel) {
            MacQueuePanelView()
        }
        .overlay(alignment: .top) {
            // 播放失败提示（2026-09-12 审计 P8）：载入失败不再静默（Opus/DSD 以前是
            // "点了完全无反应"）。文案由引擎统一上报，5 秒后自动消失。
            if let message = player.playbackErrorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, DesignTokens.space12)
                    .padding(.vertical, DesignTokens.space8)
                    .background(Capsule().fill(Color.red.opacity(0.9)))
                    .padding(.top, DesignTokens.space10)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: player.playbackErrorMessage)
        .animation(.easeInOut(duration: 0.25), value: isLyricsFullscreen)
        // 歌词时间轴对齐进度 / 结果 sheet（主窗口唯一宿主：曲库右键菜单与歌词栏菜单共用）
        .lyricAlignmentSheet(controller: LyricAlignmentActions.controller)
        .onReceive(NotificationCenter.default.publisher(for: .lyricsDidChange)) { note in
            // 对齐 / 恢复原时间轴后：正在放的这首歌立刻重取（task(id:) 不重载）
            guard let stableId = note.object as? String,
                  stableId == track?.stableId else { return }
            reloadLyrics()
        }
        .onReceive(NotificationCenter.default.publisher(for: .favoritesChanged)) { _ in
            // 收藏在别处变更（列表心形/右键菜单）后同步当前曲目的心形状态
            favoriteIds = Set((try? appCoordinator.getFavorites()) ?? [])
        }
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            // 设置页改了睡眠定时器开关后同步按钮可见性
            let settings = DeleteSettings.load()
            showSleepTimerButton = settings.showSleepTimerButton
            visualizerEnabled = settings.visualizerEnabled
            updateSpectrumTap()
        }
        .task(id: track?.stableId) {
            guard let track else {
                artwork = nil
                artworkTrackId = nil
                lyrics = nil
                favoriteIds = []
                // 跟唱：无曲目时清空歌词注入 + 清 AB（对齐 iOS PlayerView 切歌语义）
                karaoke.setLyrics([])
                karaoke.resetForNewTrack()
                return
            }
            let art = await services.artworkManager.getArtwork(for: track)
            artwork = art
            artworkTrackId = track.stableId
            // 切歌时刷新当前曲目的收藏状态
            favoriteIds = Set((try? appCoordinator.getFavorites()) ?? [])

            // 歌词：优先缓存/本地，在线搜索失败不阻塞 UI（跟 iOS 语义一致）
            lyricsLoading = true
            lyrics = await services.lyricsManager.getLyrics(for: track)
            // 跟唱：歌词行注入（句末自动停/单句循环/AB/上一句下一句依赖；对齐 iOS PlayerView:829）
            karaoke.setLyrics(lyrics?.syncedLyrics ?? [])
            lyricsLoading = false
        }
        // 当前曲目标签被刮削保存（封面 forceRefreshArtwork 重写）后重拉封面（stableId 不变 task(id:) 不重载；2026-09-06 播放页封面不刷新修复）
        .onReceive(NotificationCenter.default.publisher(
            for: .qqplayerArtworkRefreshed
        )) { notification in
            guard let stableId = track?.stableId,
                  (notification.object as? String) == stableId else { return }
            Task {
                if let track {
                    artwork = await services.artworkManager.getArtwork(for: track)
                    artworkTrackId = track.stableId
                }
            }
        }
    }

    // MARK: - 歌词时间轴对齐（macOS 26+）

    /// 菜单入口可见性：能力不足时整项隐藏（不是置灰）。
    private var canAlignLyricsTimeline: Bool {
        guard let track else { return false }
        let audioExists = !track.path.isEmpty
            && FileManager.default.fileExists(atPath: LibraryRoot.absolutePath(forStoredPath: track.path))
        return LyricAlignmentFeature.canOfferAlignment(track: track, fileExists: audioExists)
    }

    private var hasAlignedLyricsTimeline: Bool {
        guard let track else { return false }
        return LyricAlignmentFeature.isAligned(stableId: track.stableId)
    }

    /// 取歌词 → 复核判据 → 交给 controller（进度 / 结果 sheet 挂在本视图）。
    private func startLyricAlignment() {
        guard let track else { return }
        Task { await LyricAlignmentActions.startAlignment(for: track) }
    }

    private func revertLyricAlignment() {
        guard let track else { return }
        LyricAlignmentActions.revertAlignment(for: track)
    }

    /// 重取当前曲目歌词（对齐 / 恢复后由 .lyricsDidChange 触发）。
    private func reloadLyrics() {
        guard let track else { return }
        Task {
            let updated = await services.lyricsManager.getLyrics(for: track)
            lyrics = updated
            karaoke.setLyrics(updated?.syncedLyrics ?? [])
        }
    }

    // MARK: - 歌词大画面交互（2026-09-06 用户拍板：双击=放大；跟唱经 🎤 按钮）

    /// 双击歌词：普通态 → 放大（不进跟唱）；放大/跟唱态 → 退出并缩回。
    /// 跟唱中双击 = 退跟唱 + 缩回（用户：双击和话筒都可退出）。
    private func handleLyricsDoubleTap() {
        if karaoke.isKaraokeOn {
            karaoke.setKaraokeOn(false)
            lyricsExpanded = false
        } else if lyricsExpanded {
            lyricsExpanded = false
        } else {
            lyricsExpanded = true
        }
    }

    /// 播放区与歌词区之间的可拖分隔条（仅普通态显示；跟唱/放大时歌词撑满无分隔）
    ///
    /// 命中区（18pt）大于视觉细条（6pt）：2026-11-17 用户反馈原 6pt 命中区
    /// 「鼠标稍微偏离一点就拖不动」，视觉不变，只是上下各多出 6pt 可抓取范围。
    private func lyricsResizeHandle(containerHeight: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.gray.opacity(0.12))
                .frame(height: Self.lyricsResizeBarHeight)
        }
        .frame(height: Self.lyricsResizeHitHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.lyricsResizeCoordinateSpace))
                .onChanged { value in
                    if dragStartPanelHeight == nil {
                        // 从渲染高度起拖（用户值可能大于当前可用空间，见 renderedLyricsPanelHeight）
                        dragStartPanelHeight = renderedLyricsPanelHeight
                    }
                    // 向上拖 = 歌词变高；clamp 数学上收 MacPlaybackGate（有测试）
                    let start = dragStartPanelHeight ?? renderedLyricsPanelHeight
                    lyricsPanelHeight = MacPlaybackGate.clampedLyricsHeight(
                        start: start,
                        translation: value.translation.height,
                        containerHeight: containerHeight
                    )
                }
                .onEnded { _ in
                    // 保留拖动结束时的当前高度，只做 clamp（不再回弹到起始高度）
                    lyricsPanelHeight = MacPlaybackGate.clampedLyricsHeight(
                        lyricsPanelHeight,
                        containerHeight: containerHeight
                    )
                    UserDefaults.standard.set(Double(lyricsPanelHeight), forKey: Self.lyricsPanelHeightKey)
                    // 松手：只清拖动起点（居中由歌词区按新尺寸重锚，无动画余量）
                    dragStartPanelHeight = nil
                }
        )
    }

    // 注（2026-11-22）：窗口缩放不再改写 `lyricsPanelHeight`（原 normalizeLyricsPanelHeight 已删除）。
    // 面板渲染高度由布局按**实测**可用空间 clamp（`MacPlaybackGate.availableLyricsHeight`），
    // 用户值保持原样 → 窗口再变大时面板能回到用户想要的高度。

    // MARK: - Playback order

    private var playOrderMode: PlaybackOrderMode {
        player.playbackOrderMode
    }

    /// 分片：跨文件可见（原 private）
    var playOrderIcon: String {
        // 图标映射走 PlaybackOrderMode.systemImageName（与 iOS 播放页、CarPlay 页头同一入口）
        playOrderMode.systemImageName
    }

    /// 分片：跨文件可见（原 private）
    var playOrderTitle: String {
        switch playOrderMode {
        case .sequential: return Localized.playOrderSequential
        case .shuffle: return Localized.playOrderShuffle
        case .repeatAll: return Localized.playOrderRepeatAll
        case .repeatOne: return Localized.playOrderRepeatOne
        }
    }

    /// 分片：跨文件可见（原 private）
    var isPlayOrderActive: Bool {
        playOrderMode != .sequential
    }

}

// MARK: - 播放页竖向布局（2026-11-22）

/// 播放页竖向布局：播放区（+ 可拖分隔条）在上，歌词面板在下。
///
/// **为什么不用 `VStack`**：面板是固定高度、播放区是弹性高度。空间不足时 VStack 保住固定高度、
/// 让总高溢出容器 → 面板底部被窗口裁掉；而 `MacLyricsView` 里的 `GeometryReader` 量到的仍是
/// **未裁的布局高度**，`scrollTo(anchor: .center)` 按这个「假视口」居中 → 日志 delta=0，
/// 肉眼却明显偏低（2026-11-22 用户截图 + 运行日志定位的真根因）。
///
/// 这里先用 `sizeThatFits(height: nil)` 量出播放区的**内容固有高度**（弹性 maxHeight 帧在 nil
/// 提案下回落到内容固有高，与「当前被分到多少」无关），再按
/// `面板高 = min(用户/记忆高度, 容器 − 分隔条 − 内容固有高)` 放置；播放区吃掉剩余空间。
/// 决策数学在 `MacPlaybackGate`（有单测），本类型只负责取值与摆放。
private struct MacPlayerVerticalLayout: Layout {
    /// 用户 / 记忆的面板高度（拖拽产物）：只在渲染时被 clamp，不被改写
    var userPanelHeight: CGFloat
    /// 分隔条命中区高度（面板上方内容的一部分）
    var handleHeight: CGFloat
    /// 面板最小高度（容器极矮时保底）
    var minPanelHeight: CGFloat
    /// 布局实测上报（居中日志核对 `panelH ≤ availableH`）
    var report: LyricsCenterMetrics.PanelGeometry

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        guard let first = subviews.first else { return }
        // 单子视图 = 歌词大画面（跟唱 / 双击放大）：播放区不参与，面板占满整个区域
        guard subviews.count > 1 else {
            first.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
            report.availableHeight = bounds.height
            return
        }
        let player = subviews[0]
        let handle = subviews[1]
        let panel = subviews[2]
        // 内容固有高度：height 提 nil 提案 → 弹性的 maxHeight 帧回落到内容固有高，
        // 不受「当前被分到多少」影响（这正是 VStack 分配算不出、又必须拿来 clamp 的那个数）。
        let measured = player.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
        // 兜底：理论上不会出现非有限值；真出现时退回常量，宁可面板矮一点也不溢出
        let playerContentHeight = (measured.isFinite && measured > 0)
            ? measured
            : MacPlaybackGate.playerSectionMinHeight
        let available = MacPlaybackGate.availableLyricsHeight(
            containerHeight: bounds.height,
            playerTopHeight: playerContentHeight + handleHeight,
            minHeight: minPanelHeight
        )
        let panelHeight = MacPlaybackGate.effectiveLyricsHeight(
            userHeight: userPanelHeight,
            available: available,
            minHeight: minPanelHeight
        )
        let playerHeight = Swift.max(0, bounds.height - handleHeight - panelHeight)
        player.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: playerHeight))
        handle.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + playerHeight),
            proposal: ProposedViewSize(width: bounds.width, height: handleHeight)
        )
        panel.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + playerHeight + handleHeight),
            proposal: ProposedViewSize(width: bounds.width, height: panelHeight)
        )
        report.availableHeight = available
    }
}

/// 面板实际高度的实测上报（日志核对 `panelH − header − divider ≈ viewportH`）。
/// 由面板自身背景几何写入；布局只上报可用上限，两者分开写，避免互相覆盖。
private struct LyricsPanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
