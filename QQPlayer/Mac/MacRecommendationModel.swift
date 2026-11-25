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
    /// 已下载判定状态（曲库键 + 可注入读取器；生成时赋值，下载落库/面板关闭后再刷）。
    /// 已下载判定（协议注入：单测换桩，无需真实曲库）。
    var downloadedIndex: any RecommendationDownloadedIndexProviding = RecommendationDownloadedIndex()
    /// 合并突发刷新通知的待执行任务（连续 `.trackFound` / `.libraryNeedsRefresh` 只读一次曲库）。
    @ObservationIgnored var downloadedKeysRefreshTask: Task<Void, Never>?
    /// 最近一次生成用的画像输入（后台重算复用，避免二次 DB 读）。
    private var lastProfileInput: RecommendationProfileInput?
    private(set) var lastGeneratedAt: Date?
    /// 最近一次生成用的检索计划来源（规则 / 本地模型），页脚展示用。
    var planSource: RecommendationPlanSource = .rule
    /// 打开 App 时判断 24h（P1 不做定时器，见任务包 F）。
    static let refreshInterval: TimeInterval = 24 * 3600

    /// 本次结果是否来自结果缓存（UI 页脚展示「缓存结果 · X 分钟前」）。
    private(set) var cacheHit = false
    /// 缓存条目的生成时间（命中时展示；未命中为 nil）。
    private(set) var cacheCreatedAt: Date?

    let blacklistURL: URL?
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

    /// 理由来源（nil = 按设置解析：v3 起恒为模板规则；单测可注入桩）。
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
        cacheDirectoryURL: URL? = RecommendationResultCache.defaultDirectoryURL(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.blacklistURL = blacklistURL
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
    func refresh(count: Int) async {
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
        await generate(count: count, bypassCache: true)
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
        let settings = DeleteSettings.load()
        let profileV3 = RecommendationProfileV3Builder.build(
            RecommendationProfileV3Input(legacy: input),
            weights: settings.recommendationProfileWeights
        )
        downloadedIndex = downloadedIndex.withKeys(profileV3.libraryKeys)
        lastProfileInput = input
        if let reason = profileV3.emptyReason {
            phase = .failed(reason.localizationKey.localized)
            return
        }
        let selection = RecommendationPlannerFactory.selection(settings: settings)
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
            applyCacheHit(hit)
            return
        case let .stale(hit):
            // 列表优先：先用旧候选垫底，后台重算完成后平滑替换。
            applyCacheHit(hit)
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

        planSource = .rule
        let poolTarget = max(RecommendationBatchPolicy.poolTarget, count * 4)
        let result = await RecommendationV3Engine.configured(settings).recommend(
            profile: profileV3,
            count: poolTarget,
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
            storeCache(key, planSource: .rule, candidates: batch)
        case let .failure(error):
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - 结果缓存

    /// P4：艺人关系扩展开关（进缓存键：开关变化不复用旧池）。
    private var artistRelationExpansionEnabled: Bool {
        DeleteSettings.load().recommendationArtistRelationExpansion
    }

    /// 缓存键：请求原话（批次 C 起恒为空）+ 画像摘要 + 曲库指纹 + planner/模型身份 + locale。
    ///
    /// 说明：rawText 是输入框时代的「请求身份」。输入框移除后恒为空串，保留该字段是为了
    /// 不改键格式（改格式须同步递增 RecommendationResultCache.schemaVersion，等于让所有
    /// 用户缓存失效一次）。
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
    private func applyCacheHit(_ hit: RecommendationCacheHit) {
        candidates = hit.candidates
        session = nil
        batchRemaining = 0
        planSource = hit.planSource
        lastGeneratedAt = hit.createdAt
        cacheHit = true
        cacheCreatedAt = hit.createdAt
        phase = .loaded
        startReasonRefresh(for: candidates)
    }

    /// 成功后写缓存（空结果 / 失败结果不写）。
    func storeCache(
        _ key: RecommendationCacheKeyInput,
        planSource: RecommendationPlanSource,
        candidates: [RecommendedCandidate]
    ) {
        flow.store(
            RecommendationRecompute(candidates: candidates, planSource: planSource),
            key: key
        )
    }

    // MARK: - 后台重算（stale 垫底后的平滑替换）

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
            self?.applyRecompute(recompute, changed: changed)
        }
    }

    private func computeProfileRecompute(
        selection _: RecommendationPlannerSelection,
        profile _: TasteProfile,
        count: Int
    ) async -> RecommendationRecompute? {
        guard let input = lastProfileInput else { return nil }
        let profileV3 = RecommendationProfileV3Builder.build(
            RecommendationProfileV3Input(legacy: input),
            weights: DeleteSettings.load().recommendationProfileWeights
        )
        let result = await RecommendationV3Engine.configured().recommend(
            profile: profileV3,
            count: count,
            excludedTrackKeys: excludedTrackKeys,
            // 后台重算不是「换一批」：本批已下载的曲目保留并打标，不从列表凭空消失。
            keepKeys: retainedDownloadedKeys()
        )
        if Task.isCancelled { return nil }
        guard case let .success(list) = result else { return nil }
        return RecommendationRecompute(
            candidates: RecommendationDownloadedRetention.merge(
                previous: candidates,
                fresh: list,
                isDownloaded: isDownloaded
            ),
            planSource: .rule
        )
    }

    /// 后台重算落状态：序列相同则不重设候选（避免 UI 抖动），缓存已由 flow 写回。
    private func applyRecompute(
        _ recompute: RecommendationRecompute,
        changed: Bool
    ) {
        if changed {
            candidates = recompute.candidates
            session = nil
            batchRemaining = 0
        }
        planSource = recompute.planSource
        lastGeneratedAt = clock()
        cacheHit = false
        cacheCreatedAt = nil
        phase = .loaded
    }
}
