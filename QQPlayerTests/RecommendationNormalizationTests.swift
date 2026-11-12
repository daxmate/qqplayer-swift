//
//  RecommendationNormalizationTests.swift
//  QQPlayerTests
//
//  推荐 v2 P1 自证测试：
//  1. 归一化（繁→简 / 版本尾缀 / feat. 拆分 / 标点 / 幂等 / 空串 / 去重键）
//  2. 准入闸（每个条件各一条「该拒」+ 一条「该留」，且只走 isLikelyNonSong 一个入口；
//     歌曲 ID 缺失按 2026-11-12 口径只 flagged、不拒绝——单列回归用例）
//
//  注意：套件名不能叫 RecommendationNormalizationTests —— 那个名字已被
//  QQPlayerTests/RecommendationTests.swift 占用（同 module 重名 = 编译失败）。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 归一化

@Suite("推荐 v2 归一化")
struct RecommendationNormalizationKeyTests {
    @Test("繁→简走 CharacterMapResourceLoader 的唯一表")
    func convertsTraditionalToSimplified() {
        #expect(RecommendationNormalization.toSimplified("風衣") == "风衣")
        #expect(RecommendationNormalization.normalizeTitle("風衣") == "风衣")
        #expect(RecommendationNormalization.normalizeTitle("我懷念的") == "我怀念的")
        #expect(RecommendationNormalization.normalizeArtist("孫燕姿") == "孙燕姿")
        // 繁简必须收敛到同一去重键（iTunes 繁体标题 vs 库内简体）。
        #expect(
            RecommendationNormalization.dedupeKey(title: "風衣", artist: "孫燕姿")
                == RecommendationNormalization.dedupeKey(title: "风衣", artist: "孙燕姿")
        )
    }

    @Test("版本 / 现场 / 伴奏后缀剥离")
    func stripsVersionSuffixes() {
        #expect(RecommendationNormalization.normalizeTitle("晴天（Live）") == "晴天")
        #expect(RecommendationNormalization.normalizeTitle("晴天 - Remastered 2011") == "晴天")
        #expect(RecommendationNormalization.normalizeTitle("晴天 Live") == "晴天")
        #expect(RecommendationNormalization.normalizeTitle("倔强 演唱会") == "倔强")
        #expect(RecommendationNormalization.normalizeTitle("倔强 现场版") == "倔强")
        #expect(RecommendationNormalization.normalizeTitle("倔强 重制版") == "倔强")
        #expect(RecommendationNormalization.normalizeTitle("倔强 伴奏") == "倔强")
        #expect(RecommendationNormalization.normalizeTitle("Song instrumental") == "song")
        #expect(RecommendationNormalization.normalizeTitle("Song inst.") == "song")
        #expect(RecommendationNormalization.normalizeTitle("Song Demo") == "song")
        #expect(RecommendationNormalization.normalizeTitle("晴天 试听版") == "晴天")
        #expect(RecommendationNormalization.normalizeTitle("Song feat. Jay") == "song")
        // 尾缀叠加也要剥离干净。
        #expect(RecommendationNormalization.normalizeTitle("Song Live Remastered") == "song")
    }

    @Test("feat. / & / , / 、 / x 拆分取主艺人")
    func splitsFeaturedArtists() {
        #expect(RecommendationNormalization.normalizeArtist("周杰倫 feat. 費玉清") == "周杰伦")
        #expect(RecommendationNormalization.normalizeArtist("A & B") == "a")
        #expect(RecommendationNormalization.normalizeArtist("A, B") == "a")
        #expect(RecommendationNormalization.normalizeArtist("A、B") == "a")
        #expect(RecommendationNormalization.normalizeArtist("A x B") == "a")
        #expect(RecommendationNormalization.normalizeArtist("孙燕姿") == "孙燕姿")
    }

    @Test("标点与多余空白归一")
    func stripsPunctuationAndSpaces() {
        #expect(RecommendationNormalization.normalizeTitle("Don't Stop!!") == "dont stop")
        #expect(RecommendationNormalization.normalizeTitle("  晴天   ") == "晴天")
        #expect(RecommendationNormalization.normalizeTitle("晴天，。") == "晴天")
        #expect(RecommendationNormalization.normalizeArtist("  Jay   Chou ") == "jaychou")
    }

    @Test("幂等：同一输入连续两次结果一致")
    func isIdempotent() {
        let titles = ["風衣", "晴天 Live", "Song feat. Jay", "Don't Stop!!", "", "倔强 演唱会"]
        for title in titles {
            let once = RecommendationNormalization.normalizeTitle(title)
            #expect(RecommendationNormalization.normalizeTitle(once) == once, "歌名不幂等：\(title)")
        }
        let artists = ["孫燕姿", "A & B", "A x B", "", "Jay   Chou"]
        for artist in artists {
            let once = RecommendationNormalization.normalizeArtist(artist)
            #expect(RecommendationNormalization.normalizeArtist(once) == once, "艺人不幂等：\(artist)")
        }
    }

    @Test("空串安全")
    func handlesEmptyStrings() {
        #expect(RecommendationNormalization.normalizeTitle("").isEmpty)
        #expect(RecommendationNormalization.normalizeArtist("").isEmpty)
        #expect(RecommendationNormalization.toSimplified("").isEmpty)
        #expect(RecommendationNormalization.dedupeKey(title: "", artist: "") == "|")
    }

    @Test("去重键：繁简 / 版本 / 大小写不同的同曲收敛到同一键")
    func dedupeKeyCollapsesVariants() {
        let base = RecommendationNormalization.dedupeKey(title: "晴天", artist: "周杰伦")
        #expect(RecommendationNormalization.dedupeKey(title: "晴天（Live）", artist: "周杰伦") == base)
        #expect(RecommendationNormalization.dedupeKey(title: "晴天 - Remastered", artist: "周杰伦") == base)
        #expect(RecommendationNormalization.dedupeKey(title: "晴天", artist: "周杰倫 feat. 某人") == base)
    }
}

// MARK: - 准入闸

@Suite("推荐 v2 准入闸")
struct RecommendationAdmissionGateTests {
    private func song(
        _ title: String,
        _ artist: String,
        album: String? = nil,
        songID: Int? = 1,
        durationMs: Int? = 269_000
    ) -> RecommendationRemoteSong {
        RecommendationRemoteSong(
            title: title,
            artist: artist,
            album: album,
            year: nil,
            songID: songID,
            durationMs: durationMs
        )
    }

    @Test("歌曲 ID 缺失不拒（只 flagged）")
    func missingSongIDIsNotARejection() {
        // 2026-11-12 口径：歌曲海源全量无 id，id 的用途是相似召回 / 去重，不是单曲身份判据。
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("晴天", "周杰伦", songID: nil)) == nil)
        #expect(!RecommendationCandidateFilter.isLikelyNonSong(song("晴天", "周杰伦", songID: nil)))
        // 枚举 rawValue 已发布到日志：保留不动（历史日志可对照）。
        #expect(RecommendationAdmissionRejection.missingSongID.rawValue == "missing_song_id")
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("晴天", "周杰伦", songID: 42)) == nil)
        #expect(!RecommendationCandidateFilter.isLikelyNonSong(song("晴天", "周杰伦", songID: 42)))
    }

    @Test("条件 2：30s ≤ 时长 ≤ 10min（缺失沿用既有语义）")
    func enforcesDurationWindow() {
        #expect(
            RecommendationCandidateFilter.admissionRejection(for: song("晴天", "周杰伦", durationMs: 10_000))
                == .durationOutOfRange
        )
        #expect(
            RecommendationCandidateFilter.admissionRejection(for: song("晴天", "周杰伦", durationMs: 15 * 60 * 1000))
                == .durationOutOfRange
        )
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("晴天", "周杰伦", durationMs: 30_000)) == nil)
        #expect(
            RecommendationCandidateFilter.admissionRejection(for: song("晴天", "周杰伦", durationMs: 10 * 60 * 1000))
                == nil
        )
        // 时长缺失不拦（既有语义）。
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("晴天", "周杰伦", durationMs: nil)) == nil)
    }

    @Test("条件 3：艺人非泛称")
    func rejectsGenericArtists() {
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("晴天", "群星")) == .genericArtist)
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("晴天", "Various Artists")) == .genericArtist)
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("晴天", "未知")) == .genericArtist)
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("晴天", "Radiohead")) == nil)
    }

    @Test("条件 4：标题非空 / 非歌单标记 / 非纯年代标签")
    func rejectsLabelTitles() {
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("   ", "周杰伦")) == .emptyTitle)
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("华语精选100首", "周杰伦")) == .playlistMarker)
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("Greatest Hits", "Queen")) == .playlistMarker)
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("1990s", "周杰伦")) == .decadeOnlyTitle)
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("晴天", "周杰伦")) == nil)
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("1990s Love Song", "周杰伦")) == nil)
    }

    @Test("条件 5：标题 ≠ 专辑名")
    func rejectsTitleEqualsAlbum() {
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("晴天", "周杰伦", album: "晴天")) == .titleEqualsAlbum)
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("晴天", "周杰伦", album: " 晴天 ")) == .titleEqualsAlbum)
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("晴天", "周杰伦", album: "叶惠美")) == nil)
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("晴天", "周杰伦", album: nil)) == nil)
        #expect(RecommendationCandidateFilter.admissionRejection(for: song("晴天", "周杰伦", album: "  ")) == nil)
    }

    @Test("条件 6：既有歌单 / 合辑 / 串烧标记仍生效")
    func keepsExistingMarkerRules() {
        for title in ["歌单", "合辑", "串烧", "榜单", "playlist", "medley", "non-stop", "top 100"] {
            #expect(
                RecommendationCandidateFilter.admissionRejection(for: song("\(title) 精选集", "周杰伦"))
                    == .playlistMarker,
                "既有标记失效：\(title)"
            )
        }
    }

    @Test("唯一入口：isLikelyNonSong 与原因判定一致")
    func singleEntryMatchesReason() {
        let samples = [
            song("晴天", "周杰伦", album: "叶惠美"),
            song("晴天", "周杰伦", songID: nil),
            song("群星", "群星"),
            song("1990s", "周杰伦"),
            song("晴天", "周杰伦", album: "晴天"),
        ]
        for sample in samples {
            let hasReason = RecommendationCandidateFilter.admissionRejection(for: sample) != nil
            #expect(RecommendationCandidateFilter.isLikelyNonSong(sample) == hasReason)
        }
    }
}
