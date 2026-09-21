//
//  LibraryView+SectionRow.swift
//  QQPlayer
//
//  音乐库主页**分区行**：图标 + 标题 + 副标题 + 计数徽标的通用行视图
//  （`LibrarySectionRowView`，被 `homeSectionView` 的每个分区入口复用）。
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

struct LibrarySectionRowView: View {
    /// App 强调色（读环境值；根注入见 ContentView / QQPlayerMacApp）
    @Environment(\.appAccentColor) private var accentColor
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    @State private var settings = DeleteSettings.load()

    var body: some View {
        HStack(spacing: DesignTokens.space16) {
            // Icon
            if settings.minimalistIcons {
                Image(systemName: icon)
                    .font(.system(size: DesignTokens.font24, weight: .medium))
                    .foregroundColor(.primary)
                    .frame(width: 60, height: 60)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignTokens.radius12)
                        .fill(color.opacity(0.2))
                        .frame(width: 60, height: 60)

                    Image(systemName: icon)
                        .font(.system(size: DesignTokens.font24, weight: .medium))
                        .foregroundColor(color)
                }
            }

            // Text content
            VStack(alignment: .leading, spacing: DesignTokens.space4) {
                Text(title)
                    .responsiveSectionTitleFont()
                    .foregroundColor(.primary)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Chevron
            Image(systemName: "chevron.right")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, DesignTokens.space20)
        .padding(.vertical, DesignTokens.space16)
        .background(
            // Glassy background that reflects gradient
            RoundedRectangle(cornerRadius: DesignTokens.radius12)
                .fill(.ultraThinMaterial)
                .opacity(0.8)
        )
        .cornerRadius(DesignTokens.radius12)
        .shadow(color: accentColor.opacity(0.15), radius: 4, x: 0, y: 2)
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            settings = DeleteSettings.load()
        }
    }
}
