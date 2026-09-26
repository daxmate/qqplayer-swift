//
//  SyncDataPane.swift
//  QQPlayer
//
//  播放数据流（2026-09-26 批 B1「拆 Pane + 顶层两页」；批 D 改为独立 `struct`；QQPlayerMac target only）——
//  原 `MacSyncView+Run.swift` 的 **F 数据同步区**整体迁到本文件（内容零改动，只换文件）。
//
//  为什么单列一 Pane：「同步」页顶部分段切换「传歌 / 播放数据」，两流**永不共用一屏**
//  （用户 2026-09-26 拍板）。本 Pane = 播放数据流：收藏 / 播放历史 / 歌单结构的独立动作入口
//  ——与文件传输无关（不选方向、不选歌），一次 = 推本端增量 + 拉对端增量；
//  驱动与账目全在 `MacSyncDataViewModel` + `SyncDataSyncCoordinator`（共享 Core）。
//
//  R6「长期开关归设置」：跨端续播开关（`sync_run_playback_position_toggle`）留在本流内。
//  R4「不得回退批 A 的折叠行为」：数据同步结果「结论行常显 + 明细进「详情」」逐字保留。
//
//  ⚠️ 批 B2（2026-09-26）：本流的两个动作都盯**所选设备**（选中设备 = 唯一合法同步目标）——
//  「同步数据」按钮过 `SyncUIStartGate.dataSyncAvailability`（目标离线即禁用）；
//  「重新对账」把所选设备 ID 显式传给 `MacSyncDataViewModel.resetCursorsForPeer(_:)`。
//  两者都不是本视图的判断（决策在共享 Core 的纯逻辑里）。
//
//  ⚠️ 批 D（2026-09-26）为什么 Pane 是**独立 struct**：三个 ViewModel 仍是
//  `ObservableObject`（`@Observable` 迁移尚未覆盖），子视图**不得**写
//  `@ObservedObject` / `@StateObject`（`ObservationMigrationContractTests` 是「新增
//  (文件, 标记) 即红」的棘轮）。做法 = **父 = 唯一观察者**：状态与 ViewModel 生命周期
//  **全在 `MacSyncRunSection`**；本 struct 只收「值输入 + 回调 / 绑定」，父 body 重算 ⇒
//  子拿到新值即重绘（需要写回的 `@State` 以 `@Binding` 下传，状态不搬家）。
//  本文件内**零** `@ObservedObject` / `@StateObject` / `@EnvironmentObject`。
//
//  可见性：`SyncDataPane` 为 internal（被 `MacSyncView.swift` 装配进「同步」页）；
//  仅本文件使用的辅助成员保持 `private`。
//

import SwiftUI

/// 播放数据流（收藏 / 播放历史 / 歌单结构）。输入全部来自 `MacSyncRunSection`（唯一观察者）。
struct SyncDataPane: View {
    /// 数据同步侧（阶段 / 进度 / 账目 / 闸门）。
    let dataModel: MacSyncDataViewModel
    /// 运行时装配自检事实（L5：缺口 > 0 才出一行）。
    let wiringFacts: SyncWiringFactsStore
    /// 本次同步目标状态（闸门与「等待上线」行的唯一依据）。
    let syncTargetStatus: SyncDeviceTargetStatus
    /// 「一键改用当前连上的设备」（目标状态行内的动作；落在父上）。
    let onAdoptConnected: () -> Void

    // 父持有的本地态：本 struct 只以绑定读写（状态不搬家，生命周期仍在父）。
    /// 本页设置（跨端续播开关）。
    @Binding var deleteSettings: DeleteSettings
    /// 「重新对账」二次确认（父持有弹框态）。
    @Binding var showResetCursorsConfirm: Bool
    /// F 数据同步结果「详情」展开态。
    @Binding var showDataResultDetail: Bool

    // MARK: - F 数据同步区（S2-T12：与文件传输解耦的「同步数据」）

    /// 播放数据（收藏 / 播放历史 / 歌单结构）的独立动作区：不选方向、不选歌，
    /// 一次动作 = 推本端增量 + 拉对端增量（阶段 / 账目全来自 `MacSyncDataViewModel`）。
    @ViewBuilder
    var body: some View {
        Section {
            Text("sync_run_data_description".localized)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 跨端续播开关（默认关；关 = 本端既不上报也不接受播放位置）。
            // 文案必须与真实行为逐字一致：本步开也只允许交换，上报/落点见下一版本。
            Toggle("sync_run_playback_position_toggle".localized, isOn: $deleteSettings.syncPlaybackPositionEnabled)
                .onChange(of: deleteSettings.syncPlaybackPositionEnabled) { _, _ in
                    deleteSettings.save()
                }
                .help("sync_run_playback_position_help".localized)

            HStack(spacing: DesignTokens.space12) {
                if dataModel.isRunning {
                    Button("sync_run_data_cancel".localized, role: .destructive) {
                        dataModel.cancel()
                    }
                } else {
                    // 批 B2：禁用条件 = 数据同步闸门（连接 / 会话 / 未在跑 / **目标在线**，
                    // 唯一实现 = `SyncUIStartGate.dataSyncAvailability`）；目标状态由
                    // 视图层唯一真值 `syncTargetStatus` 显式传入（本批收尾：VM 不再存镜像）。
                    Button("sync_run_data_button".localized) {
                        dataModel.start(for: syncTargetStatus)
                    }
                    .disabled(!dataModel.canStart(for: syncTargetStatus))
                    .help("sync_run_data_help".localized)

                    // 次要动作：重置与**所选设备**的推/拉游标（身份修复后必须能重拉，否则已被
                    // 游标越过的行永不重来）。二次确认后执行，与主按钮同步进行态无关。
                    Button("sync_run_data_reset_button".localized) {
                        showResetCursorsConfirm = true
                    }
                    .disabled(!dataModel.canResetCursors(for: syncTargetStatus))
                    .help("sync_run_data_reset_help".localized)
                }

                if let phaseText = dataPhaseText {
                    Text(phaseText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            // 批 B2：目标状态行（与传歌流同一渲染；离线时上面的按钮已被闸门禁用）。
            SyncTargetStatusBanner(status: syncTargetStatus, onAdoptConnected: onAdoptConnected)

            if dataModel.isRunning {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if let failure = dataModel.errorMessage {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(dataModel.isInterrupted ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !dataModel.isRunning, let reason = dataModel.unavailableReason(for: syncTargetStatus) {
                // 禁用按钮永远有解释（与执行区同一纪律）。
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 装配自检（L5，INV-16 后半句）：缺口 > 0 才显示一行；缺口 = 0 = 空态。
            // 判定全在 `SyncWiringSelfCheckPresenter`（纯逻辑），View 不写判断。
            if let wiringRow = SyncWiringSelfCheckPresenter.gapRow(wiringFacts.gaps) {
                VStack(alignment: .leading, spacing: DesignTokens.space4) {
                    Text(wiringRow.labelKey.localized(with: wiringRow.count))
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Text(
                        wiringRow.hintKey.localized(
                            with: wiringRow.probeLabelKeys.map { $0.localized }.joined(separator: ", ")
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            dataResult

            if let resetMessage = dataModel.resetResultMessage {
                Text(resetMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("sync_run_data_section".localized)
        } footer: {
            VStack(alignment: .leading, spacing: DesignTokens.space4) {
                Text("sync_run_data_footer".localized)
                Text("sync_run_data_identity_footer".localized)
            }
        }
    }

    /// 运行中阶段文案（非运行中 = nil；终态只说结果，不再报阶段）。
    private var dataPhaseText: String? {
        switch dataModel.phase {
        case .pushing: return "sync_run_data_phase_pushing".localized
        case .pulling: return "sync_run_data_phase_pulling".localized
        case .idle, .finished: return nil
        }
    }

    /// 账目结论行（2026-09-25）：默认只显示「发送 / 应用 / 缺口」的非零项——判定与文案 key 全来自
    /// 唯一投影 `SyncEntityOutcomeDisclosure.dataConclusion(_:)`，本视图不写判断；
    /// 指标墙 / 各缺口解释 / 按实体披露全在「详情」里（默认折叠）。
    @ViewBuilder
    private var dataResult: some View {
        let report = dataModel.report
        if dataModel.phase == .finished {
            let conclusion = SyncEntityOutcomeDisclosure.dataConclusion(report)
            SyncConclusionLine(line: conclusion)
            if conclusion.hasDetail {
                DisclosureGroup(isExpanded: $showDataResultDetail) {
                    dataResultDetail(report)
                } label: {
                    Text(SyncEntityOutcomeDisclosure.detailLabelKey.localized)
                        .font(.callout)
                }
            }
        } else if !dataModel.isRunning {
            Text("sync_run_data_result_none".localized)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// 账目**详情**（默认折叠）：发送 / 应用 / 挂起（本地缺歌）/ 未定位（缺身份键）/ 身份歧义
    /// / 未支持（播放位置未落地）/ 缺指纹（本端发出）/ 忽略删除 + 各自解释。
    @ViewBuilder
    private func dataResultDetail(_ report: SyncDataSyncReport) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.space20) {
            SyncMetric(label: "sync_run_data_result_sent".localized, value: report.pushedEntries, color: .primary)
            SyncMetric(label: "sync_run_data_result_applied".localized, value: report.appliedEntries, color: .primary)
            SyncMetric(
                label: "sync_run_data_result_pending".localized,
                value: report.suspendedEntries,
                color: report.suspendedEntries > 0 ? .orange : .secondary
            )
            SyncMetric(
                label: "sync_run_data_result_unresolved".localized,
                value: report.unresolvedEntries,
                color: report.unresolvedEntries > 0 ? .orange : .secondary
            )
            SyncMetric(
                label: "sync_run_data_unsupported".localized,
                value: report.unsupportedEntries,
                color: report.unsupportedEntries > 0 ? .orange : .secondary
            )
            SyncMetric(
                label: "sync_run_data_skipped_parent".localized,
                value: report.skippedMissingParentEntries,
                color: report.skippedMissingParentEntries > 0 ? .orange : .secondary
            )
            SyncMetric(
                label: "sync_run_data_result_missing_identity".localized,
                value: report.pushedMissingIdentityEntries,
                color: report.pushedMissingIdentityEntries > 0 ? .orange : .secondary
            )
            // 身份歧义（2026-09-15）：**仅当 N > 0 才显示**（无歧义时不留一个恒 0 的噪音格）。
            if report.ambiguousIdentityEntries > 0 {
                SyncMetric(
                    label: "sync_run_data_ambiguous_identity".localized,
                    value: report.ambiguousIdentityEntries,
                    color: .orange
                )
            }
            // 应用失败（2026-09-15）：同样仅 N > 0 才显示；口径与 iOS 面板的缺口行一致（INV-29）。
            if report.applyFailedEntries > 0 {
                SyncMetric(
                    label: "sync_run_data_apply_failed".localized,
                    value: report.applyFailedEntries,
                    color: .orange
                )
            }
            SyncMetric(
                label: "sync_run_data_result_skipped".localized,
                value: report.ignoredDeletes,
                color: .secondary
            )
            Spacer()
        }
        .padding(.vertical, DesignTokens.space2)

        // 缺口解释（计数 > 0 才出；key / 计数逐条对应既有口径，未改任何触发条件）。
        hintText("sync_run_data_pending_hint", report.suspendedEntries)
        hintText("sync_run_data_unresolved_hint", report.unresolvedEntries)
        hintText("sync_run_data_ambiguous_identity_hint", report.ambiguousIdentityEntries)
        hintText("sync_run_data_unsupported_hint", report.unsupportedEntries)
        hintText("sync_run_data_skipped_parent_hint", report.skippedMissingParentEntries)
        hintText("sync_run_data_apply_failed_hint", report.applyFailedEntries)
        hintText("sync_run_data_missing_identity_hint", report.pushedMissingIdentityEntries)

        // 按实体披露（INV-18 后半句）：只出计数 > 0 的 (结果, 实体) 行——正常实体不占行。
        // 数字与顺序全部来自唯一投影 `SyncEntityOutcomeDisclosure`（UI 不自算、不枚举实体）。
        let entityRows = SyncEntityOutcomeDisclosure.rows(report.tally)
        if !entityRows.isEmpty {
            VStack(alignment: .leading, spacing: DesignTokens.space4) {
                Text(SyncEntityOutcomeDisclosure.breakdownTitleKey.localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(Array(entityRows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.space6) {
                        Text(SyncEntityOutcomeDisclosure.rowLabel(row))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(row.count)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(.top, DesignTokens.space2)
        }
    }

    /// 缺口解释行（计数 > 0 才出现；文案 key 由调用方点名，触发条件与折叠前逐字一致）。
    @ViewBuilder
    private func hintText(_ key: String, _ count: Int) -> some View {
        if count > 0 {
            Text(key.localized(with: count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
