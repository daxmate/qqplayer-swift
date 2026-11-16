//
//  LyricAlignmentTextNormalizerTests.swift
//  QQPlayerTests
//
//  歌词对齐归一化：空白/标点/全角/大小写/emoji/繁简。
//

import Foundation
import Testing

@testable import QQPlayer

struct LyricAlignmentTextNormalizerTests {
    @Test("空白、标点、全角标点、大小写全部折叠")
    func foldsNoise() {
        let characters = LyricAlignmentTextNormalizer.normalizedCharacters(
            of: "  Hello,  World！！  你好，世界。 ",
            simplifyChinese: false
        )
        #expect(String(characters) == "helloworld你好世界")
    }

    @Test("emoji 与纯符号不参与匹配")
    func dropsEmoji() {
        let characters = LyricAlignmentTextNormalizer.normalizedCharacters(
            of: "爱❤️你🎵（笑）",
            simplifyChinese: false
        )
        #expect(String(characters) == "爱你笑")
    }

    @Test("NFKC：全角字母数字等价半角")
    func compatibilityMapping() {
        let characters = LyricAlignmentTextNormalizer.normalizedCharacters(
            of: "ＡＢＣ１２３",
            simplifyChinese: false
        )
        #expect(String(characters) == "abc123")
    }

    @Test("中文繁→简走项目唯一映射表；关闭时保留原字形")
    func traditionalToSimplified() {
        let simplified = LyricAlignmentTextNormalizer.normalizedCharacters(
            of: "愛與夢想",
            simplifyChinese: true
        )
        #expect(String(simplified) == "爱与梦想")

        let original = LyricAlignmentTextNormalizer.normalizedCharacters(
            of: "愛與夢想",
            simplifyChinese: false
        )
        #expect(String(original) == "愛與夢想")
    }

    @Test("纯标点/空白行归一化后为空")
    func punctuationOnly() {
        let characters = LyricAlignmentTextNormalizer.normalizedCharacters(
            of: "  …… —— ！？ ",
            simplifyChinese: false
        )
        #expect(characters.isEmpty)
    }

    @Test("假名/汉字原样保留（日文歌词不被当标点删掉）")
    func keepsKana() {
        let characters = LyricAlignmentTextNormalizer.normalizedCharacters(
            of: "君の名は、永遠に",
            simplifyChinese: false
        )
        #expect(String(characters) == "君の名は永遠に")
    }
}
