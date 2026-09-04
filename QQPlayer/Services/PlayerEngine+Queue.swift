//  PlayerEngine+Queue.swift
//  QQPlayer
//
//  Queue management, playback order modes, shuffle, and loop handling for
//  PlayerEngine.
//
import Foundation

/// 队列手动重排的索引数学（纯函数，可单测——PlayerEngine.shared 单例 + @MainActor
/// 无法在测试里安全实例化，索引修正是最容易回归的部分，抽出来锁定）。
enum QueueReorderMath {
    /// List onMove 落点修正：destination 是移除源项后的插入点。
    /// - source 在 destination 前：移除源项使后续索引整体前移 1 → 插入点 = destination - 1
    /// - source 在 destination 后：不受影响 → 插入点 = destination
    static func insertIndex(sourceIndex: Int, destination: Int) -> Int {
        sourceIndex < destination ? destination - 1 : destination
    }

    /// 移动后 currentIndex 应指向的索引（保持指向同一曲目）。
    /// 规则（均以 sourceIndex 移除前的坐标系讨论）：
    /// - source == current：当前曲被移动 → 新位置即 current 新址
    /// - source < current && insertAt >= current：被移动项插到 current 之后/处 → current 前移 1
    /// - source > current && insertAt <= current：被移动项从 current 后挪到 current 前 → current 后移 1
    /// - 其余：current 不受影响
    static func adjustedCurrentIndexAfterMove(sourceIndex: Int, insertAt: Int, currentIndex: Int) -> Int {
        if sourceIndex == currentIndex {
            return insertAt
        }
        if sourceIndex < currentIndex, insertAt >= currentIndex {
            return currentIndex - 1
        }
        if sourceIndex > currentIndex, insertAt <= currentIndex {
            return currentIndex + 1
        }
        return currentIndex
    }

    /// 移除若干项后 currentIndex 的修正（offsets 应已排除当前项；多选从尾往头删）。
    static func adjustedCurrentIndexAfterRemoval(removedIndices: [Int], currentIndex: Int) -> Int {
        removedIndices.reduce(currentIndex) { acc, removed in
            removed < acc ? acc - 1 : acc
        }
    }
}

extension PlayerEngine {
    // MARK: - Index Normalization Helper

    func normalizeIndexAndTrack() {
        if playbackQueue.isEmpty {
            currentIndex = 0
            currentTrack = nil
            return
        }

        if let ct = currentTrack,
           let idx = playbackQueue.firstIndex(where: { $0.stableId == ct.stableId }) {
            currentIndex = idx
        } else {
            currentIndex = max(0, min(currentIndex, playbackQueue.count - 1))
            currentTrack = playbackQueue[currentIndex]
        }
    }

    // MARK: - Queue Management

    func playTrack(_ track: Track, queue: [Track] = []) async {
        print("🎵 Playing track: \(track.title)")

        // Restore player state on first interaction if not already done
        await ensurePlayerStateRestored()

        playbackQueue = queue.isEmpty ? [track] : queue
        currentIndex = playbackQueue.firstIndex(where: { $0.stableId == track.stableId }) ?? 0

        // Explicitly set the current track to ensure UI synchronization
        currentTrack = track

        // Save original queue for shuffle functionality
        originalQueue = playbackQueue.map { $0.stableId }

        normalizeIndexAndTrack()

        let loaded = await loadTrack(track)
        guard loaded else { return }

        if usingSFBEngine && isPlaying {
            playbackState = .playing
            startPlaybackTimer()
            updateNowPlayingInfoEnhanced()
            updateWidgetData()
        } else {
            play()
        }
    }

    func nextTrack(autoplay: Bool? = nil) async {
        guard !playbackQueue.isEmpty else { return }
        normalizeIndexAndTrack()
        let shouldAutoplay = autoplay ?? isPlaying

        currentIndex = (currentIndex + 1) % playbackQueue.count
        let next = playbackQueue[currentIndex]
        let loaded = await loadTrack(next, preservePlaybackTime: false)
        guard loaded else { return }

        if shouldAutoplay {
            if usingSFBEngine && isPlaying {
                playbackState = .playing
                startPlaybackTimer()
            } else {
                play()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cancelPendingCompletions()
                self.playerNode.stop()
                self.isPlaying = false
                self.playbackState = .paused
                self.seekTimeOffset = 0
                self.playbackTime = 0
                self.updateNowPlayingInfoEnhanced()
                self.updateWidgetData()
            }
        }
    }

    func previousTrack(autoplay: Bool? = nil) async {
        guard !playbackQueue.isEmpty else { return }
        normalizeIndexAndTrack()

        let wasPlaying = autoplay ?? isPlaying

        if playbackTime > 3.0 {
            await seek(to: 0)
            if !wasPlaying {
                await MainActor.run {
                    isPlaying = false
                    playbackState = .paused
                    updateNowPlayingInfoEnhanced()
                    updateWidgetData()
                }
            }
            return
        }

        currentIndex = currentIndex > 0 ? currentIndex - 1 : playbackQueue.count - 1
        let prev = playbackQueue[currentIndex]
        let loaded = await loadTrack(prev, preservePlaybackTime: false)
        guard loaded else { return }

        if wasPlaying {
            await MainActor.run {
                if usingSFBEngine && isPlaying {
                    playbackState = .playing
                    startPlaybackTimer()
                } else {
                    play()
                }
            }
        } else {
            await MainActor.run {
                cancelPendingCompletions()
                playerNode.stop()
                isPlaying = false
                playbackState = .paused
                seekTimeOffset = 0
                playbackTime = 0
                updateNowPlayingInfoEnhanced()
                updateWidgetData()
            }
        }
    }

    func addToQueue(_ track: Track) {
        playbackQueue.append(track)
    }

    func insertNext(_ track: Track) {
        let insertIndex = currentIndex + 1
        playbackQueue.insert(track, at: min(insertIndex, playbackQueue.count))
    }

    // MARK: - Queue 手动重排（macOS 队列面板，2026-09-03 B 组对齐 web 队列持久化）

    /// 移动队列一段（List onMove 语义）。修正 currentIndex 指向同一曲目；
    /// 随机模式下禁止重排（队列顺序会被 shuffle 覆盖，UI 层 isQueueReorderable 拦截）。
    /// 重排后立即 savePlayerState()——否则顺序只在 pause/stop 时才落盘，重启丢序。
    func moveQueueItems(from source: IndexSet, to destination: Int) {
        guard isQueueReorderable, let sourceIndex = source.first,
              playbackQueue.indices.contains(sourceIndex) else { return }

        let insertAt = QueueReorderMath.insertIndex(sourceIndex: sourceIndex, destination: destination)
        guard insertAt >= 0, insertAt < playbackQueue.count, insertAt != sourceIndex else { return }

        let moved = playbackQueue.remove(at: sourceIndex)
        playbackQueue.insert(moved, at: insertAt)

        currentIndex = QueueReorderMath.adjustedCurrentIndexAfterMove(
            sourceIndex: sourceIndex,
            insertAt: insertAt,
            currentIndex: currentIndex
        )
        print("🔀 Queue reordered: \(moved.title) to \(insertAt), currentIndex=\(currentIndex)")
        savePlayerState()
    }

    /// 从队列移除若干项（当前播放项不可移除——UI 已过滤，这里再兜底）。
    /// 移除后立即持久化。
    func removeQueueItems(at offsets: IndexSet) {
        let removable = offsets.filter { $0 != currentIndex }
        guard !removable.isEmpty else { return }

        var newQueue = playbackQueue
        for index in removable.sorted().reversed() {
            newQueue.remove(at: index)
        }
        currentIndex = QueueReorderMath.adjustedCurrentIndexAfterRemoval(
            removedIndices: Array(removable),
            currentIndex: currentIndex
        )
        currentIndex = max(0, min(currentIndex, newQueue.count - 1))

        playbackQueue = newQueue
        normalizeIndexAndTrack()
        print("🗑️ Queue items removed, remaining \(playbackQueue.count)")
        savePlayerState()
    }

    /// 跳到队列指定项播放（队列面板点行）。等价 iOS QueueManagementView.jumpToTrack。
    func jumpToQueueIndex(_ index: Int) async {
        guard index >= 0, index < playbackQueue.count else { return }
        currentIndex = index
        let track = playbackQueue[index]
        await loadTrack(track, preservePlaybackTime: false)
        if usingSFBEngine && isPlaying {
            playbackState = .playing
            startPlaybackTimer()
        } else {
            play()
        }
        savePlayerState()
    }

    /// 队列可否手动重排：非空 + 非随机。随机模式下播放顺序由 shuffle 决定，
    /// 手动重排无意义且会被 toggleShuffle 覆盖（web 版 canReorder 语义对齐）。
    var isQueueReorderable: Bool {
        !playbackQueue.isEmpty && !isShuffled
    }

    // MARK: - Playback Order Mode

    func cyclePlaybackOrderMode() {
        let nextRaw = (playbackOrderMode.rawValue + 1) % PlaybackOrderMode.allCases.count
        applyPlaybackOrderMode(PlaybackOrderMode(rawValue: nextRaw) ?? .sequential)
    }

    func applyPlaybackOrderMode(_ mode: PlaybackOrderMode) {
        // 这两个 @Published 无副作用，先直接置位
        isRepeating = false
        isLoopingSong = false

        switch mode {
        case .sequential:
            // 关随机 → 恢复原队列
            if isShuffled {
                toggleShuffle()
            }
        case .shuffle:
            // 开随机 → 保存原队列 + 重排
            if !isShuffled {
                toggleShuffle()
            }
        case .repeatAll:
            if isShuffled {
                toggleShuffle()
            }
            isRepeating = true
        case .repeatOne:
            if isShuffled {
                toggleShuffle()
            }
            isLoopingSong = true
        }
    }

    var playbackOrderMode: PlaybackOrderMode {
        if isShuffled {
            return .shuffle
        }
        if isLoopingSong {
            return .repeatOne
        }
        if isRepeating {
            return .repeatAll
        }
        return .sequential
    }

    func cycleLoopMode() {
        if !isRepeating && !isLoopingSong {
            // Off → Queue Loop
            isRepeating = true
            isLoopingSong = false
            print("🔁 Queue loop mode: ON")
        } else if isRepeating && !isLoopingSong {
            // Queue Loop → Song Loop
            isRepeating = false
            isLoopingSong = true
            print("🔂 Song loop mode: ON")
        } else {
            // Song Loop → Off
            isRepeating = false
            isLoopingSong = false
            print("🚫 Loop mode: OFF")
        }
    }

    func toggleShuffle() {
        isShuffled.toggle()
        print("🔀 Shuffle mode: \(isShuffled ? "ON" : "OFF")")

        if isShuffled {
            // Save original order and shuffle the queue
            originalQueue = playbackQueue.map { $0.stableId }
            shuffleQueue()
        } else {
            // Restore original order
            restoreOriginalQueue()
        }

        normalizeIndexAndTrack()
    }

    private func shuffleQueue() {
        guard !playbackQueue.isEmpty else { return }
        normalizeIndexAndTrack()
        let anchor = playbackQueue[currentIndex]
        var rest = playbackQueue
        rest.remove(at: currentIndex)
        rest.shuffle()
        playbackQueue = [anchor] + rest
        currentIndex = 0

        print("🔀 Queue shuffled, current track remains at index 0")
    }

    private func restoreOriginalQueue() {
        guard !originalQueue.isEmpty else { return }

        do {
            let restoredQueue = try databaseManager.getTracksByStableIdsPreservingOrder(originalQueue)
            guard !restoredQueue.isEmpty else { return }

            // 随机期间增删队列（addToQueue/insertNext 只改 playbackQueue）的曲目
            // 按 stableId 差集补回队尾，否则关闭随机时这些曲目消失
            // （2026-08-29 审计 #5）。
            let restoredIds = Set(restoredQueue.map { $0.stableId })
            let additions = playbackQueue.filter { !restoredIds.contains($0.stableId) }
            let mergedQueue = restoredQueue + additions

            // Find current track in merged queue
            if let currentTrack = self.currentTrack,
               let mergedIndex = mergedQueue.firstIndex(where: { $0.stableId == currentTrack.stableId }) {
                playbackQueue = mergedQueue
                currentIndex = mergedIndex
                print("🔀 Original queue restored, current track at index \(mergedIndex)" +
                    (additions.isEmpty ? "" : ", \(additions.count) shuffled-era additions kept"))
            } else {
                playbackQueue = mergedQueue
                currentIndex = min(currentIndex, max(0, mergedQueue.count - 1))
            }
        } catch {
            print("❌ Failed to restore original queue: \(error)")
        }

        normalizeIndexAndTrack()
    }
}
