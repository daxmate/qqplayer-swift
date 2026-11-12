//
//  SettingsView.swift
//  QQPlayer
//
//  iOS 设置首页（齿轮 → sheet）。
//  2026-11-12 设置页分类化（用户拍板 A 方案）：原「一个 Form 平铺约 10 个 Section」
//  改为分类入口列表，每类进独立子页（两下即达）；外层 NavigationView / sheet 形态、
//  齿轮入口（LibraryView）、Done 按钮与底部安全区留白均不变。
//  各分类页内容见 Views/Utility/Settings/。
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    NavigationLink(destination: SettingsAppearanceView()) {
                        SettingsCategoryRow(
                            title: Localized.appearance,
                            systemImage: "paintbrush.fill",
                            tint: .blue
                        )
                    }

                    NavigationLink(destination: SettingsAudioView()) {
                        SettingsCategoryRow(
                            title: Localized.audioSettings,
                            systemImage: "waveform",
                            tint: .purple
                        )
                    }

                    NavigationLink(destination: SettingsLyricsView()) {
                        SettingsCategoryRow(
                            title: Localized.lyricsDisplay,
                            systemImage: "text.quote",
                            tint: .indigo
                        )
                    }

                    NavigationLink(destination: SettingsLibraryView()) {
                        SettingsCategoryRow(
                            title: Localized.librarySection,
                            systemImage: "books.vertical.fill",
                            tint: .orange
                        )
                    }

                    // S2 M1-UI：局域网同步设置（Client 侧：主机列表/扫码/手输配对）
                    NavigationLink(destination: SyncSettingsView()) {
                        SettingsCategoryRow(
                            title: "sync_settings".localized,
                            systemImage: "arrow.triangle.2.circlepath",
                            tint: .green
                        )
                    }
                }

                Section {
                    NavigationLink(destination: FeatureGuideView()) {
                        SettingsCategoryRow(
                            title: Localized.featureGuide,
                            systemImage: "hand.point.up.left.fill",
                            tint: .teal
                        )
                    }

                    NavigationLink(destination: SettingsAboutView()) {
                        SettingsCategoryRow(
                            title: Localized.information,
                            systemImage: "info.circle.fill",
                            tint: .gray
                        )
                    }
                }
            }
            .listStyle(.insetGrouped)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 100)
            }
            .navigationTitle(Localized.settings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(Localized.done) {
                        dismiss()
                    }
                }
            }
        }
    }
}

/// 设置分类入口行：圆角方形图标底（半透明色）+ SF Symbol + 主标题。
/// 跳转箭头由 List 里的 NavigationLink 自带（视觉对齐 iOS 系统设置）。
private struct SettingsCategoryRow: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: DesignTokens.space12) {
            Image(systemName: systemImage)
                .font(.system(size: DesignTokens.font15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: DesignTokens.radius6, style: .continuous)
                        .fill(tint.opacity(0.16))
                )

            Text(title)
        }
    }
}

#Preview {
    SettingsView()
}
