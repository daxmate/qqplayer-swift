//
//  MacSyncSettingsView.swift
//  QQPlayer
//
//  局域网同步（S2, M1-UI；M6 T11 2026-09-12 收敛为**壳**；2026-09-26 批 B1 顶层两页）
//  macOS「设置 → 同步」分类。
//
//  内容全部在 `MacSyncCenterView`：本文件只负责**设置页外观**（`Form` +
//  `.formStyle(.grouped)`）与**默认页**。
//
//  2026-09-26 批 B1（用户拍板）：同步中心 = 顶层两页「设备 / 同步」，两份入口**允许不同组合**
//  （旧的「逐字一致」强制作废）——设置页给两页、**默认「设备」**（低频/配置面）；
//  主窗口工具栏「同步」面板用同一个 `MacSyncCenterView`，默认「同步」（操作入口）。
//
//  入口：MacSettingsView 左导航「同步」分类（最小侵入：仅加 category）。
//

import SwiftUI

/// macOS「设置 → 同步」分类（内容见 `MacSyncCenterView`，与工具栏面板共用）。
struct MacSyncSettingsView: View {
    var body: some View {
        MacSyncCenterView(initialPage: .device)
    }
}

#Preview {
    MacSyncSettingsView()
        .frame(width: 560, height: 640)
        // Preview 是组合根之外的第二个合法装配点（App 根注入不覆盖画布）→ 显式装配（批 6-8）。
        // 实例取自 `MacSyncPreviewEnvironment`（非视图层 helper）⇒ 视图文件里不留 `.shared` 直连。
        .environment(MacSyncPreviewEnvironment.hostCenter)
        .environment(MacSyncPreviewEnvironment.wiringFacts)
        .environment(MacSyncPreviewEnvironment.lyricsResendFacts)
}
