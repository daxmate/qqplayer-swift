//
//  MacSyncView+Connection.swift
//  QQPlayer
//
//  `MacSyncRunSection` 的 B 方向区（原文件含 A 连接状态区 / B 方向区；2026-09-26 批 B1
//  把 A 区随设备语义整体迁到「设备」页 —— 见 `SyncDevicePane.swift` 的 `connectionSection`）。
//
//  B 区保留在「同步」页（传歌流的第一屏）：T10（2026-09-12）把方向提到内容之前，
//  未选方向时内容区只显示引导，选定后内容面板整体切到对应一端。
//
//  纪律不变：本文件只做展示——选中方向来自 `MacSyncContentModel`（纯逻辑，有单测），
//  View 里不写判断。
//
//  ⚠️ 可见性：被 `body` 或其它分区文件引用的成员为 internal（原 `private`）。
//

import SwiftUI

extension MacSyncRunSection {
    // MARK: - B 方向区（T10：面板第一屏）

    @ViewBuilder
    var directionSection: some View {
        Section {
            directionRow(
                .upload,
                title: "sync_run_direction_upload".localized,
                detail: "sync_run_direction_upload_detail".localized
            )
            directionRow(
                .download,
                title: "sync_run_direction_download".localized,
                detail: "sync_run_direction_download_detail".localized
            )
        } header: {
            Text("sync_run_direction_section".localized)
        } footer: {
            Text("sync_run_direction_footer".localized)
        }
    }

    /// 方向行（单选；选中态用勾 + 底色，与内容区的「全曲库」行同一视觉语言）。
    private func directionRow(
        _ direction: SyncTransferDirection,
        title: String,
        detail: String
    ) -> some View {
        let selected = model.direction == direction
        return HStack(alignment: .top, spacing: DesignTokens.space10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(title)
                    .fontWeight(selected ? .medium : .regular)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DesignTokens.space0)
        }
        .padding(.vertical, DesignTokens.space4)
        .padding(.horizontal, DesignTokens.space6)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radius6)
                .fill(selected ? accentColor.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { model.selectDirection(direction) }
    }

}
