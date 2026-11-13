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

    var phase: Phase = .idle
    var candidates: [RecommendedCandidate] = []
    private(set) var lastGeneratedAt: Date?
    /// 最近一次生成用的检索计划来源（规则 / 本地模型），页脚展示用。
    var planSource: RecommendationPlanSource = .rule
    /// 当前生效的指令原话（只用于 chip 展示；历史不展示）。
    private(set) var activeRequestText: String?
    /// 本轮点名的艺人（展示名）：结果不足时页面据此说明「只找到 N 首 X 的歌」。
    var requestedArtist: String?

    /// 打开 App 时判断 24h（P1 不做定时器，见任务包 F）。
    static let refreshInterval: TimeInterval = 24 * 3600

    /// 本次结果是否来自结果缓存（UI 页脚展示「缓存结果 · X 分钟前」）。
    private(set) var cacheHit = false
    /// 缓存条目的生成时间（命中时展示；未命中为 nil）。
    private(set) var cacheCreatedAt: Date?

    let blacklistURL: URL?
    private let historyURL: URL?
    let clock: () -> Date
    /// 缓存命中编排（exact / stale 垫底 / miss）+ 后台重算代次控制。
    private let flow: RecommendationCacheFlow
    var blacklist: RecommendationBlacklist
    private var isGenerating = false
    /// 最近一次请求的缓存键（「不再推荐」时清掉，避免下次命中把已拉黑的歌带回来）。
    var lastCacheKey: RecommendationCacheKeyInput?

    // MARK: P2 会话池（15 首 / 换一批）

    /// 会话池（换一批只推进游标，不重新请求网络）。
    var session: RecallSession?
    /// 池里还剩多少首可推（UI 页脚状态）。
    var batchRemaining = 0
    /// 池不足一批、正在增量查询（UI「补充中」）。
    private(set) var isRefilling = false

    // MARK: P3 模型理由（首屏规则 → 异步替换）

    /// 理由来源（nil = 按设置解析：本地模型就绪用 MLX，否则规则；单测可注入桩）。
    var reasonProvider: (any RecommendationReasonProviding)?
    /// 在跑的理由刷新任务（换批 / 新一批时取消）。
    var reasonTask: Task<Void, Never>?
    /// 理由刷新代次（防止旧任务把旧理由盖到新一批上）。
    var reasonGeneration = 0
    /// 本次计算是否为「补池」（true = 追加到现有会话，不重建池）。
    var isRefillingSession = false
    /// 当前是否有会话池（决定「换一批 / 已看完」文案）。
    var hasBatchSession: Bool { session != nil }

    init(
        blacklistURL: URL? = RecommendationBlacklistStore.defaultURL(),
        historyURL: URL? = RecommendationRequestHistoryStore.defaultURL(),
        cacheDirectoryURL: URL? = RecommendationResultCache.defaultDirectoryURL(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.blacklistURL = blacklistURL
        self.historyURL = historyURL
        self.clock = clock
        flow = RecommendationCacheFlow(
            cache: cacheDirectoryURL.map { RecommendationResultCache(directory: $0, clock: clock) },
            clock: clock
        )
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

    /// 「换一批」/ 页脚「刷新」：手动动作，**强制绕过缓存并覆盖**。
    func refresh(
        count: Int,
        rounds: Int = DeleteSettings.defaultRecommendationChatRounds,
        useLocalModel: Bool = true
    ) async {
        guard !isGenerating else { return }
        // 换一批：池里还有 ≥15 → 直接推进游标（不重算、不重新请求）。
        if advanceBatchIfAvailable() { return }
        // 池剩余 <15 或已耗尽 → 增量查询补池；补满一批前不出残批。
        isRefilling = true
        isRefillingSession = session != nil
        defer {
            isRefilling = false
            isRefillingSession = false
        }
        if let text = activeRequestText {
            await submit(text, count: count, rounds: rounds, useLocalModel: useLocalModel, bypassCache: true)
        } else {
            await generate(count: count, bypassCache: true)
        }
    }

    /// 指令输入：只走本地模型；模型未就绪直接失败，绝不回退规则解析。
    func submit(
        _ text: String,
        count: Int,
        rounds: Int,
        useLocalModel: Bool,
        bypassCache: Bool = false
    ) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isGenerating else { return }
        isGenerating = true
        let token = flow.beginRequest()
        if candidates.isEmpty {
            phase = .loading
        }
        cacheHit = false
        cacheCreatedAt = nil
        if !isRefillingSession {
            session = nil
            batchRemaining = 0
        }
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
            let key = cacheKey(
                rawText: trimmed,
                profile: profile,
                libraryFingerprint: input.libraryFingerprint,
                planSource: .localModel,
                modelIdentity: RecommendationPlannerFactory.localModelIdentity() ?? "none"
            )
            lastCacheKey = key
            switch flow.lookup(key, bypassCache: bypassCache) {
            case let .exact(hit):
                applyCacheHit(hit, requestText: trimmed)
                return
            case let .stale(hit):
                // 列表优先：先用旧候选垫底，后台重算完成后平滑替换。
                applyCacheHit(hit, requestText: trimmed)
                startChatRefresh(
                    token: token,
                    key: key,
                    context: ChatRefreshContext(
                        planner: planner,
                        profile: profile,
                        count: count,
                        text: trimmed,
                        rounds: rounds
                    )
                )
                return
            case .miss:
                phase = .loading
            }

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

            let poolTarget = max(RecommendationBatchPolicy.poolTarget, count * 4)
            let result = await poolEngine().recommend(
                request: request,
                profile: profile,
                count: poolTarget,
                planSource: .localModel,
                excludedTrackKeys: excludedTrackKeys
            )
            if Task.isCancelled { return }

            switch result {
            case let .success(list):
                let batch = applyPool(
                    list,
                    count: count,
                    namedArtist: RecommendationArtistMix.isNamedArtistRequest(request),
                    relatedArtistShare: DeleteSettings.load().relatedArtistShare
                )
                if batch.isEmpty, isRefillingSession {
                    phase = .loaded
                    return
                }
                candidates = batch
                startReasonRefresh(for: batch)
                blacklist.markRecommended(batch, at: clock())
                _ = RecommendationBlacklistStore.save(blacklist, to: blacklistURL)
                activeRequestText = trimmed
                requestedArtist = request.referenceArtists
                    .map { RecommendationKey.displayPrimaryArtist($0) }
                    .first { !$0.isEmpty }
                lastGeneratedAt = clock()
                planSource = .localModel
                phase = .loaded
                storeCache(
                    key,
                    planSource: .localModel,
                    candidates: batch,
                    requestedArtist: requestedArtist
                )
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
                requestedArtist = nil
                phase = .failed(error.localizedDescription)
            }
        #else
            requestedArtist = nil
            phase = .failed(RecommendationRequestError.modelNotReady.localizedDescription)
        #endif
    }

    /// 清除当前指令，回到画像推荐。
    func clearRequest(count: Int) async {
        activeRequestText = nil
        requestedArtist = nil
        session = nil
        batchRemaining = 0
        await generate(count: count)
    }

    /// 「不再推荐」：写黑名单并立即从列表移除。
    func dismiss(_ candidate: RecommendedCandidate) {
        blacklist.add(title: candidate.title, artist: candidate.artist)
        RecommendationBlacklistStore.save(blacklist, to: blacklistURL)
        session?.markSeen([candidate])
        candidates.removeAll { $0.id == candidate.id }
        if let lastCacheKey {
            // 在途后台重算先作废：否则它算完会把刚拉黑的歌带回来。
            _ = flow.beginRequest()
            flow.invalidate(lastCacheKey)
        }
    }

    /// 跳转在线搜索时的预填词：`歌名 主艺人`。
    func searchQuery(for candidate: RecommendedCandidate) -> String {
        let artist = RecommendationKey.displayPrimaryArtist(candidate.artist)
        return artist.isEmpty ? candidate.title : "\(candidate.title) \(artist)"
    }

    private func generate(count: Int, bypassCache: Bool = false) async {
        guard !isGenerating else { return }
        isGenerating = true
        let token = flow.beginRequest()
        if candidates.isEmpty {
            phase = .loading
        }
        cacheHit = false
        cacheCreatedAt = nil
        requestedArtist = nil
        if !isRefillingSession {
            session = nil
            batchRemaining = 0
        }
        defer { isGenerating = false }

        guard let input = await RecommendationDataSource.loadInput(now: clock(), blacklist: blacklist) else {
            phase = .failed("recommendation_error_load_failed".localized)
            return
        }
        if Task.isCancelled { return }

        let profile = RecommendationProfileBuilder.build(input)
        let selection = RecommendationPlannerFactory.selection(settings: DeleteSettings.load())
        let key = cacheKey(
            rawText: "",
            profile: profile,
            libraryFingerprint: input.libraryFingerprint,
            planSource: selection.planSource,
            modelIdentity: selection.modelIdentity
        )
        lastCacheKey = key
        switch flow.lookup(key, bypassCache: bypassCache) {
        case let .exact(hit):
            applyCacheHit(hit, requestText: nil)
            return
        case let .stale(hit):
            // 列表优先：先用旧候选垫底，后台重算完成后平滑替换。
            applyCacheHit(hit, requestText: nil)
            startProfileRefresh(
                token: token,
                key: key,
                selection: selection,
                profile: profile,
                count: count
            )
            return
        case .miss:
            phase = .loading
        }

        let plan = await selection.planner.makePlan(for: profile)
        if Task.isCancelled { return }
        planSource = plan.source
        let poolTarget = max(RecommendationBatchPolicy.poolTarget, count * 4)
        let result = await poolEngine().recommend(
            profile: profile,
            count: poolTarget,
            intents: plan.intents,
            planSource: plan.source,
            excludedTrackKeys: excludedTrackKeys
        )
        if Task.isCancelled { return }

        switch result {
        case let .success(list):
            let batch = applyPool(list, count: count)
            if batch.isEmpty, isRefillingSession {
                phase = .loaded
                return
            }
            candidates = batch
            lastGeneratedAt = clock()
            phase = .loaded
            startReasonRefresh(for: batch)
            blacklist.markRecommended(batch, at: clock())
            _ = RecommendationBlacklistStore.save(blacklist, to: blacklistURL)
            storeCache(key, planSource: plan.source, candidates: batch)
        case let .failure(error):
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - 结果缓存

    /// P4：艺人关系扩展开关（进缓存键：开关变化不复用旧池）。
    private var artistRelationExpansionEnabled: Bool {
        DeleteSettings.load().recommendationArtistRelationExpansion
    }

    /// 缓存键：请求原话 + 画像摘要 + 曲库指纹 + planner/模型身份 + locale。
    ///
    /// 说明：chat 指令的解析结果（referenceArtists 等）是模型的非确定输出，放进键会让同句
    /// 复现率趋零，故请求身份用 rawText；解析结果只作为条目摘要留档。
    private func cacheKey(
        rawText: String,
        profile: TasteProfile,
        libraryFingerprint: String,
        planSource: RecommendationPlanSource,
        modelIdentity: String
    ) -> RecommendationCacheKeyInput {
        RecommendationCacheKeyInput(
            rawText: rawText,
            profileSummary: RecommendationProfileSummary.make(from: profile).cacheKeyText,
            libraryFingerprint: libraryFingerprint,
            planner: planSource,
            modelIdentity: modelIdentity,
            localeIdentifier: Locale.current.identifier,
            sourceVersion: RecommendationSourceChain.cacheVersion(
                artistRelationExpansion: artistRelationExpansionEnabled
            ),
            blacklistVersion: blacklist.recentVersion
        )
    }

    /// 命中即落状态（planner / 召回引擎都不启动）；stale 命中随后由调用方安排后台重算。
    private func applyCacheHit(_ hit: RecommendationCacheHit, requestText: String?) {
        candidates = hit.candidates
        session = nil
        batchRemaining = 0
        planSource = hit.planSource
        lastGeneratedAt = hit.createdAt
        cacheHit = true
        cacheCreatedAt = hit.createdAt
        if let requestText {
            activeRequestText = requestText
        }
        requestedArtist = hit.requestedArtist
        phase = .loaded
        startReasonRefresh(for: candidates)
    }

    /// 成功后写缓存（空结果 / 失败结果不写）。
    func storeCache(
        _ key: RecommendationCacheKeyInput,
        planSource: RecommendationPlanSource,
        candidates: [RecommendedCandidate],
        requestedArtist: String? = nil
    ) {
        flow.store(
            RecommendationRecompute(
                candidates: candidates,
                planSource: planSource,
                requestedArtist: requestedArtist
            ),
            key: key
        )
    }

    // MARK: - 后台重算（stale 垫底后的平滑替换）

    /// 指令推荐重算的输入（planner + 请求上下文）。
    private struct ChatRefreshContext {
        var planner: any RecommendationRequestPlanning
        var profile: TasteProfile
        var count: Int
        var text: String
        var rounds: Int
    }

    /// 画像推荐：stale 命中后先返回，后台跑 planner + 召回，完成后替换候选并写回新键。
    private func startProfileRefresh(
        token: Int,
        key: RecommendationCacheKeyInput,
        selection: RecommendationPlannerSelection,
        profile: TasteProfile,
        count: Int
    ) {
        flow.startBackgroundRefresh(
            token: token,
            key: key,
            currentCandidates: candidates
        ) { [weak self] in
            await self?.computeProfileRecompute(selection: selection, profile: profile, count: count)
        } apply: { [weak self] recompute, changed in
            self?.applyRecompute(recompute, changed: changed, requestText: nil, chat: nil)
        }
    }

    /// 指令推荐：同上，只是重算走 chat planner（解析 + 召回）。
    private func startChatRefresh(
        token: Int,
        key: RecommendationCacheKeyInput,
        context: ChatRefreshContext
    ) {
        flow.startBackgroundRefresh(
            token: token,
            key: key,
            currentCandidates: candidates
        ) { [weak self] in
            await self?.computeChatRecompute(context: context)
        } apply: { [weak self] recompute, changed in
            self?.applyRecompute(
                recompute,
                changed: changed,
                requestText: context.text,
                chat: (text: context.text, rounds: context.rounds)
            )
        }
    }

    private func computeProfileRecompute(
        selection: RecommendationPlannerSelection,
        profile: TasteProfile,
        count: Int
    ) async -> RecommendationRecompute? {
        let plan = await selection.planner.makePlan(for: profile)
        if Task.isCancelled { return nil }
        let result = await RecommendationEngine.configured().recommend(
            profile: profile,
            count: count,
            intents: plan.intents,
            planSource: plan.source
        )
        if Task.isCancelled { return nil }
        guard case let .success(list) = result else { return nil }
        return RecommendationRecompute(candidates: list, planSource: plan.source, requestedArtist: nil)
    }

    private func computeChatRecompute(context: ChatRefreshContext) async -> RecommendationRecompute? {
        let history = RecommendationRequestHistoryStore.load(from: historyURL, limit: context.rounds)
        let planned = await context.planner.makeRequest(
            text: context.text,
            history: history.entries,
            profile: context.profile
        )
        if Task.isCancelled { return nil }
        guard case let .success(request) = planned else { return nil }
        let result = await RecommendationEngine.configured().recommend(
            request: request,
            profile: context.profile,
            count: context.count,
            planSource: .localModel
        )
        if Task.isCancelled { return nil }
        guard case let .success(list) = result else { return nil }
        let artist = request.referenceArtists
            .map { RecommendationKey.displayPrimaryArtist($0) }
            .first { !$0.isEmpty }
        return RecommendationRecompute(candidates: list, planSource: .localModel, requestedArtist: artist)
    }

    /// 后台重算落状态：序列相同则不重设候选（避免 UI 抖动），缓存已由 flow 写回。
    private func applyRecompute(
        _ recompute: RecommendationRecompute,
        changed: Bool,
        requestText: String?,
        chat: (text: String, rounds: Int)?
    ) {
        if changed {
            candidates = recompute.candidates
            session = nil
            batchRemaining = 0
        }
        planSource = recompute.planSource
        requestedArtist = recompute.requestedArtist
        lastGeneratedAt = clock()
        cacheHit = false
        cacheCreatedAt = nil
        if let requestText {
            activeRequestText = requestText
        }
        phase = .loaded
        if let chat {
            var updated = RecommendationRequestHistoryStore.load(from: historyURL, limit: chat.rounds)
            updated.append(
                RecommendationRequestHistoryEntry(
                    requestText: chat.text,
                    results: RecommendationRequestHistory.results(from: recompute.candidates),
                    createdAt: clock()
                ),
                limit: chat.rounds
            )
            _ = RecommendationRequestHistoryStore.save(updated, to: historyURL, limit: chat.rounds)
        }
    }
}
