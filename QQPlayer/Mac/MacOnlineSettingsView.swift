//
//  MacOnlineSettingsView.swift
//  QQPlayer
//
//  设置「下载」分类（web 版 download 分类对齐，2026-09 C 组）：在线下载音质档位。
//  目录固定为曲库文件夹（默认 ~/Music/QQPlayer，附加目录在音乐库分类管理）——
//  落盘目录语义见 MacOnlineDownloadService。
//

import SwiftUI

struct MacOnlineSettingsView: View {
    @State private var deleteSettings = DeleteSettings.load()

    private let qualityOptions: [(value: String, labelKey: String)] = [
        ("standard", "settings_quality_standard"),
        ("exhigh", "settings_quality_exhigh"),
        ("lossless", "settings_quality_lossless"),
        ("hires", "settings_quality_hires"),
    ]

    var body: some View {
        Form {
            Section(Localized.settingsDownloadQuality) {
                Picker(Localized.settingsDownloadQuality, selection: $deleteSettings.onlineDownloadQuality) {
                    ForEach(qualityOptions, id: \.value) { option in
                        Text(option.labelKey.localized).tag(option.value)
                    }
                }
                .labelsHidden()
                .onChange(of: deleteSettings.onlineDownloadQuality) { _ in
                    deleteSettings.save()
                }
            }
            Section {
                Text("settings_download_hint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
            deleteSettings = DeleteSettings.load()
        }
    }
}
