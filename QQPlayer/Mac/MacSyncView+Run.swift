//
//  MacSyncView+Run.swift
//  QQPlayer
//
//  `MacSyncRunSection` 的 D 执行区 / E 结果区
//  （2026-09-19 从 `MacSyncView.swift` 纯搬家，零行为/UI 变化；
//   2026-09-25 结果区改「默认只显示结论行 + 详情折叠」，E2 对齐歌词补发区并入 E 的详情；
//   2026-09-26 批 B1 把 F 数据同步区整体迁到 `SyncDataPane.swift`——本文件只剩 D / E）：
//  开始与阶段/进度上屏、最近一次结果（结论行 + 折叠详情）。
//
//  ⚠️ 可见性变化（批 B1）：`conclusionLine` / `metric` 由 `private` 放开为 internal ——
//  播放数据流（`SyncDataPane.swift`）复用同一套结论行与指标墙渲染，禁第二份实现。
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
    func conclusionLine(_ line: SyncResultConclusionLine) -> some View {
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

    func metric(_ label: String, _ value: Int, _ color: Color) -> some View {
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

}
