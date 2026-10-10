//
//  LibraryView+SyncFeedback.swift
//  QQPlayer
//
//  音乐库主页**同步反馈 + 下拉刷新编排**：
//    · toast 唯一呈现点（`presentToast`）与结果分级（`showSyncFeedback`）；
//    · 下拉刷新唯一入口 `runPullToRefresh()`（无配对桌面端 → 跳过握手只刷新；
//      有配对 → 先握手连接再全库重扫 + 重读）。
//
//  2026-09-21 从 LibraryView.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Library/LibraryView.swift                     — 视图壳：stored property + `body` + 导入入口
//    · Views/Library/LibraryView+ImportSupport.swift       — 导入结果分桶 + 书签落库
//    · Views/Library/LibraryView+SectionRendering.swift    — 首页分区视图（homeSectionView）
//    · Views/Library/LibraryView+SyncFeedback.swift        — 同步反馈 toast + 下拉刷新入口
//    · Views/Library/LibraryView+SectionRow.swift          — 首页分区行（LibrarySectionRowView）
//    · Views/Library/LibraryView+ResponsiveFonts.swift     — View 响应式字号 helper
//
// target: ios-only（LibraryView 分片：消费端全在 iOS；Mac 侧为 MacLibraryView）

import SwiftUI

extension LibraryView {
    // MARK: - toast 唯一呈现点

    /// 同步反馈 toast 的**唯一**呈现点：设图标 / 颜色 / 文案 + 动画 + 3s 自动隐藏。
    /// 分级反馈（`showSyncFeedback`）与轻量提示都经此处，不各写一份。
    private func presentToast(message: String, icon: String, color: Color) {
        syncToastIcon = icon
        syncToastColor = color
        syncToastMessage = message

        withAnimation(.easeInOut(duration: 0.2)) {
            showSyncToast = true
        }

        // Auto-hide toast after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            withAnimation(.easeInOut(duration: 0.3)) {
                showSyncToast = false
            }
        }
    }

    /// 增删结果 → 分级 toast（文案 / 图标 / 颜色按增删分级）。
    private func showSyncFeedback(trackCountBefore: Int, trackCountAfter: Int) {
        let trackDifference = trackCountAfter - trackCountBefore

        let icon: String
        let color: Color
        let message: String

        // Set appropriate message and icon based on changes
        if trackDifference > 0 {
            // New tracks added
            icon = "plus.circle.fill"
            color = .green
            if trackDifference == 1 {
                message = NSLocalizedString("sync_one_new_track", value: "1 new song found", comment: "")
            } else {
                message = String(format: NSLocalizedString("sync_multiple_new_tracks", value: "%d new songs found", comment: ""), trackDifference)
            }
        } else if trackDifference < 0 {
            // Tracks removed
            let deletedCount = abs(trackDifference)
            icon = "minus.circle.fill"
            color = .orange
            if deletedCount == 1 {
                message = NSLocalizedString("sync_one_track_deleted", value: "1 song removed", comment: "")
            } else {
                message = String(format: NSLocalizedString("sync_multiple_tracks_deleted", value: "%d songs removed", comment: ""), deletedCount)
            }
        } else {
            // No changes
            icon = "checkmark.circle.fill"
            color = .blue
            message = NSLocalizedString("sync_no_changes", value: "Library is up to date", comment: "")
        }

        presentToast(message: message, icon: icon, color: color)
    }

    // MARK: - 下拉刷新唯一入口

    /// 首页下拉刷新唯一入口（`.refreshable` 调用）：
    /// - 无已配对桌面端（`refreshOnly`）→ 跳过握手，只重读本机曲库 + 轻提示；
    /// - 有已配对桌面端（`connectThenSync`）→ 先握手连接（成功 / 失败 / 超时有界），
    ///   **无条件**继续全库重扫 + 重读，再出既有结果 toast。
    ///
    /// isRefreshing 互斥由调用方（`.refreshable`）持有；本函数结束时复位。
    /// 分片：跨文件可见（原 private）
    func runPullToRefresh() async {
        let center = passiveSync
        let (plan, handshakeTimeout) = await MainActor.run {
            (
                LibraryPullToRefreshPlan.make(pairedHostCount: center.pairedHostCount),
                SyncAutoConnectController.discoveryTimeout
            )
        }

        switch plan {
        case .refreshOnly:
            // 无已配对桌面端：不碰网络，只重读本机曲库。
            // 等待索引的唯一实现是 IndexingGate（onRefresh 内部已走，不在此复述）。
            _ = await onRefresh()
            await MainActor.run {
                isRefreshing = false
                presentToast(
                    message: NSLocalizedString(
                        "sync_pull_no_paired_desktop",
                        value: "No paired desktop — refreshed this device's library",
                        comment: ""
                    ),
                    icon: "wifi.slash",
                    color: .secondary
                )
            }

        case .connectThenSync:
            // 握手有界等待（超时口径 = SyncAutoConnectController.discoveryTimeout）；
            // 结果（已连接 / 失败 / 超时）不阻塞后续重扫。
            _ = await center.connectAndWait(timeout: handshakeTimeout)

            let result: (before: Int, after: Int)
            if let onManualSync {
                result = await onManualSync() // 全库重扫 + 重读
            } else {
                result = await onRefresh() // 只重读
            }

            await MainActor.run {
                isRefreshing = false
                showSyncFeedback(trackCountBefore: result.before, trackCountAfter: result.after)
            }
        }
    }
}
