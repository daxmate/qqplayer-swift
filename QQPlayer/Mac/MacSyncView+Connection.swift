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

    /// 方向卡（P1a 2026-11-16）：`[ 本机 Mac ]  ⇄  [ 目标设备 ]` 胶囊卡，替掉原来的两行 radio。
    /// 箭头朝向 = 当前方向（上传 → 指向右侧设备；下载 ← 指向左侧本机；未选 = 双向箭头）。
    /// 唯一事实源仍是 `model.direction` + `model.selectDirection(_:)`——本文件不存第二份方向；
    /// 同步进行中 / 没有本次同步目标时整卡禁用，并在卡下说明原因（不做「点了没反应」）。
    @ViewBuilder
    var directionSection: some View {
        Section {
            directionCard
                .disabled(directionDisabledReason != nil)
        } header: {
            Text("sync_run_direction_section".localized)
        } footer: {
            Text(directionFooterText)
        }
    }

    /// 卡下方唯一一句说明：可操作时讲当前方向的语义（既有 `_detail` 文案），
    /// 不可操作时讲原因。不新写一套方向解释。
    private var directionFooterText: String {
        if let reason = directionDisabledReason {
            return reason
        }
        switch model.direction {
        case .upload:
            return "sync_run_direction_upload_detail".localized(with: targetDeviceName)
        case .download:
            return "sync_run_direction_download_detail".localized(with: targetDeviceName)
        case nil:
            return "sync_run_direction_footer".localized
        }
    }

    /// 方向不可改的原因（nil = 可改）：同步进行中 / 还没有本次同步目标。
    /// 文案全部复用既有 key，不新增同义句。
    private var directionDisabledReason: String? {
        if model.phase.isBusy {
            return "sync_run_reason_already_running".localized
        }
        if syncTargetStatus.target == nil {
            return "sync_run_reason_not_connected".localized
        }
        return nil
    }

    /// 胶囊卡本体：左端点 = 本机 Mac（上传的来源），右端点 = 目标设备（下载的来源）。
    private var directionCard: some View {
        HStack(spacing: DesignTokens.space10) {
            directionEndpoint(.upload, title: hostName, systemImage: "laptopcomputer")
            flipButton
            directionEndpoint(.download, title: targetDeviceName, systemImage: "iphone")
        }
        .padding(.vertical, DesignTokens.space4)
    }

    /// 端点胶囊（真控件）：点它 = 「从这一端取内容」（左 = 上传 / 右 = 下载）。
    private func directionEndpoint(
        _ direction: SyncTransferDirection,
        title: String,
        systemImage: String
    ) -> some View {
        let selected = model.direction == direction
        return Button {
            model.selectDirection(direction)
        } label: {
            HStack(spacing: DesignTokens.space6) {
                Image(systemName: systemImage)
                    .foregroundStyle(selected ? accentColor : Color.secondary)
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .fontWeight(selected ? .semibold : .regular)
            }
            .padding(.horizontal, DesignTokens.space12)
            .padding(.vertical, DesignTokens.space6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.radius10)
                    .fill(selected ? accentColor.opacity(0.12) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.radius10)
                    .strokeBorder(selected ? accentColor.opacity(0.45) : Color.secondary.opacity(0.25))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 端点本身的文字是设备名 → 朗读文案复用既有方向标题键（避免只念设备名听不出方向）。
        .accessibilityLabel(directionAccessibilityLabel(direction))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    /// 端点朗读文案复用既有方向标题键（「上传到 %@」/「从 %@ 下载」），不新造说法。
    private func directionAccessibilityLabel(_ direction: SyncTransferDirection) -> String {
        switch direction {
        case .upload:
            return "sync_run_direction_upload".localized(with: targetDeviceName)
        case .download:
            return "sync_run_direction_download".localized(with: targetDeviceName)
        }
    }

    /// 中间箭头：点一下在「上传 / 下载」间翻转（未选方向时先落到「上传」）。
    private var flipButton: some View {
        Button {
            model.selectDirection(model.direction == .upload ? .download : .upload)
        } label: {
            Image(systemName: directionSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.direction == nil ? Color.secondary : accentColor)
                .frame(width: DesignTokens.space24, height: DesignTokens.space24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("sync_direction_flip".localized)
    }

    /// 箭头朝向 = 当前方向（上传指向设备；下载指向本机；未选 = 双向）。
    private var directionSymbol: String {
        switch model.direction {
        case .upload:
            return "arrow.right"
        case .download:
            return "arrow.left"
        case nil:
            return "arrow.left.arrow.right"
        }
    }

    /// 方向文案的**设备锚点** = 所选目标设备的展示名。
    /// 名字来自唯一决策层 `SyncDeviceTargetSelection` 的结论（`syncTargetStatus.target`）——
    /// 这里不重算「哪一行是目标」，也不新造第二套兜底：没选目标（或目标已不在列表里）时
    /// 沿用既有兜底 key（空名已由 `SyncDeviceList.displayName` 回落到占位文案）。
    private var targetDeviceName: String {
        guard let name = syncTargetStatus.target?.displayName,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return "sync_run_direction_download_target".localized
        }
        return name
    }

}
