//
//  MacLibraryView+SyncPanel.swift
//  QQPlayer
//
//  `MacLibraryView` 的同步面板（2026-09-21 从 `MacLibraryView.swift` 纯搬家，零行为/UI 变化）：
//  主窗口工具栏弹出的 sheet，内容完全复用设置页同一个 `MacSyncCenterView`；
//  sheet 高度受控（防 macOS 关闭 sheet 后主窗逐次下移）。
//
//  ⚠️ 可见性：被 `body` 或其它分区文件引用的成员为 internal（原 `private`）。
//
import AppKit
import SwiftUI

// MARK: - 同步面板（主窗口工具栏入口）

/// 主窗口工具栏弹出的同步面板。
///
/// 内容**完全复用**设置页同一个 `MacSyncCenterView`（M6 T11）——同步界面只允许一份
/// 实现，避免「设置里一套、主界面一套」的行为漂移（封面解析散落多处的教训）：
/// 待批准请求 / 本机身份与二维码 / 连接状态与局域网开关 / 同步两页 / 已配对设备，两处同源。
/// 同步只能由桌面端发起；方向与内容在面板内选择。
///
/// 2026-09-26 批 B1（用户拍板）：顶层两页「设备 / 同步」，两份入口**允许不同组合**
/// （旧的「逐字一致」强制作废）——面板是操作入口，**默认「同步」**，可切「设备」；
/// 设置页同为两页但默认「设备」。
///
/// ⚠️ sheet 尺寸**必须受控**（2026-09-14 用户反馈「关掉面板后主界面整体下移」）：
/// macOS 的 sheet 顶边锚在主窗顶边下方约 52pt（unified 工具栏）。只要 sheet 的底边
/// 超出屏幕底边，系统在**每次关闭 sheet 后**会把主窗永久下移「超出量」那么多
/// （实测 12pt/次、逐次累积，一度把主窗推到屏幕外）。最小复现 App 对照实验：
///   - 铺满屏幕的主窗 + 内容撑高的 sheet（620×909，底边超屏 12pt）→ 每轮下移 12pt
///   - 同窗口 + 高度受控的 sheet（620×700，底边在屏内）→ 零漂移
///   - 未铺满屏幕的主窗（sheet 完整落在屏内）→ 零漂移
/// 所以这里把高度钉在放得下的范围（内容由 `Form` 内部滚动承接），不让 sheet 超屏。
/// 分片：跨文件可见（原 private）
struct MacSyncPanel: View {
    @Environment(\.dismiss) private var dismiss

    /// 面板高度：屏幕可见高度 − 52（sheet 锚点偏移）− 24（底部余量），限 420…720。
    private static var sheetHeight: CGFloat {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame.height ?? 900
        return max(420, min(720, visible - 52 - 24))
    }

    var body: some View {
        VStack(spacing: DesignTokens.space0) {
            header

            Form {
                MacSyncCenterView(initialPage: .sync)
            }
            .formStyle(.grouped)
        }
        .frame(width: 620, height: Self.sheetHeight)
    }

    /// 与其它 Mac sheet 一致的标题栏：标题 + 关闭按钮（Esc 也可关）。
    /// 原先只有 `navigationTitle`——用户从工具栏打开面板后**没有任何关闭途径**
    /// （macOS 的 sheet 不会自动给关闭按钮，也没有默认 Esc 取消）。
    private var header: some View {
        HStack(spacing: DesignTokens.space12) {
            Text("sync_run_panel_title".localized)
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            Button("close".localized) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }
}
