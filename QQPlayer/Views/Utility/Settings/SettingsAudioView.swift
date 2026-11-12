//
//  SettingsAudioView.swift
//  QQPlayer
// target: ios-only
//
//  设置 → 音频设置（原 SettingsView 的 audioSettings + playerControls 两个 Section，
//  2026-11-12 设置页分类化迁移）。文案 / 存储字段 / 默认值 / 显示顺序与迁移前逐行一致。
//

import SwiftUI

struct SettingsAudioView: View {
    @State private var deleteSettings = DeleteSettings.load()

    var body: some View {
        Form {
            Section(Localized.audioSettings) {
                NavigationLink(destination: EQSettingsView()) {
                    HStack {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundColor(.blue)
                            .font(.system(size: DesignTokens.font20))
                        Text(Localized.graphicEqualizer)
                    }
                }

                VStack(alignment: .leading, spacing: DesignTokens.space8) {
                    Text(Localized.dsdPlaybackMode)
                        .font(.headline)

                    Text(Localized.dsdPlaybackModeDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("", selection: $deleteSettings.dsdPlaybackMode) {
                        ForEach(DSDPlaybackMode.allCases, id: \.self) { mode in
                            VStack(alignment: .leading) {
                                Text(mode.displayName)
                                    .font(.body)
                            }
                            .tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: deleteSettings.dsdPlaybackMode) { _, _ in
                        deleteSettings.save()
                    }

                    Text(deleteSettings.dsdPlaybackMode.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, DesignTokens.space4)
                }
                .padding(.vertical, DesignTokens.space4)
            }

            Section(Localized.playerControls) {
                Toggle(Localized.showSleepTimerButton, isOn: $deleteSettings.showSleepTimerButton)
                    .onChange(of: deleteSettings.showSleepTimerButton) { _, _ in
                        deleteSettings.save()
                    }

                Text(Localized.showSleepTimerButtonDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(Localized.audioSettings)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView {
        SettingsAudioView()
    }
}
