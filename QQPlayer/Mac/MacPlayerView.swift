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
    /// 歌词搜索 sheet（手动指定歌词）
    @State private var showLyricsSearch = false
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
    /// 分隔条拖动坐标系：固定在播放页容器上，避免分隔条自身位移污染 translation（拖动抖动）
    private static let lyricsResizeCoordinateSpace = "macPlayerLyricsResize"
    /// 分隔条视觉细条高度（pt）
    private static let lyricsResizeBarHeight: CGFloat = 6
    /// 分隔条可拖命中区高度（pt）：视觉仍 6pt 细条，上下各外扩 6pt 便于抓取（2026-11-17 用户反馈太窄）
    private static let lyricsResizeHitHeight: CGFloat = 18

    /// 播放区是否隐藏/歌词是否撑满：跟唱或放大（决策上收 MacPlaybackGate，有测试）
    private var isLyricsFullscreen: Bool {
        MacPlaybackGate.shouldExpandLyrics(
            isKaraokeOn: karaoke.isKaraokeOn,
            isLyricsExpanded: lyricsExpanded
        )
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: DesignTokens.space0) {
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
                        showLyricsSearch = true
                    },
                    // 歌词时间轴对齐（macOS 26+；能力不足时整项隐藏）
                    onAlignTimeline: canAlignLyricsTimeline ? { startLyricAlignment() } : nil,
                    onRevertTimeline: hasAlignedLyricsTimeline ? { revertLyricAlignment() } : nil
                )
                .frame(height: isLyricsFullscreen ? geo.size.height : lyricsPanelHeight)
            }
            .coordinateSpace(name: Self.lyricsResizeCoordinateSpace)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            let saved = UserDefaults.standard.double(forKey: Self.lyricsPanelHeightKey)
            lyricsPanelHeight = saved > 0 ? CGFloat(saved) : 330
        }
        .sheet(isPresented: $showLyricsSearch) {
            if let track = player.currentTrack {
                MacLyricsSearchView(
                    track: track,
                    onClose: { showLyricsSearch = false },
                    onApply: { newLyrics in
                        // 应用搜索结果：更新歌词显示 + 跟唱行注入（nil = 恢复自动）
                        lyrics = newLyrics
                        karaoke.setLyrics(newLyrics?.syncedLyrics ?? [])
                    }
                )
            }
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
        return LyricAlignmentFeature.canOfferAlignment(
            track: track,
            fileExists: FileManager.default.fileExists(atPath: track.path)
        )
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
                        dragStartPanelHeight = lyricsPanelHeight
                    }
                    // 向上拖 = 歌词变高；clamp 数学上收 MacPlaybackGate（有测试）
                    let start = dragStartPanelHeight ?? lyricsPanelHeight
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
                    dragStartPanelHeight = nil
                    UserDefaults.standard.set(Double(lyricsPanelHeight), forKey: Self.lyricsPanelHeightKey)
                }
        )
    }

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
