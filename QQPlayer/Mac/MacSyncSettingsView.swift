//
//  MacSyncSettingsView.swift
//  QQPlayer
//
//  局域网同步（S2, M1-UI；M6 T11 2026-09-12 收敛为**壳**）macOS「设置 → 同步」分类。
//
//  内容全部在 `MacSyncCenterView`：本文件只负责**设置页外观**（`Form` +
//  `.formStyle(.grouped)`）。主窗口工具栏「同步」面板渲染同一个
//  `MacSyncCenterView`——**同步中心只允许一份实现**，两处内容永远一致。
//
//  入口：MacSettingsView 左导航「同步」分类（最小侵入：仅加 category）。
//

import SwiftUI

/// macOS「设置 → 同步」分类（内容见 `MacSyncCenterView`，与工具栏面板共用）。
struct MacSyncSettingsView: View {
    var body: some View {
        Form {
            MacSyncCenterView()
        }
        .formStyle(.grouped)
    }
}

#Preview {
    MacSyncSettingsView()
        .frame(width: 560, height: 640)
}
