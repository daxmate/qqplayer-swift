//
//  SyncTracksPane.swift
//  QQPlayer
//
//  「同步」页（2026-09-26 批 B1「拆 Pane + 顶层两页」；QQPlayerMac target only）。
//
//  页面内容（用户 2026-09-26 拍板）：**顶部分段切换「传歌 / 播放数据」**，
//  两流**永不共用一屏** —— 同一时刻只渲染一个流（`switch flow`）。
//   · 传歌流（`tracksPane`）= 方向区 + 内容选择区 + 执行区 + 结果区（A 连接状态区已随设备语义
//     迁到「设备」页，见 `SyncDevicePane.swift`；R3「设备只讲一次」）
//   · 播放数据流（`dataPane`，见 `SyncDataPane.swift`）= 原 F 数据同步区（含跨端续播开关；R6）
//
//  纪律：本文件只做展示与分流；两个流各自的绑定/动作**沿用既有 model 调用**，语义零改变。
//
//  ⚠️ 为什么本 Pane 是 `MacSyncRunSection` 的 extension 而不是独立 struct：三个 ViewModel
//  仍是 `ObservableObject`，子视图要拿活的重绘就得写 `@ObservedObject`/`@StateObject` →
//  命中 `ObservationMigrationContractTests` 的「新增 (文件, 标记) 即红」棘轮。
//  extension 是唯一零新增标记、零行为改变的拆法（详见 `MacSyncView.swift` 文件头）。
//
//  可见性：`syncPage` / `tracksPane` / `dataPane` 为 internal（跨文件/被 `body` 引用）；
//  仅本文件使用的辅助成员为 `private`。
//

import SwiftUI

extension MacSyncRunSection {
    // MARK: - 「同步」页（分段：传歌 / 播放数据）

    var syncPage: some View {
        Group {
            flowPicker
            switch flow {
            case .tracks:
                tracksPane
            case .data:
                dataPane
            }
        }
    }

    /// 流分段控件。文案：新增 key `sync_flow_tracks`（五语已补）+ 既有 `sync_run_data_section`。
    private var flowPicker: some View {
        Picker("", selection: $flow) {
            Text("sync_flow_tracks".localized).tag(MacSyncFlow.tracks)
            Text("sync_run_data_section".localized).tag(MacSyncFlow.data)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// 传歌流：方向 / 内容选择 / 执行 / 结果（B C D E 四区，原样复用，语义不变）。
    var tracksPane: some View {
        Group {
            directionSection
            selectionSection
            runSection
            resultSection
        }
    }
}
