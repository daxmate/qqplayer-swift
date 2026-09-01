//
//  MacSettingsView.swift
//  QQPlayer
//
//  macOS settings sheet (对齐 iOS SettingsView，按 macOS sheet 惯例实现)：
//  外观（强制深色）、音频（Graphic EQ 入口）、播放控制（歌词/睡眠定时器
//  按钮开关）、信息（版本/应用名/GitHub）。QQPlayerMac target only。
//

import AppKit
import SwiftUI

struct MacSettingsView: View {
    @State private var deleteSettings = DeleteSettings.load()
    @State private var showEQSettings = false

    var body: some View {
        Form {
            appearanceSection
            audioSection
            playerControlsSection
            informationSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
        .sheet(isPresented: $showEQSettings) {
            MacEQSettingsView()
        }
        // 与 MacLibraryView 工具栏月亮按钮双向同步：任何一处写入
        // DeleteSettings 都会发 .qqplayerSettingsDidChange，这里重读。
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            deleteSettings = DeleteSettings.load()
        }
    }

    // MARK: - Sections

    private var appearanceSection: some View {
        Section(Localized.appearance) {
            Toggle(Localized.forceDarkMode, isOn: $deleteSettings.forceDarkMode)
                .onChange(of: deleteSettings.forceDarkMode) { _ in
                    deleteSettings.save()
                }
        }
    }

    private var audioSection: some View {
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
    }

    private var playerControlsSection: some View {
        Section(Localized.playerControls) {
            Toggle(Localized.showLyricsButton, isOn: $deleteSettings.showLyricsButton)
                .onChange(of: deleteSettings.showLyricsButton) { _ in
                    deleteSettings.save()
                }

            Toggle(Localized.showSleepTimerButton, isOn: $deleteSettings.showSleepTimerButton)
                .onChange(of: deleteSettings.showSleepTimerButton) { _ in
                    deleteSettings.save()
                }
        }
    }

    private var informationSection: some View {
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
}

#Preview {
    MacSettingsView()
}
