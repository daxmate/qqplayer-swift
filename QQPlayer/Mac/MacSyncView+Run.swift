//
//  MacSyncView+Run.swift
//  QQPlayer
//
//  `MacSyncRunSection` 的 D 执行区 / E 结果区 / F 数据同步区
//  （2026-09-19 从 `MacSyncView.swift` 纯搬家，零行为/UI 变化；
//   2026-09-25 结果区改「默认只显示结论行 + 详情折叠」，E2 对齐歌词补发区并入 E 的详情）：
//  开始与阶段/进度上屏、最近一次结果（结论行 + 折叠详情）、
//  播放数据（收藏/播放历史/歌单结构）同步动作与账目上屏。
//
//  纪律不变：本文件只做展示——阶段/进度/结果全来自 `MacSyncRunViewModel` +
//  `MacSyncDataViewModel` + `MacLyricsResendFactsStore` / `SyncEntityOutcomeDisclosure`
//  （纯逻辑/纯事实，有单测），View 里不写判断。
//
//  ⚠️ 可见性：被 `body` 或其它分区文件引用的成员为 internal（原 `private`）；
//  仅本文件内使用的辅助成员仍保持 `private`。
//

import SwiftUI

extension MacSyncRunSection {
    // MARK: - D 执行区

    @ViewBuilder
    var runSection: some View {
        Section {
            HStack(spacing: DesignTokens.space12) {
                if model.phase.isBusy {
                    Button("sync_run_cancel".localized, role: .destructive) {
                        model.cancelSync()
                    }
                } else {
                    // T10：方向已在第一屏选定 → 这里是**一个**按方向命名的开始键
                    // （两个独立方向键会在「已选下载却点上传」时自相矛盾）。
                    Button(startButtonTitle) {
                        model.startSync()
                    }
                    .disabled(!model.startAvailability.canStart)
                    .help(startButtonHelp)
                }

                Text(phaseText)
                    .font(.callout)
                    .foregroundStyle(model.failureText == nil ? Color.secondary : Color.red)

                Spacer()
            }

            if model.phase.isBusy {
                ProgressView(value: model.progress.isDeterminate ? model.progress.fraction : nil)
                Text(progressText)
                    .font(.callout)
                if let path = model.progress.currentPath {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let failure = model.failureText, !model.phase.isBusy {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.phase.isBusy, let reason = availabilityHint {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("sync_run_execute_section".localized)
        }
    }

    /// 开始键标题：按当前方向命名（未选方向 = 通用「开始同步」，此时按钮禁用）。
    private var startButtonTitle: String {
        switch model.direction {
        case .none: return "sync_run_start".localized
        case .some(.upload): return "sync_run_upload".localized
        case .some(.download): return "sync_run_download".localized
        }
    }

    private var startButtonHelp: String {
        switch model.direction {
        case .some(.download): return "sync_run_download_help".localized
        default: return "sync_run_upload_help".localized
        }
    }

    /// 阶段文案（非失败态）。
    private var phaseText: String {
        switch model.phase {
        case .disconnected: return "sync_run_phase_disconnected".localized
        case .idle: return "sync_run_phase_idle".localized
        case .planning: return "sync_run_progress_planning".localized
        case .pushing, .pulling: return progressText
        case .done: return "sync_run_progress_done".localized
        case .failed: return model.failureText ?? ""
        }
    }

    /// 传输计数文案（"正在推送 37/128"）。
    private var progressText: String {
        let progress = model.progress
        switch progress.direction {
        case .push:
            return "sync_run_progress_push".localized(with: progress.clampedCompleted, progress.total)
        case .pull:
            return "sync_run_progress_pull".localized(with: progress.clampedCompleted, progress.total)
        case .none:
            return "sync_run_progress_planning".localized
        }
    }

    /// 不能开始的原因（可开始 / 同步中 = nil）。
    private var availabilityHint: String? {
        switch model.startAvailability {
        case .ready:
            return nil
        case .alreadyRunning:
            // 禁用按钮**永远有解释**。正常跑起来时渲染的是取消键（`phase.isBusy`），
            // 该分支只在「非 busy 却被判定为正在运行」的病态态下可见（防御性文案）。
            return "sync_run_reason_already_running".localized
        case .notPaired:
            return "sync_run_reason_not_paired".localized
        case .notConnected:
            return "sync_run_reason_not_connected".localized
        case .libraryUnavailable:
            return "sync_run_reason_library_unavailable".localized
        case .noDirection:
            return "sync_run_reason_no_direction".localized
        case .emptySelection:
            return "sync_run_reason_empty_selection".localized
        }
    }

    // MARK: - E 结果区（2026-09-25：默认只显示结论行；明细折叠）

    @ViewBuilder
    var resultSection: some View {
        let report = model.reportSummary
        let resend = lyricsFacts.lastSummary
        let conclusion = report.map { SyncEntityOutcomeDisclosure.fileConclusion($0, lyricsResend: resend) }
        Section {
            if let conclusion {
                conclusionLine(conclusion)
            } else {
                Text("sync_run_result_none".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let report, let conclusion, conclusion.hasDetail {
                DisclosureGroup(isExpanded: $showFileResultDetail) {
                    fileResultDetail(report, resend: resend)
                } label: {
                    Text(SyncEntityOutcomeDisclosure.detailLabelKey.localized)
                        .font(.callout)
                }
            }

            Text("sync_run_result_no_deletion".localized)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("sync_run_result_section".localized)
        }
    }

    /// 结论行：只显示投影给出的段（哪些指标出现 / 文案 key / 严重度全在
    /// `SyncEntityOutcomeDisclosure` 里定，本视图不写判断，只负责拼接与上色）。
    @ViewBuilder
    private func conclusionLine(_ line: SyncResultConclusionLine) -> some View {
        if let messageKey = line.messageKey {
            Text(messageKey.localized)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: DesignTokens.space12) {
                ForEach(Array(line.segments.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .firstTextBaseline, spacing: DesignTokens.space4) {
                        Text(segment.labelKey.localized)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("\(segment.count)")
                            .font(.callout)
                            .fontWeight(.semibold)
                            .foregroundStyle(conclusionColor(segment.severity))
                    }
                }
                Spacer(minLength: DesignTokens.space0)
            }
        }
    }

    /// 严重度 → 颜色（颜色属界面层；“缺口 / 失败”的判断在投影里）。
    private func conclusionColor(_ severity: SyncResultConclusionSegment.Severity) -> Color {
        switch severity {
        case .normal: .primary
        case .gap: .orange
        case .failure: .red
        }
    }

    /// E 结果区**详情**（默认折叠）：指标墙 / 提示行 / 「对端已一致」例举 / 失败路径清单 /
    /// 对齐歌词（E2 补发轮事实**并入此处**——它与 E 的歌词行同一投影，不再单开一区）。
    @ViewBuilder
    private func fileResultDetail(
        _ report: SyncUIReportSummary,
        resend: SyncLyricsResendSummary?
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.space8) {
            if !report.isEmptySelection {
                HStack(alignment: .top, spacing: DesignTokens.space24) {
                    metric("sync_run_result_pushed".localized, report.pushedCount, .primary)
                    metric("sync_run_result_pulled".localized, report.pulledCount, .primary)
                    metric("sync_run_result_skipped".localized, report.skippedCount, .secondary)
                    metric(
                        "sync_run_result_failed".localized,
                        report.failedCount,
                        report.failedCount > 0 ? .red : .secondary
                    )
                    Spacer()
                }
                .padding(.vertical, DesignTokens.space2)
            }

            // E-1（2026-09-21）：「计划为空（对端已一致）」不得显示成普通完成。
            // 判定在 `SyncUIReportSummary.isEmptyPlanAlreadyIdentical`（纯逻辑），
            // 本视图只展示：计数 + 前 3 条路径（否则用户看到的是「秒报完成、零字节」）。
            if report.isEmptyPlanAlreadyIdentical {
                VStack(alignment: .leading, spacing: DesignTokens.space4) {
                    Text("sync_run_result_peer_identical".localized(with: report.peerAlreadyHasCount))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(report.peerAlreadyHasSample, id: \.self) { path in
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.top, DesignTokens.space2)
            }

            if report.unresolvedCount > 0 {
                Text("sync_run_result_unresolved".localized(with: report.unresolvedCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !report.unknownPlaylistIDs.isEmpty {
                Text("sync_run_unknown_playlists".localized(with: report.unknownPlaylistIDs.count))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            // 失败永不折叠进沉默：计数已在结论行，「详情」展开即见路径清单。
            if report.failedCount > 0 {
                Text("sync_run_result_failures_header".localized(with: report.failedCount))
                    .font(.callout)
                VStack(alignment: .leading, spacing: DesignTokens.space4) {
                    ForEach(report.failedItems) { item in
                        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.space8) {
                            Image(systemName: item.isPush ? "arrow.up.circle" : "arrow.down.circle")
                                .foregroundStyle(.red)
                            Text(item.relativePath.isEmpty ? item.reason : item.relativePath)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(SyncUIFailureReasonText.key(for: item.reason).localized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, DesignTokens.space4)
            }

            // 对齐歌词（唯一投影**一次成型**）：接收侧事实（E）+ 本轮补发事实（原 E2）。
            // 补发那一轮只推不拉（桌面 → 移动）；三个数字全来自账目、行与 key 全来自
            // `SyncEntityOutcomeDisclosure.lyricsRows`，本视图不自己算、不自己拼 key。
            let lyricsRows = SyncEntityOutcomeDisclosure.lyricsRows(
                discarded: report.lyricsDiscarded.count,
                pendingResend: resend?.pendingResend.count ?? 0,
                keptLocal: report.lyricsKeptLocal.count
            )
            if resend != nil || !lyricsRows.isEmpty {
                VStack(alignment: .leading, spacing: DesignTokens.space6) {
                    Text(SyncEntityOutcomeDisclosure.lyricsSectionTitleKey.localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let resend {
                        HStack(alignment: .top, spacing: DesignTokens.space24) {
                            metric("sync_run_result_pushed".localized, resend.pushed.count, .primary)
                            metric("sync_run_result_skipped".localized, resend.presentCount, .secondary)
                            Spacer()
                        }
                        .padding(.vertical, DesignTokens.space2)
                    }
                    ForEach(Array(lyricsRows.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: DesignTokens.space4) {
                            LabeledContent(row.labelKey.localized(with: row.count)) {
                                Text("\(row.count)")
                                    .foregroundStyle(row.isGap ? Color.orange : Color.secondary)
                            }
                            if let hintKey = row.hintKey {
                                Text(hintKey.localized(with: row.count))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.top, DesignTokens.space2)
            }
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

    private func metric(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.space2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
    }

    // MARK: - F 数据同步区（S2-T12：与文件传输解耦的「同步数据」）

    /// 播放数据（收藏 / 播放历史 / 歌单结构）的独立动作区：不选方向、不选歌，
    /// 一次动作 = 推本端增量 + 拉对端增量（阶段 / 账目全来自 `MacSyncDataViewModel`）。
    @ViewBuilder
    var dataSection: some View {
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
                    Button("sync_run_data_button".localized) {
                        dataModel.start()
                    }
                    .disabled(!dataModel.canStart)
                    .help("sync_run_data_help".localized)

                    // 次要动作：重置与该对端的推/拉游标（身份修复后必须能重拉，否则已被
                    // 游标越过的行永不重来）。二次确认后执行，与主按钮同步进行态无关。
                    Button("sync_run_data_reset_button".localized) {
                        showResetCursorsConfirm = true
                    }
                    .disabled(!dataModel.canResetCursors)
                    .help("sync_run_data_reset_help".localized)
                }

                if let phaseText = dataPhaseText {
                    Text(phaseText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if dataModel.isRunning {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if let failure = dataModel.errorMessage {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(dataModel.isInterrupted ? Color.secondary : Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !dataModel.isRunning, let reason = dataModel.unavailableReason {
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
            conclusionLine(conclusion)
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
            metric("sync_run_data_result_sent".localized, report.pushedEntries, .primary)
            metric("sync_run_data_result_applied".localized, report.appliedEntries, .primary)
            metric(
                "sync_run_data_result_pending".localized,
                report.suspendedEntries,
                report.suspendedEntries > 0 ? .orange : .secondary
            )
            metric(
                "sync_run_data_result_unresolved".localized,
                report.unresolvedEntries,
                report.unresolvedEntries > 0 ? .orange : .secondary
            )
            metric(
                "sync_run_data_unsupported".localized,
                report.unsupportedEntries,
                report.unsupportedEntries > 0 ? .orange : .secondary
            )
            metric(
                "sync_run_data_skipped_parent".localized,
                report.skippedMissingParentEntries,
                report.skippedMissingParentEntries > 0 ? .orange : .secondary
            )
            metric(
                "sync_run_data_result_missing_identity".localized,
                report.pushedMissingIdentityEntries,
                report.pushedMissingIdentityEntries > 0 ? .orange : .secondary
            )
            // 身份歧义（2026-09-15）：**仅当 N > 0 才显示**（无歧义时不留一个恒 0 的噪音格）。
            if report.ambiguousIdentityEntries > 0 {
                metric(
                    "sync_run_data_ambiguous_identity".localized,
                    report.ambiguousIdentityEntries,
                    .orange
                )
            }
            // 应用失败（2026-09-15）：同样仅 N > 0 才显示；口径与 iOS 面板的缺口行一致（INV-29）。
            if report.applyFailedEntries > 0 {
                metric(
                    "sync_run_data_apply_failed".localized,
                    report.applyFailedEntries,
                    .orange
                )
            }
            metric("sync_run_data_result_skipped".localized, report.ignoredDeletes, .secondary)
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
}
