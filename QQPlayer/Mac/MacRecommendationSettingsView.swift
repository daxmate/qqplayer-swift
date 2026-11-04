//
//  MacRecommendationSettingsView.swift
//  QQPlayer
//
//  本地 AI 推荐 P2：macOS「设置 → 推荐」分类。
//
//  - 模型卡片：repo 名 / 体积 / 状态 / 下载 / 进度 / 取消 / 删除。
//  - 开关：推荐使用本地模型（默认开）、模型常驻内存（默认关）。
//  - Intel Mac / 依赖不可用：明确提示，推荐自动走规则。
//
//  模型文件不进 bundle：下载目标见 RecommendationModelManager。
//  视图层不直连任何单例（planner 生命周期由 RecommendationPlannerFactory 负责）。
//

import SwiftUI

struct MacRecommendationSettingsView: View {
    @State private var settings = DeleteSettings.load()
    @State private var manager = RecommendationModelManager()

    private var mlxAvailable: Bool {
        #if canImport(MLXLLM) && arch(arm64) && os(macOS)
            return true
        #else
            return false
        #endif
    }

    var body: some View {
        Form {
            Section {
                modelCard
            } header: {
                Text("recommendation_model_title".localized)
            } footer: {
                Text(mlxAvailable ? "recommendation_model_footer".localized : "recommendation_model_unsupported".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("recommendation_use_local_model".localized, isOn: $settings.recommendationUseLocalModel)
                    .settingsAnchor(MacSettingsCatalog.recommendationUseLocalModel)
                    .onChange(of: settings.recommendationUseLocalModel) { _, _ in
                        settings.save()
                    }
                Toggle("recommendation_model_keep_loaded".localized, isOn: $settings.recommendationKeepModelLoaded)
                    .settingsAnchor(MacSettingsCatalog.recommendationKeepLoaded)
                    .onChange(of: settings.recommendationKeepModelLoaded) { _, _ in
                        settings.save()
                    }
            } footer: {
                Text("recommendation_model_keep_loaded_footer".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(value: $settings.recommendationChatRounds, in: DeleteSettings.recommendationChatRoundsRange) {
                    HStack {
                        Text("recommendation_chat_rounds_title".localized)
                        Spacer()
                        Text("\(settings.recommendationChatRounds)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .settingsAnchor(MacSettingsCatalog.recommendationChatRounds)
                .onChange(of: settings.recommendationChatRounds) { _, newValue in
                    settings.recommendationChatRounds = DeleteSettings.clampRecommendationChatRounds(newValue)
                    settings.save()
                }
            } footer: {
                Text("recommendation_chat_rounds_footer".localized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            manager.refreshState()
        }
    }

    // MARK: - 模型卡片

    private var modelCard: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space8) {
            HStack(alignment: .firstTextBaseline) {
                Text(manager.modelId)
                    .font(.callout)
                    .textSelection(.enabled)
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            Text(sizeText)
                .font(.caption)
                .foregroundStyle(.secondary)

            switch manager.state {
            case let .downloading(progress):
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                HStack {
                    Text(verbatim: "\(Int(progress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                    Spacer()
                    Button("recommendation_model_cancel".localized) {
                        manager.cancel()
                    }
                }
            case .ready, .loading:
                HStack {
                    Spacer()
                    Button("recommendation_model_delete".localized, role: .destructive) {
                        Task { await manager.delete() }
                    }
                }
            case .notDownloaded, .failed:
                HStack {
                    Spacer()
                    Button("recommendation_model_download".localized) {
                        manager.download()
                    }
                    .disabled(!mlxAvailable)
                }
            }
        }
        .padding(.vertical, DesignTokens.space4)
        .settingsAnchor(MacSettingsCatalog.recommendationModel)
    }

    private var statusText: String {
        switch manager.state {
        case .notDownloaded: return "recommendation_model_status_not_downloaded".localized
        case .downloading: return "recommendation_model_status_downloading".localized
        case .ready: return "recommendation_model_status_ready".localized
        case .loading: return "recommendation_model_status_loading".localized
        case let .failed(message): return message
        }
    }

    private var statusColor: Color {
        switch manager.state {
        case .ready: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private var sizeText: String {
        guard manager.totalBytes > 0 else {
            return "recommendation_model_size_unknown".localized
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(manager.totalBytes))
    }
}
