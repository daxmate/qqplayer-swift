//
//  SyncManualEntryView.swift
//  QQPlayer
//
//  局域网同步（S2, M1-UI）iOS 手动输入 Device ID 配对页（docs §4.2 备选路径）：
//  1. TextField 输入（容忍分隔符/空白/大小写）→ SyncPairingFlow.manualEvent
//     组装 → PairingStateMachine.manualIDEntered（规范化/字符集校验在机器内）
//  2. awaitingConfirmation → 确认页（无对方公钥/nonce：指纹校验与签名证明
//     在 M2 握手响应完成 → 卡片标注「连接后补全公钥」）
//  3. approved 后不落库（手输候选 peerPublicKey 为空串，落库前需公钥）：
//     提示「已请求配对（等待主机批准；首次连接补全设备信息）」，到 client
//     approved 态即止——UI 不承诺双向完成。
//

import SwiftUI

/// iOS 手动输入配对页。
struct SyncManualEntryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var machine = PairingStateMachine()
    @State private var input = ""
    @State private var flow: SyncManualFlow = .input
    @State private var showInputError = false
    private let deviceStore = DeviceStore()

    /// 输入是否为合法 Device ID（即时提示用；最终校验以机器 handle 结果为准）
    private var inputLooksValid: Bool {
        DeviceID.isValid(input)
    }

    var body: some View {
        Group {
            switch flow {
            case .input:
                inputBody
            case let .awaitingConfirm(candidate):
                confirmBody(candidate)
            case let .outcome(outcome):
                SyncPairOutcomeView(
                    symbol: outcome.symbol,
                    title: outcome.title,
                    message: outcome.message,
                    actionTitle: outcome.actionTitle,
                    onAction: { handleOutcomeAction(outcome) },
                    symbolColor: outcome.symbolColor
                )
            }
        }
        .navigationTitle("sync_manual_input".localized)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(Localized.cancel) { dismiss() }
            }
        }
        .alert("sync_invalid_id_title".localized, isPresented: $showInputError) {
            Button(Localized.ok) {}
        } message: {
            Text("sync_invalid_id_message".localized)
        }
    }

    // MARK: - 输入态

    private var inputBody: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("sync_manual_hint".localized)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("sync_manual_placeholder".localized, text: $input, axis: .vertical)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2 ... 4)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }

                if !input.isEmpty {
                    Label(
                        inputLooksValid
                            ? "sync_manual_id_valid".localized
                            : "sync_manual_id_invalid".localized,
                        systemImage: inputLooksValid ? "checkmark.circle" : "xmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(inputLooksValid ? .green : .red)
                }
            }

            Button("sync_manual_continue".localized) {
                submit()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: - 确认态

    private func confirmBody(_ candidate: PeerCandidate) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("sync_confirm_pair_title".localized)
                    .font(.headline)
                SyncPairConfirmCardView(
                    candidate: candidate,
                    awaitingPublicKey: true,
                    onConfirm: { confirm(candidate) },
                    onCancel: { cancelToInput() }
                )
            }
            .padding(16)
        }
    }

    // MARK: - 动作

    /// 点继续：组装 manualIDEntered 事件 → 机器校验 → awaiting 卡 / failed 提示。
    @MainActor
    private func submit() {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        // alreadyPaired：机器内部会规范化；这里先规范化查库（查不到=false）
        let alreadyPaired: Bool
        if let normalized = DeviceID.normalized(raw) {
            alreadyPaired = (try? deviceStore.byPeerID(normalized)) != nil
        } else {
            alreadyPaired = false
        }
        machine.handle(.manualIDEntered(raw, at: Date().timeIntervalSince1970, alreadyPaired: alreadyPaired))
        switch machine.state {
        case let .awaitingConfirmation(candidate):
            flow = .awaitingConfirm(candidate)
        case let .failed(failure):
            // 非法 ID/字符集：回到输入态并提示（用户可改错重输）
            if failure == .invalidDeviceID(raw) {
                showInputError = true
                flow = .input
            } else {
                flow = .outcome(.failed(failure))
            }
        default:
            flow = .outcome(.invalidQRCode)
        }
    }

    /// 用户确认 → approved → 不落库（无公钥），展示「等待主机批准 + 连接补全」。
    @MainActor
    private func confirm(_ candidate: PeerCandidate) {
        machine.handle(.userConfirmedOnClient(at: Date().timeIntervalSince1970))
        guard case let .approved(approved) = machine.state else {
            if case let .expired(expired) = machine.state {
                flow = .outcome(.expired(expired.displayName))
            }
            return
        }
        flow = .outcome(.manualApprovedAwaitingHost(name: approved.displayName))
    }

    @MainActor
    private func cancelToInput() {
        machine.handle(.cancel)
        machine = PairingStateMachine()
        flow = .input
    }

    @MainActor
    private func handleOutcomeAction(_ outcome: SyncPairOutcome) {
        switch outcome {
        case .manualApprovedAwaitingHost, .storeFailed:
            dismiss()
        default:
            // 失败/过期/无效码 → 回到输入态重试
            machine = PairingStateMachine()
            flow = .input
        }
    }
}

/// 手输页流程。
enum SyncManualFlow: Equatable {
    case input
    case awaitingConfirm(PeerCandidate)
    case outcome(SyncPairOutcome)
}
