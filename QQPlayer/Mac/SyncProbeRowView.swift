//
//  SyncProbeRowView.swift
//  QQPlayer
//
//  T2 测速行（Mac 同步面板 D 执行区）：一个「测速」按钮 + 一个结果数值。
//
//  为什么自成一个 View：`MacSyncRunViewModel` 的 `@Published` 面有棘轮（基线 8，只减不增），
//  探针结果属于**面板局部状态**，用 `@State` 持有即可，不进 view model 的发布面。
//  代码逻辑（探针怎么跑、结果怎么算）全在 `SyncProbe` / `SyncProbeRunner`（Core），本文件只上屏。
//
import SwiftUI

struct SyncProbeRowView: View {
    /// 触发一次探针：回调给 MB/s（nil = 失败/超时/对端不支持）。
    let run: (@escaping (Double?) -> Void) -> Void

    @State private var isProbing = false
    @State private var megabytesPerSecond: Double?

    var body: some View {
        HStack(spacing: DesignTokens.space12) {
            Button("sync_run_probe".localized) {
                guard !isProbing else { return }
                isProbing = true
                run { value in
                    Task { @MainActor in
                        megabytesPerSecond = value
                        isProbing = false
                    }
                }
            }
            .disabled(isProbing)

            if isProbing {
                ProgressView()
                    .controlSize(.small)
            } else if let megabytesPerSecond {
                Text(String(format: "sync_run_probe_value".localized, megabytesPerSecond))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}
