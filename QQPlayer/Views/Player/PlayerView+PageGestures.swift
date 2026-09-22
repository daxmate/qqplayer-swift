//
//  PlayerView+PageGestures.swift
//  QQPlayer
//
//  播放页**整页手势**（2026-09-22 立，用户拍板）：把手势作用范围从「封面 / 小歌词窗 /
//  控制区」三个小区域扩到**整页**——
//    · 下滑：展开面板时先收起「更多播放控制」，否则缩回主页（跟手移动整页，UIKit transform 驱动）
//    · 上滑：展开「更多播放控制」
//    · 左滑：全屏歌词页；右滑：歌词搜索页
//  两处**例外按起手位置排除**（只排除那一个区域，不排除整个方向）：
//    · 封面区横滑 = 切歌（封面自己的手势，轮播动画归它，见 PlayerView+Artwork）
//    · 进度条区横滑 = seek（进度条自己的手势，拖进度条不会误开歌词页）
//  「下拉跟手」「打开歌词页 / 搜索页」都是唯一入口，封面手势与小歌词窗点击共用。
//
//  同族文件：
//    · Views/Player/PlayerView.swift                 — 视图壳：stored property + body 装配
//    · Views/Player/PlayerView+Artwork.swift         — 封面区视图 / 横滑切歌 / 封面下拉
//    · Views/Player/PlayerView+TitleAndLyrics.swift  — 标题/歌手/收藏、小歌词窗
//    · Views/Player/PlayerGestureLogic.swift         — 判定阈值纯逻辑（可单测）
//
// target: ios-only（PlayerView 分片：消费端全在 iOS；Mac 侧为 MacPlayerView）
//
import SwiftUI

/// 整页手势的坐标空间名：`startLocation` 与区域 frame 必须用**同一个**空间
/// （frame 在 PlayerView.body 的 ZStack 上命名，见 `playerPageCoordinateSpace`）
enum PlayerPageCoordinateSpace {
    static let name = "playerPage"
}

/// 整页手势按**起手位置**划分的区域（例外手势按区域排除）
enum PlayerPageRegion: Hashable {
    /// 封面区：横滑切歌 + 下拉缩回主页（封面自己的手势）
    case artwork
    /// 进度条 + 时间标签区：横滑归 seek 独占
    case progress
    /// 其余整页区：左右滑开歌词 / 搜索，上下滑展开 / 收起 / 缩回主页
    case page
}

extension PlayerView {
    // MARK: - 坐标与区域分流

    /// 起手位置 → 区域（区块未测量到或不在其中 = 整页区）
    func pageRegion(for location: CGPoint) -> PlayerPageRegion {
        if artworkFrame.contains(location) {
            return .artwork
        }
        if progressRegionFrame.contains(location) {
            return .progress
        }
        return .page
    }

    /// 进度条区 = 控制容器顶部 60pt（进度条 + 时间标签）。
    /// 与旧折叠手势的 `startLocation.y > 60` 同一口径，只是换到整页坐标系。
    var progressRegionFrame: CGRect {
        CGRect(
            x: controlsFrame.minX,
            y: controlsFrame.minY,
            width: controlsFrame.width,
            height: min(60, controlsFrame.height)
        )
    }

    // MARK: - 整页手势

    /// 整页手势：横滑开歌词 / 搜索，上滑展开更多控制，下滑收起面板 / 缩回主页
    var pageDragGesture: some Gesture {
        DragGesture(
            minimumDistance: 12,
            coordinateSpace: .named(PlayerPageCoordinateSpace.name)
        )
        .onChanged { value in
            guard !isAnimating else { return }

            if pageDragAxis == nil {
                let axis = PlayerPageGesture.axis(translation: value.translation)
                pageDragAxis = axis == .horizontal ? .horizontal : .vertical
            }

            // 跟手只服务「非封面 + 面板未展开」的下拉：封面下拉归封面手势（同一 UIKit 通道）
            guard pageDragAxis == .vertical,
                  !isControlsExpanded,
                  value.translation.height > 0,
                  pageRegion(for: value.startLocation) != .artwork
            else { return }

            isPullingPlayer = true
            updatePull(translationHeight: value.translation.height)
        }
        .onEnded { value in
            let axis = pageDragAxis
            pageDragAxis = nil

            guard !isAnimating else {
                isPullingPlayer = false
                return
            }

            switch axis {
            case .horizontal:
                openPageForHorizontalSwipe(value)
            case .vertical:
                endPageVerticalDrag(value)
            case nil:
                // 位移没过 minimumDistance：只收尾可能残留的跟手位移
                if isPullingPlayer {
                    endPull(
                        translationHeight: value.translation.height,
                        predictedHeight: value.predictedEndTranslation.height
                    )
                }
            }
        }
    }

    /// 横滑分流：封面（切歌）与进度条（seek）之外的整页区，左滑开歌词、右滑开搜索
    private func openPageForHorizontalSwipe(_ value: DragGesture.Value) {
        guard pageRegion(for: value.startLocation) == .page else { return }

        if PlayerPageGesture.shouldOpenLyricsSheet(
            translation: value.translation.width,
            predictedTranslation: value.predictedEndTranslation.width
        ) {
            openLyricsSheet()
        } else if PlayerPageGesture.shouldOpenLyricsSearch(
            translation: value.translation.width,
            predictedTranslation: value.predictedEndTranslation.width
        ) {
            openLyricsSearch()
        }
    }

    /// 纵滑分流：下滑「先收面板、再缩回主页」，上滑展开更多控制
    private func endPageVerticalDrag(_ value: DragGesture.Value) {
        let height = value.translation.height

        if height < 0 {
            if PlayerPageGesture.shouldExpandMoreControls(translationHeight: height) {
                setControlsExpanded(true)
            }
            if isPullingPlayer {
                // 下拉中途改上滑：已跟手的位移归零回弹
                endPull(
                    translationHeight: height,
                    predictedHeight: value.predictedEndTranslation.height
                )
            }
            return
        }

        // 下滑在任何位置都先收起「更多播放控制」（用户 2026-09-22 拍板：任何位置下滑 = 关闭更多播放控制）
        if isControlsExpanded {
            if PlayerPageGesture.shouldCollapseMoreControls(translationHeight: height) {
                setControlsExpanded(false)
            }
            return
        }

        // 封面下拉由封面手势收尾（同一通道，不重复驱动）
        guard pageRegion(for: value.startLocation) != .artwork else { return }
        endPull(
            translationHeight: height,
            predictedHeight: value.predictedEndTranslation.height
        )
    }

    // MARK: - 下拉跟手（封面 / 整页共用同一通道）

    /// 跟手：按位移下移宿主 view（1pt 死区滤触摸噪声，限幅 `pullMaxOffset`）。
    /// 直接驱动 UIKit transform，绕过 SwiftUI 状态重算/布局（大视图树逐帧重算会掉帧抖动，见 knowledge/ios-dev.md §8）
    func updatePull(translationHeight: CGFloat) {
        let target = min(translationHeight, pullMaxOffset)
        guard abs(target - lastPullY) >= 1 else { return }
        lastPullY = target
        pullHostView?.transform = CGAffineTransform(translationX: 0, y: target)
    }

    /// 收尾：达阈值 / 快速回甩 → 滑出屏幕后缩回主页，否则回弹。全走 UIKit 动画（与跟手同通道）
    func endPull(translationHeight: CGFloat, predictedHeight: CGFloat) {
        isPullingPlayer = false
        lastPullY = 0
        guard let hostView = pullHostView else { return }

        if PlayerDismissGesture.shouldDismissPlayer(
            pullOffset: translationHeight,
            predictedHeight: predictedHeight
        ) {
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
                    NotificationCenter.default.post(name: .minimizePlayer, object: nil)
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
    }

    // MARK: - 展开面板 / 打开歌词（唯一入口，封面手势与小歌词窗共用）

    /// 展开 / 收起「更多播放控制」（动画与旧容器手势同款 spring 0.35/0.85）
    func setControlsExpanded(_ expanded: Bool) {
        guard isControlsExpanded != expanded else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isControlsExpanded = expanded
        }
    }

    /// 打开全屏歌词页（整页左滑 / 小歌词窗单击 / 小歌词窗双击共用）
    func openLyricsSheet() {
        withAnimation(.easeOut(duration: 0.26)) {
            showLyricsSheet = true
        }
        if currentLyrics == nil && !isLoadingLyrics {
            loadLyrics()
        }
    }

    /// 打开歌词搜索页（整页右滑共用）
    func openLyricsSearch() {
        withAnimation(.easeOut(duration: 0.26)) {
            showLyricsSearch = true
        }
    }
}
