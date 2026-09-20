//
//  MacSyncView+Connection.swift
//  QQPlayer
//
//  `MacSyncRunSection` 的 A 连接状态区 / B 方向区（2026-09-19 从 `MacSyncView.swift`
//  纯搬家，零行为/UI 变化）：已连对端行的状态/电量/信号上屏、未连接提示行，
//  以及方向选择（T10，2026-09-12：方向提到内容之前，面板第一屏）。
//
//  纪律不变：本文件只做展示——连接事实来自 `MacSyncRunViewModel`，选中方向来自
//  `MacSyncContentModel`（纯逻辑，有单测），View 里不写判断。
//
//  ⚠️ 可见性：被 `body` 或其它分区文件引用的成员为 internal（原 `private`）。
//

import SwiftUI

extension MacSyncRunSection {
    // MARK: - A 连接状态区

    @ViewBuilder
    var connectionSection: some View {
        // 2026-09-20 批 6-8：中心迁 `@Observable` 后视图改环境注入，`$hostCenter.…` 不再可用
        // （计算属性不可投影）⇒ 局部 `@Bindable`（与 MacEQSettingsView 同款既有写法），双向写回保留。
        @Bindable var center = hostCenter
        Section {
            if let peer = model.connectedPeer {
                connectedRow(peer)
            } else {
                Label(connectionHint, systemImage: "wifi.slash")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Toggle("sync_run_allow_lan".localized, isOn: $center.allowsLANConnections)

            if !model.isListening {
                Text("sync_run_listener_off_hint".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("sync_run_connection_section".localized)
        }
    }

    private func connectedRow(_ peer: SyncConnectedPeer) -> some View {
        HStack(spacing: DesignTokens.space10) {
            Image(systemName: "iphone")
                .font(.system(size: DesignTokens.font18))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(peer.displayName.isEmpty ? "sync_unknown_device".localized : peer.displayName)
                    .fontWeight(.medium)
                HStack(spacing: DesignTokens.space10) {
                    if !peer.peerID.isEmpty {
                        Text("sync_device_id_short".localized(with: DeviceID.formatted(peer.peerID)))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    if let duration = model.connectionDurationText {
                        Text("sync_run_connected_for".localized(with: duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .padding(.vertical, DesignTokens.space2)
    }

    /// 未连接提示：一台都没配对 vs 配对了但没连上，指引不同。
    private var connectionHint: String {
        model.startAvailability == .notPaired
            ? "sync_run_not_paired_hint".localized
            : "sync_run_not_connected_hint".localized
    }

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
