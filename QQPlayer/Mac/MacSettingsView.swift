//
//  MacSettingsView.swift
//  QQPlayer
//
//  macOS settings（对齐 web 版「左侧分类导航 + 右侧内容区」布局；macOS
//  13+ Settings scene 内的 TabView 自动渲染成系统设置式左侧导航）。
//  分类：播放（EQ/睡眠定时器按钮）、界面（主题三态/强调色）、关于。
//  QQPlayerMac target only。
//

import AppKit
import SwiftUI

struct MacSettingsView: View {
    /// 设置分类（web 版左导航语义；后续加音乐库/歌词/快捷键等分类时在此扩展）
    private enum SettingsCategory: String, CaseIterable, Hashable {
        case playback
        case appearance
        case about

        var title: String {
            switch self {
            case .playback: return Localized.settingsCategoryPlayback
            case .appearance: return Localized.settingsCategoryAppearance
            case .about: return Localized.settingsCategoryAbout
            }
        }

        var icon: String {
            switch self {
            case .playback: return "play.circle"
            case .appearance: return "paintbrush"
            case .about: return "info.circle"
            }
        }
    }

    @State private var selectedCategory: SettingsCategory = .playback
    @State private var deleteSettings = DeleteSettings.load()
    @State private var showEQSettings = false

    var body: some View {
        // 左侧分类导航 + 右侧内容区（web 版布局；分类多了比顶部 tab 更合理）
        HStack(spacing: 0) {
            List(SettingsCategory.allCases, id: \.self, selection: $selectedCategory) { category in
                Label(category.title, systemImage: category.icon)
                    .tag(category)
            }
            .listStyle(.sidebar)
            .frame(width: 220)

            Divider()

            Group {
                switch selectedCategory {
                case .playback:
                    MacPlaybackSettingsView(showEQSettings: $showEQSettings)
                case .appearance:
                    MacAppearanceSettingsView()
                case .about:
                    MacAboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 620, minHeight: 420)
        .sheet(isPresented: $showEQSettings) {
            MacEQSettingsView()
        }
        // 与 MacLibraryView 双向同步：任何一处写入 DeleteSettings 都会发
        // .qqplayerSettingsDidChange，这里重读。
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            deleteSettings = DeleteSettings.load()
        }
    }
}

// MARK: - 播放

/// 播放分类：音频（EQ 入口）、播放控制（睡眠定时按钮开关）。
private struct MacPlaybackSettingsView: View {
    @Binding var showEQSettings: Bool

    @State private var deleteSettings = DeleteSettings.load()

    var body: some View {
        Form {
            Section(Localized.audioSettings) {
                Button {
                    showEQSettings = true
                } label: {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(.blue)
                            .font(.system(size: 16))
                        Text(Localized.graphicEqualizer)
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Section(Localized.playerControls) {
                Toggle(Localized.showSleepTimerButton, isOn: $deleteSettings.showSleepTimerButton)
                    .onChange(of: deleteSettings.showSleepTimerButton) { _ in
                        deleteSettings.save()
                    }
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            deleteSettings = DeleteSettings.load()
        }
    }
}

// MARK: - 界面

/// 界面分类：外观主题三态（跟随系统/深色/浅色）+ 强调色 6 预设。
private struct MacAppearanceSettingsView: View {
    @State private var deleteSettings = DeleteSettings.load()

    /// 当前生效主题（含旧数据迁移推导），Picker 绑定。
    private var theme: AppearanceTheme {
        AppearanceTheme.resolved(
            raw: deleteSettings.appearanceTheme,
            forceDarkMode: deleteSettings.forceDarkMode
        )
    }

    var body: some View {
        Form {
            Section(Localized.appearanceTheme) {
                Picker(Localized.appearanceTheme, selection: themeBinding) {
                    Text(Localized.themeSystem).tag(AppearanceTheme.system)
                    Text(Localized.themeDark).tag(AppearanceTheme.dark)
                    Text(Localized.themeLight).tag(AppearanceTheme.light)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Section(Localized.accentColor) {
                HStack(spacing: 14) {
                    ForEach(MacAppearance.accentPresets, id: \.key) { preset in
                        accentSwatch(preset)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            deleteSettings = DeleteSettings.load()
        }
    }

    private var themeBinding: Binding<AppearanceTheme> {
        Binding(
            get: { theme },
            set: { newTheme in
                var settings = deleteSettings
                settings.appearanceTheme = newTheme.rawValue
                settings.forceDarkMode = newTheme == .dark
                settings.save()
                deleteSettings = settings
            }
        )
    }

    private func accentSwatch(_ preset: (key: String, color: Color)) -> some View {
        let isSelected = deleteSettings.accentColorName == preset.key
        return Button {
            var settings = deleteSettings
            settings.accentColorName = preset.key
            settings.save()
            deleteSettings = settings
        } label: {
            ZStack {
                Circle()
                    .fill(preset.color)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.gray.opacity(0.3),
                                lineWidth: isSelected ? 3 : 1
                            )
                    )
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                }
            }
        }
        .buttonStyle(.plain)
        .help(Localized.accentName(preset.key))
    }
}

// MARK: - 关于

/// 关于分类：版本 / 应用名 / GitHub。
private struct MacAboutSettingsView: View {
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

                Button {
                    if let url = URL(string: "https://github.com/daxmate/qqplayer-swift") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack {
                        Text(Localized.githubRepository)
                            .foregroundColor(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary)
                            .font(.system(size: 14))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    MacSettingsView()
}
