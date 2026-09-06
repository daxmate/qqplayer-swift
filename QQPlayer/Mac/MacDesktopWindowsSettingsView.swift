//
//  MacDesktopWindowsSettingsView.swift
//  QQPlayer
//
//  设置「迷你窗与桌面歌词」分类面板（E3→v2，QQPlayerMac target only）：
//  - 迷你窗入口开关（DeleteSettings.showMiniWindowButton）：开 = 主窗工具栏显示
//    「进入迷你模式」按钮；点击按钮进入迷你模式（主窗收起 + 迷你窗 + 桌面歌词）。
//    入口开关不直接开关窗口，窗口显隐是瞬态操作。
//  - 迷你模式歌词开关（DeleteSettings.miniLyricsEnabled）：迷你模式是否带桌面歌词
//    窗；与迷你窗内歌词按钮同源（设置页 ↔ mini 窗双向一致），状态记忆。
//  - 字号滑杆（desktopLyricFontSize，译文行字号按比例派生；译文行显示跟随「歌词」
//    分类的 lyricShowTranslation 开关——桌面歌词窗与歌词面板共用同一译文偏好）
//  - 存储：DeleteSettings v2 namespace，改动即 save() → .qqplayerSettingsDidChange
//    → DesktopWindowsManager.reconcile() 收敛歌词窗显隐 / 浮窗视图刷新字号
//
//  形态说明：v1 的分类是「桌面歌词」（开关×2 直接开窗 + 字号）；v2 用户拍板改为
//  主窗 ⇄ 迷你模式互斥后，桌面歌词只在迷你模式存在，分类收纳迷你入口 + 歌词偏好。
//
import SwiftUI

struct MacDesktopWindowsSettingsView: View {
    @State private var deleteSettings = DeleteSettings.load()

    var body: some View {
        Form {
            Section {
                Toggle("mini_window_button_enabled".localized, isOn: $deleteSettings.showMiniWindowButton)
                    .onChange(of: deleteSettings.showMiniWindowButton) { _ in
                        deleteSettings.save()
                    }
            } footer: {
                Text("mini_window_button_hint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Toggle("mini_lyrics_enabled".localized, isOn: $deleteSettings.miniLyricsEnabled)
                    .onChange(of: deleteSettings.miniLyricsEnabled) { _ in
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
