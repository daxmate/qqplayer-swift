import SwiftUI

/// 播放页折叠控制容器：常驻进度条 + 三键（上一首/播放暂停/下一首），
/// 上滑展开更多按钮（播放顺序 + 队列/定时/隔空播放），下滑收起。
/// 三键行与展开工具行均为透明容器：按钮用 Spacer 均匀分布、与进度条同宽。
///
/// 2026-09-22：展开/收起手势改由**整页手势**驱动（展开状态提升为 `isExpanded` Binding，
/// 见 `PlayerView+PageGestures`）——容器内原来那份 DragGesture 已删，避免两套阈值打架；
/// 展开区的「歌词」按钮同时取消（左滑整页任意位置即开全屏歌词）。
struct CollapsiblePlayerControls: View {
    @Environment(PlayerEngine.self) private var playerEngine
    /// 展开状态由 PlayerView 持有（整页手势要读写）：上滑展开 / 下滑先收起 / 封面让位
    @Binding var isExpanded: Bool

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

    var body: some View {
        VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 12 : 16) {
            PlayerProgressSection(
                duration: duration,
                onSeek: onSeek
            )

            threeButtonRow

            if isExpanded {
                expandedSection
                // 展开后向下箭头置于最底部（提示可下滑收起）
                chevronIndicator
            } else {
                chevronIndicator
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

    private var chevronIndicator: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
            .font(.caption2)
            .foregroundColor(.secondary)
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

    /// 辅助行：定时（可开关）。歌词按钮已于 2026-09-22 取消（左滑整页任意位置即开全屏歌词）
    @ViewBuilder private var accessoryRow: some View {
        if showSleepTimerButton {
            HStack(spacing: DesignTokens.space0) {
                sleepTimerButton
                Spacer()
            }
            .padding(.horizontal, DesignTokens.space8)
            .padding(.vertical, DesignTokens.space8)
        }
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
}
