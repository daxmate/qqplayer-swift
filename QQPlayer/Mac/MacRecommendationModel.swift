//
//  MacRecommendationModel.swift
//  QQPlayer
//
//  本地 AI 推荐 P1：推荐页状态模型（macOS only）。
//
//  职责：读设置 → 拉画像输入 → 调规则引擎 → 维护列表 / 加载 / 失败态；
//  「不再推荐」写本地黑名单 JSON（App Support，不建表不迁移）。
//  生成在后台 Task 里跑（DB 读在 detached task，网络在引擎内部并发），不阻塞主线程。
//

import Foundation
import Observation

@MainActor
@Observable
final class MacRecommendationModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var candidates: [RecommendedCandidate] = []
    private(set) var lastGeneratedAt: Date?
    /// 最近一次生成用的检索计划来源（规则 / 本地模型），页脚展示用。
    private(set) var planSource: RecommendationPlanSource = .rule
    /// 当前生效的指令原话（只用于 chip 展示；历史不展示）。
    private(set) var activeRequestText: String?

    /// 打开 App 时判断 24h（P1 不做定时器，见任务包 F）。
    static let refreshInterval: TimeInterval = 24 * 3600

    private let blacklistURL: URL?
    private let historyURL: URL?
    private let clock: () -> Date
    private var blacklist: RecommendationBlacklist
    private var isGenerating = false

    init(
        blacklistURL: URL? = RecommendationBlacklistStore.defaultURL(),
        historyURL: URL? = RecommendationRequestHistoryStore.defaultURL(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.blacklistURL = blacklistURL
        self.historyURL = historyURL
        self.clock = clock
        blacklist = RecommendationBlacklistStore.load(from: blacklistURL)
    }

    /// 首次进入或过期（autoRefresh 开启且距上次生成 ≥ 24h）才重新生成。
    func loadIfNeeded(count: Int, autoRefresh: Bool) async {
        if !candidates.isEmpty, let lastGeneratedAt {
            let expired = clock().timeIntervalSince(lastGeneratedAt) >= Self.refreshInterval
            if !(autoRefresh && expired) { return }
        }
        await generate(count: count)
    }

    /// 「换一批」：有指令时重跑该指令，否则重新生成画像推荐。
    func refresh(
        count: Int,
        rounds: Int = DeleteSettings.defaultRecommendationChatRounds,
        useLocalModel: Bool = true
    ) async {
        if let text = activeRequestText {
            await submit(text, count: count, rounds: rounds, useLocalModel: useLocalModel)
        } else {
            await generate(count: count)
        }
    }

    /// 指令输入：只走本地模型；模型未就绪直接失败，绝不回退规则解析。
    func submit(_ text: String, count: Int, rounds: Int, useLocalModel: Bool) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }
        isGenerating = true
        phase = .loading
        defer { isGenerating = false }

        #if canImport(MLXLLM) && arch(arm64) && os(macOS)
            guard RecommendationPlannerFactory.chatAvailability(useLocalModel: useLocalModel) == .available,
                  let planner = RecommendationPlannerFactory.makeChatPlanner()
            else {
                phase = .failed(RecommendationRequestError.modelNotReady.localizedDescription)
                return
            }

            guard let input = await RecommendationDataSource.loadInput(now: clock(), blacklist: blacklist) else {
                phase = .failed("recommendation_error_load_failed".localized)
                return
            }
            if Task.isCancelled { return }

            let profile = RecommendationProfileBuilder.build(input)
            let history = RecommendationRequestHistoryStore.load(from: historyURL, limit: rounds)
            let planned = await planner.makeRequest(text: trimmed, history: history.entries, profile: profile)
            if Task.isCancelled { return }

            let request: RecommendationUserRequest
            switch planned {
            case let .success(value):
                request = value
            case let .failure(error):
                phase = .failed(error.localizedDescription)
                return
            }

            let result = await RecommendationEngine().recommend(
                request: request,
                profile: profile,
                count: count
            )
            if Task.isCancelled { return }

            switch result {
            case let .success(list):
                candidates = list
                activeRequestText = trimmed
                lastGeneratedAt = clock()
                planSource = .localModel
                phase = .loaded
                var updated = history
                updated.append(
                    RecommendationRequestHistoryEntry(
                        requestText: trimmed,
                        results: RecommendationRequestHistory.results(from: list),
                        createdAt: clock()
                    ),
                    limit: rounds
                )
                _ = RecommendationRequestHistoryStore.save(updated, to: historyURL, limit: rounds)
            case let .failure(error):
                phase = .failed(error.localizedDescription)
            }
        #else
            phase = .failed(RecommendationRequestError.modelNotReady.localizedDescription)
        #endif
    }

    /// 清除当前指令，回到画像推荐。
    func clearRequest(count: Int) async {
        activeRequestText = nil
        await generate(count: count)
    }

    /// 「不再推荐」：写黑名单并立即从列表移除。
    func dismiss(_ candidate: RecommendedCandidate) {
        blacklist.add(title: candidate.title, artist: candidate.artist)
        RecommendationBlacklistStore.save(blacklist, to: blacklistURL)
        candidates.removeAll { $0.id == candidate.id }
    }

    /// 跳转在线搜索时的预填词：`歌名 主艺人`。
    func searchQuery(for candidate: RecommendedCandidate) -> String {
        let artist = RecommendationKey.displayPrimaryArtist(candidate.artist)
        return artist.isEmpty ? candidate.title : "\(candidate.title) \(artist)"
    }

    private func generate(count: Int) async {
        guard !isGenerating else { return }
        isGenerating = true
        phase = .loading
        defer { isGenerating = false }

        guard let input = await RecommendationDataSource.loadInput(now: clock(), blacklist: blacklist) else {
            phase = .failed("recommendation_error_load_failed".localized)
            return
        }
        if Task.isCancelled { return }

        let profile = RecommendationProfileBuilder.build(input)
        let planner = RecommendationPlannerFactory.make(settings: DeleteSettings.load())
        let plan = await planner.makePlan(for: profile)
        if Task.isCancelled { return }
        planSource = plan.source
        let result = await RecommendationEngine().recommend(
            profile: profile,
            count: count,
            intents: plan.intents
        )
        if Task.isCancelled { return }

        switch result {
        case let .success(list):
            candidates = list
            lastGeneratedAt = clock()
            phase = .loaded
        case let .failure(error):
            phase = .failed(error.localizedDescription)
        }
    }
}
