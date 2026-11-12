//
//  MacRecommendationView.swift
//  QQPlayer
//
//  本地 AI 推荐 P1：推荐页（macOS only）。
//
//  列表：歌名 · 艺人 · 专辑 · 来源 · 理由；每行「下载」打开既有在线搜索面板并预填
//  `歌名 主艺人` 自动检索（用户自己点下载），「不再推荐」写本地黑名单。
//  空态 / 失败态明确文案，不放假数据。
//

import SwiftUI

struct MacRecommendationView: View {
    @State private var model = MacRecommendationModel()
    @State private var settings = DeleteSettings.load()
    @State private var downloadTarget: RecommendedCandidate?
    @State private var query = ""
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: DesignTokens.space0) {
            header
            Divider()
            chatBar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.phase == .loaded {
                sourceFooter
            }
        }
        .task {
            await model.loadIfNeeded(
                count: settings.recommendationCount,
                autoRefresh: settings.recommendationAutoRefresh
            )
        }
        .sheet(item: $downloadTarget) { candidate in
            MacOnlineSearchView(initialQuery: model.searchQuery(for: candidate))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: DesignTokens.space12) {
            Label("recommendations".localized, systemImage: "sparkles")
                .font(.title3.weight(.semibold))
            Spacer()
            Button {
                Task { await refresh() }
            } label: {
                Label("recommendation_refresh".localized, systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.phase == .loading)
        }
        .padding(.horizontal, DesignTokens.space16)
        .padding(.vertical, DesignTokens.space12)
    }

    // MARK: - 指令输入

    private var chatAvailability: RecommendationChatAvailability {
        RecommendationPlannerFactory.chatAvailability(useLocalModel: settings.recommendationUseLocalModel)
    }

    private var canSubmit: Bool {
        chatAvailability.canSubmit
            && model.phase != .loading
            && !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var chatBar: some View {
        VStack(alignment: .leading, spacing: DesignTokens.space6) {
            HStack(spacing: DesignTokens.space8) {
                TextField("recommendation_chat_placeholder".localized, text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                    .disabled(chatAvailability != .available || model.phase == .loading)

                Button {
                    submit()
                } label: {
                    if model.phase == .loading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!canSubmit)
                .help("recommendation_chat_send".localized)
            }

            if chatAvailability != .available {
                HStack(spacing: DesignTokens.space8) {
                    Text("recommendation_chat_model_not_ready".localized)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("recommendation_chat_go_to_settings".localized) {
                        openRecommendationSettings()
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            if let text = model.activeRequestText {
                HStack(spacing: DesignTokens.space6) {
                    Image(systemName: "text.bubble")
                        .font(.caption)
                    Text(text)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Button {
                        query = ""
                        Task { await model.clearRequest(count: settings.recommendationCount) }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("recommendation_chat_clear".localized)
                    Spacer(minLength: DesignTokens.space0)
                }
                .padding(.horizontal, DesignTokens.space8)
                .padding(.vertical, DesignTokens.space4)
                .background(
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                )
            }
        }
        .padding(.horizontal, DesignTokens.space16)
        .padding(.bottom, DesignTokens.space8)
    }

    private func submit() {
        guard canSubmit else { return }
        let text = query
        Task { await model.submit(text, count: settings.recommendationCount, rounds: settings.recommendationChatRounds, useLocalModel: settings.recommendationUseLocalModel) }
    }

    private func refresh() async {
        await model.refresh(
            count: settings.recommendationCount,
            rounds: settings.recommendationChatRounds,
            useLocalModel: settings.recommendationUseLocalModel
        )
    }

    private func openRecommendationSettings() {
        openSettings()
        MacSettingsRouter.open(
            .init(
                category: .recommendations,
                itemID: MacSettingsCatalog.recommendationModel.id
            )
        )
    }

    /// 页脚小字：生成来源 +（命中缓存时）「缓存结果 · X 分钟前」与「刷新」。
    private var sourceFooter: some View {
        HStack(spacing: DesignTokens.space8) {
            Text("recommendation_footer_source".localized(with: model.planSource.localizationKey.localized))
            if model.cacheHit, let cachedAt = model.cacheCreatedAt {
                Text("recommendation_footer_cache".localized(with: cacheAgeText(cachedAt)))
            }
            batchStatusText
            Spacer()
            Button("recommendation_refresh".localized) {
                Task { await refresh() }
            }
            .buttonStyle(.link)
            .disabled(model.phase == .loading || model.isRefilling)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, DesignTokens.space16)
        .padding(.vertical, DesignTokens.space8)
    }

    /// 缓存时间的相对文案（分钟 / 小时两档，够用且不引第三方格式化）。
    /// 批次状态：补充中 / 还有下一批 / 本批已看完（不静默）。
    @ViewBuilder
    private var batchStatusText: some View {
        if model.isRefilling {
            Text("recommendation_batch_refilling".localized)
        } else if model.hasBatchSession {
            if model.batchRemaining > 0 {
                Text("recommendation_batch_remaining".localized(with: model.batchRemaining))
            } else {
                Text("recommendation_batch_exhausted".localized)
            }
        }
    }

    private func cacheAgeText(_ date: Date) -> String {
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        if minutes < 60 {
            return "recommendation_cache_age_minutes".localized(with: minutes)
        }
        return "recommendation_cache_age_hours".localized(with: minutes / 60)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            loadingView
        case .loaded:
            if model.candidates.isEmpty {
                emptyView
            } else {
                candidateList
            }
        case let .failed(message):
            failureView(message)
        }
    }

    private var candidateList: some View {
        List {
            Section {
                ForEach(model.candidates) { candidate in
                    row(candidate)
                }
            } header: {
                Text(resultsTitle)
                    .font(.caption.weight(.semibold))
            } footer: {
                if let notice = artistShortfallNotice {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.inset)
    }

    /// 点名艺人结果不足时如实说明（不静默填充画像项）。
    private var artistShortfallNotice: String? {
        guard let artist = model.requestedArtist,
              model.candidates.count < settings.recommendationCount
        else { return nil }
        return "recommendation_artist_shortfall".localized(with: model.candidates.count, artist)
    }

    /// 结果标题：有指令 = 按你的要求；否则 = 为你推荐（不展示任何历史消息）。
    private var resultsTitle: String {
        model.activeRequestText == nil
            ? "recommendation_results_for_you".localized
            : "recommendation_chat_results_title".localized
    }

    private func row(_ candidate: RecommendedCandidate) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.space12) {
            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(DisplayScriptNormalizer.display(candidate.title))
                    .font(.body)
                    .lineLimit(1)
                Text(subtitle(for: candidate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(reasons(for: candidate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: DesignTokens.space8)
            Button("recommendation_download".localized) {
                downloadTarget = candidate
            }
            .buttonStyle(.bordered)
            Button("recommendation_dismiss".localized) {
                model.dismiss(candidate)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, DesignTokens.space4)
    }

    private func subtitle(for candidate: RecommendedCandidate) -> String {
        var parts = [DisplayScriptNormalizer.display(candidate.artist), candidate.source.localizationKey.localized]
        if let album = candidate.album, !album.isEmpty {
            parts.insert(album, at: 1)
        }
        return parts.joined(separator: " · ")
    }

    private func reasons(for candidate: RecommendedCandidate) -> String {
        candidate.reasons.prefix(2).joined(separator: " · ")
    }

    private var loadingView: some View {
        VStack(spacing: DesignTokens.space12) {
            ProgressView()
            Text("recommendation_loading".localized)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: DesignTokens.space12) {
            Image(systemName: "sparkles")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(artistShortfallNotice ?? "recommendation_empty".localized)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("recommendation_refresh".localized) {
                Task { await refresh() }
            }
        }
        .padding(DesignTokens.space24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: DesignTokens.space12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("recommendation_refresh".localized) {
                Task { await refresh() }
            }
        }
        .padding(DesignTokens.space24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
