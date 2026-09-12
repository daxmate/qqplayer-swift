//
//  SyncUIDirectionContentTests.swift
//  QQPlayerTests
//
//  T10（2026-09-12）「方向优先 · 内容源随方向切换」的纯逻辑测试：
//  - 方向 → 内容源（未选 / 上传 = 本端 / 下载 = 对端）
//  - 开始可用性（未选方向 → 不可开始；与既有判定顺序不破）
//  - 对端清单 → 选择区行模型（收藏置顶 + 本端语言、非法标识丢弃、标题兜底）
//  - 对端清单 → 选择集映射（歌单 slug / `@favorites` / 单曲 relativePath）
//  - 分页拼接（追加去重 / 重置 / 下一页游标）
//  - 搜索去抖状态机（归一 + 待生效/已生效 + 提交才重载）
//  - 对端错误归一（客户端错误 → UI 错误 + 文案键）
//
//  这些用例能跑，是因为被测类型刻意放在共享 Core
//  （`QQPlayer/Services/SyncUIDirectionContent.swift`）：纯值 + 纯函数、零 IO（M6 契约 A3）。
//

import Testing

@testable import QQPlayer

// MARK: - 方向 → 内容源

struct SyncUIContentSourceResolverTests {
    @Test("方向未选：不显示任何一端的内容（T10 核心修复点）")
    func noDirection() {
        #expect(SyncUIContentSourceResolver.source(for: nil) == .none)
        #expect(!SyncUIContentSourceResolver.requiresPeer(for: nil))
    }

    @Test("上传 → 本端（Mac）内容")
    func uploadUsesLocal() {
        #expect(SyncUIContentSourceResolver.source(for: .upload) == .local)
        #expect(!SyncUIContentSourceResolver.requiresPeer(for: .upload))
    }

    @Test("下载 → 对端（iPhone）内容（旧实现在这里显示本端曲库 = 用户反馈的错配）")
    func downloadUsesPeer() {
        #expect(SyncUIContentSourceResolver.source(for: .download) == .peer)
        #expect(SyncUIContentSourceResolver.requiresPeer(for: .download))
    }
}

// MARK: - 开始可用性（T10 新增「未选方向」前置）

struct SyncUIStartGateDirectionTests {
    @Test("未选方向：即使连接 + 有会话 + 有选择也不可开始")
    func noDirectionBlocksStart() {
        let availability = SyncUIStartGate.evaluate(
            hasPairedDevice: true,
            isConnected: true,
            hasSession: true,
            isRunning: false,
            hasDirection: false,
            isEmptySelection: false
        )
        #expect(availability == .noDirection)
        #expect(!availability.canStart)
    }

    @Test("方向判定排在选择集之前：未选方向 + 空选择 → 先提示选方向")
    func directionBeatsEmptySelection() {
        let availability = SyncUIStartGate.evaluate(
            hasPairedDevice: true,
            isConnected: true,
            hasSession: true,
            isRunning: false,
            hasDirection: false,
            isEmptySelection: true
        )
        #expect(availability == .noDirection)
    }

    @Test("连接类原因优先于方向：未连接时提示去连接，而不是先选方向")
    func connectionBeatsDirection() {
        #expect(
            SyncUIStartGate.evaluate(
                hasPairedDevice: false,
                isConnected: false,
                hasSession: false,
                isRunning: false,
                hasDirection: false,
                isEmptySelection: false
            ) == .notPaired
        )
        #expect(
            SyncUIStartGate.evaluate(
                hasPairedDevice: true,
                isConnected: false,
                hasSession: false,
                isRunning: false,
                hasDirection: false,
                isEmptySelection: false
            ) == .notConnected
        )
    }

    @Test("同步中优先于方向：跑起来之后按钮是「取消」而不是「先选方向」")
    func runningBeatsDirection() {
        let availability = SyncUIStartGate.evaluate(
            hasPairedDevice: true,
            isConnected: true,
            hasSession: true,
            isRunning: true,
            hasDirection: false,
            isEmptySelection: false
        )
        #expect(availability == .alreadyRunning)
    }

    @Test("方向 + 连接 + 会话 + 非空选择 → 可开始")
    func readyWithDirection() {
        let availability = SyncUIStartGate.evaluate(
            hasPairedDevice: true,
            isConnected: true,
            hasSession: true,
            isRunning: false,
            hasDirection: true,
            isEmptySelection: false
        )
        #expect(availability == .ready)
        #expect(availability.canStart)
    }

    @Test("hasDirection 默认 true：老调用点（未传方向）语义不变")
    func defaultKeepsLegacySemantics() {
        let availability = SyncUIStartGate.evaluate(
            hasPairedDevice: true,
            isConnected: true,
            hasSession: true,
            isRunning: false,
            isEmptySelection: false
        )
        #expect(availability == .ready)
    }
}

// MARK: - 对端错误归一

struct SyncUIPeerContentErrorTests {
    @Test("客户端错误逐项映射（超时 / 未就绪 / 会话关闭 / 发送失败）")
    func mapsClientErrors() {
        #expect(SyncUIPeerContentError.from(SyncPeerLibraryClient.ClientError.timeout) == .timeout)
        #expect(
            SyncUIPeerContentError.from(SyncPeerLibraryClient.ClientError.sessionNotReady)
                == .sessionNotReady
        )
        #expect(
            SyncUIPeerContentError.from(SyncPeerLibraryClient.ClientError.sessionClosed)
                == .sessionClosed
        )
        #expect(
            SyncUIPeerContentError.from(SyncPeerLibraryClient.ClientError.sendFailed("boom"))
                == .sendFailed("boom")
        )
    }

    @Test("未知错误 → other（不崩、不假装知道原因）")
    func mapsUnknownError() {
        struct Dummy: Error {}
        #expect(SyncUIPeerContentError.from(Dummy()) == .other)
    }

    @Test("取消不是用户可见失败（切方向/关面板不弹错误）")
    func cancelledIsNotVisible() {
        #expect(!SyncUIPeerContentError.cancelled.isUserVisibleFailure)
        #expect(SyncUIPeerContentError.timeout.isUserVisibleFailure)
        #expect(SyncUIPeerContentError.notConnected.isUserVisibleFailure)
    }

    @Test("每个错误都有非空文案键（且不同原因不共用同一句）")
    func messageKeysArePresent() {
        let errors: [SyncUIPeerContentError] = [
            .notConnected, .sessionNotReady, .timeout, .cancelled, .sessionClosed,
            .sendFailed("x"), .other,
        ]
        for error in errors {
            #expect(!error.messageKey.isEmpty)
            #expect(error.messageKey.hasPrefix("sync_peer_error_"))
        }
        #expect(SyncUIPeerContentError.notConnected.messageKey != SyncUIPeerContentError.timeout.messageKey)
        // 会话类原因共用一句（都是「重连再试」）
        #expect(SyncUIPeerContentError.sessionNotReady.messageKey == SyncUIPeerContentError.sessionClosed.messageKey)
    }

    @Test("加载状态：失败原因/是否可见的派生")
    func loadStateDerivations() {
        #expect(SyncUIContentLoadState.idle.isLoading == false)
        #expect(SyncUIContentLoadState.loading.isLoading)
        #expect(SyncUIContentLoadState.loaded.failure == nil)
        #expect(SyncUIContentLoadState.failed(.timeout).failure == .timeout)
        #expect(SyncUIContentLoadState.failed(.timeout).isVisibleFailure)
        #expect(!SyncUIContentLoadState.failed(.cancelled).isVisibleFailure)
    }
}

// MARK: - 对端清单 → 行模型

struct SyncUIPeerContentMapperTests {
    @Test("收藏置顶且用本端语言显示（对端回传的名字被覆盖）")
    func favoritesPinnedTop() {
        let options = SyncUIPeerContentMapper.playlistOptions(
            from: [
                SyncPeerPlaylistItem(id: "road-trip", name: "Road Trip", trackCount: 12),
                SyncPeerPlaylistItem(id: "@favorites", name: "Favoris", trackCount: 3),
                SyncPeerPlaylistItem(id: "chill", name: "Chill", trackCount: 7),
            ],
            favoritesTitle: "收藏"
        )
        #expect(options.map(\.id) == ["@favorites", "road-trip", "chill"])
        #expect(options[0].title == "收藏")
        #expect(options[0].isFavorites)
        #expect(options[0].trackCount == 3)
        #expect(options[1].title == "Road Trip")
    }

    @Test("非法标识丢弃、同标识去重（不可信的对端数据不乱进选择集）")
    func dropsInvalidAndDuplicates() {
        let options = SyncUIPeerContentMapper.playlistOptions(
            from: [
                SyncPeerPlaylistItem(id: "ok", name: "OK", trackCount: 1),
                SyncPeerPlaylistItem(id: "ok", name: "重复", trackCount: 9),
                SyncPeerPlaylistItem(id: "../evil", name: "Evil", trackCount: 1),
                SyncPeerPlaylistItem(id: "   ", name: "Blank", trackCount: 1),
            ],
            favoritesTitle: "收藏"
        )
        #expect(options.map(\.id) == ["ok"])
        #expect(options[0].title == "OK")
        #expect(options[0].trackCount == 1)
    }

    @Test("空名回落标识本身；负数曲目数归零（对端脏数据不显示 -1 首）")
    func fallbacks() {
        let options = SyncUIPeerContentMapper.playlistOptions(
            from: [SyncPeerPlaylistItem(id: "unnamed", name: "  ", trackCount: -2)],
            favoritesTitle: "收藏"
        )
        #expect(options[0].title == "unnamed")
        #expect(options[0].trackCount == 0)
    }

    @Test("曲目：标题缺失回落文件名（去扩展名）、空歌手为 nil、大小 0 视为未知")
    func trackMapping() {
        let option = SyncUIPeerContentMapper.trackOption(
            from: SyncPeerTrackItem(
                relativePath: "Rock/未命名 01.flac",
                title: "  ",
                artistName: " ",
                sizeBytes: 0
            )
        )
        #expect(option.relativePath == "Rock/未命名 01.flac")
        #expect(option.title == "未命名 01")
        #expect(option.artistName == nil)
        #expect(option.fileSize == nil)
    }

    @Test("曲目：标题/歌手/大小齐备时原样带出")
    func trackMappingFull() {
        let option = SyncUIPeerContentMapper.trackOption(
            from: SyncPeerTrackItem(
                relativePath: "Pop/a.mp3",
                title: "名曲",
                artistName: "歌手",
                sizeBytes: 4_194_304
            )
        )
        #expect(option.title == "名曲")
        #expect(option.artistName == "歌手")
        #expect(option.fileSize == 4_194_304)
        #expect(option.id == "Pop/a.mp3")
    }

    @Test("一页响应 → 单曲选项（保持页内序）")
    func responseMappingKeepsOrder() {
        let response = SyncPeerLibraryResponsePayload(
            requestID: 7,
            scope: SyncPeerLibraryScope.tracks.rawValue,
            total: 2,
            items: [
                .track(SyncPeerTrackItem(relativePath: "b.mp3", title: "B", sizeBytes: 1)),
                .track(SyncPeerTrackItem(relativePath: "a.mp3", title: "A", sizeBytes: 2)),
            ],
            hasMore: true,
            libraryTrackCount: 9,
            librarySizeBytes: 99
        )
        let options = SyncUIPeerContentMapper.trackOptions(from: response)
        #expect(options.map(\.relativePath) == ["b.mp3", "a.mp3"])
    }
}

// MARK: - 对端清单 → 选择集映射

struct SyncUIPeerSelectionMappingTests {
    @Test("下载方向勾歌单：对端 slug 原样进选择集（含收藏保留标识）")
    func playlistSelectionKeepsSlugs() {
        let slugs = ["@favorites", "road-trip"]
        let selection = SyncUISelectionMode.selection(
            mode: .playlists,
            playlistIDs: Set(slugs),
            trackPaths: []
        )
        #expect(selection == .playlists(["@favorites", "road-trip"]))
        #expect(!selection.isEmptySelection)
        // 规范化（升序）后仍保留收藏标识：`@` 排在字母前
        #expect(selection.playlistIDs == ["@favorites", "road-trip"])
    }

    @Test("下载方向勾单曲：对端 relativePath 进选择集（对账键口径）")
    func trackSelectionKeepsRelativePaths() {
        let paths = ["Rock/02 track.flac", "Pop/a.mp3"]
        let selection = SyncUISelectionMode.selection(mode: .tracks, playlistIDs: [], trackPaths: Set(paths))
        #expect(selection == .relativePaths(["Pop/a.mp3", "Rock/02 track.flac"]))
        #expect(!selection.isEmptySelection)
    }

    @Test("空勾选 → 空选择集（不推不拉），不会退化成全库")
    func emptyPicksStayEmpty() {
        #expect(SyncUISelectionMode.selection(mode: .playlists, playlistIDs: [], trackPaths: []).isEmptySelection)
        #expect(SyncUISelectionMode.selection(mode: .tracks, playlistIDs: [], trackPaths: []).isEmptySelection)
        #expect(!SyncUISelectionMode.selection(mode: .library, playlistIDs: [], trackPaths: []).isEmptySelection)
    }

    @Test("对端清单行 → 选择集：勾选后 slug 可回读到选择区（往返一致）")
    func roundTripThroughOptions() {
        let options = SyncUIPeerContentMapper.playlistOptions(
            from: [
                SyncPeerPlaylistItem(id: "@favorites", name: "Favorites", trackCount: 1),
                SyncPeerPlaylistItem(id: "mix", name: "Mix", trackCount: 2),
            ],
            favoritesTitle: "歌单收藏"
        )
        var picked: Set<String> = []
        for option in options where option.trackCount > 0 { picked.insert(option.id) }
        let selection = SyncUISelectionMode.selection(mode: .playlists, playlistIDs: picked, trackPaths: [])
        #expect(SyncUISelectionMode.mode(for: selection) == .playlists)
        #expect(Set(selection.playlistIDs ?? []) == picked)
    }
}

// MARK: - 分页拼接

struct SyncUIContentPagerTests {
    private func option(_ path: String) -> SyncUITrackOption {
        SyncUITrackOption(relativePath: path, title: path, artistName: nil, fileSize: 1)
    }

    @Test("追加：保序拼接")
    func appendKeepsOrder() {
        let merged = SyncUIContentPager.merge(
            existing: [option("a"), option("b")],
            page: [option("c")],
            reset: false
        )
        #expect(merged.map(\.relativePath) == ["a", "b", "c"])
    }

    @Test("重置：只留新一页")
    func resetReplaces() {
        let merged = SyncUIContentPager.merge(
            existing: [option("a")],
            page: [option("z")],
            reset: true
        )
        #expect(merged.map(\.relativePath) == ["z"])
    }

    @Test("重复页/重复条目去重（对端慢响应重发不会显示两行同一首歌）")
    func dedupesByRelativePath() {
        let merged = SyncUIContentPager.merge(
            existing: [option("a"), option("b")],
            page: [option("b"), option("c")],
            reset: false
        )
        #expect(merged.map(\.relativePath) == ["a", "b", "c"])
    }

    @Test("下一页游标 = 实际已加载条数（去重后，不是页数×页大小）")
    func nextOffsetUsesLoadedCount() {
        #expect(SyncUIContentPager.nextOffset(loadedCount: 0) == 0)
        #expect(SyncUIContentPager.nextOffset(loadedCount: 100) == 100)
        #expect(SyncUIContentPager.nextOffset(loadedCount: -5) == 0)
    }
}

// MARK: - 搜索去抖状态机

struct SyncUISearchGateTests {
    @Test("归一：去首尾空白 + 截断到协议上限（与请求载荷同源）")
    func normalize() {
        #expect(SyncUISearchGate.normalize("  hello  ") == "hello")
        #expect(SyncUISearchGate.normalize("   ").isEmpty)
        let long = String(repeating: "x", count: SyncPeerLibraryRequestPayload.maxQueryLength + 50)
        #expect(SyncUISearchGate.normalize(long).count == SyncPeerLibraryRequestPayload.maxQueryLength)
        #expect(SyncUISearchGate.maxQueryLength == SyncPeerLibraryRequestPayload.maxQueryLength)
    }

    @Test("同词重复输入不触发重载（去抖到期后 commit 返回 false）")
    func sameQueryDoesNotReload() {
        var gate = SyncUISearchGate()
        // ⚠️ `#expect` 宏无法包住 mutating 调用（展开后 `$0` 是常量）→ 先落局部变量
        let emptyStaged = gate.stage("   ")
        #expect(!emptyStaged)
        let emptyCommitted = gate.commit()
        #expect(!emptyCommitted)
        let firstStaged = gate.stage("rock")
        #expect(firstStaged)
        let firstCommitted = gate.commit()
        #expect(firstCommitted)
        // 再输入同一个词（含前后空白差异）→ 归一后相同 = 不需要重载
        let sameStaged = gate.stage(" rock ")
        #expect(!sameStaged)
        let sameCommitted = gate.commit()
        #expect(!sameCommitted)
    }

    @Test("新词在 commit 之后才生效（去抖期的输入不改变当前列表）")
    func commitAppliesPending() {
        var gate = SyncUISearchGate()
        #expect(gate.appliedQuery.isEmpty)
        let staged = gate.stage("jazz")
        #expect(staged)
        #expect(gate.appliedQuery.isEmpty)     // 还没提交
        #expect(gate.pendingQuery == "jazz")
        let committed = gate.commit()
        #expect(committed)
        #expect(gate.appliedQuery == "jazz")
        let recommitted = gate.commit()         // 幂等：再提交无事发生
        #expect(!recommitted)
    }

    @Test("reset：清空待生效与已生效（切方向 / 切歌单）")
    func reset() {
        var gate = SyncUISearchGate()
        _ = gate.stage("jazz")
        _ = gate.commit()
        gate.reset()
        #expect(gate.appliedQuery.isEmpty)
        #expect(gate.pendingQuery.isEmpty)
        let afterReset = gate.commit()
        #expect(!afterReset)
    }

    @Test("构造时可带初始词（列表首屏就是搜索结果）")
    func initWithAppliedQuery() {
        let gate = SyncUISearchGate(appliedQuery: "pop")
        #expect(gate.appliedQuery == "pop")
        #expect(gate.pendingQuery == "pop")
    }
}

// MARK: - 对端摘要

struct SyncUIPeerSummaryFactsTests {
    @Test("负数归零（对端脏数据不显示 -1 首 / -1 B）")
    func clampsNegatives() {
        let facts = SyncUIPeerSummaryFacts(trackCount: -3, sizeBytes: -9)
        #expect(facts.trackCount == 0)
        #expect(facts.totalBytes == 0)
        #expect(facts.sizeText == "0 B")
    }

    @Test("摘要 → 全库规模事实（全曲库二次确认用对端的数字）")
    func libraryFactsBridge() {
        let facts = SyncUIPeerSummaryFacts(trackCount: 1_234, sizeBytes: 4_509_715_660)
        #expect(facts.libraryFacts.trackCount == 1_234)
        #expect(facts.libraryFacts.totalBytes == 4_509_715_660)
        #expect(facts.sizeText == "4.2 GB")
    }

    @Test("选择集摘要用对端数字：全曲库提示 = 对端曲目数 + 对端大小")
    func summaryUsesPeerNumbers() {
        let summary = SyncUISelectionSummarizer.make(
            selection: .all,
            playlists: [],
            tracks: [],
            library: SyncUIPeerSummaryFacts(trackCount: 88, sizeBytes: 1_073_741_824).libraryFacts
        )
        #expect(summary.trackCount == 88)
        #expect(summary.sizeText == "1 GB")
        #expect(summary.requiresConfirmation)
    }

    @Test("选择集摘要用对端歌单数字（歌单级：曲目数与大小都来自对端清单）")
    func playlistSummaryUsesPeerOptions() {
        let options = SyncUIPeerContentMapper.playlistOptions(
            from: [SyncPeerPlaylistItem(id: "mix", name: "Mix", trackCount: 40)],
            favoritesTitle: "收藏"
        )
        var withSize = options
        withSize[0].totalBytes = 2_147_483_648
        let summary = SyncUISelectionSummarizer.make(
            selection: .playlists(["mix"]),
            playlists: withSize,
            tracks: [],
            library: .empty
        )
        #expect(summary.playlistCount == 1)
        #expect(summary.trackCount == 40)
        #expect(summary.sizeText == "2 GB")
        #expect(!summary.requiresConfirmation)
    }
}
