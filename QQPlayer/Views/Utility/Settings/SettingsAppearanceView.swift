//
//  SettingsAppearanceView.swift
//  QQPlayer
// target: ios-only
//
//  设置 → 外观（原 SettingsView 的 appearance Section，2026-11-12 设置页分类化迁移）。
//  文案 / 存储字段 / 默认值 / 显示顺序与迁移前逐行一致。
//

import SwiftUI

struct SettingsAppearanceView: View {
    @State private var deleteSettings = DeleteSettings.load()

    var body: some View {
        Form {
            Section(Localized.appearance) {
                Toggle(Localized.minimalistLibraryIcons, isOn: $deleteSettings.minimalistIcons)
                    .onChange(of: deleteSettings.minimalistIcons) { _, _ in
                        deleteSettings.save()
                    }

                Text(Localized.useSimpleIcons)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Toggle(Localized.forceDarkMode, isOn: $deleteSettings.forceDarkMode)
                    .onChange(of: deleteSettings.forceDarkMode) { _, _ in
                        deleteSettings.save()
                    }

                Text(Localized.overrideSystemAppearance)
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: DesignTokens.space12) {
                    // 标题用「强调色」（2026-09-17）：与 macOS 设置页同一语义、同写
                    // 唯一字段 accentColorName，两端不该两个措辞。
                    Text(Localized.accentColor)
                        .font(.headline)

                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                    ], spacing: DesignTokens.space16) {
                        ForEach(IOSAppearance.accentPresets, id: \.key) { preset in
                            Button(action: {
                                // 唯一配色字段（2026-09-17 字段层收口）：写 token。
                                // save() 本身已发 .qqplayerSettingsDidChange（设置变更唯一信号）——
                                // 不再补发第二个「配色变更」事件（.backgroundColorChanged 已退役）。
                                deleteSettings.accentColorName = preset.key
                                deleteSettings.save()
                            }) {
                                ZStack {
                                    Circle()
                                        .fill(IOSAppearance.accentColor(forKey: preset.key))
                                        .frame(width: 44, height: 44)
                                        .overlay(
                                            Circle()
                                                .stroke(deleteSettings.accentColorName == preset.key ? Color.primary : Color.clear, lineWidth: 3)
                                        )

                                    if deleteSettings.accentColorName == preset.key {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: DesignTokens.font16, weight: .bold))
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                }

                Text(Localized.chooseColorTheme)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(Localized.appearance)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView {
        SettingsAppearanceView()
    }
}
