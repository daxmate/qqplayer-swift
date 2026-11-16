//
//  LyricAlignmentProgressSheet.swift
//  QQPlayer
//
//  歌词时间轴对齐的进度 / 结果 sheet（iOS 与 macOS 共用同一份实现）。
//  状态全部来自 `LyricAlignmentController`：这里不持有任务，只做展示与转发动作。
//

import SwiftUI

struct LyricAlignmentProgressSheet: View {
    let controller: LyricAlignmentController

    /// 恢复失败（写盘错误）时的行内提示：不弹 alert，避免和 sheet 抢焦点。
    @State private var revertFailureMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space16) {
            Text("lyrics.align.title".localized)
                .font(.headline)
            content
        }
        .padding(DesignTokens.space24)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
            .frame(minWidth: 360)
        #endif
    }

    // MARK: - 分状态内容

    @ViewBuilder
    private var content: some View {
        switch controller.state {
        case .idle:
            // sheet 由 state 驱动；idle 时理论上不会显示，这里只防关闭过程闪一帧。
            EmptyView()
        case let .running(progress, phase):
            runningContent(progress: progress, phase: phase)
        case let .finished(report):
            finishedContent(report)
        case let .failed(message):
            failedContent(message)
        }
    }

    private func runningContent(progress: Double, phase: LyricAlignmentController.Phase) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.space12) {
            Text(phaseText(phase))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ProgressView(value: progress)

            HStack {
                Spacer()
                Button("lyrics.align.cancel".localized) {
                    controller.cancel()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func finishedContent(_ report: LyricAlignmentReport) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.space12) {
            if LyricAlignmentController.isLowMatch(report) {
                // 低匹配率不自动回退（已写入）：给一行说明 + 一键恢复原时间轴。
                Text("lyrics.align.result.lowMatch".localized(with: percent(for: report)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("lyrics.align.result.success".localized(with: report.matchedCount, report.lineCount))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let revertFailureMessage {
                Text(revertFailureMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: DesignTokens.space12) {
                if LyricAlignmentController.isLowMatch(report) {
                    Button("lyrics.align.result.revert".localized) {
                        revertAlignment()
                    }
                }
                Spacer()
                Button("lyrics.align.close".localized) {
                    controller.dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failedContent(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.space12) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("lyrics.align.close".localized) {
                    controller.dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - 动作

    private func revertAlignment() {
        guard let stableId = controller.activeStableId else { return }
        do {
            try controller.revert(stableId: stableId)
        } catch {
            AppLog.error(.ui, "Lyrics alignment revert failed: \(error)")
            revertFailureMessage = "lyrics.align.error.revert".localized
        }
    }

    // MARK: - 文案

    private func phaseText(_ phase: LyricAlignmentController.Phase) -> String {
        switch phase {
        case .installingAssets:
            return "lyrics.align.phase.installing".localized
        case .transcribing:
            return "lyrics.align.phase.transcribing".localized
        case .aligning:
            return "lyrics.align.phase.aligning".localized
        }
    }

    private func percent(for report: LyricAlignmentReport) -> Int {
        Int((LyricAlignmentController.matchRate(for: report) * 100).rounded())
    }
}

// MARK: - 宿主挂载

private struct LyricAlignmentSheetModifier: ViewModifier {
    let controller: LyricAlignmentController

    func body(content: Content) -> some View {
        // 在 body 里读 state：@Observable 的依赖追踪只覆盖 body 内的读取。
        let presented = controller.presentsSheet
        content.sheet(
            isPresented: Binding(
                get: { presented },
                set: { newValue in
                    if !newValue { controller.dismiss() }
                }
            )
        ) {
            #if os(iOS)
                LyricAlignmentProgressSheet(controller: controller)
                    .presentationDetents([.height(250)])
                    .presentationDragIndicator(.visible)
                    .interactiveDismissDisabled(controller.isRunning)
            #else
                LyricAlignmentProgressSheet(controller: controller)
                    .interactiveDismissDisabled(controller.isRunning)
            #endif
        }
    }
}

extension View {
    /// 挂一次即可：对齐状态机有内容时弹进度 sheet（运行中禁止下滑关闭，取消走按钮）。
    /// controller 由宿主传入（视图层不写 `.shared`，见 ViewSharedSingletonContractTests）。
    func lyricAlignmentSheet(controller: LyricAlignmentController) -> some View {
        modifier(LyricAlignmentSheetModifier(controller: controller))
    }
}
