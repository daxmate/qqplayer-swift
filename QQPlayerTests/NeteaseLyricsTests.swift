//
//  NeteaseLyricsTests.swift
//  QQPlayerTests
//
//  网易云歌词源（eapi）测试：
//  - eapi 加密基准向量对齐（与桌面版 QQPlayer 后端算法一致，向量经 Node/openssl 交叉验证）
//  - 解密回环
//  - 逐字歌词（JSON-lines）转 LRC
//  - 翻译按时间戳合并进歌词行
//

import Foundation
import Testing

@testable import QQPlayer

struct NeteaseEAPITests {
    // 基准向量 1：歌词接口（桌面版 netease_provider.eapi_encrypt 同算法输出）
    @Test("eapi 加密与桌面端基准向量一致（歌词接口）")
    func encryptMatchesDesktopBaseline() {
        let uri = "/api/song/lyric/v1"
        let json = """
        {"header":{"os":"pc","appver":"3.1.19.204510","requestId":"0","osver":"Microsoft-Windows-11-Home-China-build-22631-64bit","deviceId":"abcdef0123456789","MUSIC_U":""},"e_r":true,"id":123,"cp":false,"tv":0,"lv":0,"rv":0,"kv":0,"yv":0,"ytv":0,"yrv":0}
        """
        let expected = """
        04AE33D34A93FE3EC22DA8FA305D290AB337D0FE5F36D211DE0D338CC6AA89D07B63054957D496D15CCD63631109FBCBE24EFD0BBA8A8479EF76721F4E939F21F440C0DD27A1FEA97D040D3513A427B2720862F8707FAE2B3353DE3BC18DCE2B53353BC7771A20C87E3BF564361E7AB3BF38A004CFE14112DFC87091811D02134738243E22D9490C5AB8ACCA384B5499A7D29894E9AA4F54BD9FC45C44F5F6B66AFCBC81E8668C75C1CF0A2DE801B3FB2C9CAE36658A2B39982CEA5B34E7686038F0F69A492A89B33763D489A6D7AB97C60F95F08D71D81C3EAAD3DF324575CCFF4F07F38633BE58BFE2E45F78037021B794D106F4CAFB9D1FBDA37D002C2F1F3450192D8D5D959024F31EA67F018585B82B44583DE23D00A74A174BCC2B62D15A3EBBDBCA0E3D29BE7F5C267E485F3DAE974CD209ABB28275C4C60211D0BE450D80FC06D55D359475D2C2B137F14103
        """
        #expect(NeteaseEAPI.encrypt(uri: uri, payloadJSON: json) == expected)
    }

    // 基准向量 2：搜索接口（含中文，验证 UTF-8 原样输出）
    @Test("eapi 加密与桌面端基准向量一致（搜索接口含中文）")
    func encryptMatchesDesktopBaselineSearch() {
        let uri = "/api/cloudsearch/pc"
        let json = """
        {"header":{"os":"pc","appver":"3.1.19.204510","requestId":"0","osver":"Microsoft-Windows-11-Home-China-build-22631-64bit","deviceId":"abcdef0123456789","MUSIC_U":""},"e_r":true,"s":"花海 周杰伦","type":1,"limit":8,"offset":0,"total":true}
        """
        let expected = """
        2B5D64177AA6460FBAA3DCB1285E28954BBB4F7556E09B0FB25750F12398BB502D7EE23CE28BE835C0656A5F05F8FE3C359B976D30211A2BB37C9F2030C78827390020D6F0C5DDDFE7ED442D8A15AF0D74E4ADDCB23ED8EA43FD21DACD06D9B080534E7EFC69ED93D9A78EF2E5DE8C175650CB7760384BD27B7B78083291F8C8F9B6EF066085D4DF3EF6CC40D173429C175E286B9BDEEC05D27B76521721E1129240FD25EE06541411EA06C52898E64D938ACC514E70B18BA1020AC2A5C925B60295E0BE91C8BF29F5961860239BCA3BD6BFA5C7174136ECDDEE82CFB086B2B87BE0409B588BE8D6D0A0947DFCB861D9068AFF83F08E57BC59559E1BB2EC1E72227F0BF6A62BF9661C11233240DFAF7430AF1FCF2A9705886F4D126B33FFF69492C87679AD23EE2613A98E060A2ECABAFD3822071B69C56C93023761530EFA726AA3B102FBE7296AB0DB9EA5C46AD12B
        """
        #expect(NeteaseEAPI.encrypt(uri: uri, payloadJSON: json) == expected)
    }

    @Test("eapi 解密回环：加密报文可解密还原 JSON")
    func decryptRoundTrip() throws {
        let uri = "/api/song/lyric/v1"
        let json = """
        {"header":{"os":"pc","appver":"3.1.19.204510","requestId":"0","osver":"Microsoft-Windows-11-Home-China-build-22631-64bit","deviceId":"abcdef0123456789","MUSIC_U":""},"e_r":true,"id":123,"cp":false,"tv":0,"lv":0,"rv":0,"kv":0,"yv":0,"ytv":0,"yrv":0}
        """
        let enc = NeteaseEAPI.encrypt(uri: uri, payloadJSON: json)
        let decrypted = try NeteaseEAPI.decrypt(Data(hexString: enc.lowercased())!)
        #expect(decrypted["id"] as? Int == 123)
        #expect((decrypted["header"] as? [String: Any])?["os"] as? String == "pc")
    }

    @Test("eapi 解密兼容纯 JSON 响应（content-type 含 json）")
    func decryptPlainJSON() throws {
        let plain = #"{"code":200,"lrc":{"lyric":"[00:01.00]test"}}"#
        let data = Data(plain.utf8)
        let obj = try NeteaseEAPI.decrypt(data, contentType: "application/json")
        #expect((obj["lrc"] as? [String: Any])?["lyric"] as? String == "[00:01.00]test")
    }
}

struct WordJSONToLRCTests {
    @Test("逐字歌词 JSON-lines 转普通 LRC")
    func convertsWordJSON() {
        let input = """
        {"t":12345,"c":[{"tx":"海"},{"tx":"棠"}]}
        {"t":13000,"c":[{"tx":"花"}]}
        """
        let expected = """
        [00:12.34]海棠
        [00:13.00]花
        """
        #expect(wordJSONToLRC(input) == expected)
    }

    @Test("普通 LRC 行原样保留（混排兼容）")
    func keepsPlainLRCLines() {
        let input = "[00:12.34]海棠\n[00:13.00]花"
        #expect(wordJSONToLRC(input) == input)
    }

    @Test("空输入返回原样")
    func emptyInput() {
        #expect(wordJSONToLRC("").isEmpty)
    }
}

struct NeteaseLyricsMergeTests {
    @Test("翻译按时间戳合并进对应歌词行（容差 0.6s）")
    func mergeTranslationByTimestamp() async {
        let lrc = """
        [00:01.00]海
        [00:05.00]棠
        [00:10.00]花
        """
        let tlyric = """
        [00:01.30]中文海
        [00:05.00]中文棠
        """
        let manager = LyricsManager.shared
        let lyrics = await manager.makeLyrics(fromLRC: lrc, tlyric: tlyric)

        #expect(lyrics.source == .netease)
        #expect(lyrics.syncedLyrics.count == 3)
        // 0.3s 差距在 0.6s 容差内 → 合并
        #expect(lyrics.syncedLyrics[0].translation == "中文海")
        // 精确匹配 → 合并
        #expect(lyrics.syncedLyrics[1].translation == "中文棠")
        // 无翻译行 → nil
        #expect(lyrics.syncedLyrics[2].translation == nil)
    }

    @Test("无翻译时返回原文歌词（source 仍为 netease）")
    func noTranslation() async {
        let lrc = "[00:01.00]海"
        let manager = LyricsManager.shared
        let lyrics = await manager.makeLyrics(fromLRC: lrc, tlyric: nil)
        #expect(lyrics.syncedLyrics.count == 1)
        #expect(lyrics.syncedLyrics[0].translation == nil)
        #expect(lyrics.source == .netease)
    }

    @Test("罗马音按时间戳合并进对应歌词行（与翻译同一套容差）")
    func mergeRomanByTimestamp() async {
        let lrc = """
        [00:01.00]残酷な天使のように
        [00:05.00]少年よ 神話になれ
        """
        let romalrc = """
        [00:01.30]za n ko ku na te n shi no yo u ni
        [00:05.00]sho u ne n yo shi n wa ni na re
        """
        let manager = LyricsManager.shared
        let lyrics = await manager.makeLyrics(fromLRC: lrc, tlyric: nil, romalrc: romalrc)

        #expect(lyrics.syncedLyrics.count == 2)
        // 0.3s 差距在 0.6s 容差内 → 合并
        #expect(lyrics.syncedLyrics[0].roman == "za n ko ku na te n shi no yo u ni")
        #expect(lyrics.syncedLyrics[1].roman == "sho u ne n yo shi n wa ni na re")
        // 没有翻译轨时不影响译文占位
        #expect(lyrics.syncedLyrics[0].translation == nil)
    }

    @Test("罗马音与翻译同时合并：两条附轨各写各的字段，互不覆盖")
    func mergeBothAttachedTracks() async {
        let lrc = "[00:02.46]残酷な天使のように"
        let tlyric = "[00:02.46]就像那残酷的天使一样"
        let romalrc = "[00:02.46]za n ko ku na te n shi no yo u ni"
        let manager = LyricsManager.shared
        let lyrics = await manager.makeLyrics(fromLRC: lrc, tlyric: tlyric, romalrc: romalrc)

        #expect(lyrics.syncedLyrics[0].translation == "就像那残酷的天使一样")
        #expect(lyrics.syncedLyrics[0].roman == "za n ko ku na te n shi no yo u ni")
    }

    @Test("无罗马音时不占位：roman 保持 nil，译文照常")
    func noRomanStaysNil() async {
        let manager = LyricsManager.shared
        let lyrics = await manager.makeLyrics(fromLRC: "[00:01.00]海", tlyric: "[00:01.00]sea", romalrc: nil)
        #expect(lyrics.syncedLyrics[0].roman == nil)
        #expect(lyrics.syncedLyrics[0].translation == "sea")
    }

    @Test("纯文本歌词（无时间戳）保持 plainLyrics")
    func plainLyrics() async {
        let text = "海\n棠\n花"
        let manager = LyricsManager.shared
        let lyrics = await manager.makeLyrics(fromLRC: text, tlyric: nil)
        #expect(lyrics.plainLyrics == text)
        #expect(lyrics.syncedLyrics.isEmpty)
    }
}

struct MultiTimestampLRCTests {
    @Test("同一行多时间戳：每个时间戳各生成一行，文本相同且不含残留时间戳")
    func multiTimestampLine() async {
        let manager = LyricsManager.shared
        let lines = await manager.parseSyncedLyrics("[00:12.00][00:15.00]副歌")
        #expect(lines.count == 2)
        #expect(lines[0].timestamp == 12.0)
        #expect(lines[1].timestamp == 15.0)
        #expect(lines[0].text == "副歌")
        #expect(lines[1].text == "副歌")
    }

    @Test("三时间戳行：三行同文本，按时间戳排序")
    func tripleTimestampLine() async {
        let manager = LyricsManager.shared
        let lines = await manager.parseSyncedLyrics("[00:03.00][00:01.00][00:02.00]合唱")
        #expect(lines.count == 3)
        #expect(lines.map(\.timestamp) == [1.0, 2.0, 3.0])
        #expect(lines.allSatisfy { $0.text == "合唱" })
    }

    @Test("单时间戳行为不变：文本剥离时间戳标记，元数据行跳过")
    func singleTimestampUnchanged() async {
        let manager = LyricsManager.shared
        let lines = await manager.parseSyncedLyrics("[00:01.50]你好\n[ar:周杰伦]\n[00:02.34]世界")
        #expect(lines.count == 2)
        #expect(lines[0].timestamp == 1.5)
        #expect(lines[0].text == "你好")
        #expect(lines[1].timestamp == 2.34)
        #expect(lines[1].text == "世界")
    }

    @Test("翻译行（tlyric）多时间戳：按时间戳拆行后仍能合并进对应歌词行")
    func multiTimestampTranslationStillMerges() async {
        let lrc = "[00:12.00]副歌\n[00:15.00]副歌"
        let tlyric = "[00:12.00][00:15.00]合唱"
        let manager = LyricsManager.shared
        let lyrics = await manager.makeLyrics(fromLRC: lrc, tlyric: tlyric)
        #expect(lyrics.syncedLyrics.count == 2)
        #expect(lyrics.syncedLyrics[0].translation == "合唱")
        #expect(lyrics.syncedLyrics[1].translation == "合唱")
    }
}

struct NeteaseSongMappingTests {
    @Test("搜索候选选择：标题精确匹配 + 歌手包含优先")
    func bestCandidateSelection() {
        let candidates = [
            NeteaseSong(id: 1, title: "花海", artist: "周杰伦", duration: 240),
            NeteaseSong(id: 2, title: "花海", artist: "其他歌手", duration: 250),
            NeteaseSong(id: 3, title: "无关歌曲", artist: "周杰伦", duration: 200),
        ]
        // 调用生产选择函数（此前内联重写逻辑 = 测试自己，生产改了测试依然绿）
        let best = NeteaseLyricsProvider.selectBestCandidate(candidates, title: "花海", artistName: "周杰伦")
        #expect(best?.id == 1)
    }

    @Test("无精确匹配时取第一个候选")
    func fallbackFirstCandidate() {
        let candidates = [
            NeteaseSong(id: 7, title: "A", artist: "B", duration: 100),
        ]
        let best = NeteaseLyricsProvider.selectBestCandidate(candidates, title: "不存在", artistName: "X")
        #expect(best?.id == 7)
    }

    @Test("空候选返回 nil")
    func emptyCandidates() {
        let best = NeteaseLyricsProvider.selectBestCandidate([], title: "花海", artistName: "周杰伦")
        #expect(best == nil)
    }
}

struct OrderedJSONEscapeTests {
    @Test("有序 JSON 转义：0x20 以下控制字符按 Python json.dumps 输出 \\uXXXX")
    func escapesControlCharsAsUnicode() {
        let json = OrderedJSON {
            OrderedJSONEntry("k", "a\u{01}b\u{1F}c")
        }
        #expect(json.stringValue() == "{\"k\":\"a\\u0001b\\u001Fc\"}")
    }

    @Test("有序 JSON 转义：短转义/引号/反斜杠保持，中文原样输出")
    func shortEscapesAndNonASCII() {
        let json = OrderedJSON {
            OrderedJSONEntry("a", "x\n\"y\\z\t")
            OrderedJSONEntry("b", "花海")
        }
        #expect(json.stringValue() == "{\"a\":\"x\\n\\\"y\\\\z\\t\",\"b\":\"花海\"}")
    }

    @Test("有序 JSON 转义：0x20 以上的 ASCII 与 DEL(0x7F) 原样输出")
    func printableAndDelStayRaw() {
        let json = OrderedJSON {
            OrderedJSONEntry("k", "a~\u{7F}")
        }
        // 0x7F 不是控制字符（json.dumps 不转义），原样输出
        #expect(json.stringValue() == "{\"k\":\"a~\u{7F}\"}")
    }
}

// MARK: - 工具扩展（测试用）

private extension Data {
    init?(hexString: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard next <= hexString.endIndex,
                  let byte = UInt8(hexString[index ..< next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
