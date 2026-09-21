//
//  LibraryView+SyncFeedback.swift
//  QQPlayer
//
//  音乐库主页**同步反馈**：同步结果 toast（文案 / 图标 / 颜色按增删分级）与
//  统一同步入口 `runSync()`（索引进度等待 + 手动同步优先 + 结果反馈）。
//
//  2026-09-21 从 LibraryView.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Library/LibraryView.swift                     — 视图壳：stored property + `body` + 导入入口
//    · Views/Library/LibraryView+ImportSupport.swift       — 导入结果分桶 + 书签落库
//    · Views/Library/LibraryView+SectionRendering.swift    — 首页分区视图（homeSectionView）
//    · Views/Library/LibraryView+SyncFeedback.swift        — 同步反馈 toast + runSync
//    · Views/Library/LibraryView+SectionRow.swift          — 首页分区行（LibrarySectionRowView）
//    · Views/Library/LibraryView+ResponsiveFonts.swift     — View 响应式字号 helper
//
// target: ios-only（LibraryView 分片：消费端全在 iOS；Mac 侧为 MacLibraryView）

import SwiftUI

extension LibraryView {
    // Helper function to show sync feedback
    private func showSyncFeedback(trackCountBefore: Int, trackCountAfter: Int) {
        let trackDifference = trackCountAfter - trackCountBefore

        // Set appropriate message and icon based on changes
        if trackDifference > 0 {
            // New tracks added
            syncToastIcon = "plus.circle.fill"
            syncToastColor = .green
            if trackDifference == 1 {
                syncToastMessage = NSLocalizedString("sync_one_new_track", value: "1 new song found", comment: "")
            } else {
                syncToastMessage = String(format: NSLocalizedString("sync_multiple_new_tracks", value: "%d new songs found", comment: ""), trackDifference)
            }
        } else if trackDifference < 0 {
            // Tracks removed
            let deletedCount = abs(trackDifference)
            syncToastIcon = "minus.circle.fill"
            syncToastColor = .orange
            if deletedCount == 1 {
                syncToastMessage = NSLocalizedString("sync_one_track_deleted", value: "1 song removed", comment: "")
            } else {
                syncToastMessage = String(format: NSLocalizedString("sync_multiple_tracks_deleted", value: "%d songs removed", comment: ""), deletedCount)
            }
        } else {
            // No changes
            syncToastIcon = "checkmark.circle.fill"
            syncToastColor = .blue
            syncToastMessage = NSLocalizedString("sync_no_changes", value: "Library is up to date", comment: "")
        }

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

    /// 统一同步入口（按钮与下拉刷新共用）：isRefreshing 互斥 + 无忙等等待索引完成。
    /// 等待索引走 IndexingGate（唯一实现，带超时兜底）：索引异常时不会再永久卡住同步按钮。
    /// 分片：跨文件可见（原 private）
    func runSync() async {
        let outcome = await IndexingGate.waitUntilIdle(libraryIndexer)
        if outcome == .timedOut {
            AppLog.warn(.ui, "⏱️ LibrarySync: indexing wait timed out — proceeding without waiting")
        }

        // For pull-to-refresh, use manual sync if available, otherwise just refresh
        let result: (before: Int, after: Int)
        if let onManualSync = onManualSync {
            result = await onManualSync() // Full sync + refresh
        } else {
            result = await onRefresh()    // Just refresh
        }

        // Show feedback after sync/refresh is complete
        await MainActor.run {
            isRefreshing = false
            showSyncFeedback(trackCountBefore: result.before, trackCountAfter: result.after)
        }
    }
}
