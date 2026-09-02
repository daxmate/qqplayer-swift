import AVKit
import GRDB
import SwiftUI

private enum ArtworkSwipeDirection: Equatable {
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
    @StateObject private var playerEngine = PlayerEngine.shared
    @StateObject private var artworkManager = ArtworkManager.shared
    @StateObject private var cloudDownloadManager = CloudDownloadManager.shared
    @EnvironmentObject private var appCoordinator: AppCoordinator
    @State private var currentArtwork: UIImage?
    @State private var nextArtwork: UIImage?
    @State private var previousArtwork: UIImage?
    @State private var dragOffset: CGFloat = 0
    /// 封面拖动手势的方向锁定（nil = 未定）：首次判定后锁定，防下拉过程中手指微斜
    /// 导致横/纵分支来回切换（abs(width) vs abs(height) 瞬时翻转）→ 视图抖动
    @State private var gestureAxis: Axis?
    /// 下拉移动的宿主 UIView（fullScreenCover 的 hosting view）：
    /// 纵向跟手直接驱动 UIKit transform，完全绕过 SwiftUI 状态重算/布局（Apple Music 同款底层），
    /// 避免 PlayerView 大视图树在拖动手势中每帧重算导致的掉帧抖动
    @State private var pullHostView: UIView?
    /// 下拉最后应用的位移（死区用）：UIKit 驱动下触摸噪声同样会导致 transform 微变
    @State private var lastPullY: CGFloat = 0
    @State private var isAnimating = false
    @State private var allTracks: [Track] = []
    @State private var isFavorite = false
    @State private var showPlaylistDialog = false
    @State private var showQueueSheet = false
    @State private var showLyricsSheet = false
    @State private var showLyricsSearch = false
    @State private var currentLyrics: Lyrics?
    @State private var isLoadingLyrics = false
    @State private var settings = DeleteSettings.load()
    /// 标题/歌手按钮的元数据缓存（onChange(currentTrack) 时刷新，替代 body 求值中同步 DB 读）
    @State private var trackAlbum: Album?
    @State private var trackArtist: Artist?
    @State private var trackArtistDisplayName: String?
    @State private var sleepTimerTask: Task<Void, Never>?
    @State private var sleepTimerEndDate: Date?
    /// 首次进入播放页的手势提示气泡
    @State private var showHint = false
    /// AirPlay 路由选择器宿主（常驻层级，见 RoutePickerHost / showAirPlayPicker）
    @State private var routePickerView: AVRoutePickerView?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

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
                    accentColor: settings.backgroundColorChoice.color,
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
        // 封面下拉跟手：播放页整体下移（UIKit transform 驱动，见 artworkDragGesture）
        // 不用 .animation(value:) 修饰符：会泄漏隐式动画到手势跟手更新（iOS 17+
        // 事务变更后 withTransaction(.continuous) 不再可靠禁用），导致下拉抖动；
        // 歌词页/搜索页的过渡动画改在赋值处显式 withAnimation（与歌词页右滑同款实现）
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var mainContent: some View {
        contentView
            .padding(.horizontal, max(16, min(20, UIScreen.main.bounds.width * 0.05)))
            .padding(.vertical)
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

                // Clear current lyrics
                currentLyrics = nil

                // 跟唱：切歌清空歌词注入 + 清 AB（旧歌行号在新歌上失效；resetForNewTrack 幂等，
                // PlayerEngine 侧若已接入同款调用，重复执行无副作用）
                KaraokeController.shared.setLyrics([])
                KaraokeController.shared.resetForNewTrack()

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
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("BackgroundColorChanged"))) { _ in
                settings = DeleteSettings.load()
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
                    KaraokeController.shared.setKaraokeOn(false)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                // App 到后台：退出跟唱模式（用户 2026-08-29 拍板）
                if phase == .background {
                    KaraokeController.shared.setKaraokeOn(false)
                }
            }
    }

    private var contentView: some View {
        VStack(spacing: 0) {
            if let currentTrack = playerEngine.currentTrack {
                VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 20 : 25) {
                    artworkSection
                    titleAndArtistSection(track: currentTrack)
                }

                // 封面区与控制区之间用弹性 Spacer 撑开：封面贴顶、控制区贴底、歌词居中
                Spacer(minLength: UIScreen.main.scale < UIScreen.main.nativeScale ? 16 : 20)

                // 首次进入播放页的手势提示气泡：显示在小歌词窗上方（布局内插入，
                // 不遮挡任何手势区域；卡片自带过渡动画，隐藏后布局平滑复位）
                VStack(spacing: 10) {
                    if showHint {
                        HintCardView(
                            title: Localized.hintPlaybackTitle,
                            lines: [
                                Localized.hintPlaybackLine1,
                                Localized.hintPlaybackLine2,
                                Localized.hintPlaybackLine3,
                            ],
                            accentColor: settings.backgroundColorChoice.color,
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
                    duration: playerEngine.duration,
                    accentColor: settings.backgroundColorChoice.color,
                    onSeek: { newTime in
                        Task {
                            await playerEngine.seek(to: newTime)
                        }
                    },
                    showSleepTimerButton: settings.showSleepTimerButton,
                    isLoadingLyrics: isLoadingLyrics,
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
                    onShowLyrics: {
                        withAnimation(.easeOut(duration: 0.26)) {
                            showLyricsSheet = true
                        }
                        if currentLyrics == nil && !isLoadingLyrics {
                            loadLyrics()
                        }
                    },
                    onShowAirPlay: {
                        showAirPlayPicker()
                    }
                )
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
                    .accentColor(settings.backgroundColorChoice.color)
            }
        }
    }

    private var queueSheet: some View {
        QueueManagementView()
            .accentColor(settings.backgroundColorChoice.color)
    }

    // MARK: - Artwork Section

    private var artworkSection: some View {
        GeometryReader { geometry in
            let maxWidth = min(geometry.size.width - 40, 360)
            let artworkSize = min(maxWidth, geometry.size.height)
            let gestureWidth = max(geometry.size.width, 1)
            // 相邻封面初始位置推到屏幕外（静止时完全不露出边缘），跟手滑动时从屏幕边缘滑入
            let pageDistance = geometry.size.width / 2 + artworkSize / 2 + 12
            let swipeProgress = min(abs(dragOffset) / pageDistance, 1)
            let signedProgress = max(-1, min(1, dragOffset / pageDistance))
            let canNavigate = playerEngine.playbackQueue.count > 1

            ZStack {
                if canNavigate {
                    adjacentArtworkView(artwork: previousArtwork, size: artworkSize)
                        .offset(x: dragOffset - pageDistance)
                        .scaleEffect(0.96 + (0.04 * max(0, signedProgress)))
                        .opacity(Double(0.72 + (0.28 * max(0, signedProgress))))
                        // EXPERIMENT: shadow disabled
                        // .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 5)
                        .zIndex(0)
                }

                currentArtworkView(size: artworkSize)
                    .offset(x: dragOffset)
                    .scaleEffect(1 - (0.025 * swipeProgress))
                    // EXPERIMENT: shadow disabled
                    // .shadow(
                    //     color: .black.opacity(0.2 - (0.06 * Double(swipeProgress))),
                    //     radius: 10 - (2 * swipeProgress),
                    //     x: 0,
                    //     y: 6 - (2 * swipeProgress)
                    // )
                    .zIndex(1)
                    .onTapGesture {
                        NotificationCenter.default.post(name: NSNotification.Name("MinimizePlayer"), object: nil)
                    }

                if canNavigate {
                    adjacentArtworkView(artwork: nextArtwork, size: artworkSize)
                        .offset(x: dragOffset + pageDistance)
                        .scaleEffect(0.96 + (0.04 * max(0, -signedProgress)))
                        .opacity(Double(0.72 + (0.28 * max(0, -signedProgress))))
                        // EXPERIMENT: shadow disabled
                        // .shadow(color: .black.opacity(0.16), radius: 8, x: 0, y: 5)
                        .zIndex(0)
                }
            }
            .frame(width: geometry.size.width, height: artworkSize)
            .contentShape(Rectangle())
            .gesture(
                artworkDragGesture(
                    gestureWidth: gestureWidth,
                    pageDistance: pageDistance
                )
            )
        }
        .frame(height: min(360, UIScreen.main.bounds.width - 80))
        .clipped()
    }

    private func currentArtworkView(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.1))
                .frame(width: size, height: size)

            if let artwork = currentArtwork {
                Image(uiImage: artwork)
                    .resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: min(80, size * 0.2)))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func adjacentArtworkView(artwork: UIImage?, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.gray.opacity(0.1))
                .frame(width: size, height: size)

            if let artwork = artwork {
                Image(uiImage: artwork)
                    .resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: min(80, size * 0.2)))
                    .foregroundColor(.secondary)
            }
        }
    }

    // 封面下拉关闭播放页：跟手限幅（阈值/快速回甩判定在 PlayerDismissGesture）
    private let pullMaxOffset: CGFloat = 160

    private func artworkDragGesture(gestureWidth: CGFloat, pageDistance: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard !isAnimating else { return }

                // 方向锁定：首个回调判定后不再改变，避免下拉/横滑过程中手指微斜导致抖动
                if gestureAxis == nil {
                    gestureAxis = abs(value.translation.width) > abs(value.translation.height)
                        ? .horizontal
                        : .vertical
                }

                if gestureAxis == .horizontal {
                    // 横向：切歌跟手（直接赋值，无隐式动画——与歌词页右滑 dragX 同款）
                    let canNavigate = playerEngine.playbackQueue.count > 1
                    let proposedOffset = canNavigate
                        ? value.translation.width
                        : value.translation.width * 0.16
                    let limit = pageDistance
                    dragOffset = max(-limit, min(limit, proposedOffset))
                } else if value.translation.height > 0 {
                    // 纵向下拉：直接驱动宿主 UIView 的 transform（UIKit 层，GPU 渲染，
                    // 不触发 SwiftUI 状态重算/布局——避免大视图树每帧重算掉帧抖动）。
                    // 死区过滤触摸噪声（±1-2pt）：差值小于死区不更新。
                    let target = min(value.translation.height, pullMaxOffset)
                    guard abs(target - lastPullY) >= 1 else { return }
                    lastPullY = target
                    pullHostView?.transform = CGAffineTransform(translationX: 0, y: target)
                }
            }
            .onEnded { value in
                guard !isAnimating else {
                    gestureAxis = nil
                    return
                }

                let isHorizontal = gestureAxis == .horizontal
                gestureAxis = nil // 手势结束，释放方向锁定

                if isHorizontal {
                    guard playerEngine.playbackQueue.count > 1 else {
                        resetArtworkDrag()
                        return
                    }

                    let translation = value.translation.width
                    let projectedTranslation = value.predictedEndTranslation.width
                    let distanceThreshold = gestureWidth * 0.22
                    let projectionThreshold = gestureWidth * 0.34
                    let shouldCommit = abs(translation) > distanceThreshold ||
                        abs(projectedTranslation) > projectionThreshold

                    guard shouldCommit else {
                        resetArtworkDrag()
                        return
                    }

                    let directionValue = abs(projectedTranslation) > abs(translation)
                        ? projectedTranslation
                        : translation

                    if directionValue > 0 {
                        completeArtworkSwipe(.previous, pageDistance: pageDistance)
                    } else {
                        completeArtworkSwipe(.next, pageDistance: pageDistance)
                    }
                } else {
                    // 纵向结束（无论最终位移方向）：达阈值/快速回甩 → 下滑滑出后关闭；否则回弹。
                    // 全部用 UIKit 动画驱动宿主 view（与跟手同一通道，动画衔接顺滑）
                    let shouldDismiss = PlayerDismissGesture.shouldDismissPlayer(
                        pullOffset: value.translation.height,
                        predictedHeight: value.predictedEndTranslation.height
                    )
                    guard let hostView = pullHostView else { return }
                    if shouldDismiss {
                        // 跟手滑出屏幕后关闭（Apple Music 风格）。
                        // completion 不复位 transform：视图即将被 dismiss 销毁，
                        // 复位会在关闭前闪回原位（造成"动画出现两次"）
                        UIView.animate(
                            withDuration: 0.24,
                            delay: 0,
                            options: [.curveEaseIn],
                            animations: {
                                hostView.transform = CGAffineTransform(
                                    translationX: 0,
                                    y: UIScreen.main.bounds.height
                                )
                            },
                            completion: { _ in
                                NotificationCenter.default.post(
                                    name: NSNotification.Name("MinimizePlayer"),
                                    object: nil
                                )
                            }
                        )
                    } else {
                        UIView.animate(
                            withDuration: 0.35,
                            delay: 0,
                            usingSpringWithDamping: 0.82,
                            initialSpringVelocity: 0.4,
                            options: [.curveEaseOut]
                        ) {
                            hostView.transform = .identity
                        }
                    }
                    lastPullY = 0
                }
            }
    }

    private func resetArtworkDrag() {
        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(response: 0.36, dampingFraction: 0.82)
        withAnimation(animation) {
            dragOffset = 0
        }
    }

    private func completeArtworkSwipe(_ direction: ArtworkSwipeDirection, pageDistance: CGFloat) {
        // "Previous" restarts the current track after three seconds. Keep the
        // artwork honest in that case instead of briefly showing another song.
        if direction == .previous && playerEngine.playbackTime > 3 {
            resetArtworkDrag()
            Task {
                await playerEngine.previousTrack()
            }
            return
        }

        isAnimating = true
        let oldTrackId = playerEngine.currentTrack?.stableId
        let outgoingArtwork = currentArtwork
        let incomingArtwork = direction == .next ? nextArtwork : previousArtwork
        // Exactly one page: the adjacent card lands at x == 0. Any overrun
        // here causes a visible jump when the buffers are normalized.
        let targetOffset = direction.offsetSign * pageDistance

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        let commitAnimation: Animation = reduceMotion
            ? .easeOut(duration: 0.14)
            : .timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)
        withAnimation(commitAnimation) {
            dragOffset = targetOffset
        }

        Task { @MainActor in
            let animationDelay: UInt64 = reduceMotion ? 140_000_000 : 240_000_000
            try? await Task.sleep(nanoseconds: animationDelay)

            switch direction {
            case .previous:
                await playerEngine.previousTrack()
            case .next:
                await playerEngine.nextTrack()
            }

            guard playerEngine.currentTrack?.stableId != oldTrackId else {
                isAnimating = false
                resetArtworkDrag()
                return
            }

            // The incoming card is already centered. Replace the artwork
            // buffers and reset coordinates without animation, so there is no
            // jump or flash while the engine finishes changing tracks.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                currentArtwork = incomingArtwork
                switch direction {
                case .previous:
                    nextArtwork = outgoingArtwork
                case .next:
                    previousArtwork = outgoingArtwork
                }
                dragOffset = 0
            }

            if currentArtwork == nil {
                await loadCurrentArtwork()
            }

            isAnimating = false
            await loadNextArtwork()
            await loadPreviousArtwork()
        }
    }

    // MARK: - Title and Artist Section

    private func titleAndArtistSection(track: Track) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                titleButton(track: track)
                artistButton(track: track)
            }

            Spacer()

            HStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 16 : 20) {
                likeButton
                addToPlaylistButton
            }
        }
        .padding(.horizontal, 8)
    }

    private func titleButton(track: Track) -> some View {
        Group {
            if let album = trackAlbum {
                Button(action: {
                    let userInfo = ["album": album, "allTracks": allTracks] as [String: Any]
                    NotificationCenter.default.post(name: NSNotification.Name("NavigateToAlbumFromPlayer"), object: nil, userInfo: userInfo)
                }) {
                    Text(track.title)
                        .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.leading)
                        .foregroundColor(.primary)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Text(track.title)
                    .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private func artistButton(track: Track) -> some View {
        Group {
            if let artist = trackArtist {
                Button(action: {
                    let userInfo = ["artist": artist, "allTracks": allTracks] as [String: Any]
                    NotificationCenter.default.post(name: NSNotification.Name("NavigateToArtistFromPlayer"), object: nil, userInfo: userInfo)
                }) {
                    Text(trackArtistDisplayName ?? ArtistNameNormalizer.displayName(artist.name))
                        .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .caption : .subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    /// 标题/歌手按钮元数据缓存（切歌/首次出现时加载一次，替代 body 求值中同步 DB 读）
    private func loadTrackMetadata() {
        guard let currentTrack = playerEngine.currentTrack else {
            trackAlbum = nil
            trackArtist = nil
            trackArtistDisplayName = nil
            return
        }

        if let albumId = currentTrack.albumId {
            trackAlbum = try? DatabaseManager.shared.read({ db in
                try Album.fetchOne(db, key: albumId)
            })
        } else {
            trackAlbum = nil
        }

        if let artistId = currentTrack.artistId {
            let artist = try? DatabaseManager.shared.read({ db in
                try Artist.fetchOne(db, key: artistId)
            })
            trackArtist = artist
            trackArtistDisplayName = artist.map {
                (try? DatabaseManager.shared.getArtistDisplayName(forTrackStableId: currentTrack.stableId, fallbackArtistId: artistId)) ?? ArtistNameNormalizer.displayName($0.name)
            }
        } else {
            trackArtist = nil
            trackArtistDisplayName = nil
        }
    }

    private var likeButton: some View {
        Button(action: {
            toggleFavorite()
        }) {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                .foregroundColor(isFavorite ? .red : .primary)
        }
    }

    private var addToPlaylistButton: some View {
        Button(action: {
            showPlaylistDialog = true
        }) {
            Image(systemName: "plus.circle")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title3 : .title2)
                .foregroundColor(.primary)
        }
    }

    // MARK: - Mini Lyrics Section

    // 封面下方的小歌词窗口：三行（上一句/当前句/下一句），当前句放大 + 主题色
    // 点击/左滑进入全屏歌词，右滑打开歌词搜索页（从左滑入）
    private var lyricMiniSection: some View {
        LyricMiniSection(
            lyrics: currentLyrics,
            isLoading: isLoadingLyrics,
            accentColor: settings.backgroundColorChoice.color
        )
        .padding(.horizontal, 8)
        // 点击进全屏歌词页（普通视图 + onTapGesture：与 DragGesture 仲裁标准，
        // 不用 Button——Button 手势优先级高，快速右滑会误触发 tap 直接进歌词页）
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.26)) {
                showLyricsSheet = true
            }
            if currentLyrics == nil && !isLoadingLyrics {
                loadLyrics()
            }
        }
        // 左滑 → 全屏歌词页（从右侧滑入）；右滑 → 歌词搜索页（从左侧滑入）
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if MiniLyricSwipeGesture.shouldOpenLyricsSheet(
                        translation: value.translation.width,
                        predictedTranslation: value.predictedEndTranslation.width
                    ) {
                        withAnimation(.easeOut(duration: 0.26)) {
                            showLyricsSheet = true
                        }
                        if currentLyrics == nil && !isLoadingLyrics {
                            loadLyrics()
                        }
                    } else if MiniLyricSwipeGesture.shouldOpenLyricsSearch(
                        translation: value.translation.width,
                        predictedTranslation: value.predictedEndTranslation.width
                    ) {
                        withAnimation(.easeOut(duration: 0.26)) {
                            showLyricsSearch = true
                        }
                    }
                }
        )
        // 双击：进全屏歌词页并开启跟唱（跟唱只发生在全屏歌词页，小窗口空间小不做控制条）。
        // 与单击（仅进全屏歌词页）共存：双击优先，单击等双击窗口判定失败后触发（~0.3s 延迟可接受）；
        // 与左/右滑 DragGesture 也不冲突（双击无位移，拖动判失败后滑动手势接管）。
        .highPriorityGesture(
            TapGesture(count: 2)
                .onEnded {
                    KaraokeController.shared.setKaraokeOn(true)
                    withAnimation(.easeOut(duration: 0.26)) {
                        showLyricsSheet = true
                    }
                    if currentLyrics == nil && !isLoadingLyrics {
                        loadLyrics()
                    }
                }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            withAnimation(.easeOut(duration: 0.26)) {
                showLyricsSheet = true
            }
            if currentLyrics == nil && !isLoadingLyrics {
                loadLyrics()
            }
        }
    }

    private var emptyStateView: some View {
        VStack {
            Image(systemName: "music.note")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text(Localized.noTrackSelected)
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helper Functions

    private func startSleepTimer(minutes: Int) {
        sleepTimerTask?.cancel()
        let endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEndDate = endDate

        sleepTimerTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(minutes * 60) * 1_000_000_000)

            guard !Task.isCancelled else { return }

            await MainActor.run {
                playerEngine.pause()
                sleepTimerEndDate = nil
                sleepTimerTask = nil
            }
        }
    }

    private func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
    }

    private func loadLyrics() {
        guard let currentTrack = playerEngine.currentTrack else { return }

        // 捕获发起时的歌曲身份：切歌后旧请求完成必须丢弃（网易云歌词耗时 2-10s，
        // 期间切歌会让旧结果覆盖新歌歌词，跟唱行号也随之错乱），与 loadCurrentArtwork 同款防护
        let trackId = currentTrack.stableId
        isLoadingLyrics = true

        Task {
            let lyrics = await LyricsManager.shared.getLyrics(for: currentTrack)

            await MainActor.run {
                // 切歌后当前歌曲已变，丢弃旧请求结果，不写任何状态（isLoadingLyrics 由新任务接管）
                guard playerEngine.currentTrack?.stableId == trackId else { return }
                currentLyrics = lyrics
                // 跟唱模式歌词注入（LyricsView / 控制条共用 PlayerView 的 currentLyrics 数据源）
                KaraokeController.shared.setLyrics(lyrics?.syncedLyrics ?? [])
                isLoadingLyrics = false
            }
        }
    }

    private func loadAllArtworks() async {
        await loadCurrentArtwork()
        await loadNextArtwork()
        await loadPreviousArtwork()
    }

    private func loadCurrentArtwork() async {
        guard let track = playerEngine.currentTrack else {
            currentArtwork = nil
            return
        }

        let trackId = track.stableId
        let artwork = await artworkManager.getArtwork(for: track)
        guard playerEngine.currentTrack?.stableId == trackId else { return }
        currentArtwork = artwork
    }

    private func loadNextArtwork() async {
        let currentTrackId = playerEngine.currentTrack?.stableId
        let nextTrack = getNextTrack()
        guard let track = nextTrack else {
            guard playerEngine.currentTrack?.stableId == currentTrackId else { return }
            nextArtwork = nil
            return
        }

        let nextTrackId = track.stableId
        let artwork = await artworkManager.getArtwork(for: track)
        guard playerEngine.currentTrack?.stableId == currentTrackId,
              getNextTrack()?.stableId == nextTrackId else { return }
        nextArtwork = artwork
    }

    private func loadPreviousArtwork() async {
        let currentTrackId = playerEngine.currentTrack?.stableId
        let prevTrack = getPreviousTrack()
        guard let track = prevTrack else {
            guard playerEngine.currentTrack?.stableId == currentTrackId else { return }
            previousArtwork = nil
            return
        }

        let previousTrackId = track.stableId
        let artwork = await artworkManager.getArtwork(for: track)
        guard playerEngine.currentTrack?.stableId == currentTrackId,
              getPreviousTrack()?.stableId == previousTrackId else { return }
        previousArtwork = artwork
    }

    private func getNextTrack() -> Track? {
        let queue = playerEngine.playbackQueue
        let currentIndex = playerEngine.currentIndex

        guard !queue.isEmpty else { return nil }

        if currentIndex < queue.count - 1 {
            // Normal next track
            return queue[currentIndex + 1]
        } else {
            // Wraparound to first track
            return queue[0]
        }
    }

    private func getPreviousTrack() -> Track? {
        let queue = playerEngine.playbackQueue
        let currentIndex = playerEngine.currentIndex

        guard !queue.isEmpty else { return nil }

        if currentIndex > 0 {
            // Normal previous track
            return queue[currentIndex - 1]
        } else {
            // Wraparound to last track
            return queue[queue.count - 1]
        }
    }

    @MainActor
    private func loadTracks() async {
        do {
            allTracks = try appCoordinator.getAllTracks()
            print("✅ Loaded \(allTracks.count) tracks for artist navigation")
        } catch {
            print("❌ Failed to load tracks: \(error)")
        }
    }

    private func checkFavoriteStatus() {
        guard let currentTrack = playerEngine.currentTrack else {
            isFavorite = false
            return
        }

        do {
            isFavorite = try DatabaseManager.shared.isFavorite(trackStableId: currentTrack.stableId)
        } catch {
            print("Failed to check favorite status: \(error)")
            isFavorite = false
        }
    }

    private func toggleFavorite() {
        guard let currentTrack = playerEngine.currentTrack else { return }

        do {
            try appCoordinator.toggleFavorite(trackStableId: currentTrack.stableId)
            isFavorite.toggle()
        } catch {
            print("Failed to toggle favorite: \(error)")
        }
    }

    /// 弹出系统 AirPlay 路由选择器。
    /// 上游遗留：离屏创建的 AVRoutePickerView 未加入 window 层级时 subviews 为空，
    /// 遍历找不到内部 UIButton → 弹窗静默失效且无降级。
    /// 现改为触发常驻视图层级的 RoutePickerHost（内部按钮已随布局加载），
    /// 递归查找按钮并模拟点击；仍失败时打日志便于定位（系统版本可能变化）。
    private func showAirPlayPicker() {
        guard let picker = routePickerView else {
            // 理论上不会发生：按钮只在 PlayerView 挂载后可见
            print("⚠️ AirPlay: route picker 未挂载，无法弹出选择器")
            return
        }
        if let button = Self.routePickerButton(in: picker) {
            button.sendActions(for: .touchUpInside)
        } else {
            print("⚠️ AirPlay: 未找到 route picker 内部按钮（系统版本可能变化）")
        }
    }

    private static func routePickerButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for subview in view.subviews {
            if let found = routePickerButton(in: subview) { return found }
        }
        return nil
    }
}
