//
//  MacDesktopWindowsSettingsView.swift
//  QQPlayer
//
//  设置「桌面歌词」分类面板（E3，web 迷你窗/桌面歌词语义移植；QQPlayerMac target only）：
//  - 迷你窗开关（DeleteSettings.miniWindowEnabled）
//  - 桌面歌词开关（DeleteSettings.desktopLyricEnabled）+ 字号滑杆
//    （desktopLyricFontSize，译文行字号按比例派生；译文行显示跟随「歌词」分类的
//     lyricsShowTranslation 开关——桌面歌词窗与歌词面板共用同一译文偏好）
//  - 存储：DeleteSettings E3 namespace，改动即 save() → .qqplayerSettingsDidChange
//    → DesktopWindowsManager.reconcile() 收敛窗口显隐 / 浮窗视图刷新字号
//  - 分类形态说明：web 语义中桌面歌词设置散在「歌词/播放」设置组、迷你窗开关在顶栏按钮，
//    无独立分类；v1 任务拍板收进新分类「桌面歌词」（开关×2 + 字号），待用户确认。
//
import SwiftUI

struct MacDesktopWindowsSettingsView: View {
    @State private var deleteSettings = DeleteSettings.load()

    var body: some View {
        Form {
            Section {
                Toggle("mini_window_enabled".localized, isOn: $deleteSettings.miniWindowEnabled)
                    .onChange(of: deleteSettings.miniWindowEnabled) { _ in
                        deleteSettings.save()
                    }
            } footer: {
                Text("mini_window_enabled_hint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("desktop_lyric_enabled".localized, isOn: $deleteSettings.desktopLyricEnabled)
                    .onChange(of: deleteSettings.desktopLyricEnabled) { _ in
                        deleteSettings.save()
                    }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("desktop_lyric_font_size".localized)
                        Spacer()
                        Text("\(Int(deleteSettings.desktopLyricFontSize))pt")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $deleteSettings.desktopLyricFontSize, in: 18 ... 40, step: 1)
                        .onChange(of: deleteSettings.desktopLyricFontSize) { _ in
                            deleteSettings.save()
                        }
                }
            } footer: {
                Text("desktop_lyric_translation_hint".localized)
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
