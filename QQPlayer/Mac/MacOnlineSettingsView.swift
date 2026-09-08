//
//  MacOnlineSettingsView.swift
//  QQPlayer
//
//  设置「下载」分类（web 版 download 分类对齐，2026-09 C 组 + B2 批扩展）：
//  - 在线下载音质档位（网易云，web download.defaultQuality 对齐）
//  - 歌曲海音质（quarkQuality mp3/flac，web download.quarkQuality 对齐）
//  - 下载引擎（downloadEngine httpx/aria2；aria2 时追加 RPC 地址 + Secret）
//  - 限速 MB/s（downloadMaxSpeed，0=不限速；web download.maxSpeed 对齐）
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

            // 歌曲海音质（web quarkQuality：mp3 默认/flac；格式名不本地化）
            Section("settings_download_quark_quality".localized) {
                Picker("settings_download_quark_quality".localized, selection: $deleteSettings.quarkQuality) {
                    Text("MP3").tag("mp3")
                    Text("FLAC").tag("flac")
                }
                .labelsHidden()
                .onChange(of: deleteSettings.quarkQuality) { _ in
                    deleteSettings.save()
                }
            }

            // 下载引擎 + aria2 专属字段 + 限速（web download.engine/maxSpeed 对齐）
            Section {
                Picker("settings_download_engine".localized, selection: $deleteSettings.downloadEngine) {
                    Text("settings_download_engine_builtin".localized).tag("httpx")
                    Text("settings_download_engine_aria2".localized).tag("aria2")
                }
                .labelsHidden()
                .onChange(of: deleteSettings.downloadEngine) { _ in
                    deleteSettings.save()
                }
                Text("settings_download_engine_hint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if deleteSettings.downloadEngine == "aria2" {
                    TextField(
                        "settings_download_aria2_rpc".localized,
                        text: $deleteSettings.aria2Rpc,
                        prompt: Text("http://localhost:6800/jsonrpc")
                    )
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: deleteSettings.aria2Rpc) { _ in
                        deleteSettings.save()
                    }
                    SecureField(
                        "settings_download_aria2_secret".localized,
                        text: $deleteSettings.aria2Secret,
                        prompt: Text("settings_download_aria2_secret_placeholder".localized)
                    )
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: deleteSettings.aria2Secret) { _ in
                        deleteSettings.save()
                    }
                }

                TextField(
                    "settings_download_max_speed".localized,
                    value: $deleteSettings.downloadMaxSpeed,
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .onChange(of: deleteSettings.downloadMaxSpeed) { _ in
                    deleteSettings.save()
                }
            } header: {
                Text("settings_download_engine".localized)
            } footer: {
                Text("settings_download_max_speed_hint".localized)
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
