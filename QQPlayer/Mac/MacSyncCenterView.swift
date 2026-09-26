//
//  MacSyncCenterView.swift
//  QQPlayer
//
//  局域网同步（S2, M6 T11, 2026-09-12；2026-09-26 批 B1 收敛为**壳**）macOS「同步中心」入口：
//  两个入口共用同一个 View 类型 ——
//  ①「设置 → 同步」（`MacSyncSettingsView`）② 主窗口工具栏「同步」面板
//  （`MacLibraryView.MacSyncPanel`）。**同步中心只允许一份实现**，不存在第二份
//  （「设置里一套、主界面一套」的行为漂移是封面解析散落多处的老教训）。
//
//  2026-09-26 批 B1「拆 Pane + 顶层两页」后本文件只剩三件事：
//   ① `Form` 壳（`.formStyle(.grouped)`）；② 默认页（`initialPage`）；③ `SyncQRImageFactory`。
//  内容（顶层两页 + 三块 Pane + 全部状态）都在 `MacSyncRunSection`（`MacSyncView.swift`
//  及其分区文件）里 —— 装配点唯一，两个入口只是**默认页不同**：
//   · 设置页 = 「设备 + 同步」两页，默认「设备」
//   · 工具栏面板 = 同样两页，默认「同步」（操作入口）
//  （用户 2026-09-26 拍板：设置页与工具栏面板**允许不同组合**，打破旧的「逐字一致」强制。）
//
//  ⚠️ 状态归属：拆分后所有 `@State` / `@StateObject` 都在 `MacSyncRunSection`（唯一观察者），
//  本壳自己**不持有状态** ⇒ 页切换不卸载观察者、ViewModel 生命周期与拆分前一致。
//
//  ⚠️ 历史（2026-09-18 前）：曾要求「macOS 13 兼容：不使用 macOS 14+ API（`onChange` 单参数闭包、
//  不用 `ContentUnavailableView`）」。同日部署目标提到 14.0，此约束解除。
//

import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import SwiftUI

/// macOS 同步中心（设置页「同步」分类 + 工具栏同步面板共用）。
struct MacSyncCenterView: View {
    /// 默认顶层页（2026-09-26 批 B1）：设置页传 `.device`，工具栏面板传 `.sync`。
    var initialPage: MacSyncPage = .device
    /// S2 接线：App 级 Host 监听中心（**同一个 shared 实例**，生命周期不归本视图）。
    /// 2026-09-20 批 6-8：迁 `@Observable` ⇒ 组合根环境注入；这里只把它转交给内容视图
    /// （`MacSyncRunSection` 的 init 读不到环境值，用它建三个 view model）。
    @Environment(SyncHostCenter.self) private var hostCenter

    var body: some View {
        Form {
            MacSyncRunSection(hostCenter: hostCenter, initialPage: initialPage)
        }
        .formStyle(.grouped)
    }
}

/// QR 码生成（CoreImage CIQRCodeGenerator，无新依赖；仅 macOS 展示用）。
enum SyncQRImageFactory {
    /// JSON 文本 → NSImage（4px/模块缩放到 ~520px 展示清晰）。
    static func make(from text: String, scale: CGFloat = 4) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

#Preview {
    MacSyncCenterView(initialPage: .device)
        .frame(width: 560, height: 640)
        // Preview 是组合根之外的第二个合法装配点（App 根注入不覆盖画布）→ 显式装配（批 6-8）。
        // 实例取自 `MacSyncPreviewEnvironment`（非视图层 helper）⇒ 视图文件里不留 `.shared` 直连。
        .environment(MacSyncPreviewEnvironment.hostCenter)
        .environment(MacSyncPreviewEnvironment.wiringFacts)
        .environment(MacSyncPreviewEnvironment.lyricsResendFacts)
}
