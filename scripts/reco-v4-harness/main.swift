//
//  main.swift — 推荐 v4 纯逻辑本地 harness（无模拟器、无网络、无 DB）
//
//  跑的是**生产源码**（scripts/run-reco-v4-tests.sh 里列出的文件），断言与
//  QQPlayerTests/RecommendationV4Tests.swift 同构。CI 侧仍以 xcodebuild test 为准，
//  这里解决「不许开模拟器」纪律下的本地真跑问题。
//

import Foundation

var failures: [String] = []
var checks = 0

func expect(_ condition: Bool, _ message: String) {
    checks += 1
    if !condition { failures.append(message) }
}

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
    checks += 1
    if lhs != rhs { failures.append("\(message)（实际 \(lhs) ≠ 期望 \(rhs)）") }
}

func near(_ lhs: Double, _ rhs: Double, _ tolerance: Double = 1e-6) -> Bool {
    abs(lhs - rhs) <= tolerance
}

func seed(_ artist: String, affinity: Double) -> RecommendationSeedArtist {
    RecommendationSeedArtist(
        artist: artist,
        affinity: affinity,
        libraryCount: 10,
        playCount: 10,
        representativeTitles: []
    )
}

func track(
    _ id: String,
    artist: String,
    title: String = "歌",
    durationMs: Int? = 200_000
) -> RecommendationProfileV3Input.Track {
    RecommendationProfileV3Input.Track(
        stableId: id, title: title, artist: artist, durationMs: durationMs
    )
}

func item(
    _ key: String,
    _ channel: RecommendationChannel = .seed,
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

// MARK: - 1. 种子抽样

do {
    let pool = (0 ..< 25).map { index in seed("艺人\(index)", affinity: max(0.01, 1.0 - Double(index) * 0.03)) }
    let a = RecommendationSeedSampler.sample(pool, k: 8, seed: 42)
    let b = RecommendationSeedSampler.sample(pool, k: 8, seed: 42)
    expectEqual(a.map(\.artist), b.map(\.artist), "同 seed 结果一致")
    expectEqual(a.count, 8, "K=8 取满")
    expectEqual(Set(RecommendationSeedSampler.sample(pool, k: 20, seed: 7).map(\.artist)).count, 20, "无重复")
    let window = Set(RecommendationSeedSampler.ranked(pool).prefix(20).map(\.artist))
    var inWindow = true
    var sawDifferent = Set<[String]>()
    for s in UInt64(1) ... 30 {
        let picked = RecommendationSeedSampler.sample(pool, k: 10, seed: s)
        if !picked.allSatisfy({ window.contains($0.artist) }) { inWindow = false }
        sawDifferent.insert(picked.map(\.artist))
    }
    expect(inWindow, "只在前 20 名内抽")
    expect(sawDifferent.count > 1, "不同 seed 抽样不同")
    expect(RecommendationSeedSampler.sample(pool, k: 0, seed: 1).isEmpty, "K=0 返回空")
    expectEqual(RecommendationSeedSampler.sample(pool, k: 99, seed: 1).count, 20, "K 超窗口裁剪到 20")
    expect(RecommendationSeedSampler.sample([], k: 5, seed: 1).isEmpty, "空池返回空")
    expectEqual(
        RecommendationSeedSampler.ranked([seed("Zeta", affinity: 0.5), seed("Alpha", affinity: 0.5)]).map(\.artist),
        ["Alpha", "Zeta"],
        "并列按 artist key 稳定"
    )
}

// MARK: - 2. 画像行为信号

do {
    expect(near(RecommendationProfileV3Builder.completionFactor(1.0), 1.0), "完成率 1.0 → 1.0")
    expect(near(RecommendationProfileV3Builder.completionFactor(0.9), 1.0), "完成率 0.9 → 1.0")
    expect(near(RecommendationProfileV3Builder.completionFactor(0.6), 0.55), "完成率 0.6 → 0.55")
    expect(near(RecommendationProfileV3Builder.completionFactor(0.3), 0.1), "完成率 0.3 → 0.1")
    expect(near(RecommendationProfileV3Builder.completionFactor(0.1), 0.1), "跳过 → 0.1")

    let now = Date()
    let tracks = [
        track("a", artist: "甲"),
        track("b", artist: "乙"),
    ]
    let plays = [
        RecommendationProfileV3Input.Play(trackStableId: "a", playedAt: now, playDurationMs: 200_000),
        RecommendationProfileV3Input.Play(trackStableId: "b", playedAt: now.addingTimeInterval(-31 * 86_400), playDurationMs: 200_000),
    ]
    let input = RecommendationProfileV3Input(tracks: tracks, plays: plays, now: now)
    let scores = RecommendationProfileV3Builder.artistBehaviorScores(input, tracks: tracks)
    expect(near(scores["甲"] ?? 0, 1.0), "今天完整播放 = 1.0")
    expect(near(scores["乙"] ?? 0, 0.489, 0.01), "31 天前 ≈ 半衰 0.489")

    let empty = RecommendationProfileV3Builder.artistBehaviorScores(RecommendationProfileV3Input(tracks: tracks), tracks: tracks)
    expect(empty.isEmpty, "空播放历史 → 空行为分")

    var fav = track("f", artist: "只收藏")
    fav.isFavorite = true
    let behaviorTracks = [fav, track("p", artist: "常听")]
    let behaviorPlays = (0 ..< 5).map { offset in
        RecommendationProfileV3Input.Play(
            trackStableId: "p",
            playedAt: now.addingTimeInterval(-Double(offset) * 86_400),
            playDurationMs: 200_000
        )
    }
    let profile = RecommendationProfileV3Builder.build(
        RecommendationProfileV3Input(tracks: behaviorTracks, plays: behaviorPlays, now: now)
    )
    expectEqual(profile.seeds.first?.artist, "常听", "行为信号压过收藏")
}

// MARK: - 3. 选择（下限 / 重分配 / 去重 / 上限 / MMR）

do {
    var items: [RecommendationSelectionItem] = []
    var score = 1.0
    for index in 0 ..< 5 {
        items.append(item("s\(index)", .seed, artist: "S\(index)", album: "SA\(index)", score: score)); score -= 0.01
    }
    for index in 0 ..< 5 {
        items.append(item("m\(index)", .similar, artist: "M\(index)", album: "MA\(index)", score: score)); score -= 0.01
    }
    for index in 0 ..< 5 {
        items.append(item("e\(index)", .explore, artist: "E\(index)", album: "EA\(index)", score: score)); score -= 0.01
    }
    let picked = RecommendationSelectionV4.select(items, total: 10)
    expectEqual(picked.count, 10, "总数 10")
    var byChannel: [RecommendationChannel: Int] = [:]
    for index in picked { byChannel[items[index].channel, default: 0] += 1 }
    expect((byChannel[.seed] ?? 0) >= 2, "seed 下限 2")
    expect((byChannel[.similar] ?? 0) >= 2, "similar 下限 2")
    expect((byChannel[.explore] ?? 0) >= 1, "explore 下限 1")
    expectEqual(Set(picked.map { items[$0].key }).count, picked.count, "无重复")

    expect(RecommendationSelectionV4.minimums(total: 4) == (1, 1, 0), "total=4 下限按比例缩小")
    expect(RecommendationSelectionV4.minimums(total: 2) == (0, 0, 0), "total=2 无下限")

    var scarce = Array(items.filter { $0.channel != .similar })
    scarce.append(item("m-only", .similar, artist: "M0", album: "MA0", score: 0.99))
    let redistributed = RecommendationSelectionV4.select(scarce, total: 10)
    expectEqual(redistributed.count, 10, "通道不足不少发")
    expectEqual(redistributed.filter { scarce[$0].channel == .similar }.count, 1, "similar 只有 1 条")

    var dup = items
    dup.append(item("s0", .similar, artist: "S0", album: "SA0", score: 0.995))
    let deduped = RecommendationSelectionV4.select(dup, total: 8)
    expectEqual(deduped.filter { dup[$0].key == "s0" }.count, 1, "归一化键去重")

    let caps = [
        item("a1", artist: "同一人", album: "专一", score: 1.0),
        item("a2", artist: "同一人", album: "专二", score: 0.9),
        item("a3", artist: "同一人", album: "专三", score: 0.8),
        item("b1", artist: "乙", album: "同一专", score: 0.7),
        item("b2", artist: "丙", album: "同一专", score: 0.6),
        item("c1", artist: "丁", album: "丁专", score: 0.5),
    ]
    let capped = RecommendationSelectionV4.select(caps, total: 6)
    let sameArtist = RecommendationLibraryMatcher.artistKey("同一人")
    expect(capped.filter { caps[$0].artistKey == sameArtist }.count <= 2, "同艺人 ≤2")
    let albums = capped.map { caps[$0].albumKey }
    expectEqual(Set(albums).count, albums.count, "同专辑 ≤1")

    var retainedItems: [RecommendationSelectionItem] = []
    for index in 0 ..< 6 { retainedItems.append(item("r\(index)", artist: "R\(index)", album: "RA\(index)", score: 1.0 - Double(index) * 0.01, retained: true)) }
    for index in 0 ..< 10 { retainedItems.append(item("n\(index)", artist: "N\(index)", album: "NA\(index)", score: 0.5 - Double(index) * 0.01)) }
    let retainedPicked = RecommendationSelectionV4.select(retainedItems, total: 10)
    expect(retainedPicked.filter { retainedItems[$0].isRetainedDownload }.count <= RecommendationSelectionV4.maxRetainedDownloads, "保留已下载 ≤3")
    expectEqual(retainedPicked.count, 10, "保留项不挤掉总数")
    expectEqual(RecommendationSelectionV4.select(items, total: 10), picked, "确定性")

    // MMR：有替代时不连选同艺人
    let mmr = [
        item("x1", artist: "X", album: "XA", score: 1.0),
        item("x2", artist: "X", album: "XB", score: 0.9),
        item("y1", artist: "Y", album: "YA", score: 0.8),
        item("y2", artist: "Y", album: "YB", score: 0.7),
    ]
    let mmrPicked = RecommendationSelectionV4.select(mmr, total: 2)
    expectEqual(mmr[mmrPicked[0]].artistKey, RecommendationLibraryMatcher.artistKey("X"), "MMR 首选最高分")
    expectEqual(mmr[mmrPicked[1]].artistKey, RecommendationLibraryMatcher.artistKey("Y"), "MMR 次选避开同艺人")

    // 相似度信号取最大 + 惩罚顺序
    let g1 = item("g1", artist: "甲", album: "A", genre: "摇滚", year: 2000, score: 1.0)
    let sameGenre = item("g2", artist: "乙", album: "B", genre: "摇滚", year: 2015, score: 0.95)
    let sameAlbum = item("g3", artist: "丙", album: "A", genre: "民谣", year: 2014, score: 0.95)
    expect(near(RecommendationSelectionV4.similarity(g1, sameGenre), 0.3), "同风格 0.3")
    expect(near(RecommendationSelectionV4.similarity(g1, sameAlbum), 0.6), "同专辑 0.6")
    expect(near(RecommendationSelectionV4.similarity(g1, item("g4", artist: "甲", album: "Z", genre: "x", year: 1990, score: 1)), 1.0), "同艺人 1.0")
    expectEqual(RecommendationSelectionV4.select([g1, sameAlbum, sameGenre], total: 2), [0, 2], "同风格比同专辑更早被跳过")
}

// MARK: - 4. 归一化键

do {
    let candidate = RecommendationLibraryMatcher.keys(title: "因为爱情", artist: "陈奕迅 & 王菲")
    expect(candidate.contains("因为爱情#陈奕迅"), "& 拆出主艺人")
    expect(candidate.contains("因为爱情#王菲"), "& 拆出次艺人")
    expect(
        RecommendationLibraryMatcher.matches(candidate, libraryKeys: RecommendationLibraryMatcher.keys(title: "因为爱情", artist: "王菲")),
        "& 任一命中即算"
    )
    expect(
        RecommendationLibraryMatcher.matches(
            RecommendationLibraryMatcher.keys(title: "因为爱情", artist: "陈奕迅 & 王菲"),
            libraryKeys: RecommendationLibraryMatcher.keys(title: "因为爱情", artist: "陈奕迅、王菲")
        ),
        "& 与顿号等价"
    )
    expect(RecommendationLibraryMatcher.keys(title: "歌", artist: "甲, 乙").contains("歌#乙"), "逗号拆分")
    expect(RecommendationLibraryMatcher.keys(title: "歌", artist: "甲/乙").contains("歌#乙"), "斜杠拆分")
    expect(RecommendationLibraryMatcher.keys(title: "歌", artist: "甲 feat. 乙").contains("歌#乙"), "feat. 拆分")
    expect(RecommendationLibraryMatcher.keys(title: "歌", artist: "甲 ft. 乙").contains("歌#乙"), "ft. 拆分")

    let base = RecommendationLibraryMatcher.titleKey("晴天")
    expectEqual(RecommendationLibraryMatcher.titleKey("晴天（电影《不能说的秘密》主题曲）"), base, "中文括号副标题剥离")
    expectEqual(RecommendationLibraryMatcher.titleKey("晴天【电影主题曲】"), base, "【】副标题剥离")
    expect(
        RecommendationLibraryMatcher.matches(
            RecommendationLibraryMatcher.keys(title: "晴天（电影《不能说的秘密》主题曲）", artist: "周杰伦"),
            libraryKeys: RecommendationLibraryMatcher.keys(title: "晴天", artist: "周杰伦")
        ),
        "副标题版本命中原曲"
    )
    for suffix in ["- 现场版", "- Live", "- 演唱会", "- Remastered", "- 2011 Remaster", "- 伴奏", "- DJ版", "- 片段"] {
        expectEqual(RecommendationLibraryMatcher.titleKey("晴天 \(suffix)"), base, "dash 后缀 \(suffix) 剥离")
    }

    expect(
        RecommendationLibraryMatcher.matches(
            RecommendationLibraryMatcher.keys(title: "晴天", artist: "周杰倫"),
            libraryKeys: RecommendationLibraryMatcher.keys(title: "晴天", artist: "周杰伦")
        ),
        "繁简折叠"
    )
    expect(
        RecommendationLibraryMatcher.keys(title: "ＬＯＶＥ　ＳＴＯＲＹ", artist: "Ｔａｙｌｏｒ　Ｓｗｉｆｔ").contains("lovestory#taylorswift"),
        "全半角 + 大小写折叠"
    )

    let orphanLibrary = RecommendationLibraryMatcher.keys(title: "晴天", artist: "")
    expect(orphanLibrary.contains("晴天#"), "无 artistId → 纯标题键")
    expect(
        RecommendationLibraryMatcher.matches(RecommendationLibraryMatcher.keys(title: "晴天", artist: "周杰伦"), libraryKeys: orphanLibrary),
        "无 artistId 兜底命中"
    )
    expect(
        !RecommendationLibraryMatcher.matches(
            RecommendationLibraryMatcher.keys(title: "晴天", artist: "周杰伦"),
            libraryKeys: RecommendationLibraryMatcher.keys(title: "晴天", artist: "蔡依林")
        ),
        "两侧有艺人时同名不同歌不误伤"
    )

    expect(RecommendationLibraryMatcher.keys(title: "周杰伦-晴天", artist: "").contains("晴天#周杰伦"), "文件名兜底拆分")
    expect(RecommendationLibraryMatcher.keys(title: "周杰伦 - 晴天", artist: "").contains("晴天#周杰伦"), "文件名兜底（带空格）")
    expectEqual(RecommendationLibraryMatcher.titleKey("AC-DC"), "acdc", "有艺人时 dash 不拆")
    expectEqual(RecommendationLibraryMatcher.key(title: "因为爱情", artist: "陈奕迅 & 王菲"), "因为爱情#陈奕迅王菲", "唯一键保住组合名（& 不拆）")
}

// MARK: - 5. 已下载保留 / 新批次排除

do {
    let c1 = RecommendedCandidate(title: "晴天", artist: "周杰伦", source: .netease)
    let c2 = RecommendedCandidate(title: "七里香", artist: "周杰伦", source: .netease)
    let c3 = RecommendedCandidate(title: "稻香", artist: "周杰伦", source: .netease)
    let ownedKeys = RecommendationLibraryMatcher.keys(title: c1.title, artist: c1.artist)
    let isDownloaded: (RecommendedCandidate) -> Bool = { candidate in
        RecommendationLibraryMatcher.matches(
            RecommendationLibraryMatcher.keys(title: candidate.title, artist: candidate.artist),
            libraryKeys: ownedKeys
        )
    }
    expect(isDownloaded(c1), "下载完成 → 判定为已下载")
    expect(!isDownloaded(c2), "未下载不误判")
    let merged = RecommendationDownloadedRetention.merge(previous: [c1, c2, c3], fresh: [c2, c3], isDownloaded: isDownloaded)
    expectEqual(merged.count, 3, "下载项仍在列表")
    expectEqual(merged.first?.title, "晴天", "保留原位置")
    expectEqual(merged.filter { $0.title == "晴天" }.count, 1, "不重复插入")

    let many = (0 ..< 6).map { RecommendedCandidate(title: "歌\($0)", artist: "甲\($0)", source: .netease) }
    let limited = RecommendationDownloadedRetention.merge(previous: many, fresh: [], isDownloaded: { _ in true })
    expectEqual(limited.count, RecommendationDownloadedRetention.maxRetained, "保留上限 3")
    expectEqual(limited.map(\.title), ["歌0", "歌1", "歌2"], "超出按原批顺序丢弃")
    let noneRetained = RecommendationDownloadedRetention.merge(
        previous: [c1],
        fresh: [c2],
        isDownloaded: { _ in false }
    )
    expectEqual(noneRetained.map(\.title), ["七里香"], "未下载旧项不保留")
}

// MARK: - 汇总

if failures.isEmpty {
    print("✅ reco-v4 harness 全绿：\(checks) 条断言")
    exit(0)
}
print("❌ reco-v4 harness 失败 \(failures.count)/\(checks)：")
for failure in failures { print("  - \(failure)") }
exit(1)
