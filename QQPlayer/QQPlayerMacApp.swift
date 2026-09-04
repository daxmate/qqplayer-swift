//  QQPlayerMacApp.swift
//  QQPlayer
//
//  macOS app entry point (QQPlayerMac target only). The iOS app uses
//  QQPlayerApp.swift as its @main; this file must stay out of the iOS
//  QQPlayer target to avoid duplicate @main declarations.
//
import SwiftUI

@main
struct QQPlayerMacApp: App {
    @State private var deleteSettings = DeleteSettings.load()

    init() {
        // 诊断基建：stderr + stdout 重定向落盘（print 走 stdout，Swift fatal 走 stderr），
        // 运行时报错/业务日志可离线读取（~/Library/Logs/QQPlayerMac/{stdout,stderr}.log）
        MacScanLogger.redirectStderr()
        MacScanLogger.redirectStdout()
    }

    var body: some Scene {
        WindowGroup {
            MacLibraryView()
                // macOS 26 (Tahoe) 上 unified 工具栏默认透明，sidebar 内容会延伸到
                // 标题栏区域、第一行与交通灯重叠。强制工具栏背景不透明后内容从标题栏下方开始。
                .toolbarBackground(.visible, for: .windowToolbar)
                // 强调色：对齐 web 版 ACCENT_OPTIONS 预设，设置页切换后全局生效
                .tint(MacAppearance.accentColor(forKey: deleteSettings.accentColorName))
                .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
                    deleteSettings = DeleteSettings.load()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        // 设置：系统 Settings scene → App 菜单自动出现「Settings…」(⌘,)，
        // 打开独立设置窗口（macOS 惯例；主窗口 toolbar 不放设置按钮）
        Settings {
            MacSettingsView()
                .tint(MacAppearance.accentColor(forKey: deleteSettings.accentColorName))
        }
        // search anything（C 组②）：⌘K 唤起全屏搜索层（web SearchAnything 快捷键同键）
        .commands {
            CommandGroup(after: .toolbar) {
                Button {
                    MacSearchAnythingState.shared.isOpen.toggle()
                } label: {
                    Text("search_any_menu".localized)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
    }
}
