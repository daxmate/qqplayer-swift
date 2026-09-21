//
//  PlayerView+PlaybackSupport.swift
//  QQPlayer
//
//  播放页**非 UI 支撑**：睡眠定时（启动 / 取消）、曲库全量加载、收藏状态查询，
//  以及 AirPlay 路由选择器的程序化弹出。
//
//  2026-09-21 从 PlayerView.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Player/PlayerView.swift                   — 视图壳：stored property + body 装配
//    · Views/Player/PlayerView+Artwork.swift           — 封面区视图 / 手势 / 封面加载
//    · Views/Player/PlayerView+TitleAndLyrics.swift    — 标题/歌手/收藏按钮、小歌词窗
//
// target: ios-only（PlayerView 分片：消费端全在 iOS；Mac 侧为 MacPlayerView）
//
import AVKit
import SwiftUI

extension PlayerView {
    // MARK: - Helper Functions

    /// 分片：跨文件可见（原 private）
    func startSleepTimer(minutes: Int) {
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

    /// 分片：跨文件可见（原 private）
    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerEndDate = nil
    }

    /// 分片：跨文件可见（原 private）
    @MainActor
    func loadTracks() async {
        do {
            allTracks = try appCoordinator.getAllTracks()
            AppLog.info(.ui, "✅ Loaded \(allTracks.count) tracks for artist navigation")
        } catch {
            AppLog.error(.ui, "❌ Failed to load tracks: \(error)")
        }
    }

    /// 分片：跨文件可见（原 private）
    func checkFavoriteStatus() {
        guard let currentTrack = playerEngine.currentTrack else {
            isFavorite = false
            return
        }

        do {
            isFavorite = try LibraryReads.isFavorite(trackStableId: currentTrack.stableId)
        } catch {
            AppLog.error(.ui, "Failed to check favorite status: \(error)")
            isFavorite = false
        }
    }

    /// 弹出系统 AirPlay 路由选择器。
    /// 上游遗留：离屏创建的 AVRoutePickerView 未加入 window 层级时 subviews 为空，
    /// 遍历找不到内部 UIButton → 弹窗静默失效且无降级。
    /// 现改为触发常驻视图层级的 RoutePickerHost（内部按钮已随布局加载），
    /// 递归查找按钮并模拟点击；仍失败时打日志便于定位（系统版本可能变化）。
    /// 分片：跨文件可见（原 private）
    func showAirPlayPicker() {
        guard let picker = routePickerView else {
            // 理论上不会发生：按钮只在 PlayerView 挂载后可见
            AppLog.warn(.ui, "⚠️ AirPlay: route picker 未挂载，无法弹出选择器")
            return
        }
        if let button = Self.routePickerButton(in: picker) {
            button.sendActions(for: .touchUpInside)
        } else {
            AppLog.warn(.ui, "⚠️ AirPlay: 未找到 route picker 内部按钮（系统版本可能变化）")
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
