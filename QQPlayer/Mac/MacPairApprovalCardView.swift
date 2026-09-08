//
//  MacPairApprovalCardView.swift
//  QQPlayer
//
//  局域网同步（S2, M1-UI）Host 侧配对请求批准卡片（可复用组件）。
//
//  职责：展示一个待批准候选（PeerCandidate）——设备名 + Device ID 分组 +
//  来源/替换标记 + [批准][拒绝]。批准/拒绝动作以闭包上抛，由宿主接线到
//  PairingStateMachine（userApprovedOnHost / reject）。
//
//  触发路径：M2a 接通前没有真实网络请求源；本组件作为呈现层预留，宿主在
//  「收到候选（来自网络/未来传输层）」时实例化并弹层。纯呈现 + 回调，
//  不含任何状态机/存储逻辑，保证 M2a 可原样复用。
//

import SwiftUI

/// Host 侧配对请求批准卡片。
struct MacPairApprovalCardView: View {
    /// 待批准候选（由宿主传入：M2a = 网络 PairRequest 映射的候选；
    /// 本地模拟路径 = 状态机 awaitingConfirmation 态的候选）。
    let candidate: PeerCandidate
    /// 用户点「批准」（宿主接线 machine.handle(.userApprovedOnHost(at:))）。
    let onApprove: () -> Void
    /// 用户点「拒绝」（宿主接线 machine.handle(.reject)）。
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(SyncDeviceList.displayName(candidate))
                        .font(.headline)
                    Text(DeviceID.formatted(candidate.deviceID))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 6) {
                // 来源标记（QR 扫码 / 手动输入）
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

            HStack(spacing: 8) {
                Button("sync_approve".localized, action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                Button("sync_reject".localized, role: .cancel, action: onReject)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    VStack(spacing: 12) {
        MacPairApprovalCardView(candidate: PreviewCandidates.qr, onApprove: {}, onReject: {})
        MacPairApprovalCardView(candidate: PreviewCandidates.manualReplacement, onApprove: {}, onReject: {})
    }
    .padding(20)
    .frame(width: 480)
}

/// #Preview 用静态候选（预览不参与运行时逻辑；仅保证组件可实例化编译）。
private enum PreviewCandidates {
    static let qr = PeerCandidate(
        deviceID: "ABCDEFG234567ABCDEFG234567ABCDEFG234567ABCDEFG23",
        displayName: "张超的 iPhone",
        publicKeyRaw: Data(repeating: 1, count: 32),
        sessionNonce: Data(repeating: 2, count: 16),
        source: .qr,
        receivedAt: Date().timeIntervalSince1970,
        isReplacement: false
    )

    static let manualReplacement = PeerCandidate(
        deviceID: "ABCDEFG234567ABCDEFG234567ABCDEFG234567ABCDEFG23",
        displayName: "",
        publicKeyRaw: nil,
        sessionNonce: nil,
        source: .manualInput,
        receivedAt: Date().timeIntervalSince1970,
        isReplacement: true
    )
}
