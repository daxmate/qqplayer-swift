//
//  SyncDevicePane+Peer.swift
//  QQPlayer
//
//  批 1（2026-10-30）从 `SyncDevicePane.swift` 拆出：Mac 侧客户端角色的两块 UI
//  （本机 6 位配对码 / 发现的对端列表）。拆分理由 = 结构预算棘轮（单文件 >600 行即红）；
//  行为零变化，仍遵守「父 = 唯一观察者」：只读值 + 回调 / 绑定，不持有 @State。
//

import SwiftUI

extension SyncDevicePane {
    // MARK: - f 本机配对码（批 1，A 方案）

    /// 展示 6 位配对码（host 侧）：生成 / 倒计时 / 作废。
    /// 1s 刷新用 TimelineView（中心侧不装定时器；过期由时间判断 ⇒ UI 自然收起）。
    var pairingCodeSection: some View {
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let code = hostCenter.currentPairingCode(now: context.date) {
                    VStack(alignment: .leading, spacing: DesignTokens.space4) {
                        HStack(spacing: DesignTokens.space12) {
                            Text(code.grouped)
                                .font(.system(size: DesignTokens.font30, weight: .semibold, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Text("sync_pair_code_remaining".localized(with: code.remainingSeconds))
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Text("sync_pair_code_hint".localized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("sync_pair_code_empty".localized)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: DesignTokens.space8) {
                if hasActivePairingCode {
                    Button("sync_pair_code_cancel".localized, role: .destructive) {
                        hostCenter.cancelPairingCode()
                    }
                } else {
                    Button("sync_pair_code_generate".localized) {
                        hostCenter.generatePairingCode()
                    }
                    .disabled(!hostCenter.isRunning)
                }
                if !hostCenter.isRunning {
                    Text("sync_pair_code_need_listening".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("sync_pair_code_section".localized)
        }
    }

    var hasActivePairingCode: Bool {
        hostCenter.currentPairingCode() != nil
    }

    // MARK: - g 发现的对端（批 1，客户端角色）

    /// 发现列表 + 连接 / 配对码入口 + 当前客户端会话状态（与 host 监听并存）。
    var peerDiscoverySection: some View {
        Section {
            Toggle("sync_peer_browsing_toggle".localized, isOn: Binding(
                get: { peerClient.browsingEnabled },
                set: { onTogglePeerBrowsing($0) }
            ))
            if let key = peerClient.lastErrorKey {
                Text(key.localized)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if peerClient.peers.isEmpty {
                Text("sync_peer_empty".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(peerClient.peers) { peer in
                    peerRow(peer)
                }
            }
            if case .connected = peerClient.phase {
                Button("sync_peer_disconnect".localized, role: .destructive) {
                    onDisconnectPeer()
                }
            }
        } header: {
            Text("sync_peer_section".localized)
        }
    }

    @ViewBuilder
    func peerRow(_ peer: MacPeerClientCenter.DiscoveredPeer) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.space4) {
            HStack(spacing: DesignTokens.space8) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.secondary)
                Text(peer.name)
                if peer.isPaired {
                    Text("sync_peer_paired_badge".localized)
                        .font(.caption2)
                        .padding(.horizontal, DesignTokens.space6)
                        .padding(.vertical, DesignTokens.space2)
                        .background(Capsule().fill(accentColor.opacity(0.15)))
                        .foregroundStyle(accentColor)
                }
                Spacer()
                Text(peerPhaseText(peer.name))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if peerCodeTarget == peer.name {
                HStack(spacing: DesignTokens.space8) {
                    TextField("sync_pair_code_placeholder".localized, text: $peerCodeInput)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                        .onSubmit { submitPeerCode() }
                    Button("sync_pair_code_submit".localized) {
                        submitPeerCode()
                    }
                    .disabled(SyncPairingCodeStore.normalizedInput(peerCodeInput) == nil)
                    Button(Localized.cancel, role: .cancel) {
                        cancelPeerCodeEntry()
                    }
                }
            } else {
                HStack(spacing: DesignTokens.space8) {
                    Button("sync_peer_connect".localized) {
                        onConnectPeer(peer.name)
                    }
                    .disabled(peerClient.phase.isBusy)
                    Button("sync_peer_pair".localized) {
                        beginPeerCodeEntry(peer.name)
                    }
                    .disabled(peerClient.phase.isBusy)
                }
            }
        }
        .padding(.vertical, DesignTokens.space2)
    }

    /// 该设备当前会话状态文案（只对目标设备显示；其余留空）。
    func peerPhaseText(_ name: String) -> String {
        switch peerClient.phase {
        case .idle, .browsing, .failed:
            return ""
        case let .connecting(target):
            return target == name ? "sync_peer_phase_connecting".localized : ""
        case let .pairing(target):
            return target == name ? "sync_peer_phase_pairing".localized : ""
        case let .connected(target):
            return target == name ? "sync_peer_phase_connected".localized : ""
        }
    }

    func beginPeerCodeEntry(_ name: String) {
        peerCodeTarget = name
        peerCodeInput = ""
    }

    func cancelPeerCodeEntry() {
        peerCodeTarget = nil
        peerCodeInput = ""
    }

    func submitPeerCode() {
        guard let target = peerCodeTarget else { return }
        onPairPeer(target, peerCodeInput)
        cancelPeerCodeEntry()
    }
}
