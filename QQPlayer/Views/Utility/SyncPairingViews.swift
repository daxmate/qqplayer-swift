//
//  SyncPairingViews.swift
//  QQPlayer
//
//  局域网同步（S2, M1-UI）iOS 配对流程共享视图组件：
//  - SyncPairConfirmCardView：待确认候选卡（设备名 + ID 分组 + 来源/
//    替换标记 + 手输公钥提示），扫码与手输两条路径共用（行为单一事实源）。
//  - SyncPairOutcomeView：配对结果页（成功「已配对（等待主机批准）」/
//    超时/失败原因/拒绝），统一排版，两端流程共用。
//
//  纯呈现组件：确认/取消/完成动作全部闭包上抛，状态机事件与落库由
//  各流程页（SyncQRScannerView / SyncManualEntryView）负责。
//

import SwiftUI

/// 待确认候选卡（iOS）。
struct SyncPairConfirmCardView: View {
    let candidate: PeerCandidate
    /// 手输路径候选无公钥（M1-UI 落库前需公钥，等待 M2 握手补全）→ 显示提示
    let awaitingPublicKey: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SyncDeviceList.displayName(candidate))
                        .font(.headline)
                    Text("sync_confirm_pair_caption".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("sync_device_id".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(DeviceID.formatted(candidate.deviceID))
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                switch candidate.source {
                case .qr:
                    Label("sync_source_qr".localized, systemImage: "qrcode.viewfinder")
                case .manualInput:
                    Label("sync_source_manual".localized, systemImage: "keyboard")
                }
                if candidate.isReplacement {
                    Label("sync_replacement_badge".localized, systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)

            if awaitingPublicKey {
                Label("sync_pubkey_pending_hint".localized, systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            HStack(spacing: 10) {
                Button("sync_confirm_pair".localized, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                Button(Localized.cancel, action: onCancel)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// 配对流程结果页（成功/超时/失败/拒绝统一排版）。
struct SyncPairOutcomeView: View {
    let symbol: String
    let title: String
    let message: String
    /// 主按钮文案；nil = 不显示按钮（宿主自行处理关闭）
    let actionTitle: String?
    let onAction: () -> Void
    /// 图标着色（成功绿/失败红/警告橙，由调用方语义决定）
    var symbolColor: Color = .secondary

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 52))
                .foregroundStyle(symbolColor)
            Text(title)
                .font(.title3)
                .fontWeight(.semibold)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(actionTitle, action: onAction)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
