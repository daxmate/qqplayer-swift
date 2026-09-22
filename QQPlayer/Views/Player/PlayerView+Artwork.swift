//
//  PlayerView+Artwork.swift
//  QQPlayer
//
//  播放页**封面区**：封面轮播视图（当前 / 相邻）、封面拖拽手势（横滑切歌 / 下拉关闭播放页）、
//  以及封面缓冲加载（当前 / 下一首 / 上一首，含队列邻居查询）。
//
//  2026-09-21 从 PlayerView.swift 原样搬出（纯搬家，无逻辑变更）。
//  2026-09-22 整页手势上线：下拉跟手 / 收尾改用 `PlayerView+PageGestures` 的共用入口
//  （`updatePull` / `endPull`）；面板展开时封面竖向让位给「收起面板」。
//  同族文件：
//    · Views/Player/PlayerView.swift                   — 视图壳：stored property + body 装配
//    · Views/Player/PlayerView+TitleAndLyrics.swift    — 标题/歌手/收藏按钮、小歌词窗
//    · Views/Player/PlayerView+PlaybackSupport.swift   — 睡眠定时、曲库加载、AirPlay
//    · Views/Player/PlayerView+PageGestures.swift      — 整页手势 + 下拉跟手 / 打开歌词入口
//
// target: ios-only（PlayerView 分片：消费端全在 iOS；Mac 侧为 MacPlayerView）
//
import AVKit
import SwiftUI

extension PlayerView {
    // MARK: - Artwork Section

    /// 分片：跨文件可见（原 private）
    var artworkSection: some View {
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
                        NotificationCenter.default.post(name: .minimizePlayer, object: nil)
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
        // 封面区 frame → 整页坐标系：整页手势据此把横滑（切歌）与下拉让给封面手势
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(PlayerPageCoordinateSpace.name))
        } action: { frame in
            artworkFrame = frame
        }
    }

    private func currentArtworkView(size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.radius12)
                .fill(Color.gray.opacity(0.1))
                .frame(width: size, height: size)

            if let artwork = currentArtwork {
                Image(uiImage: artwork)
                    .resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius12))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: min(80, size * 0.2)))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func adjacentArtworkView(artwork: UIImage?, size: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: DesignTokens.radius12)
                .fill(Color.gray.opacity(0.1))
                .frame(width: size, height: size)

            if let artwork = artwork {
                Image(uiImage: artwork)
                    .resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius12))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: min(80, size * 0.2)))
                    .foregroundColor(.secondary)
            }
        }
    }

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
                } else if value.translation.height > 0, !isControlsExpanded {
                    // 纵向下拉：走整页共用的跟手通道（UIKit transform 直驱宿主 view，见 updatePull）。
                    // 面板展开时下拉归「收起面板」（整页手势），封面不再跟手。
                    // 死区过滤（±1pt）与限幅在 updatePull 里。
                    isPullingPlayer = true
                    updatePull(translationHeight: value.translation.height)
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
                } else if !isControlsExpanded {
                    // 纵向结束（无论最终位移方向）：达阈值/快速回甩 → 下滑滑出后关闭；否则回弹。
                    // 面板展开时竖向归「收起面板」（整页手势）。
                    endPull(
                        translationHeight: value.translation.height,
                        predictedHeight: value.predictedEndTranslation.height
                    )
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

    /// 分片：跨文件可见（原 private）
    func loadAllArtworks() async {
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
        let artwork = await services.artworkManager.getArtwork(for: track)
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
        let artwork = await services.artworkManager.getArtwork(for: track)
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
        let artwork = await services.artworkManager.getArtwork(for: track)
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
}
