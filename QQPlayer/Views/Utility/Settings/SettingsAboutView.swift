//
//  SettingsAboutView.swift
//  QQPlayer
// target: ios-only
//
//  设置 → 关于（原 SettingsView 的 information Section，2026-11-12 设置页分类化迁移）。
//  文案 / 取值来源 / 显示顺序与迁移前逐行一致。
//

import SwiftUI

struct SettingsAboutView: View {
    var body: some View {
        Form {
            Section(Localized.information) {
                HStack {
                    Text(Localized.version)
                    Spacer()
                    Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text(Localized.appName)
                    Spacer()
                    Text(Localized.qqplayerName)
                        .foregroundColor(.secondary)
                }

                Button(action: {
                    if let url = URL(string: "https://github.com/daxmate/qqplayer-ios") {
                        AppLog.info(.ui, "🔗 Opening URL: \(url)")
                        UIApplication.shared.open(url)
                    } else {
                        AppLog.error(.ui, "❌ Invalid GitHub URL")
                    }
                }) {
                    HStack {
                        Text(Localized.githubRepository)
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                            .font(.system(size: DesignTokens.font16))
                    }
                    .contentShape(Rectangle()) // Make entire area tappable
                }
                .buttonStyle(PlainButtonStyle()) // Remove default button styling that might interfere
            }
            .glassClearRowBackground()
        }
        // 封面毛玻璃底（分组底在玻璃生效时隐藏、未生效回落 .automatic，见 ArtworkGlassGroupedListModifier）
        .artworkGlassGroupedList {
            ScreenSpecificBackgroundView(screen: .library)
        }
        .navigationTitle(Localized.information)
        .navigationBarTitleDisplayMode(.inline)
        // 真透明导航栏（与库页面同款：背景让路给封面玻璃）
        .toolbarBackground(.clear, for: .navigationBar)
        .toolbarBackground(.clear, for: .automatic)
    }
}

#Preview {
    NavigationView {
        SettingsAboutView()
    }
}
