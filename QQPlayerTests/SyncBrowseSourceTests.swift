//
//  SyncBrowseSourceTests.swift
//  QQPlayerTests
//
//  同步页「内容来源」模型的纯逻辑测试（S2，2026-09-13）：
//  - `SyncBrowseSourceRef.parse(id:)` 全分支（保留命名空间 / 真实歌单 / 未知 / 非法）
//  - `peerPlaylistID`（全部曲库 → nil = 发帧 15 不过滤）与 `smartKind`
//  - 标识往返（`parse(ref.id) == ref`）与命名空间不冲突
//  - 展示序（`SyncBrowseSourceCatalog.ordered`：全部曲库 → 收藏 → 3 个自动歌单 → 真实歌单）
//  - 保留标识标题装配（`SyncBrowseSourceTitles`）
//  - 来源内搜索（口径与对端清单 `SyncPeerLibraryCatalog.matches` 一致）
//  - 内存分页切片（来源内分页）
//  - 对端 `@smart:*` 条目装配（`SyncPeerLibraryCatalog.smartPlaylistEntries`）
//
//  这些用例能跑，是因为被测类型刻意放在共享 Core（`QQPlayer/Sync/SyncBrowseSource.swift`）：
//  纯值 + 纯函数、零 IO。
//

import Testing

@testable import QQPlayer

// MARK: - 标识解析

struct SyncBrowseSourceRefParseTests {
    @Test("保留标识：@library / @favorites")
    func reservedIDs() {
        #expect(SyncBrowseSourceRef.parse(id: "@library") == .library)
        #expect(SyncBrowseSourceRef.parse(id: "@favorites") == .favorites)
        #expect(SyncBrowseSourceRef.parse(id: "@library")?.isLibraryWide == true)
        #expect(SyncBrowseSourceRef.parse(id: "@favorites")?.isLibraryWide == false)
    }

    @Test("自动歌单：@smart:<kind> 三个分支")
    func smartIDs() {
        for kind in SyncBrowseSmartKind.allCases {
            let ref = SyncBrowseSourceRef.parse(id: "@smart:\(kind.rawValue)")
            #expect(ref?.kind == .smart)
            #expect(ref?.smartKind == kind)
            #expect(ref?.id == "@smart:\(kind.rawValue)")
        }
        #expect(SyncBrowseSmartKind.allCases.map(\.rawValue) == ["recentAdded", "recentPlayed", "topPlayed"])
        #expect(SyncBrowseSmartKind.recentAdded.wireID == "@smart:recentAdded")
    }

    @Test("未知 / 残缺 / 大小写不符的 @smart：nil（绝不回落全库）")
    func unknownSmartIDs() {
        #expect(SyncBrowseSourceRef.parse(id: "@smart:bogus") == nil)
        #expect(SyncBrowseSourceRef.parse(id: "@smart:") == nil)
        #expect(SyncBrowseSourceRef.parse(id: "@smart:RecentAdded") == nil)
        #expect(SyncBrowseSourceRef.parse(id: "@smart:decades") == nil, "年代本期不做")
        #expect(SyncBrowseSourceRef.parse(id: "@smart:recentAddedx") == nil)
    }

    @Test("其它 @ 前缀：一律 nil（保留命名空间不解释成真实歌单）")
    func reservedPrefixAmbiguity() {
        #expect(SyncBrowseSourceRef.parse(id: "@") == nil)
        #expect(SyncBrowseSourceRef.parse(id: "@libraryx") == nil)
        #expect(SyncBrowseSourceRef.parse(id: "@fav") == nil)
        #expect(SyncBrowseSourceRef.parse(id: "@favorites2") == nil)
        #expect(SyncBrowseSourceRef.parse(id: "@@library") == nil)
    }

    @Test("不带前缀的合法串 → 真实歌单（去首尾空白）")
    func playlistSlug() {
        let ref = SyncBrowseSourceRef.parse(id: "  jazz-2026  ")
        #expect(ref?.kind == .playlist)
        #expect(ref?.id == "jazz-2026")
        #expect(ref?.smartKind == nil)
        #expect(SyncBrowseSourceRef.parse(id: "zhongwen")?.id == "zhongwen")
    }

    @Test("非法输入：空 / 点段 / 路径分隔符 / 控制字符 / 超长 → nil")
    func invalidIDs() {
        #expect(SyncBrowseSourceRef.parse(id: "") == nil)
        #expect(SyncBrowseSourceRef.parse(id: "   ") == nil)
        #expect(SyncBrowseSourceRef.parse(id: ".") == nil)
        #expect(SyncBrowseSourceRef.parse(id: "..") == nil)
        #expect(SyncBrowseSourceRef.parse(id: "../evil") == nil)
        #expect(SyncBrowseSourceRef.parse(id: "a/b") == nil)
        #expect(SyncBrowseSourceRef.parse(id: "a\\b") == nil)
        #expect(SyncBrowseSourceRef.parse(id: "a\u{0}b") == nil)

        let limit = SyncCollectionSelection.maxPlaylistIDLength
        let atLimit = String(repeating: "x", count: limit)
        #expect(SyncBrowseSourceRef.parse(id: atLimit)?.id == atLimit, "恰好到上限 = 合法")
        #expect(SyncBrowseSourceRef.parse(id: atLimit + "x") == nil, "超一个字符 = 非法")
    }

    @Test("标识往返：parse(ref.id) == ref（UI 行标识可直接回读）")
    func roundTrip() throws {
        var refs: [SyncBrowseSourceRef] = [.library, .favorites]
        refs.append(contentsOf: SyncBrowseSmartKind.allCases.map { SyncBrowseSourceRef.smart($0) })
        refs.append(try #require(SyncBrowseSourceRef.playlist("road-trip")))
        for ref in refs {
            #expect(SyncBrowseSourceRef.parse(id: ref.id) == ref)
        }
    }

    @Test("工厂拒绝保留标识当歌单 slug（命名空间不冲突）")
    func factoriesRejectReserved() {
        #expect(SyncBrowseSourceRef.playlist("@favorites") == nil)
        #expect(SyncBrowseSourceRef.playlist("@library") == nil)
        #expect(SyncBrowseSourceRef.playlist("@smart:recentAdded") == nil)
        #expect(SyncBrowseSourceRef.playlist("  ") == nil)
        #expect(SyncBrowseSourceRef.playlist("ok-slug")?.id == "ok-slug")
        // 三个保留标识互不相同（同 id 只可能是一种来源）
        let ids = Set(
            [SyncBrowseSourceRef.library.id, SyncBrowseSourceRef.favorites.id]
                + SyncBrowseSmartKind.allCases.map { SyncBrowseSourceRef.smart($0).id }
        )
        #expect(ids.count == 5)
    }

    @Test("peerPlaylistID：全部曲库 → nil（发帧 15 不过滤）；其余 → 标识本身")
    func peerPlaylistID() {
        #expect(SyncBrowseSourceRef.library.peerPlaylistID == nil)
        #expect(SyncBrowseSourceRef.favorites.peerPlaylistID == "@favorites")
        #expect(SyncBrowseSourceRef.smart(.recentPlayed).peerPlaylistID == "@smart:recentPlayed")
        #expect(SyncBrowseSourceRef.playlist("mix")?.peerPlaylistID == "mix")
    }
}

// MARK: - 展示序

struct SyncBrowseSourceCatalogTests {
    private func option(_ ref: SyncBrowseSourceRef, title: String = "", trackCount: Int = 1) -> SyncBrowseSourceOption {
        SyncBrowseSourceOption(ref: ref, title: title, trackCount: trackCount)
    }

    @Test("顺序：全部曲库 → 收藏 → 3 个自动歌单（固定序）→ 真实歌单（标识升序）")
    func ordering() {
        let options = [
            option(.playlist("zeta")!),
            option(.smart(.topPlayed)),
            option(.playlist("alpha")!),
            option(.smart(.recentAdded)),
            option(.favorites),
            option(.smart(.recentPlayed)),
            option(.library),
        ]
        let ordered = SyncBrowseSourceCatalog.ordered(options)
        #expect(
            ordered.map(\.id) == [
                "@library",
                "@favorites",
                "@smart:recentAdded",
                "@smart:recentPlayed",
                "@smart:topPlayed",
                "alpha",
                "zeta",
            ]
        )
    }

    @Test("同标识去重（先到者优先，不出现两行同一来源）")
    func dedupes() {
        let ordered = SyncBrowseSourceCatalog.ordered([
            option(.favorites, title: "先", trackCount: 5),
            option(.favorites, title: "后", trackCount: 99),
        ])
        #expect(ordered.count == 1)
        #expect(ordered[0].title == "先")
        #expect(ordered[0].trackCount == 5)
    }

    @Test("空清单 → 空（不编造来源）")
    func empty() {
        #expect(SyncBrowseSourceCatalog.ordered([]).isEmpty)
    }
}

// MARK: - 行模型

struct SyncBrowseSourceOptionTests {
    @Test("空标题回落标识；负数归零；未知大小 = nil")
    func fallbacks() {
        let option = SyncBrowseSourceOption(
            ref: SyncBrowseSourceRef.smart(.recentAdded),
            title: "   ",
            trackCount: -3,
            totalBytes: -9
        )
        #expect(option.id == "@smart:recentAdded")
        #expect(option.title == "@smart:recentAdded")
        #expect(option.trackCount == 0)
        #expect(option.totalBytes == 0)
        #expect(option.isSmart)
        #expect(!option.isLibraryWide)
        #expect(SyncBrowseSourceOption(ref: .library, title: "全部曲库", trackCount: 1).totalBytes == nil)
    }

    @Test("保留标识标题：全部曲库 / 收藏 / 自动歌单有值，真实歌单为 nil（用歌单自己的名字）")
    func titles() {
        let titles = SyncBrowseSourceTitles(
            library: "全部曲库",
            favorites: "收藏",
            smart: [.recentAdded: "最近添加", .recentPlayed: "最近播放", .topPlayed: "常听排行"]
        )
        #expect(titles.title(for: .library) == "全部曲库")
        #expect(titles.title(for: .favorites) == "收藏")
        #expect(titles.title(for: SyncBrowseSourceRef.smart(.topPlayed)) == "常听排行")
        #expect(titles.title(for: SyncBrowseSourceRef.playlist("mix")!) == nil)
        // 缺项的自动歌单 → nil（调用方回落对端名 / 标识）
        let partial = SyncBrowseSourceTitles(library: "L", favorites: "F", smart: [:])
        #expect(partial.title(for: SyncBrowseSourceRef.smart(.recentPlayed)) == nil)
        #expect(SyncBrowseSourceTitles.empty.title(for: .library)?.isEmpty == true)
    }
}

// MARK: - 来源内搜索

struct SyncBrowseSourceSearchTests {
    private func option(_ path: String, title: String, artist: String? = nil) -> SyncUITrackOption {
        SyncUITrackOption(relativePath: path, title: title, artistName: artist, fileSize: 1)
    }

    @Test("标题 / 歌手 / 相对路径任一命中；大小写不敏感")
    func matches() {
        #expect(SyncBrowseSourceSearch.matches(title: "Yellow", artistName: "Coldplay", relativePath: "Rock/y.mp3", query: "yell"))
        #expect(SyncBrowseSourceSearch.matches(title: "Yellow", artistName: "Coldplay", relativePath: "Rock/y.mp3", query: "COLD"))
        #expect(SyncBrowseSourceSearch.matches(title: "Yellow", artistName: "Coldplay", relativePath: "Rock/y.mp3", query: "rock/"))
        #expect(!SyncBrowseSourceSearch.matches(title: "Yellow", artistName: "Coldplay", relativePath: "Rock/y.mp3", query: "jazz"))
        // 空查询 = 全部命中（列表不过滤）
        #expect(SyncBrowseSourceSearch.matches(title: "x", artistName: nil, relativePath: "a", query: "   "))
    }

}

// MARK: - 来源内分页

struct SyncBrowseSourcePagerTests {
    @Test("切片：首页 / 末页 hasMore / 越界空页 / 非法页大小")
    func slice() {
        let items = Array(1 ... 250)
        let first = SyncBrowseSourcePager.slice(items, offset: 0, pageSize: 100)
        #expect(first.items.count == 100)
        #expect(first.items.first == 1)
        #expect(first.hasMore)
        let last = SyncBrowseSourcePager.slice(items, offset: 200, pageSize: 100)
        #expect(last.items.count == 50)
        #expect(last.items.last == 250)
        #expect(!last.hasMore)
        let beyond = SyncBrowseSourcePager.slice(items, offset: 999, pageSize: 100)
        #expect(beyond.items.isEmpty)
        #expect(!beyond.hasMore)
        let negative = SyncBrowseSourcePager.slice(items, offset: -5, pageSize: 10)
        #expect(negative.items.first == 1, "负偏移钳到 0（不崩）")
        let zeroPage = SyncBrowseSourcePager.slice(items, offset: 0, pageSize: 0)
        #expect(zeroPage.items.isEmpty)
        #expect(!zeroPage.hasMore)
        #expect(SyncBrowseSourcePager.slice([Int](), offset: 0, pageSize: 10).items.isEmpty)
    }
}

// MARK: - 对端自动歌单条目装配

struct SyncPeerSmartPlaylistEntriesTests {
    @Test("顺序 = allCases；trackCount = 成员集 ∩ 曲目清单；成员集按 id 落表")
    func entries() {
        let catalog = SyncPeerLibraryCatalog(
            playlists: [],
            tracks: [
                SyncPeerTrackItem(relativePath: "a.mp3", title: "A", sizeBytes: 1),
                SyncPeerTrackItem(relativePath: "b.mp3", title: "B", sizeBytes: 1),
            ]
        )
        let entries = SyncPeerLibraryCatalog.smartPlaylistEntries(
            names: [.recentAdded: "最近添加", .recentPlayed: "", .topPlayed: "常听排行"],
            memberPaths: [
                .recentAdded: ["a.mp3", "b.mp3"],
                .recentPlayed: ["a.mp3"],
                .topPlayed: ["b.mp3", "不在清单里.mp3"],
            ],
            catalogPaths: Set(catalog.tracks.map(\.relativePath))
        )
        #expect(entries.playlists.map(\.id) == ["@smart:recentAdded", "@smart:recentPlayed", "@smart:topPlayed"])
        #expect(entries.playlists.map(\.trackCount) == [2, 1, 1], "不在清单里的成员不计入（与筛选结果一致）")
        #expect(entries.playlists[0].name == "最近添加")
        #expect(entries.playlists[1].name == "@smart:recentPlayed", "空名回落标识（不产生空行）")
        #expect(entries.members["@smart:topPlayed"] == ["b.mp3"])
        // 与 catalog 的筛选口径自洽：trackCount == 按该 id 筛 tracks 的条数
        for item in entries.playlists {
            let request = SyncPeerLibraryRequestPayload(
                scope: SyncPeerLibraryScope.tracks.rawValue,
                playlistID: item.id,
                limit: 500,
                requestID: 1
            )
            let catalogWithMembers = SyncPeerLibraryCatalog(
                playlists: [],
                tracks: catalog.tracks,
                trackPathsByPlaylist: entries.members
            )
            #expect(catalogWithMembers.matchedTracks(for: request).count == item.trackCount)
        }
    }
}
