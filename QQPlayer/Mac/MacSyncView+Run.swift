//
//  MacSyncView+Run.swift
//  QQPlayer
//
//  `MacSyncRunSection` 的 E 结果区 + 固定执行底栏
//  （2026-09-19 从 `MacSyncView.swift` 纯搬家，零行为/UI 变化；
//   2026-09-25 结果区改「默认只显示结论行 + 详情折叠」，E2 对齐歌词补发区并入 E 的详情；
//   2026-09-26 批 B1 把 F 数据同步区整体迁到 `SyncDataPane.swift`；
//   2026-11-16 D 执行区整段删除——本文件只剩 E 结果区 + 固定底栏）：
//  底栏（摘要 / 进度 / 失败原因 / 开始取消）、最近一次结果（结论行 + 折叠详情）。
//
//  ⚠️ 可见性 / 结构变化（批 B1 → 批 D）：`conclusionLine` / `metric`（现为
//  `SyncConclusionLine` / `SyncMetric`）与目标状态行（`SyncTargetStatusBanner`，见
//  `SyncDevicePane.swift`）是**跨 Pane 共用的唯一渲染实现**（禁第二份）。批 D 把三块 Pane
//  改为独立 struct 后，这些成员不能再靠 `MacSyncRunSection` 的 extension 共享 ⇒
//  改为**独立 struct**，由各 Pane 以值输入调用（渲染逐字未变）。
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
    // MARK: - 固定执行底栏（2026-11-16 P0）

    /// 固定执行底栏：选择摘要 / 进行中进度 + 不可用原因 + 开始 / 取消。
    /// 起因：执行控件原在可滚动 `Form` 的 D 区，被 sheet 底边裁切且摘要/禁用原因不固定在
    /// 视野内（用户 2026-11-16 截图反馈）。全屏按钮只此一处，语义仍全来自
    /// `model.startAvailability` / `startButtonTitle` / `startButtonHelp`。
    /// 2026-11-16：进度 / 当前文件从可滚动 D 区搬到这里（用户要求进状态栏，滚动也看得到）。
    /// 2026-11-16：D 区已删——阶段行 / 测速 / 目标状态行撤掉（测速进「设备」页本次同步目标、
    /// 目标状态行设备页已有），失败原因由本底栏显示。
    @ViewBuilder
    var syncActionBar: some View {
        VStack(spacing: DesignTokens.space0) {
            Divider()
            // 忙时底栏兼作状态栏：进度条只在进行中出现（空闲态底栏与 P0 完全一致）。
            if model.phase.isBusy {
                ProgressView(value: model.progress.isDeterminate ? model.progress.fraction : nil)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, DesignTokens.space20)
                    .padding(.top, DesignTokens.space8)
            }
            HStack(alignment: .center, spacing: DesignTokens.space12) {
                VStack(alignment: .leading, spacing: DesignTokens.space2) {
                    if model.phase.isBusy {
                        Text(progressText)
                            .font(.callout)
                            .fontWeight(.medium)
                            .fixedSize(horizontal: false, vertical: true)
                        if let path = model.progress.currentPath {
                            Text(path)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } else {
                        Text(actionBarSummaryText)
                            .font(.callout)
                            .fontWeight(.medium)
                            .foregroundStyle(content.selectionSummary.isEmpty ? Color.secondary : Color.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        // 失败原因原在传歌流 D 区（2026-11-16 已整段删除）——改由本底栏承担：
                        // 失败必须一直可见，不进折叠、不静默。
                        if let failure = model.failureText {
                            Text(failure)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let hint = actionBarHint {
                            Text(hint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: DesignTokens.space8)
                if model.phase.isBusy {
                    Button("sync_run_cancel".localized, role: .destructive) {
                        model.cancelSync()
                    }
                } else {
                    Button(startButtonTitle) {
                        model.startSync()
                    }
                    .disabled(!model.startAvailability.canStart)
                    .help(startButtonHelp)
                }
            }
            .padding(.horizontal, DesignTokens.space20)
            .padding(.vertical, DesignTokens.space12)
        }
        // 设置窗玻璃生效时不画底 ⇒ 直接透出整窗封面模糊底（上分隔线已在 VStack 首行）。
        .background(settingsGlassActive ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.bar))
    }

    /// 底栏摘要文案：空选择用既有「请先选择…」键，其余三态复用 `selectionTotalText`
    /// （全曲库 / 歌单 / 单曲），数字与字节格式化均来自 `content.selectionSummary`。
    private var actionBarSummaryText: String {
        content.selectionSummary.isEmpty ? "sync_run_reason_empty_selection".localized : selectionTotalText
    }

    /// 底栏不可用原因：空选择的解释已由摘要位承担（同一句）→ 这里不重复；
    /// 其余（未配对 / 未连接 / 未选方向 / 曲库不可用）沿用 `availabilityHint`。
    private var actionBarHint: String? {
        switch model.startAvailability {
        case .emptySelection:
            return nil
        default:
            return availabilityHint
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
        case .targetOffline:
            // 批 B2：文案需要设备名（「等待 <名字> 上线」）→ 由 `SyncTargetStatusBanner`
            // （唯一渲染处，就在按钮下方）解释；这里不再输出第二句。
            return nil
        }
    }

    // MARK: - E 结果区（2026-09-25：默认只显示结论行；明细折叠）

    @ViewBuilder
    var resultSection: some View {
        let report = model.reportSummary
        let resend = lyricsFacts.lastSummary
        let lastRun = model.reportSummaryLastRun
        let conclusion = report.map {
            SyncEntityOutcomeDisclosure.fileConclusion($0, lyricsResend: resend, lastRun: lastRun)
        }
        Section {
            if let conclusion {
                // 「上次同步」前缀行（本次运行不显示）：结论与设备名两个事实都来自投影
                // 给出的 `line` 字段，本视图只拼 key + 上色（不写判断）。
                if let lastRunAt = conclusion.lastRunAt {
                    lastRunPrefixLine(lastRunAt: lastRunAt, peerName: conclusion.lastRunPeerName)
                }
                SyncConclusionLine(line: conclusion)
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

    /// 「上次同步」前缀行（结论行上方；跨设备回显时同排附设备名）。
    @ViewBuilder
    private func lastRunPrefixLine(lastRunAt: Date, peerName: String?) -> some View {
        HStack(spacing: DesignTokens.space8) {
            Text(
                "sync_run_result_last_run_prefix".localized(
                    with: SyncUIRelativeTimeText.short(from: lastRunAt, now: Date(), locale: .current)
                )
            )
            if let peerName {
                Text("sync_run_result_last_run_device".localized(with: peerName))
            }
            Spacer(minLength: DesignTokens.space0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// 结论行：只显示投影给出的段（哪些指标出现 / 文案 key / 严重度全在
    /// `SyncEntityOutcomeDisclosure` 里定，本视图不写判断，只负责拼接与上色）。
    /// （批 D：实现已抽为 `SyncConclusionLine`。）

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
                    SyncMetric(label: "sync_run_result_pushed".localized, value: report.pushedCount, color: .primary)
                    SyncMetric(label: "sync_run_result_pulled".localized, value: report.pulledCount, color: .primary)
                    SyncMetric(label: "sync_run_result_skipped".localized, value: report.skippedCount, color: .secondary)
                    SyncMetric(
                        label: "sync_run_result_failed".localized,
                        value: report.failedCount,
                        color: report.failedCount > 0 ? .red : .secondary
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
                            SyncMetric(label: "sync_run_result_pushed".localized, value: resend.pushed.count, color: .primary)
                            SyncMetric(label: "sync_run_result_skipped".localized, value: resend.presentCount, color: .secondary)
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

}

/// 结论行（跨 Pane 唯一实现：E 结果区 + F 数据结果区共用）：只显示投影给出的段
/// （哪些指标出现 / 文案 key / 严重度全在 `SyncEntityOutcomeDisclosure` 里定，视图不写判断，
/// 只负责拼接与上色）。
struct SyncConclusionLine: View {
    /// 投影给出的结论行（决策来自 `SyncEntityOutcomeDisclosure`）。
    let line: SyncResultConclusionLine

    var body: some View {
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
}

/// 指标格（跨 Pane 唯一实现：E 结果区详情 + F 数据结果详情共用）。
struct SyncMetric: View {
    let label: String
    let value: Int
    let color: Color

    var body: some View {
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
