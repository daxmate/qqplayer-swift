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

    var body: some View {
        VStack(spacing: DesignTokens.space0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Task { await model.refresh(count: settings.recommendationCount) }
            } label: {
                Label("recommendation_refresh".localized, systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(model.phase == .loading)
        }
        .padding(.horizontal, DesignTokens.space16)
        .padding(.vertical, DesignTokens.space12)
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
            ForEach(model.candidates) { candidate in
                row(candidate)
            }
        }
        .listStyle(.inset)
    }

    private func row(_ candidate: RecommendedCandidate) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.space12) {
            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                Text(candidate.title)
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
        var parts = [candidate.artist, candidate.source.localizationKey.localized]
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
            Text("recommendation_empty".localized)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("recommendation_refresh".localized) {
                Task { await model.refresh(count: settings.recommendationCount) }
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
                Task { await model.refresh(count: settings.recommendationCount) }
            }
        }
        .padding(DesignTokens.space24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
