//
//  SyncTracksPane.swift
//  QQPlayer
//
//  「同步」页（2026-09-26 批 B1「拆 Pane + 顶层两页」；批 D 改为独立 `struct`；QQPlayerMac target only）。
//
//  页面内容（用户 2026-09-26 拍板）：**顶部分段切换「传歌 / 播放数据」**，
//  两流**永不共用一屏** —— 同一时刻只渲染一个流（`switch flow`）。
//   · 传歌流（`SyncTracksPane`）= 方向区 + 内容选择区 + 执行区 + 结果区（A 连接状态区已随设备
//     语义迁到「设备」页，见 `SyncDevicePane.swift`；R3「设备只讲一次」）
//   · 播放数据流（`SyncDataPane`，见 `SyncDataPane.swift`）= 原 F 数据同步区（含跨端续播开关；R6）
//
//  纪律：本文件只做分流与组合；两个流各自的分区本体/绑定/动作**沿用既有实现**，语义零改变。
//
//  ⚠️ 批 D（2026-09-26）为什么 Pane 是**独立 struct**：三个 ViewModel 仍是
//  `ObservableObject`（`@Observable` 迁移尚未覆盖），子视图**不得**写
//  `@ObservedObject` / `@StateObject`（`ObservationMigrationContractTests` 是「新增
//  (文件, 标记) 即红」的棘轮）。做法 = **父 = 唯一观察者**：状态与 ViewModel 生命周期
//  **全在 `MacSyncRunSection`**；本 struct 只收「值输入 + 回调 / 绑定」（父 body 重算 ⇒
//  子拿到新值即重绘）。本文件内**零** `@ObservedObject` / `@StateObject` / `@EnvironmentObject`。
//
//  ⚠️ 分区本体仍留在 `MacSyncRunSection` 的分区文件里（`+Connection` 方向区 / `+Content`
//  内容区 / `+Run` 执行区与结果区）—— 它们仍以**父的成员**身份被构建（父读值、父持有绑定），
//  再作为**内容输入**交给 `SyncTracksPane` 组合（唯一职责 = 组合，不复制任何分区实现）。
//
//  可见性：`SyncPage` / `SyncTracksPane` 为 internal（被 `MacSyncView.swift` 装配）。
//

import SwiftUI

/// 「同步」页（分段：传歌 / 播放数据）。输入全部来自 `MacSyncRunSection`（唯一观察者）。
struct SyncPage<TracksPane: View, DataPane: View>: View {
    /// 「同步」页当前流（传歌 / 播放数据）——状态仍在父，这里只以绑定读写。
    @Binding var flow: MacSyncFlow
    /// 传歌流（`SyncTracksPane`，由父构建并传入）。
    let tracksPane: TracksPane
    /// 播放数据流（`SyncDataPane`，由父构建并传入）。
    let dataPane: DataPane

    var body: some View {
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
}

/// 传歌流：方向 / 内容选择 / 执行 / 结果（B C D E 四区，原样复用，语义不变）。
/// 四个分区本体由 `MacSyncRunSection`（及其分区文件）构建后作为内容输入传入——本类型只做组合。
struct SyncTracksPane<Direction: View, Selection: View, Run: View, Result: View>: View {
    /// B 方向区（`MacSyncView+Connection.swift`）。
    let directionSection: Direction
    /// C 内容选择区（`MacSyncView+Content.swift`）。
    let selectionSection: Selection
    /// D 执行区（`MacSyncView+Run.swift`）。
    let runSection: Run
    /// E 结果区（`MacSyncView+Run.swift`）。
    let resultSection: Result

    var body: some View {
        Group {
            directionSection
            selectionSection
            runSection
            resultSection
        }
    }
}
