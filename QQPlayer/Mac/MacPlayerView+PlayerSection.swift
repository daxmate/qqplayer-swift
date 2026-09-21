//
//  MacPlayerView+PlayerSection.swift
//  QQPlayer
//
//  MacPlayerView 分片（2026-09-21 从 MacPlayerView.swift 原样搬出，纯搬家，无逻辑变更）：
//  播放区（封面/曲目信息/进度条/控制条/频谱）+ 频谱 tap 生命周期 + 收藏态 / 睡眠定时器。
//  同族文件：
//    · Mac/MacPlayerView.swift      — 主片：视图壳（stored property + body）+ 歌词交互 + 播放顺序
//    · Mac/MacQueuePanelView.swift  — 播放队列面板（独立顶层类型）
//
//  ⚠️ 可见性：被主片 `body` 引用的成员（playerSection / updateSpectrumTap）为 internal（原 `private`）。
//

import SwiftUI
extension MacPlayerView {
    // MARK: - Player section

    /// 分片：跨文件可见（原 private）
    var playerSection: some View {
        VStack(spacing: DesignTokens.space16) {
            Spacer()

            // Artwork
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.radius16)
                    .fill(Color.gray.opacity(0.15))
                    .frame(width: 240, height: 240)
                    .shadow(radius: 8, y: 4)

                if let artwork {
                    Image(nsImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 240, height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.radius16))
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: DesignTokens.font60))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 240, height: 240)

            // Track info
            VStack(spacing: DesignTokens.space4) {
                Text(track?.displayTitle ?? "not_playing".localized)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(artistName ?? "")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            // Progress bar
            VStack(spacing: DesignTokens.space4) {
                Slider(
                    value: Binding(
                        get: { isDragging ? (dragTime ?? playbackTime) : playbackTime },
                        set: { dragTime = $0 }
                    ),
                    in: 0 ... max(duration, 0.01),
                    onEditingChanged: { editing in
                        isDragging = editing
                        if !editing, let dragTime {
                            onSeek(dragTime)
                            self.dragTime = nil
                        }
                    }
                )
                .disabled(track == nil || duration <= 0)

                HStack {
                    Text(MacTimeFormat.format(isDragging ? (dragTime ?? playbackTime) : playbackTime))
                    Spacer()
                    Text(MacTimeFormat.format(duration))
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .monospacedDigit()
            }
            .frame(maxWidth: 420)

            // Controls
            HStack(spacing: DesignTokens.space24) {
                Button(action: onPrevious) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: DesignTokens.font22))
                }
                .buttonStyle(.plain)
                .disabled(track == nil)

                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: DesignTokens.font44))
                }
                .buttonStyle(.plain)
                .disabled(track == nil)

                Button(action: onNext) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: DesignTokens.font22))
                }
                .buttonStyle(.plain)
                .disabled(track == nil)

                Divider().frame(height: 24)

                // 播放顺序四态：顺序 → 随机 → 循环列表 → 单曲循环
                // （shuffle 分支必须走 toggleShuffle()：保存/恢复 originalQueue，测试锁定）
                Button {
                    player.cyclePlaybackOrderMode()
                } label: {
                    Image(systemName: playOrderIcon)
                        .font(.system(size: DesignTokens.font16))
                }
                .buttonStyle(.plain)
                .foregroundColor(isPlayOrderActive ? appAccentColor : .secondary)
                .help(playOrderTitle)

                // 当前曲目收藏（红心）
                Button {
                    guard let track else { return }
                    try? appCoordinator.toggleFavorite(trackStableId: track.stableId)
                } label: {
                    Image(systemName: currentTrackIsFavorite ? "heart.fill" : "heart")
                        .font(.system(size: DesignTokens.font16))
                }
                .buttonStyle(.plain)
                .foregroundColor(currentTrackIsFavorite ? .pink : .secondary)
                .disabled(track == nil)
                .help(currentTrackIsFavorite ? "remove_from_liked_songs".localized : "add_to_liked_songs".localized)

                // 睡眠定时器：15/30/45/60 分钟，激活后可取消（切歌不清除）
                // 默认隐藏（对齐 iOS showSleepTimerButton=false），设置页可开启
                if showSleepTimerButton {
                    Menu {
                        Button(Localized.sleepTimer15Minutes) { startSleepTimer(minutes: 15) }
                        Button(Localized.sleepTimer30Minutes) { startSleepTimer(minutes: 30) }
                        Button(Localized.sleepTimer45Minutes) { startSleepTimer(minutes: 45) }
                        Button(Localized.sleepTimer60Minutes) { startSleepTimer(minutes: 60) }

                        if sleepTimerEndDate != nil {
                            Divider()
                            Button(Localized.cancelSleepTimer, role: .destructive) { cancelSleepTimer() }
                        }
                    } label: {
                        Image(systemName: sleepTimerEndDate == nil ? "timer" : "timer.circle.fill")
                            .font(.system(size: DesignTokens.font16))
                    }
                    .menuStyle(.borderlessButton)
                    .foregroundColor(sleepTimerEndDate == nil ? .secondary : appAccentColor)
                    .help("sleep_timer".localized)
                }

                Divider().frame(height: 24)

                // 播放队列（B 组队列排序持久化）：打开可拖排/删除/跳转的面板。
                // 只有当前在播且非随机时队列面板才有意义——随机模式下播放顺序
                // 由 shuffle 决定（isQueueReorderable=false，面板内提示）。
                Button {
                    showQueuePanel = true
                } label: {
                    Image(systemName: "list.number")
                        .font(.system(size: DesignTokens.font16))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .disabled(track == nil || player.playbackQueue.isEmpty)
                .help("playing_queue".localized)

                // 跟唱模式开关（双击歌词行的 iOS 语义在 Mac 上没有，给显式按钮）
                Button {
                    karaoke.toggleKaraokeMode()
                } label: {
                    Image(systemName: karaoke.isKaraokeOn ? "mic.fill" : "mic")
                        .font(.system(size: DesignTokens.font16))
                }
                .buttonStyle(.plain)
                .foregroundColor(karaoke.isKaraokeOn ? appAccentColor : .secondary)
                .disabled(track == nil)
                .help("karaoke_mode_help".localized)

            }

            // 播放页频谱条（D4，web Visualizer 对齐——仅 native 引擎曲目有数据，
            // SFB 曲目 Opus/OGG/DSD 无 tap 数据源，自动隐藏；跟唱大画面时本区隐藏）
            if visualizerEnabled {
                MacVisualizerView()
                    .frame(width: 420, height: 44)
                    .padding(.top, DesignTokens.space2)
            }

            Spacer()
        }
        .padding(.top, DesignTokens.space24)
        .padding(.horizontal, DesignTokens.space32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: player.isPlaying) { _, _ in
            updateSpectrumTap()
        }
        .onChange(of: track?.stableId) { _, _ in
            updateSpectrumTap()
        }
        // 视图离场/回场收尾（2026-09-12 审计 L4）：修复前 tap 只由 isPlaying/切歌/
        // 设置变更驱动——主窗进迷你模式或播放页长期不可见时，音频线程 FFT 与
        // 30fps 主线程发布照旧跑。离场摘 tap（幂等），回场按当前状态重装。
        .onAppear {
            updateSpectrumTap()
        }
        .onDisappear {
            spectrumAnalyzer.removeTap()
        }
    }

    /// 频谱 tap 生命周期：播放中且 native 引擎 → 装 mainMixer tap；否则移除。
    /// （SFB 曲目无 tap 数据源；暂停/切歌/关闭设置都走这里收尾）
    /// 分片：跨文件可见（原 private）
    func updateSpectrumTap() {
        guard visualizerEnabled else {
            spectrumAnalyzer.removeTap()
            return
        }
        if player.isPlaying, !player.usingSFBEngine {
            spectrumAnalyzer.ensureTap(engine: player.audioEngine)
        } else {
            spectrumAnalyzer.removeTap()
        }
    }

    // MARK: - Favorite

    private var currentTrackIsFavorite: Bool {
        guard let track else { return false }
        return favoriteIds.contains(track.stableId)
    }

    // MARK: - Sleep timer

    private func startSleepTimer(minutes: Int) {
        sleepTimerTask?.cancel()
        let endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimerEndDate = endDate

        sleepTimerTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000)
            guard !Task.isCancelled else { return }
            player.pause()
            sleepTimerEndDate = nil
            sleepTimerTask = nil
        }
    }

    private func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
    }
}
