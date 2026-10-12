import SwiftUI

/// 播放页折叠控制容器：常驻进度条 + 三键（上一首/播放暂停/下一首），
/// 上滑展开更多按钮（播放顺序 + 队列/定时/隔空播放/删除当前歌曲），下滑收起。
/// 三键行与展开工具行均为透明容器：按钮用 Spacer 均匀分布、与进度条同宽。
///
/// 2026-09-22：展开/收起手势改由**整页手势**驱动（展开状态提升为 `isExpanded` Binding，
/// 见 `PlayerView+PageGestures`）——容器内原来那份 DragGesture 已删，避免两套阈值打架；
/// 展开区的「歌词」按钮同时取消（左滑整页任意位置即开全屏歌词）。
///
/// 2026-10-12：删掉底部切换箭头（展开/收起已由整页手势驱动，箭头冗余）；
/// 展开辅助行行尾新增「删除当前歌曲」（二次确认后走 `TrackDeletionService` 唯一入口）。
struct CollapsiblePlayerControls: View {
    @Environment(PlayerEngine.self) private var playerEngine
    /// 展开状态由 PlayerView 持有（整页手势要读写）：上滑展开 / 下滑先收起 / 封面让位
    @Binding var isExpanded: Bool
    /// 删除当前歌曲的二次确认弹窗
    @State private var showDeleteConfirmation = false

    let duration: TimeInterval
    /// App 强调色（读环境值；根注入见 ContentView）
    @Environment(\.appAccentColor) private var accentColor
    let onSeek: (TimeInterval) -> Void
    let showSleepTimerButton: Bool
    let sleepTimerEndDate: Date?
    let onStartSleepTimer: (Int) -> Void
    let onCancelSleepTimer: () -> Void
    let onShowQueue: () -> Void
    let onShowAirPlay: () -> Void
    /// 进度条实测 frame 回传（整页坐标系）：整页手势据此把起手在进度条上的手势让给 seek
    let onProgressBarFrameChange: (CGRect) -> Void

    var body: some View {
        VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 12 : 16) {
            PlayerProgressSection(
                duration: duration,
                onProgressBarFrameChange: onProgressBarFrameChange,
                onSeek: onSeek
            )

            threeButtonRow

            if isExpanded {
                expandedSection
            }
        }
        .alert(Localized.deleteFile, isPresented: $showDeleteConfirmation) {
            Button(Localized.delete, role: .destructive) { deleteCurrentTrack() }
            Button(Localized.cancel, role: .cancel) {}
        } message: {
            if let track = playerEngine.currentTrack {
                Text(Localized.deleteFileConfirmation(track.displayTitle))
            }
        }
    }

    // MARK: - 常驻三键行

    /// 三键行：三个按钮用 Spacer 均匀分布，容器与进度条同宽（同 .padding(.horizontal, 8)），底色透明
    private var threeButtonRow: some View {
        HStack(spacing: DesignTokens.space0) {
            previousButton
            Spacer()
            playPauseButton
            Spacer()
            nextButton
        }
        .padding(.horizontal, DesignTokens.space8)
        .padding(.vertical, DesignTokens.space8)
    }

    private var previousButton: some View {
        Button(action: {
            Task {
                await playerEngine.previousTrack()
            }
        }) {
            Image(systemName: "backward.fill")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var playPauseButton: some View {
        Button(action: {
            if playerEngine.isPlaying {
                playerEngine.pause()
            } else {
                playerEngine.play()
            }
        }) {
            Image(systemName: playerEngine.isPlaying ? "pause.fill" : "play.fill")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title : .largeTitle)
                .frame(width: 72, height: 72)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var nextButton: some View {
        Button(action: {
            Task {
                await playerEngine.nextTrack()
            }
        }) {
            Image(systemName: "forward.fill")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    // MARK: - 展开区

    private var expandedSection: some View {
        VStack(spacing: DesignTokens.space12) {
            mainToolRow
            accessoryRow
        }
        .padding(.top, DesignTokens.space2)
    }

    /// 主工具行：播放顺序 / 歌单 / 输出源 三键同一容器，摆放方式及底色同三键行（Spacer 均分 + 透明 + 与进度条同宽）
    private var mainToolRow: some View {
        HStack(spacing: DesignTokens.space0) {
            playOrderButton
            Spacer()
            queueButton
            Spacer()
            airPlayButton
        }
        .padding(.horizontal, DesignTokens.space8)
        .padding(.vertical, DesignTokens.space8)
    }

    /// 辅助行：定时（可开关，靠左；歌词按钮已于 2026-09-22 取消）+ 删除当前歌曲（行尾）。
    /// 该行**始终渲染**——即使定时按钮关闭，删除按钮也要出现；删除与主工具行分开。
    @ViewBuilder private var accessoryRow: some View {
        HStack(spacing: DesignTokens.space0) {
            if showSleepTimerButton {
                sleepTimerButton
            }
            Spacer()
            deleteTrackButton
        }
        .padding(.horizontal, DesignTokens.space8)
        .padding(.vertical, DesignTokens.space8)
    }

    // 播放顺序四态轮换按钮：顺序播放 → 随机播放 → 循环列表 → 单曲循环（仅图标，无文字）
    private var playOrderButton: some View {
        Button(action: {
            playerEngine.cyclePlaybackOrderMode()
        }) {
            Image(systemName: playOrderIcon)
                .font(.title3)
                .foregroundColor(isPlayOrderActive ? accentColor : .primary)
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(playOrderTitle)
    }

    private var playOrderMode: PlaybackOrderMode {
        playerEngine.playbackOrderMode
    }

    private var playOrderIcon: String {
        // 图标映射走 PlaybackOrderMode.systemImageName（与 CarPlay 播放页同一入口）
        playOrderMode.systemImageName
    }

    private var playOrderTitle: String {
        switch playOrderMode {
        case .sequential: return Localized.playOrderSequential
        case .shuffle: return Localized.playOrderShuffle
        case .repeatAll: return Localized.playOrderRepeatAll
        case .repeatOne: return Localized.playOrderRepeatOne
        }
    }

    private var isPlayOrderActive: Bool {
        switch playOrderMode {
        case .sequential: return false
        case .shuffle, .repeatAll, .repeatOne: return true
        }
    }

    private var queueButton: some View {
        Button(action: {
            onShowQueue()
        }) {
            Image(systemName: "list.bullet")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                .foregroundColor(.primary)
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var airPlayButton: some View {
        Button(action: {
            onShowAirPlay()
        }) {
            Image(systemName: "airplayaudio")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                .foregroundColor(.primary)
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var sleepTimerButton: some View {
        Menu {
            Button(Localized.sleepTimer15Minutes) {
                onStartSleepTimer(15)
            }
            Button(Localized.sleepTimer30Minutes) {
                onStartSleepTimer(30)
            }
            Button(Localized.sleepTimer45Minutes) {
                onStartSleepTimer(45)
            }
            Button(Localized.sleepTimer60Minutes) {
                onStartSleepTimer(60)
            }

            if sleepTimerEndDate != nil {
                Divider()

                Button(Localized.cancelSleepTimer, role: .destructive) {
                    onCancelSleepTimer()
                }
            }
        } label: {
            Image(systemName: sleepTimerEndDate == nil ? "timer" : "timer.circle.fill")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                .foregroundColor(sleepTimerEndDate == nil ? .primary : accentColor)
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel(Localized.sleepTimer)
    }

    /// 删除当前歌曲（行尾）。无当前曲目时禁用；点按先弹二次确认，确认后才执行删除。
    private var deleteTrackButton: some View {
        Button(action: {
            guard playerEngine.currentTrack != nil else { return }
            showDeleteConfirmation = true
        }) {
            Image(systemName: "trash")
                .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                .foregroundColor(.primary)
                .frame(width: 56, height: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(playerEngine.currentTrack == nil)
        .accessibilityLabel(Localized.deleteFile)
    }

    /// 确认后执行：删除仪式走唯一入口 `TrackDeletionService`；队列变更走引擎唯一入口，
    /// 视图不手写下标数学。
    /// - 队列 > 1：先把当前项移出 `currentIndex`（当前项不可直接移除）并自动接着播下一首，
    ///   再按 stableId 移除被删曲目。
    /// - 队列 == 1：当前项无论如何都不可移除 → 停止播放并清空队列。
    private func deleteCurrentTrack() {
        guard let track = playerEngine.currentTrack else { return }
        let stableId = track.stableId
        Task { @MainActor in
            if playerEngine.playbackQueue.count > 1 {
                await playerEngine.nextTrack()
                playerEngine.removeQueueItem(stableId: stableId)
            } else {
                playerEngine.stopAndClearQueue()
            }
            // 删除仪式（设置分支 / 删文件 / 删 DB 引用 / 通知刷新）见 TrackDeletionService
            TrackDeletionService.delete(items: [TrackDeletionService.Item(track: track)])
        }
    }
}
