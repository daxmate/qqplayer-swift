import SwiftUI

/// 播放页折叠控制容器：常驻进度条 + 三键（上一首/播放暂停/下一首），
/// 上滑展开更多按钮（播放顺序 + 队列/定时/歌词/隔空播放），下滑收起。
/// 三键行与展开工具行均为透明容器：按钮用 Spacer 均匀分布、与进度条同宽。
struct CollapsiblePlayerControls: View {
    @ObservedObject private var playerEngine = PlayerEngine.shared
    @State private var isExpanded = false

    let duration: TimeInterval
    let accentColor: Color
    let onSeek: (TimeInterval) -> Void
    let showSleepTimerButton: Bool
    let isLoadingLyrics: Bool
    let sleepTimerEndDate: Date?
    let onStartSleepTimer: (Int) -> Void
    let onCancelSleepTimer: () -> Void
    let onShowQueue: () -> Void
    let onShowLyrics: () -> Void
    let onShowAirPlay: () -> Void

    var body: some View {
        VStack(spacing: UIScreen.main.scale < UIScreen.main.nativeScale ? 12 : 16) {
            PlayerProgressSection(
                duration: duration,
                accentColor: accentColor,
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
        // 全容器可滑动：contentShape 把命中区域扩展到整个容器（含按钮间空隙），
        // simultaneousGesture 保证在按钮上拖动也能识别（轻点仍归按钮），
        // 用户可特意挑空白处滑动避免误触。
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    // 进度条区域（顶部约 60pt：进度条 + 时间标签）的滑动归 seek 拖动独占，
                    // 不参与展开/收起，避免拖进度条时手指微斜误触折叠。
                    guard value.startLocation.y > 60 else { return }
                    if value.translation.height < -30, !isExpanded {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            isExpanded = true
                        }
                    } else if value.translation.height > 30, isExpanded {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            isExpanded = false
                        }
                    }
                }
        )
    }

    // MARK: - 常驻三键行

    /// 三键行：三个按钮用 Spacer 均匀分布，容器与进度条同宽（同 .padding(.horizontal, 8)），底色透明
    private var threeButtonRow: some View {
        HStack(spacing: 0) {
            previousButton
            Spacer()
            playPauseButton
            Spacer()
            nextButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
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
        VStack(spacing: 12) {
            mainToolRow
            accessoryRow
        }
        .padding(.top, 2)
    }

    /// 主工具行：播放顺序 / 歌单 / 输出源 三键同一容器，摆放方式及底色同三键行（Spacer 均分 + 透明 + 与进度条同宽）
    private var mainToolRow: some View {
        HStack(spacing: 0) {
            playOrderButton
            Spacer()
            queueButton
            Spacer()
            airPlayButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    /// 辅助行：定时（可开关）/ 歌词（歌词第一重要，恒显示）
    private var accessoryRow: some View {
        HStack(spacing: 0) {
            if showSleepTimerButton {
                sleepTimerButton
                Spacer()
            }
            lyricsButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
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
        switch playOrderMode {
        case .sequential: return "arrow.clockwise"
        case .shuffle: return "shuffle"
        case .repeatAll: return "repeat"
        case .repeatOne: return "repeat.1"
        }
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

    private var lyricsButton: some View {
        Button(action: {
            onShowLyrics()
        }) {
            ZStack {
                Image(systemName: "quote.bubble")
                    .font(UIScreen.main.scale < UIScreen.main.nativeScale ? .title2 : .title)
                    .foregroundColor(.primary)

                if isLoadingLyrics {
                    ProgressView()
                        .scaleEffect(0.7)
                        .offset(x: 15, y: -10)
                }
            }
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
