//
//  LibraryView+ResponsiveFonts.swift
//  QQPlayer
//
//  视图层**响应式字号 helper**：标题 / 分区标题的单行 + 缩放适配
//  （`View` 扩展，供音乐库主页与其分片复用）。
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

// MARK: - Responsive Font Helper
extension View {
    func responsiveLibraryTitleFont() -> some View {
        self.font(.title)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .fontWeight(.bold)
    }

    func responsiveSectionTitleFont() -> some View {
        self.font(.title2)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .fontWeight(.semibold)
    }
}
