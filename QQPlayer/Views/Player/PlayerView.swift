import AVKit
import SwiftUI

/// 分片：跨文件可见（原 private）
enum ArtworkSwipeDirection: Equatable {
    case previous
    case next

    var offsetSign: CGFloat {
        switch self {
        case .previous: return 1
        case .next: return -1
        }
    }
}

struct PlayerView: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    /// 分片：跨文件可见（原 private）
    @Environment(AppServices.self) var services
    /// 分片：跨文件可见（原 private）
    @Environment(PlayerEngine.self) var playerEngine
    /// 分片：跨文件可见（原 private）
    @Environment(KaraokeController.self) var karaoke
    /// 分片：跨文件可见（原 private）
    @Environment(AppCoordinator.self) var appCoordinator
    /// 分片：跨文件可见（原 private）
    @State var currentArtwork: UIImage?
    /// 分片：跨文件可见（原 private）
    @State var nextArtwork: UIImage?
    /// 分片：跨文件可见（原 private）
    @State var previousArtwork: UIImage?
    /// 分片：跨文件可见（原 private）
    @State var dragOffset: CGFloat = 0
    /// 封面拖动手势的方向锁定（nil = 未定）：首次判定后锁定，防下拉过程中手指微斜导致横/纵分支来回切换（abs(width) vs abs(height) 瞬时翻转）→ 视图抖动
    /// 分片：跨文件可见（原 private）
    @State var gestureAxis: Axis?
    /// 下拉移动的宿主 UIView（fullScreenCover 的 hosting view）：
    /// 纵向跟手直接驱动 UIKit transform，完全绕过 SwiftUI 状态重算/布局（Apple Music 同款底层），
    /// 避免 PlayerView 大视图树在拖动手势中每帧重算导致的掉帧抖动
    /// 分片：跨文件可见（原 private）
    @State var pullHostView: UIView?
    /// 下拉最后应用的位移（死区用）：UIKit 驱动下触摸噪声同样会导致 transform 微变
    /// 分片：跨文件可见（原 private）
    @State var lastPullY: CGFloat = 0
    /// 「更多播放控制」是否展开（2026-09-22 从 CollapsiblePlayerControls 提升到壳）：
    /// 整页手势要读写它（上滑展开 / 下滑先收起），封面手势要据此让位
    @State var isControlsExpanded = false
    /// 整页手势的方向锁定（与封面手势各持一份，互不干扰）
    @State var pageDragAxis: Axis?
    /// 封面区 frame（整页坐标系）：横滑切歌与下拉都归封面手势，整页手势按此排除
    @State var artworkFrame: CGRect = .zero
    /// 控制容器 frame（整页坐标系）：上滑展开 / 下滑收起的参照（旧进度条排除带同源，已于 2026-09-22 改为实测进度条 frame）
    @State var controlsFrame: CGRect = .zero
    /// 进度条实测 frame（整页坐标系，由 `PlayerProgressSection` 回传）：
    /// 整页手势把「起手在进度条上」的横/纵手势让给 seek（复核 ②）
    @State var progressBarFrame: CGRect = .zero
    /// 是否正由「非封面」的下拉跟手驱动宿主 view（onEnded 据此回弹 / 缩回主页）
    @State var isPullingPlayer = false
    /// 分片：跨文件可见（原 private）
    @State var isAnimating = false
    /// 分片：跨文件可见（原 private）
    @State var allTracks: [Track] = []
    /// 分片：跨文件可见（原 private）
    @State var isFavorite = false
    /// 分片：跨文件可见（原 private）
    @State var showPlaylistDialog = false
    @State private var showQueueSheet = false
    /// 分片：跨文件可见（原 private）
    @State var showLyricsSheet = false
    /// 分片：跨文件可见（原 private）
    @State var showLyricsSearch = false
    /// 分片：跨文件可见（原 private）
    @State var currentLyrics: Lyrics?
    /// 分片：跨文件可见（原 private）
    @State var isLoadingLyrics = false
    @State private var settings = DeleteSettings.load()
    /// 标题/歌手按钮的元数据缓存（onChange(currentTrack) 时刷新，替代 body 求值中同步 DB 读）
    /// 分片：跨文件可见（原 private）
    @State var trackAlbum: Album?
    /// 分片：跨文件可见（原 private）
    @State var trackArtist: Artist?
    /// 分片：跨文件可见（原 private）
    @State var trackArtistDisplayName: String?
    /// 分片：跨文件可见（原 private）
    @State var sleepTimerTask: Task<Void, Never>?
    /// 分片：跨文件可见（原 private）
    @State var sleepTimerEndDate: Date?
    /// 首次进入播放页的手势提示气泡
    @State private var showHint = false
    /// AirPlay 路由选择器宿主（常驻层级，见 RoutePickerHost / showAirPlayPicker）
    /// 分片：跨文件可见（原 private）
    @State var routePickerView: AVRoutePickerView?
    /// 分片：跨文件可见（原 private）
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    // 封面下拉关闭播放页：跟手限幅（阈值/快速回甩判定在 PlayerDismissGesture）
    /// 分片：跨文件可见（原 private）
    let pullMaxOffset: CGFloat = 160

    var body: some View {
        ZStack {
            ScreenSpecificBackgroundView(screen: .player)
            // 解析下拉移动的宿主 UIView（fullScreenCover 的 hosting view）：
            // 透明背景层，通过 responder 链向上找 UIViewController.view
            // （Task 延迟赋值：避免在视图更新期间修改 @State）
            HostingViewAccessor { view in
                Task { @MainActor in
                    self.pullHostView = view
                }
            }
            .frame(width: 0, height: 0)
            // AirPlay 路由选择器宿主：常驻层级保证内部按钮随布局加载（见 showAirPlayPicker）。
            // 透明 + 不响应点击，仅作程序化触发的宿主。
            RoutePickerHost { picker in
                Task { @MainActor in
                    self.routePickerView = picker
                }
            }
            .frame(width: 44, height: 44)
            .opacity(0)
            .allowsHitTesting(false)
            mainContent

            // 播放失败提示（2026-09-12 审计 P8）：载入失败不再静默（"点了不播"）。
            // 文案由引擎统一上报（playbackErrorMessage），5 秒后自动消失。
            if let message = playerEngine.playbackErrorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DesignTokens.space12)
                    .padding(.vertical, DesignTokens.space8)
                    .background(Capsule().fill(Color.red.opacity(0.9)))
                    .padding(.horizontal, DesignTokens.space24)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, DesignTokens.space8)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(30)
            }

            // 全屏歌词页：满屏覆盖（右滑入/右滑出），与播放页同一 ZStack，随下拉一起跟手
            if showLyricsSheet {
                LiveLyricsSheet(
                    lyrics: currentLyrics,
                    isLoading: isLoadingLyrics,
                    onClose: {
                        withAnimation(.easeOut(duration: 0.26)) {
                            showLyricsSheet = false
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing),
                    removal: .move(edge: .trailing)
                ))
                .zIndex(10)
            }

            // 歌词搜索页：小歌词窗口右滑从左侧滑入（与歌词页右侧滑入对称）
            if showLyricsSearch, let currentTrack = playerEngine.currentTrack {
                LyricsSearchView(
                    track: currentTrack,
                    onClose: {
                        withAnimation(.easeOut(duration: 0.26)) {
                            showLyricsSearch = false
                        }
                    },
                    onApply: { lyrics in
                        withAnimation(.easeOut(duration: 0.26)) {
                            showLyricsSearch = false
                        }
                        if let lyrics {
                            currentLyrics = lyrics
                        } else {
                            // 恢复自动：重新走自动链路加载
                            loadLyrics()
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .leading),
                    removal: .move(edge: .leading)
                ))
                .zIndex(10)
            }
        }
        // 整页手势与区域 frame 回传共用的坐标空间（见 PlayerView+PageGestures）
        .coordinateSpace(name: PlayerPageCoordinateSpace.name)
        // 封面下拉跟手：播放页整体下移（UIKit transform 驱动，见 artworkDragGesture）
        // 不用 .animation(value:) 修饰符：会泄漏隐式动画到手势跟手更新（iOS 17+
        // 事务变更后 withTransaction(.continuous) 不再可靠禁用），导致下拉抖动；
        // 歌词页/搜索页的过渡动画改在赋值处显式 withAnimation（与歌词页右滑同款实现）
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .animation(.easeInOut(duration: 0.25), value: playerEngine.playbackErrorMessage)
    }

    private var mainContent: some View {
        contentView
            // 刻意例外（B2c-b 保留，非漏做）：这是自适应夹取——左右留白随屏宽变化
            // （5% 屏宽，夹在 16…20pt 之间），不是「哪个档位」的选择，无法表达为刻度令牌。
            .padding(.horizontal, max(16, min(20, UIScreen.main.bounds.width * 0.05)))
            .padding(.vertical)
            // 整页手势（2026-09-22）：整页可滑先要整页可命中（VStack 默认命中区不含间距空隙），
            // 再挂 simultaneousGesture——按钮上的拖动也识别，轻点仍归按钮（同 ios-dev.md §10 的做法）
            .contentShape(Rectangle())
            .simultaneousGesture(pageDragGesture)
            .onChange(of: playerEngine.currentTrack) { _, _ in
                // 切歌统一处理器（合并原三个独立 onChange：复位拖拽 / 查收藏 / 清歌词重载 +
                // 标题/歌手元数据缓存）。执行顺序与原书写顺序一致，避免多个 onChange 依赖书写顺序埋雷。
                if !isAnimating {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        dragOffset = 0
                    }
                    Task {
                        await loadAllArtworks()
                    }
                }
                checkFavoriteStatus()

                // 下拉被中断（来电 / 切后台 / 系统手势）时切歌可能没收到 onEnded：补一次复位（复核 ③）
                resetInterruptedPull()

                // Clear current lyrics
                currentLyrics = nil

                // 跟唱：切歌清空歌词注入 + 清 AB（旧歌行号在新歌上失效；resetForNewTrack 幂等）
                karaoke.setLyrics([])
                karaoke.resetForNewTrack()

                // 小歌词窗口常驻：切歌自动加载歌词（不再等按钮点击）
                loadLyrics()
                loadTrackMetadata()
            }
            .onAppear {
                // 首次进入播放页：触发手势提示气泡（之后永不再现）
                withAnimation(.easeOut(duration: 0.3)) {
                    showHint = HintCoordinator.showIfNeeded(.playbackPage)
                }
                Task {
                    await loadAllArtworks()
                    await loadTracks()
                    checkFavoriteStatus()
                }
                loadLyrics()
                loadTrackMetadata()
            }
            .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
                settings = DeleteSettings.load()
            }
            .sheet(isPresented: $showPlaylistDialog) {
                playlistSheet
            }
            .sheet(isPresented: $showQueueSheet) {
                queueSheet
            }
            .onChange(of: showLyricsSheet) { _, isOpen in
                // 离开全屏歌词界面：退出跟唱模式（用户 2026-08-29 拍板）
                if !isOpen {
                    karaoke.setKaraokeOn(false)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // App 到后台：退出跟唱模式（用户 2026-08-29 拍板）
                if phase == .background {
                    karaoke.setKaraokeOn(false)
                }
                // 回前台兜底复位：下拉被中间打断（来电 / 切后台 / 系统手势）时宿主 transform
                // 会停在偏移位（页面永久拉偏），这里走唯一入口 endPull 补一次收尾（复核 ③）
                if phase == .active {
                    resetInterruptedPull()
                }
            }
    }

    private var contentView: some View {
        VStack(spacing: DesignTokens.space0) {
            if let currentTrack = playerEngine.currentTrack {
                VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 20 : 24) {
                    artworkSection
                    titleAndArtistSection(track: currentTrack)
                }

                // 封面区与控制区之间用弹性 Spacer 撑开：封面贴顶、控制区贴底、歌词居中
                Spacer(minLength: UIScreen.main.scale < UIScreen.main.nativeScale ? 16 : 20)

                // 首次进入播放页的手势提示气泡：显示在小歌词窗上方（布局内插入，
                // 不遮挡任何手势区域；卡片自带过渡动画，隐藏后布局平滑复位）
                VStack(spacing: DesignTokens.space10) {
                    if showHint {
                        HintCardView(
                            title: Localized.hintPlaybackTitle,
                            lines: [
                                Localized.hintPlaybackLine1,
                                Localized.hintPlaybackLine2,
                                Localized.hintPlaybackLine3,
                            ],
                            accentColor: accentColor,
                            onDismiss: {
                                withAnimation(.easeOut(duration: 0.3)) {
                                    showHint = false
                                }
                            }
                        )
                    }
                    lyricMiniSection
                }

                Spacer(minLength: UIScreen.main.scale < UIScreen.main.nativeScale ? 16 : 20)

                CollapsiblePlayerControls(
                    isExpanded: $isControlsExpanded,
                    duration: playerEngine.duration,
                    onSeek: { newTime in
                        Task {
                            await playerEngine.seek(to: newTime)
                        }
                    },
                    showSleepTimerButton: settings.showSleepTimerButton,
                    sleepTimerEndDate: sleepTimerEndDate,
                    onStartSleepTimer: { minutes in
                        startSleepTimer(minutes: minutes)
                    },
                    onCancelSleepTimer: {
                        cancelSleepTimer()
                    },
                    onShowQueue: {
                        showQueueSheet = true
                    },
                    onShowAirPlay: {
                        showAirPlayPicker()
                    },
                    onProgressBarFrameChange: { frame in
                        progressBarFrame = frame
                    }
                )
                // 控制容器 frame → 整页坐标系
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named(PlayerPageCoordinateSpace.name))
                } action: { frame in
                    controlsFrame = frame
                }
            } else {
                Spacer()
                emptyStateView
                Spacer()
            }
        }
    }

    private var playlistSheet: some View {
        Group {
            if let currentTrack = playerEngine.currentTrack {
                PlaylistSelectionView(track: currentTrack)
                    .accentColor(accentColor)
            }
        }
    }

    private var queueSheet: some View {
        QueueManagementView()
            .accentColor(accentColor)
    }
}
