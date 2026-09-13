//
//  DisplayScriptNormalizerTests.swift
//  QQPlayerTests
//
//  显示层简繁字形归一纯逻辑测试。方向全部显式注入（不依赖宿主语言），
//  只有"模型 display 属性"一节跟随 DisplayScriptNormalizer.current 并按其分支断言。
//  - 方向判定全矩阵（繁体语言环境 → 繁；其余含 en/fr/ru/空 → 简）
//  - 双向转换（周杰倫↔周杰伦、專輯↔专辑）
//  - 词级保护（千里/頭髮/皇后/重複）、"干"类语境（乾/干/幹）
//  - 显示层无姓氏保护（与歌手名层的差异）
//  - 日文豁免（含假名两方向原样；纯汉字日文照转）
//  - 空串/纯 ASCII/emoji 原样
//  - 模型 display 属性（Track/Album/LyricsLine）与"数据层字段不变"
//

import Foundation
import Testing

@testable import QQPlayer

struct DisplayScriptNormalizerTests {
    // MARK: - 方向判定（全矩阵）

    @Test("繁体中文语言环境 → toTraditional")
    func directionTraditional() {
        for locale in ["zh-Hant", "zh-Hant-TW", "zh-Hant-HK", "zh-HK", "zh-TW", "zh-MO", "ZH-Hant"] {
            #expect(DisplayScriptNormalizer.direction(for: [locale]) == .toTraditional, "\(locale)")
        }
        // 只看首位
        #expect(DisplayScriptNormalizer.direction(for: ["zh-Hant", "en"]) == .toTraditional)
    }

    @Test("其余语言环境（含英文/日文界面）→ toSimplified")
    func directionSimplified() {
        for locale in ["zh-Hans", "zh-Hans-CN", "en", "en-US", "fr", "ru", "ja", "de"] {
            #expect(DisplayScriptNormalizer.direction(for: [locale]) == .toSimplified, "\(locale)")
        }
        #expect(DisplayScriptNormalizer.direction(for: []) == .toSimplified)
        #expect(DisplayScriptNormalizer.direction(for: ["fr", "zh-Hant"]) == .toSimplified) // 只看首位
    }

    // MARK: - 双向转换

    @Test("双向转换：人名与专辑名")
    func bidirectionalConversion() {
        #expect(DisplayScriptNormalizer.display("周杰倫", direction: .toSimplified) == "周杰伦")
        #expect(DisplayScriptNormalizer.display("周杰伦", direction: .toTraditional) == "周傑倫")
        // 混合字形也归一到目标字形
        #expect(DisplayScriptNormalizer.display("周杰倫", direction: .toTraditional) == "周傑倫")
        #expect(DisplayScriptNormalizer.display("專輯", direction: .toSimplified) == "专辑")
        #expect(DisplayScriptNormalizer.display("专辑", direction: .toTraditional) == "專輯")
        // 台→台 特例（台湾惯用字形不做 臺 转换）
        #expect(DisplayScriptNormalizer.display("電台", direction: .toSimplified) == "电台")
        #expect(DisplayScriptNormalizer.display("电台", direction: .toTraditional) == "電台")
        // identity 原样
        #expect(DisplayScriptNormalizer.display("周杰倫", direction: .identity) == "周杰倫")
        #expect(DisplayScriptNormalizer.display("周杰伦", direction: .identity) == "周杰伦")
    }

    // MARK: - 词级保护

    @Test("词级保护：里（长度单位/地名）不转裏")
    func wordCorrectionLi() {
        #expect(DisplayScriptNormalizer.display("千里", direction: .toTraditional) == "千里")
        #expect(DisplayScriptNormalizer.display("千里之外", direction: .toTraditional) == "千里之外")
        #expect(DisplayScriptNormalizer.display("万里", direction: .toTraditional) == "萬里")
        #expect(DisplayScriptNormalizer.display("公里", direction: .toTraditional) == "公里")
        // 方位义的"里"仍按裏转（既有语境行为）
        #expect(DisplayScriptNormalizer.display("那里", direction: .toTraditional) == "那裏")
    }

    @Test("词级保护：发（头发义）转髮")
    func wordCorrectionFa() {
        #expect(DisplayScriptNormalizer.display("头发", direction: .toTraditional) == "頭髮")
        #expect(DisplayScriptNormalizer.display("理发", direction: .toTraditional) == "理髮")
        #expect(DisplayScriptNormalizer.display("假发", direction: .toTraditional) == "假髮")
    }

    @Test("词级保护：后（皇后/天后义）不转後")
    func wordCorrectionHou() {
        #expect(DisplayScriptNormalizer.display("皇后", direction: .toTraditional) == "皇后")
        #expect(DisplayScriptNormalizer.display("天后", direction: .toTraditional) == "天后")
        #expect(DisplayScriptNormalizer.display("后羿", direction: .toTraditional) == "后羿")
    }

    @Test("词级保护：复（複义）不误转復")
    func wordCorrectionFu() {
        #expect(DisplayScriptNormalizer.display("重复", direction: .toTraditional) == "重複")
        #expect(DisplayScriptNormalizer.display("复习", direction: .toTraditional) == "複習")
        #expect(DisplayScriptNormalizer.display("复杂", direction: .toTraditional) == "複雜")
        #expect(DisplayScriptNormalizer.display("反复", direction: .toTraditional) == "反覆")
    }

    @Test("干类语境：乾（干燥义）/ 干（犯·盾义）/ 幹（做事义）")
    func wordCorrectionGan() {
        // 乾：单字表把 干 固定映射为 幹，词级回改
        #expect(DisplayScriptNormalizer.display("干杯", direction: .toTraditional) == "乾杯")
        #expect(DisplayScriptNormalizer.display("干净", direction: .toTraditional) == "乾淨")
        #expect(DisplayScriptNormalizer.display("干燥", direction: .toTraditional) == "乾燥")
        #expect(DisplayScriptNormalizer.display("饼干", direction: .toTraditional) == "餅乾")
        // 干（gān）：干涉/干预/天干/干支
        #expect(DisplayScriptNormalizer.display("干涉", direction: .toTraditional) == "干涉")
        #expect(DisplayScriptNormalizer.display("天干", direction: .toTraditional) == "天干")
        // 幹（gàn）：做事义，单字表直接给出，无需修正
        #expect(DisplayScriptNormalizer.display("干部", direction: .toTraditional) == "幹部")
    }

    @Test("显示层无姓氏保护（与歌手名层的差异）")
    func noSurnameProtection() {
        // 歌手名层保护首字姓氏（于/干），显示层按字形逐字转
        #expect(DisplayScriptNormalizer.display("于文文", direction: .toTraditional) == "於文文")
        #expect(DisplayScriptNormalizer.display("干露露", direction: .toTraditional) == "幹露露")
        #expect(ArtistNameNormalizer.normalizedKey("于文文", direction: .toTraditional) == "于文文")
        #expect(ArtistNameNormalizer.normalizedKey("干露露", direction: .toTraditional) == "干露露")
    }

    // MARK: - 日文豁免

    @Test("含假名（日文）两方向原样返回")
    func kanaExempt() {
        #expect(DisplayScriptNormalizer.containsKana("東京の夜"))
        #expect(DisplayScriptNormalizer.display("東京の夜", direction: .toSimplified) == "東京の夜")
        #expect(DisplayScriptNormalizer.display("東京の夜", direction: .toTraditional) == "東京の夜")
        #expect(DisplayScriptNormalizer.display("宇多田ヒカル", direction: .toSimplified) == "宇多田ヒカル")
        #expect(DisplayScriptNormalizer.display("宇多田ヒカル", direction: .toTraditional) == "宇多田ヒカル")
    }

    @Test("纯汉字日文（无假名）照常转换")
    func japaneseKanjiConverted() {
        #expect(!DisplayScriptNormalizer.containsKana("東京"))
        #expect(DisplayScriptNormalizer.display("東京", direction: .toSimplified) == "东京")
        #expect(DisplayScriptNormalizer.display("東京", direction: .toTraditional) == "東京")
    }

    @Test("containsKana：平假名/片假名/半角片假名均识别，纯汉字与英文为 false")
    func containsKanaMatrix() {
        #expect(DisplayScriptNormalizer.containsKana("あ"))   // 平假名
        #expect(DisplayScriptNormalizer.containsKana("ア"))   // 片假名
        #expect(DisplayScriptNormalizer.containsKana("ｱ"))   // 半角片假名
        #expect(!DisplayScriptNormalizer.containsKana("漢字"))
        #expect(!DisplayScriptNormalizer.containsKana("Adele"))
        #expect(!DisplayScriptNormalizer.containsKana(""))
    }

    // MARK: - 边界输入

    @Test("空串/纯 ASCII/emoji 原样")
    func passthroughInputs() {
        #expect(DisplayScriptNormalizer.display("", direction: .toSimplified).isEmpty)
        #expect(DisplayScriptNormalizer.display("", direction: .toTraditional).isEmpty)
        #expect(DisplayScriptNormalizer.display("Adele", direction: .toSimplified) == "Adele")
        #expect(DisplayScriptNormalizer.display("Adele", direction: .toTraditional) == "Adele")
        #expect(DisplayScriptNormalizer.display("Café 🎵", direction: .toSimplified) == "Café 🎵")
        #expect(DisplayScriptNormalizer.display("Café 🎵", direction: .toTraditional) == "Café 🎵")
    }

    // MARK: - 模型 display 属性

    @Test("Track.displayTitle/displayGenre 跟随当前方向；原始字段不变")
    func trackDisplayProperties() {
        var track = Track(stableId: "s1", title: "周杰倫", path: "/tmp/a.mp3")
        track.genre = "搖滾"
        if DisplayScriptNormalizer.current == .toTraditional {
            #expect(track.displayTitle == "周傑倫")
            #expect(track.displayGenre == "搖滾")
        } else {
            #expect(track.displayTitle == "周杰伦")
            #expect(track.displayGenre == "摇滚")
        }
        // 数据层字段一个字都不动
        #expect(track.title == "周杰倫")
        #expect(track.genre == "搖滾")
    }

    @Test("Track.displayTitle：含假名标题两个方向都原样")
    func trackDisplayTitleKana() {
        let track = Track(stableId: "s2", title: "東京の夜", path: "/tmp/b.mp3")
        #expect(track.displayTitle == "東京の夜")
    }

    @Test("Track.displayGenre：nil 保持 nil")
    func trackDisplayGenreNil() {
        let track = Track(stableId: "s3", title: "Adele", path: "/tmp/c.mp3")
        #expect(track.genre == nil)
        #expect(track.displayGenre == nil)
    }

    @Test("Album.displayTitle 跟随当前方向")
    func albumDisplayTitle() {
        let album = Album(title: "專輯")
        #expect(album.displayTitle == (DisplayScriptNormalizer.current == .toTraditional ? "專輯" : "专辑"))
        #expect(album.title == "專輯")
    }

    @Test("LyricsLine.displayText/displayTranslation 跟随当前方向；nil 保持 nil")
    func lyricsLineDisplay() {
        let toTraditional = DisplayScriptNormalizer.current == .toTraditional
        let line = LyricsLine(timestamp: 12.5, text: "周杰倫", translation: "專輯")
        #expect(line.displayText == (toTraditional ? "周傑倫" : "周杰伦"))
        #expect(line.displayTranslation == (toTraditional ? "專輯" : "专辑"))
        #expect(line.text == "周杰倫")
        #expect(line.translation == "專輯")

        let noTranslation = LyricsLine(timestamp: nil, text: "東京の夜", translation: nil)
        #expect(noTranslation.displayTranslation == nil)
        #expect(noTranslation.displayText == "東京の夜")
    }
}
