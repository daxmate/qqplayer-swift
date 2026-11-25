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
    @State private var hoveredRowID: String?
    @Environment(\.openSettings) private var openSettings
    /// App 强调色（macOS 上 Color.accentColor 跟随系统而非 App tint，统一读环境值）。
    @Environment(\.appAccentColor) private var accentColor

    var body: some View {
        VStack(spacing: DesignTokens.space0) {
            header
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
        .sheet(item: $downloadTarget, onDismiss: {
            // 兜底：关闭面板时先刷一次（此刻可能尚未落库，靠下面两条通知补齐）。
            Task { await model.refreshDownloadedKeys() }
        }) { candidate in
            MacOnlineSearchView(initialQuery: model.searchQuery(for: candidate))
        }
        // 下载 → 文件落盘 → LibraryIndexer 入库 → trackFound 通知：下载真正完成的信号。
        .onReceive(NotificationCenter.default.publisher(for: .trackFound)) { _ in
            model.scheduleDownloadedKeysRefresh()
        }
        // 扫描收尾 / 元数据刷新 / 清理等批量曲库写入。
        .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
            model.scheduleDownloadedKeysRefresh()
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

    private func refresh() async {
        await model.refresh(count: settings.recommendationCount)
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
                Text("recommendation_results_for_you".localized)
                    .font(.caption.weight(.semibold))
            }
        }
        .listStyle(.inset)
        .macGlassListBackground()
    }

    private func row(_ candidate: RecommendedCandidate) -> some View {
        let isHovered = hoveredRowID == candidate.id
        let isDownloaded = model.isDownloaded(candidate)
        return HStack(alignment: .top, spacing: DesignTokens.space12) {
            VStack(alignment: .leading, spacing: DesignTokens.space2) {
                HStack(spacing: DesignTokens.space6) {
                    Text(DisplayScriptNormalizer.display(candidate.title))
                        .font(.body)
                        .lineLimit(1)
                    if isDownloaded {
                        Text("recommendation_downloaded_badge".localized)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, DesignTokens.space6)
                            .padding(.vertical, DesignTokens.space2)
                            .background(accentColor.opacity(0.16), in: Capsule())
                            .foregroundStyle(accentColor)
                            .accessibilityLabel("recommendation_downloaded_badge".localized)
                    }
                }
                .foregroundStyle(isDownloaded ? accentColor : Color.primary)
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
            // 行内动作按钮：悬停整行才显示（opacity 占位，不跳动布局）
            HStack(spacing: DesignTokens.space8) {
                if !isDownloaded {
                    Button("recommendation_download".localized) {
                        downloadTarget = candidate
                    }
                    .buttonStyle(.bordered)
                }
                Button("recommendation_dismiss".localized) {
                    model.dismiss(candidate)
                }
                .buttonStyle(.borderless)
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .animation(.easeOut(duration: 0.12), value: isHovered)
        }
        .padding(.vertical, DesignTokens.space4)
        .onHover { hoveredRowID = $0 ? candidate.id : nil }
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
            Text("recommendation_empty".localized)
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
