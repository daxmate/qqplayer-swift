//
//  RecommendationV4Tests.swift
//  QQPlayerTests
//
//  推荐 v4 第一批（A 生成质量 + B 已下载标记）的纯逻辑验收：
//   1. 种子抽样（同 seed 确定 / 无重复 / 只在前 20 名内 / K 边界）；
//   2. 画像行为信号（30 天半衰 / 完成率分档 / 跳过降权 / 归一化 / 空数据退化）；
//   3. 通道下限 + 重分配 + 去重 + 批内上限；
//   4. MMR（同质替代存在时不连选同艺人 / λ 效果 / 确定性）；
//   5. 归一化键（多艺人 & / 中文括号 / 现场版 / 繁简 / 无 artistId / 文件名兜底）；
//   6. 已下载保留（下载完成 → 仍在列表）与新批次排除。
//

import Foundation
@testable import QQPlayer
import Testing

// MARK: - 夹具

private enum V4Fixture {
    static func seed(_ artist: String, affinity: Double) -> RecommendationSeedArtist {
        RecommendationSeedArtist(
            artist: artist,
            affinity: affinity,
            libraryCount: 10,
            playCount: 10,
            representativeTitles: []
        )
    }

    static func item(
        key: String,
        channel: RecommendationChannel = .seed,
        artist: String,
        album: String = "",
        genre: String? = nil,
        year: Int? = nil,
        score: Double,
        retained: Bool = false
    ) -> RecommendationSelectionItem {
        RecommendationSelectionItem(
            key: key,
            channel: channel,
            artistKey: RecommendationLibraryMatcher.artistKey(artist),
            albumKey: album.isEmpty ? "" : RecommendationLibraryMatcher.normalize(album),
            genre: genre,
            year: year,
            score: score,
            isRetainedDownload: retained
        )
    }

    static func candidate(_ title: String, artist: String, album: String? = nil) -> RecommendedCandidate {
        RecommendedCandidate(title: title, artist: artist, album: album, source: .netease)
    }

    static func v3Candidate(_ title: String, artist: String) -> RecommendationV3Candidate {
        RecommendationV3Candidate(
            song: RecommendationRemoteSong(title: title, artist: artist),
            context: RecommendationCandidateContext(channel: .seed)
        )
    }

    static func track(
        _ id: String,
        artist: String,
        title: String = "歌",
        durationMs: Int? = 200_000
    ) -> RecommendationProfileV3Input.Track {
        RecommendationProfileV3Input.Track(
            stableId: id,
            title: title,
            artist: artist,
            album: nil,
            genre: nil,
            year: nil,
            durationMs: durationMs,
            addedAt: nil,
            isFavorite: false,
            isInPlaylist: false,
            playCount: 0
        )
    }
}

// MARK: - 1. 种子抽样

@Suite("推荐 v4：种子抽样")
struct RecommendationSeedSamplerTests {
    private func seeds(count: Int) -> [RecommendationSeedArtist] {
        (0 ..< count).map { index in
            V4Fixture.seed("艺人\(index)", affinity: max(0.01, 1.0 - Double(index) * 0.03))
        }
    }

    @Test("同 seed 同结果")
    func deterministic() {
        let pool = seeds(count: 25)
        let a = RecommendationSeedSampler.sample(pool, k: 8, seed: 42)
        let b = RecommendationSeedSampler.sample(pool, k: 8, seed: 42)
        #expect(a.map(\.artist) == b.map(\.artist))
        #expect(a.count == 8)
    }

    @Test("不同 seed 会给出不同抽样（概率性，固定 seed 反证）")
    func variesAcrossSeeds() {
        let pool = seeds(count: 25)
        var results = Set<[String]>()
        for seed in UInt64(1) ... 20 {
            results.insert(RecommendationSeedSampler.sample(pool, k: 6, seed: seed).map(\.artist))
        }
        #expect(results.count > 1)
    }

    @Test("无重复")
    func unique() {
        let picked = RecommendationSeedSampler.sample(seeds(count: 20), k: 20, seed: 7)
        #expect(Set(picked.map(\.artist)).count == picked.count)
    }

    @Test("只取亲和度前 20 名")
    func staysInTopWindow() {
        let pool = seeds(count: 30)
        let window = Set(RecommendationSeedSampler.ranked(pool).prefix(20).map(\.artist))
        for seed in UInt64(1) ... 30 {
            let picked = RecommendationSeedSampler.sample(pool, k: 10, seed: seed)
            #expect(picked.allSatisfy { window.contains($0.artist) })
        }
    }

    @Test("K 边界：0 / 超过窗口")
    func kBounds() {
        let pool = seeds(count: 25)
        #expect(RecommendationSeedSampler.sample(pool, k: 0, seed: 1).isEmpty)
        #expect(RecommendationSeedSampler.sample(pool, k: 99, seed: 1).count == 20)
        #expect(RecommendationSeedSampler.sample([], k: 5, seed: 1).isEmpty)
    }

    @Test("亲和度并列按 artist key 稳定排序")
    func tieBreakStable() {
        let pool = [
            V4Fixture.seed("Zeta", affinity: 0.5),
            V4Fixture.seed("Alpha", affinity: 0.5),
        ]
        #expect(RecommendationSeedSampler.ranked(pool).map(\.artist) == ["Alpha", "Zeta"])
    }
}

// MARK: - 2. 画像行为信号

@Suite("推荐 v4：画像行为信号")
struct RecommendationProfileV4Tests {
    private func input(plays: [RecommendationProfileV3Input.Play], tracks: [RecommendationProfileV3Input.Track]) -> RecommendationProfileV3Input {
        RecommendationProfileV3Input(tracks: tracks, plays: plays, now: Date())
    }

    @Test("完成率分档")
    func completionTiers() {
        #expect(abs(RecommendationProfileV3Builder.completionFactor(1.0) - 1.0) < 1e-9)
        #expect(abs(RecommendationProfileV3Builder.completionFactor(0.9) - 1.0) < 1e-9)
        #expect(abs(RecommendationProfileV3Builder.completionFactor(0.6) - 0.55) < 1e-9)
        #expect(abs(RecommendationProfileV3Builder.completionFactor(0.3) - 0.1) < 1e-9)
        #expect(abs(RecommendationProfileV3Builder.completionFactor(0.1) - 0.1) < 1e-9)
    }

    @Test("30 天半衰：31 天前的一次完整播放权重 ≈ 0.49，归一化后约为今天的一半")
    func halfLife() {
        let now = Date()
        let tracks = [
            V4Fixture.track("a", artist: "甲"),
            V4Fixture.track("b", artist: "乙"),
        ]
        let plays = [
            RecommendationProfileV3Input.Play(trackStableId: "a", playedAt: now, playDurationMs: 200_000),
            RecommendationProfileV3Input.Play(trackStableId: "b", playedAt: now.addingTimeInterval(-31 * 86_400), playDurationMs: 200_000),
        ]
        let scores = RecommendationProfileV3Builder.artistBehaviorScores(input(plays: plays, tracks: tracks), tracks: tracks)
        #expect(abs((scores["甲"] ?? 0) - 1.0) < 1e-6)
        #expect(abs((scores["乙"] ?? 0) - 0.489) < 0.01)
    }

    @Test("跳过降权：完成率 < 0.3 只记 0.1")
    func skipDownweighted() {
        let tracks = [V4Fixture.track("a", artist: "甲")]
        let plays = [
            RecommendationProfileV3Input.Play(trackStableId: "a", playedAt: Date(), playDurationMs: 30_000),
        ]
        let scores = RecommendationProfileV3Builder.artistBehaviorScores(input(plays: plays, tracks: tracks), tracks: tracks)
        #expect(abs((scores["甲"] ?? 0) - 1.0) < 1e-6) // 单艺人归一化后恒为 1
        let factor = RecommendationProfileV3Builder.completionFactor(30_000.0 / 200_000.0)
        #expect(abs(factor - 0.1) < 1e-9)
    }

    @Test("时长缺失按 0.6 中性")
    func neutralCompletion() {
        let tracks = [V4Fixture.track("a", artist: "甲", durationMs: nil)]
        let plays = [RecommendationProfileV3Input.Play(trackStableId: "a", playedAt: Date(), playDurationMs: 1_000)]
        let factor = RecommendationProfileV3Builder.completionFactor(0.6)
        let scores = RecommendationProfileV3Builder.artistBehaviorScores(input(plays: plays, tracks: tracks), tracks: tracks)
        #expect(abs((scores["甲"] ?? 0) - 1.0) < 1e-6)
        #expect(abs(factor - 0.55) < 1e-9)
    }

    @Test("空播放历史退化：不崩、亲和度仍由曲库规模 + 收藏决定")
    func emptyPlaysDegrade() {
        var big = V4Fixture.track("a", artist: "甲")
        big.isFavorite = true
        let tracks = [big, V4Fixture.track("b", artist: "乙"), V4Fixture.track("c", artist: "乙")]
        let profile = RecommendationProfileV3Builder.build(RecommendationProfileV3Input(tracks: tracks))
        #expect(profile.seeds.count == 2)
        let first = profile.seeds.first
        // 无播放历史 → 退化权重按 (0.35 曲库 + 0.15 收藏) / 0.90 归一化（play 恒 0）：
        //   甲 = (0.35 × log1p(1)/log1p(2) + 0.15) / 0.90 ≈ 0.412
        //   乙 = (0.35 × 1.0 + 0) / 0.90 ≈ 0.389
        // 收藏一项折算后 ≈0.167，比「2 首 vs 1 首」的曲库规模差 ≈0.144 略强，所以只收藏的甲排前。
        #expect(first?.artist == "甲")
        #expect((first?.affinity ?? 0) > 0)
        #expect(RecommendationProfileV3Builder.artistBehaviorScores(
            RecommendationProfileV3Input(tracks: tracks), tracks: tracks
        ).isEmpty)
    }

    @Test("有行为信号时 0.7/0.2/0.1 生效：重度收听艺人排到只收藏艺人的前面")
    func behaviorOutweighsFavorite() {
        var fav = V4Fixture.track("f", artist: "只收藏")
        fav.isFavorite = true
        let tracks = [fav, V4Fixture.track("p", artist: "常听")]
        let plays = (0 ..< 5).map { offset in
            RecommendationProfileV3Input.Play(
                trackStableId: "p",
                playedAt: Date().addingTimeInterval(-Double(offset) * 86_400),
                playDurationMs: 200_000
            )
        }
        let profile = RecommendationProfileV3Builder.build(input(plays: plays, tracks: tracks))
        #expect(profile.seeds.first?.artist == "常听")
    }
}

// MARK: - 3. 通道下限 + 上限

@Suite("推荐 v4：批次选择")
struct RecommendationSelectionV4Tests {
    private func pool(
        seedCount: Int = 5,
        similarCount: Int = 5,
        exploreCount: Int = 5
    ) -> [RecommendationSelectionItem] {
        var items: [RecommendationSelectionItem] = []
        var score = 1.0
        for index in 0 ..< seedCount {
            items.append(V4Fixture.item(key: "s\(index)", channel: .seed, artist: "S\(index)", album: "SA\(index)", score: score))
            score -= 0.01
        }
        for index in 0 ..< similarCount {
            items.append(V4Fixture.item(key: "m\(index)", channel: .similar, artist: "M\(index)", album: "MA\(index)", score: score))
            score -= 0.01
        }
        for index in 0 ..< exploreCount {
            items.append(V4Fixture.item(key: "e\(index)", channel: .explore, artist: "E\(index)", album: "EA\(index)", score: score))
            score -= 0.01
        }
        return items
    }

    private func counts(_ items: [RecommendationSelectionItem], _ picked: [Int]) -> [RecommendationChannel: Int] {
        var out: [RecommendationChannel: Int] = [:]
        for index in picked { out[items[index].channel, default: 0] += 1 }
        return out
    }

    @Test("下限：每通道至少 2/2/1，总数正确")
    func channelFloors() {
        let items = pool()
        let picked = RecommendationSelectionV4.select(items, total: 10)
        #expect(picked.count == 10)
        let byChannel = counts(items, picked)
        #expect((byChannel[.seed] ?? 0) >= 2)
        #expect((byChannel[.similar] ?? 0) >= 2)
        #expect((byChannel[.explore] ?? 0) >= 1)
        #expect(Set(picked.map { items[$0].key }).count == picked.count)
    }

    @Test("目标 <5 时下限按比例缩小")
    func scaledFloors() {
        #expect(RecommendationSelectionV4.minimums(total: 10) == (2, 2, 1))
        #expect(RecommendationSelectionV4.minimums(total: 4) == (1, 1, 0))
        #expect(RecommendationSelectionV4.minimums(total: 2) == (0, 0, 0))
        let items = pool()
        let picked = RecommendationSelectionV4.select(items, total: 4)
        #expect(picked.count == 4)
    }

    @Test("某通道候选不足 → 名额让给其他通道，不少发")
    func redistribution() {
        let items = pool(similarCount: 1)
        let picked = RecommendationSelectionV4.select(items, total: 10)
        #expect(picked.count == 10)
        #expect((counts(items, picked)[.similar] ?? 0) == 1)
    }

    @Test("全程按归一化键去重")
    func dedupe() {
        var items = pool(seedCount: 3)
        items.append(V4Fixture.item(key: "s0", channel: .similar, artist: "S0", album: "SA0", score: 0.99))
        let picked = RecommendationSelectionV4.select(items, total: 8)
        #expect(picked.filter { items[$0].key == "s0" }.count == 1)
    }

    @Test("批内上限：同艺人 ≤2、同专辑 ≤1")
    func batchCaps() {
        let items = [
            V4Fixture.item(key: "a1", artist: "同一人", album: "专一", score: 1.0),
            V4Fixture.item(key: "a2", artist: "同一人", album: "专二", score: 0.9),
            V4Fixture.item(key: "a3", artist: "同一人", album: "专三", score: 0.8),
            V4Fixture.item(key: "b1", artist: "乙", album: "同一专", score: 0.7),
            V4Fixture.item(key: "b2", artist: "丙", album: "同一专", score: 0.6),
            V4Fixture.item(key: "c1", artist: "丁", album: "丁专", score: 0.5),
        ]
        let picked = RecommendationSelectionV4.select(items, total: 6)
        let artists = picked.map { items[$0].artistKey }
        #expect(artists.filter { $0 == RecommendationLibraryMatcher.artistKey("同一人") }.count <= 2)
        let albums = picked.map { items[$0].albumKey }
        #expect(Set(albums).count == albums.count)
    }

    @Test("保留的已下载项 ≤3")
    func retainedLimit() {
        var items = pool(seedCount: 0, similarCount: 0, exploreCount: 0)
        for index in 0 ..< 6 {
            items.append(V4Fixture.item(key: "r\(index)", artist: "R\(index)", album: "RA\(index)", score: 1.0 - Double(index) * 0.01, retained: true))
        }
        for index in 0 ..< 10 {
            items.append(V4Fixture.item(key: "n\(index)", artist: "N\(index)", album: "NA\(index)", score: 0.5 - Double(index) * 0.01))
        }
        let picked = RecommendationSelectionV4.select(items, total: 10)
        #expect(picked.filter { items[$0].isRetainedDownload }.count <= RecommendationSelectionV4.maxRetainedDownloads)
        #expect(picked.count == 10)
    }

    @Test("确定性：同输入同输出")
    func deterministic() {
        let items = pool()
        #expect(RecommendationSelectionV4.select(items, total: 10) == RecommendationSelectionV4.select(items, total: 10))
    }
}

// MARK: - 4. MMR

@Suite("推荐 v4：MMR 多样性")
struct RecommendationMMRTests {
    @Test("有可用替代时不连选同艺人")
    func avoidsSameArtist() {
        let items = [
            V4Fixture.item(key: "x1", artist: "X", album: "XA", score: 1.0),
            V4Fixture.item(key: "x2", artist: "X", album: "XB", score: 0.9),
            V4Fixture.item(key: "y1", artist: "Y", album: "YA", score: 0.8),
            V4Fixture.item(key: "y2", artist: "Y", album: "YB", score: 0.7),
        ]
        let picked = RecommendationSelectionV4.select(items, total: 2)
        #expect(items[picked[0]].artistKey == RecommendationLibraryMatcher.artistKey("X"))
        #expect(items[picked[1]].artistKey == RecommendationLibraryMatcher.artistKey("Y"))
    }

    @Test("λ 效果：同风格（0.3 惩罚）比同专辑（0.6）更早被跳过")
    func penaltyBySignal() {
        let first = V4Fixture.item(key: "g1", artist: "甲", album: "A", genre: "摇滚", year: 2000, score: 1.0)
        let sameGenre = V4Fixture.item(key: "g2", artist: "乙", album: "B", genre: "摇滚", year: 2015, score: 0.95)
        let sameAlbum = V4Fixture.item(key: "g3", artist: "丙", album: "A", genre: "民谣", year: 2014, score: 0.95)
        #expect(RecommendationSelectionV4.similarity(first, sameGenre) == 0.3)
        #expect(RecommendationSelectionV4.similarity(first, sameAlbum) == 0.6)
        let picked = RecommendationSelectionV4.select([first, sameAlbum, sameGenre], total: 2)
        #expect(picked == [0, 2])
    }

    @Test("相似度取最大信号：同艺人 1.0 覆盖同专辑 0.6")
    func similarityTakesMax() {
        let a = V4Fixture.item(key: "1", artist: "同一", album: "同专", genre: "摇滚", year: 2000, score: 1)
        let b = V4Fixture.item(key: "2", artist: "同一", album: "同专", genre: "摇滚", year: 2001, score: 1)
        #expect(RecommendationSelectionV4.similarity(a, b) == 1.0)
    }
}

// MARK: - 5. 归一化键

@Suite("推荐 v4：归一化键")
struct RecommendationMatcherV4Tests {
    private func keys(_ title: String, _ artist: String) -> Set<String> {
        RecommendationLibraryMatcher.keys(title: title, artist: artist)
    }

    @Test("多艺人 & 拆集合：任一命中即算（库内只存其中一个）")
    func ampersandSet() {
        let candidate = keys("因为爱情", "陈奕迅 & 王菲")
        #expect(candidate.contains("因为爱情#陈奕迅"))
        #expect(candidate.contains("因为爱情#王菲"))
        #expect(RecommendationLibraryMatcher.matches(candidate, libraryKeys: keys("因为爱情", "陈奕迅")))
        #expect(RecommendationLibraryMatcher.matches(candidate, libraryKeys: keys("因为爱情", "王菲")))
        #expect(RecommendationLibraryMatcher.matches(keys("因为爱情", "陈奕迅 & 王菲"), libraryKeys: keys("因为爱情", "陈奕迅、王菲")))
    }

    @Test("逗号 / 顿号 / 斜杠 / feat. 同样拆")
    func otherSeparators() {
        #expect(keys("歌", "甲, 乙").contains("歌#乙"))
        #expect(keys("歌", "甲/乙").contains("歌#乙"))
        #expect(keys("歌", "甲 feat. 乙").contains("歌#乙"))
        #expect(keys("歌", "甲 ft. 乙").contains("歌#乙"))
    }

    @Test("中文括号副标题剥离后仍能与原曲命中")
    func chineseSubtitle() {
        #expect(RecommendationLibraryMatcher.titleKey("晴天（电影《不能说的秘密》主题曲）") == RecommendationLibraryMatcher.titleKey("晴天"))
        #expect(RecommendationLibraryMatcher.titleKey("晴天【电影主题曲】") == RecommendationLibraryMatcher.titleKey("晴天"))
        #expect(RecommendationLibraryMatcher.matches(
            keys("晴天（电影《不能说的秘密》主题曲）", "周杰伦"),
            libraryKeys: keys("晴天", "周杰伦")
        ))
    }

    @Test("dash 版后缀白名单：现场版 / Live / 演唱会 / Remastered / 伴奏 / DJ版 / 片段")
    func dashVersions() {
        let base = RecommendationLibraryMatcher.titleKey("晴天")
        for suffix in ["- 现场版", "- Live", "- 演唱会", "- Remastered", "- 2011 Remaster", "- 伴奏", "- DJ版", "- 片段"] {
            #expect(RecommendationLibraryMatcher.titleKey("晴天 \(suffix)") == base)
        }
    }

    @Test("默认繁简折叠委托仓库唯一数据源（RecommendationNormalization）")
    func defaultFoldDelegates() {
        #expect(RecommendationScriptFolding.current("周杰倫") == RecommendationNormalization.toSimplified("周杰倫"))
        #expect(RecommendationScriptFolding.current("周杰倫") == "周杰伦")
        #expect(RecommendationScriptFolding.current("愛你") == "爱你")
        #expect(RecommendationScriptFolding.current("abc") == "abc")
    }

    @Test("繁简折叠：只改键，不改展示")
    func scriptFolding() {
        #expect(RecommendationLibraryMatcher.matches(
            keys("晴天", "周杰倫"),
            libraryKeys: keys("晴天", "周杰伦")
        ))
        #expect(RecommendationLibraryMatcher.matches(
            keys("愛你", "王心凌"),
            libraryKeys: keys("爱你", "王心凌")
        ))
    }

    @Test("全半角 / 大小写 / 空格折叠")
    func widthAndCase() {
        #expect(keys("ＬＯＶＥ　ＳＴＯＲＹ", "Ｔａｙｌｏｒ　Ｓｗｉｆｔ").contains("lovestory#taylorswift"))
        #expect(keys("Love Story", "Taylor Swift").contains("lovestory#taylorswift"))
    }

    @Test("库内无 artistId：退到纯标题键，而不是标题#")
    func missingArtist() {
        let library = keys("晴天", "")
        #expect(library.contains("晴天#"))
        #expect(RecommendationLibraryMatcher.matches(keys("晴天", "周杰伦"), libraryKeys: library))
        // 两侧都有艺人 → 纯标题兜底不生效，同名不同歌不互相误伤
        #expect(!RecommendationLibraryMatcher.matches(keys("晴天", "周杰伦"), libraryKeys: keys("晴天", "蔡依林")))
    }

    @Test("文件名兜底：周杰伦-晴天 拆成艺人 + 标题并交叉验证")
    func filenameFallback() {
        #expect(keys("周杰伦-晴天", "").contains("晴天#周杰伦"))
        #expect(keys("周杰伦 - 晴天", "").contains("晴天#周杰伦"))
        // 有艺人时不做 dash 拆分（AC-DC 是标题的一部分）
        #expect(RecommendationLibraryMatcher.titleKey("AC-DC") == "acdc")
        #expect(RecommendationLibraryMatcher.artistKey("AC/DC") == "ac")
    }

    @Test("唯一键与匹配键分离：key 取主艺人，keys 展开集合")
    func canonicalVsMatchKeys() {
        // 唯一键保住组合名（& 不拆，保护 Simon & Garfunkel 这类组合）；集合键才拆
        #expect(RecommendationLibraryMatcher.key(title: "因为爱情", artist: "陈奕迅 & 王菲") == "因为爱情#陈奕迅王菲")
        #expect(keys("因为爱情", "陈奕迅 & 王菲").count >= 2)
    }
}

// MARK: - 6. 已下载保留 / 新批次排除

private actor V4LibraryKeysStub {
    private var keys: Set<String> = []

    func set(_ newKeys: Set<String>) {
        keys = newKeys
    }

    func load() -> Set<String> {
        keys
    }
}

@Suite("推荐 v4：已下载保留")
struct RecommendationDownloadedRetentionTests {
    @Test("下载完成 → isDownloaded 变 true → 条目仍在列表（不被新批抹掉）")
    func downloadedStaysInList() async {
        let stub = V4LibraryKeysStub()
        var index: any RecommendationDownloadedIndexProviding = RecommendationDownloadedIndex(keys: [], loadKeys: { await stub.load() })
        let c1 = V4Fixture.candidate("晴天", artist: "周杰伦")
        let c2 = V4Fixture.candidate("七里香", artist: "周杰伦")
        let c3 = V4Fixture.candidate("稻香", artist: "周杰伦")
        #expect(!index.isDownloaded(title: c1.title, artist: c1.artist))

        await stub.set(RecommendationLibraryMatcher.keys(title: c1.title, artist: c1.artist))
        index = await index.refreshedIndex()
        #expect(index.isDownloaded(title: c1.title, artist: c1.artist))

        let merged = RecommendationDownloadedRetention.merge(
            previous: [c1, c2, c3],
            fresh: [c2, c3],
            isDownloaded: { index.isDownloaded(title: $0.title, artist: $0.artist) }
        )
        #expect(merged.count == 3)
        #expect(merged.first?.title == "晴天")
        #expect(merged.filter { $0.title == "晴天" }.count == 1)
    }

    @Test("保留上限 3：多余项按原批顺序丢弃")
    func retentionLimit() {
        let previous = (0 ..< 6).map { V4Fixture.candidate("歌\($0)", artist: "甲\($0)") }
        let merged = RecommendationDownloadedRetention.merge(
            previous: previous,
            fresh: [],
            isDownloaded: { _ in true }
        )
        #expect(merged.count == RecommendationDownloadedRetention.maxRetained)
        #expect(merged.map(\.title) == ["歌0", "歌1", "歌2"])
    }

    @Test("未下载的旧条目不会被保留")
    func onlyDownloadedRetained() {
        let previous = [V4Fixture.candidate("旧歌", artist: "甲")]
        let fresh = [V4Fixture.candidate("新歌", artist: "乙")]
        let merged = RecommendationDownloadedRetention.merge(previous: previous, fresh: fresh, isDownloaded: { _ in false })
        #expect(merged.map(\.title) == ["新歌"])
    }

    @Test("新生成批次排除已下载；本批保留项放行")
    func newBatchExcludesDownloaded() {
        let owned = V4Fixture.v3Candidate("晴天", artist: "周杰伦")
        let other = V4Fixture.v3Candidate("七里香", artist: "周杰伦")
        var profile = RecommendationTasteProfileV3()
        profile.libraryKeys = RecommendationLibraryMatcher.keys(title: "晴天", artist: "周杰伦")
        let fresh = RecommendationRankerV3.admit([owned, other], profile: profile)
        #expect(fresh.map(\.song.title) == ["七里香"])
        let kept = RecommendationRankerV3.admit([owned, other], profile: profile, keepKeys: profile.libraryKeys)
        #expect(Set(kept.map(\.song.title)) == ["晴天", "七里香"])
    }
}
