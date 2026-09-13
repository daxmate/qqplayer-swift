//
//  ArtistNameNormalizerTests.swift
//  QQPlayerTests
//
//  歌手名简繁归一纯逻辑测试：
//  - 方向判断（zh-Hant/zh-HK/zh-TW/zh-MO → toTraditional；其余含 zh-Hans/en/fr/ru/空 → toSimplified）
//  - normalizedKey / displayName 的字形转换（繁体归并、日文假名不受影响、
//    日文汉字转简体、ASCII 不变、台→台 特例）
//  - displayName(for:) 组内显示名选择逻辑
//  - searchVariants 双向字形变体
//  - groupedArtists 同名简繁两行归并
//  注：getTracksByArtistIds 依赖 DatabaseManager 单例（private init + 私有
//  dbWriter），无内存 DB 测试缝，未直接单测（由 xcodebuild 编译 + 详情页
//  聚合路径覆盖）。
//

import Foundation
import Testing

@testable import QQPlayer

struct ArtistNameNormalizerTests {
    // MARK: - 方向判断（纯函数）

    @Test("zh-Hans → toSimplified")
    func directionSimplified() {
        #expect(ArtistNameNormalizer.direction(for: ["zh-Hans"]) == .toSimplified)
        #expect(ArtistNameNormalizer.direction(for: ["zh-Hans-CN"]) == .toSimplified)
        #expect(ArtistNameNormalizer.direction(for: ["zh-Hans", "en"]) == .toSimplified)
    }

    @Test("zh-Hant/zh-HK/zh-TW → toTraditional")
    func directionTraditional() {
        #expect(ArtistNameNormalizer.direction(for: ["zh-Hant"]) == .toTraditional)
        #expect(ArtistNameNormalizer.direction(for: ["zh-Hant-TW"]) == .toTraditional)
        #expect(ArtistNameNormalizer.direction(for: ["zh-HK"]) == .toTraditional)
        #expect(ArtistNameNormalizer.direction(for: ["zh-TW"]) == .toTraditional)
    }

    @Test("其他语言/空列表 → toSimplified（2026-09-13 语义变更：英文界面也显示简体）")
    func directionOtherLanguages() {
        #expect(ArtistNameNormalizer.direction(for: ["en"]) == .toSimplified)
        #expect(ArtistNameNormalizer.direction(for: ["ru"]) == .toSimplified)
        #expect(ArtistNameNormalizer.direction(for: ["fr", "zh-Hans"]) == .toSimplified) // 只看首位
        #expect(ArtistNameNormalizer.direction(for: []) == .toSimplified)
    }

    @Test("方向委托 DisplayScriptNormalizer（两处判定永远一致）")
    func directionDelegatesToDisplayScriptNormalizer() {
        for locales in [["zh-Hant"], ["zh-HK"], ["zh-Hans"], ["en"], ["ru"], ["fr"], []] {
            let artistDirection = ArtistNameNormalizer.direction(for: locales)
            switch DisplayScriptNormalizer.direction(for: locales) {
            case .toSimplified: #expect(artistDirection == .toSimplified, "\(locales)")
            case .toTraditional: #expect(artistDirection == .toTraditional, "\(locales)")
            case .identity: #expect(artistDirection == .identity, "\(locales)")
            }
        }
    }

    // MARK: - normalizedKey

    @Test("toSimplified：繁体名归并为简体")
    func keyToSimplified() {
        #expect(ArtistNameNormalizer.normalizedKey("周杰倫", direction: .toSimplified) == "周杰伦")
        #expect(ArtistNameNormalizer.normalizedKey("周杰伦", direction: .toSimplified) == "周杰伦") // 已是简体不变
        #expect(ArtistNameNormalizer.normalizedKey("鄧紫棋", direction: .toSimplified) == "邓紫棋")
    }

    @Test("toTraditional：简体名归并为繁体")
    func keyToTraditional() {
        #expect(ArtistNameNormalizer.normalizedKey("周杰伦", direction: .toTraditional) == "周傑倫")
        // 混合字形（含简体字）也归一为全繁体
        #expect(ArtistNameNormalizer.normalizedKey("周杰倫", direction: .toTraditional) == "周傑倫")
    }

    @Test("日文假名不受影响（映射表无假名字符）")
    func kanaUnchanged() {
        #expect(ArtistNameNormalizer.normalizedKey("宇多田ヒカル", direction: .toSimplified) == "宇多田ヒカル")
        #expect(ArtistNameNormalizer.normalizedKey("宇多田ヒカル", direction: .toTraditional) == "宇多田ヒカル")
    }

    @Test("日文汉字：简体 UI 显示简体字形")
    func japaneseKanji() {
        #expect(ArtistNameNormalizer.normalizedKey("中島美嘉", direction: .toSimplified) == "中岛美嘉")
        #expect(ArtistNameNormalizer.normalizedKey("中島美嘉", direction: .toTraditional) == "中島美嘉")
    }

    @Test("ASCII/英文名不受影响")
    func asciiUnchanged() {
        #expect(ArtistNameNormalizer.normalizedKey("Adele", direction: .toSimplified) == "Adele")
        #expect(ArtistNameNormalizer.normalizedKey("Adele", direction: .toTraditional) == "Adele")
    }

    @Test("identity 方向原样返回")
    func identityUnchanged() {
        #expect(ArtistNameNormalizer.normalizedKey("周杰倫", direction: .identity) == "周杰倫")
        #expect(ArtistNameNormalizer.normalizedKey("周杰伦", direction: .identity) == "周杰伦")
    }

    @Test("台→台 特例反转后仍稳定")
    func taiwanSpecialCase() {
        #expect(ArtistNameNormalizer.normalizedKey("電台", direction: .toSimplified) == "电台")
        #expect(ArtistNameNormalizer.normalizedKey("电台", direction: .toTraditional) == "電台")
    }

    // MARK: - displayName

    @Test("displayName：原名已是目标字形则保留原名，否则返回转换结果")
    func displayNameSingle() {
        #expect(ArtistNameNormalizer.displayName("周杰倫", direction: .toSimplified) == "周杰伦")
        #expect(ArtistNameNormalizer.displayName("周杰伦", direction: .toSimplified) == "周杰伦")
        #expect(ArtistNameNormalizer.displayName("周杰伦", direction: .toTraditional) == "周傑倫")
        // 混合字形（含简体字）→ 转换为全繁体
        #expect(ArtistNameNormalizer.displayName("周杰倫", direction: .toTraditional) == "周傑倫")
        #expect(ArtistNameNormalizer.displayName("Adele", direction: .toSimplified) == "Adele")
    }

    @Test("displayName(for:)：优先组内本来就是目标字形的名字")
    func displayNameForGroup() {
        // 简体 UI：组内有简体名 → 用它
        #expect(ArtistNameNormalizer.displayName(for: ["周杰倫", "周杰伦"], direction: .toSimplified) == "周杰伦")
        // 简体 UI：组内全是繁体 → 取第一个的转换结果
        #expect(ArtistNameNormalizer.displayName(for: ["周杰倫"], direction: .toSimplified) == "周杰伦")
        // 繁体 UI 对称
        #expect(ArtistNameNormalizer.displayName(for: ["周杰伦", "周傑倫"], direction: .toTraditional) == "周傑倫")
        #expect(ArtistNameNormalizer.displayName(for: ["周杰伦"], direction: .toTraditional) == "周傑倫")
        // identity：取第一个原名
        #expect(ArtistNameNormalizer.displayName(for: ["周杰倫", "周杰伦"], direction: .identity) == "周杰倫")
        // 空组
        #expect(ArtistNameNormalizer.displayName(for: [], direction: .toSimplified).isEmpty)
    }

    // MARK: - searchVariants

    @Test("searchVariants：简体方向同时生成繁体变体")
    func searchVariantsSimplified() {
        let variants = ArtistNameNormalizer.searchVariants(of: "周杰伦", direction: .toSimplified)
        #expect(variants.contains("周杰伦"))
        #expect(variants.contains("周傑倫"))
    }

    @Test("searchVariants：繁体方向同时生成简体变体")
    func searchVariantsTraditional() {
        let variants = ArtistNameNormalizer.searchVariants(of: "周杰倫", direction: .toTraditional)
        #expect(variants.contains("周杰倫"))
        #expect(variants.contains("周杰伦"))
    }

    @Test("searchVariants：identity 只返回原名")
    func searchVariantsIdentity() {
        #expect(ArtistNameNormalizer.searchVariants(of: "周杰伦", direction: .identity) == ["周杰伦"])
    }

    // MARK: - groupedArtists

    @Test("groupedArtists：同名简繁两行归为一组（保持输入顺序）")
    func groupedArtistsMerge() {
        let simplified = Artist(id: 1, name: "周杰伦")
        let traditional = Artist(id: 2, name: "周傑倫")
        let adele = Artist(id: 3, name: "Adele")

        let groups = ArtistNameNormalizer.groupedArtists([traditional, simplified, adele], direction: .toSimplified)
        #expect(groups.count == 2)

        let jayGroup = groups.first { $0.displayName == "周杰伦" }
        #expect(jayGroup != nil)
        #expect(jayGroup?.primaryArtist.name == "周傑倫") // 组内首位
        #expect(jayGroup?.artistIds == [2, 1])           // 组内全部 id
        #expect(jayGroup?.artists.count == 2)

        let adeleGroup = groups.first { $0.displayName == "Adele" }
        #expect(adeleGroup?.artistIds == [3])
    }

    @Test("groupedArtists：identity 方向不合并")
    func groupedArtistsIdentity() {
        let simplified = Artist(id: 1, name: "周杰伦")
        let traditional = Artist(id: 2, name: "周傑倫")
        let groups = ArtistNameNormalizer.groupedArtists([simplified, traditional], direction: .identity)
        #expect(groups.count == 2)
    }

    @Test("groupedArtists：日文名独立成组（假名不参与简繁映射）")
    func groupedArtistsKanaSeparate() {
        let a = Artist(id: 1, name: "宇多田ヒカル")
        let groups = ArtistNameNormalizer.groupedArtists([a], direction: .toSimplified)
        #expect(groups.count == 1)
        #expect(groups[0].displayName == "宇多田ヒカル")
    }

    // MARK: - 保护表：姓氏保护（toTraditional）

    @Test("姓氏保护：单字表会误转的姓氏，首字不转/转正确字形")
    func surnameProtected() {
        #expect(ArtistNameNormalizer.normalizedKey("于文文", direction: .toTraditional) == "于文文")
        #expect(ArtistNameNormalizer.normalizedKey("范玮琪", direction: .toTraditional) == "范瑋琪")
        #expect(ArtistNameNormalizer.normalizedKey("余华", direction: .toTraditional) == "余華")
        #expect(ArtistNameNormalizer.normalizedKey("郁可唯", direction: .toTraditional) == "郁可唯")
        #expect(ArtistNameNormalizer.normalizedKey("云朵", direction: .toTraditional) == "云朵")
        #expect(ArtistNameNormalizer.normalizedKey("冲田总司", direction: .toTraditional) == "沖田總司") // 冲→沖
        #expect(ArtistNameNormalizer.normalizedKey("朴树", direction: .toTraditional) == "朴樹")
        #expect(ArtistNameNormalizer.normalizedKey("干露露", direction: .toTraditional) == "干露露")
        #expect(ArtistNameNormalizer.normalizedKey("涂磊", direction: .toTraditional) == "涂磊")
        // 显式保护但单字表本就无对应项的姓氏，同样保留原字
        #expect(ArtistNameNormalizer.normalizedKey("沈腾", direction: .toTraditional) == "沈騰")
        #expect(ArtistNameNormalizer.normalizedKey("谷爱凌", direction: .toTraditional) == "谷愛凌")
        #expect(ArtistNameNormalizer.normalizedKey("姜文", direction: .toTraditional) == "姜文")
        #expect(ArtistNameNormalizer.normalizedKey("曲婉婷", direction: .toTraditional) == "曲婉婷")
        #expect(ArtistNameNormalizer.normalizedKey("曾志伟", direction: .toTraditional) == "曾志偉")
        #expect(ArtistNameNormalizer.normalizedKey("查良镛", direction: .toTraditional) == "查良鏞")
        #expect(ArtistNameNormalizer.normalizedKey("仇晓飞", direction: .toTraditional) == "仇曉飛")
        #expect(ArtistNameNormalizer.normalizedKey("解晓东", direction: .toTraditional) == "解曉東")
    }

    @Test("姓氏保护：非首字的 云/于 等仍按语境转（首字规则不误伤）")
    func surnameProtectionFirstCharOnly() {
        #expect(ArtistNameNormalizer.normalizedKey("王云", direction: .toTraditional) == "王雲")
        #expect(ArtistNameNormalizer.normalizedKey("张于", direction: .toTraditional) == "張於")
    }

    @Test("姓氏保护：本应转繁的姓氏不受影响（单/叶/万/宁/种/钟）")
    func surnameShouldConvert() {
        #expect(ArtistNameNormalizer.normalizedKey("单田芳", direction: .toTraditional) == "單田芳")
        #expect(ArtistNameNormalizer.normalizedKey("叶倩文", direction: .toTraditional) == "葉倩文")
        #expect(ArtistNameNormalizer.normalizedKey("万芳", direction: .toTraditional) == "萬芳")
        #expect(ArtistNameNormalizer.normalizedKey("宁浩", direction: .toTraditional) == "寧浩")
        #expect(ArtistNameNormalizer.normalizedKey("种丹妮", direction: .toTraditional) == "種丹妮")
        #expect(ArtistNameNormalizer.normalizedKey("钟南山", direction: .toTraditional) == "鍾南山")
    }

    // MARK: - 保护表：精确词保护（toTraditional）

    @Test("语境保护：里（长度单位）不转裏")
    func contextWordLi() {
        #expect(ArtistNameNormalizer.normalizedKey("千里之外", direction: .toTraditional) == "千里之外")
        #expect(ArtistNameNormalizer.normalizedKey("万里", direction: .toTraditional) == "萬里")
        #expect(ArtistNameNormalizer.normalizedKey("公里", direction: .toTraditional) == "公里")
        #expect(ArtistNameNormalizer.normalizedKey("英里", direction: .toTraditional) == "英里")
        // 那里/这里 的"里"是方位义，仍按裏转
        #expect(ArtistNameNormalizer.normalizedKey("那里", direction: .toTraditional) == "那裏")
        #expect(ArtistNameNormalizer.normalizedKey("这里", direction: .toTraditional) == "這裏")
    }

    @Test("语境保护：发（头发义）转髮")
    func contextWordFa() {
        #expect(ArtistNameNormalizer.normalizedKey("头发", direction: .toTraditional) == "頭髮")
        #expect(ArtistNameNormalizer.normalizedKey("理发", direction: .toTraditional) == "理髮")
        #expect(ArtistNameNormalizer.normalizedKey("发质", direction: .toTraditional) == "髮質")
        #expect(ArtistNameNormalizer.normalizedKey("假发", direction: .toTraditional) == "假髮")
    }

    @Test("语境保护：后（王后/天后义）不转後")
    func contextWordHou() {
        #expect(ArtistNameNormalizer.normalizedKey("皇后", direction: .toTraditional) == "皇后")
        #expect(ArtistNameNormalizer.normalizedKey("天后", direction: .toTraditional) == "天后")
        #expect(ArtistNameNormalizer.normalizedKey("后羿", direction: .toTraditional) == "后羿")
        #expect(ArtistNameNormalizer.normalizedKey("王后", direction: .toTraditional) == "王后")
        // 后 亦为姓氏（后弦），首字保留
        #expect(ArtistNameNormalizer.normalizedKey("后弦", direction: .toTraditional) == "后弦")
    }

    @Test("语境保护：干（相干/若干）不误转幹")
    func contextWordGan() {
        #expect(ArtistNameNormalizer.normalizedKey("相干", direction: .toTraditional) == "相干")
        #expect(ArtistNameNormalizer.normalizedKey("若干", direction: .toTraditional) == "若干")
        // 首字"干"按姓氏保护保留原字（干杯/干净 等不属歌手名语境）
        #expect(ArtistNameNormalizer.normalizedKey("干杯", direction: .toTraditional) == "干杯")
    }

    @Test("语境保护：复（複义）不误转復")
    func contextWordFu() {
        #expect(ArtistNameNormalizer.normalizedKey("重复", direction: .toTraditional) == "重複")
        #expect(ArtistNameNormalizer.normalizedKey("复习", direction: .toTraditional) == "複習")
        #expect(ArtistNameNormalizer.normalizedKey("复杂", direction: .toTraditional) == "複雜")
        #expect(ArtistNameNormalizer.normalizedKey("反复", direction: .toTraditional) == "反覆")
    }

    // MARK: - 保护表：不破坏既有行为

    @Test("保护不破坏日文假名免疫")
    func protectionKanaImmune() {
        #expect(ArtistNameNormalizer.normalizedKey("宇多田ヒカル", direction: .toTraditional) == "宇多田ヒカル")
        #expect(ArtistNameNormalizer.normalizedKey("沖田総司", direction: .toTraditional) == "沖田総司")
    }

    @Test("保护后的 displayName 保留原名（转换后不变）")
    func protectedDisplayName() {
        #expect(ArtistNameNormalizer.displayName("千里之外", direction: .toTraditional) == "千里之外")
        #expect(ArtistNameNormalizer.displayName("于文文", direction: .toTraditional) == "于文文")
        #expect(ArtistNameNormalizer.displayName("皇后", direction: .toTraditional) == "皇后")
        #expect(ArtistNameNormalizer.displayName("头发", direction: .toTraditional) == "頭髮")
    }

    @Test("保护后的 searchVariants 不含错误繁体变体")
    func protectedSearchVariants() {
        let variants = ArtistNameNormalizer.searchVariants(of: "千里之外", direction: .toTraditional)
        #expect(variants.contains("千里之外"))
        #expect(!variants.contains("千裏之外"))
    }

    @Test("toSimplified 反向无需保护：多繁体归并回正确简体")
    func protectedToSimplified() {
        #expect(ArtistNameNormalizer.normalizedKey("於文文", direction: .toSimplified) == "于文文")
        #expect(ArtistNameNormalizer.normalizedKey("發生", direction: .toSimplified) == "发生")
        #expect(ArtistNameNormalizer.normalizedKey("千裏之外", direction: .toSimplified) == "千里之外")
        #expect(ArtistNameNormalizer.normalizedKey("皇後", direction: .toSimplified) == "皇后")
    }
}
