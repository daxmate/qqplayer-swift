//
//  GraphicEQCodecTests.swift
//  QQPlayerTests
//
//  GraphicEQCodec 防回归测试（EQ 预设导入/导出的 GraphicEQ 文本编解码纯逻辑）。
//
//  背景：编解码原内联在 EQManager（@MainActor + DB 依赖，parseGraphicEQString 为
//  private 不可测）；2026-09-07 上收 Services/GraphicEQCodec.swift 纯逻辑并锁定语义：
//  "GraphicEQ: <freq> <gain>; ..." 格式（频率整数、增益浮点）；无 GraphicEQ 行 /
//  无有效对 → EQError.invalidGraphicEQFormat；非法行跳过、合法对保留。
//

import Foundation
import Testing

@testable import QQPlayer

struct GraphicEQCodecTests {
    @Test("decode：标准 GraphicEQ 单行解析频率与增益")
    func decodeStandard() throws {
        let content = "GraphicEQ: 31 0; 62 0.5; 125 -1.5; 250 3"
        let parsed = try GraphicEQCodec.decode(content)
        #expect(parsed.frequencies == [31, 62, 125, 250])
        #expect(parsed.gains == [0, 0.5, -1.5, 3])
    }

    @Test("decode：多行文本取包含 GraphicEQ 的那行")
    func decodeFindsLineInMultiLine() throws {
        let content = "Preamp: -2 dB\nGraphicEQ: 1000 -0.5; 2000 1.2\ncomment"
        let parsed = try GraphicEQCodec.decode(content)
        #expect(parsed.frequencies == [1000, 2000])
        #expect(parsed.gains == [-0.5, 1.2])
    }

    @Test("decode：无 GraphicEQ 行 → 抛 invalidGraphicEQFormat")
    func decodeMissingLineThrows() {
        #expect(throws: EQError.invalidGraphicEQFormat) {
            _ = try GraphicEQCodec.decode("Preamp: -2 dB\nsome other text")
        }
    }

    @Test("decode：数据区为空 → 抛 invalidGraphicEQFormat")
    func decodeEmptyDataThrows() {
        #expect(throws: EQError.invalidGraphicEQFormat) {
            _ = try GraphicEQCodec.decode("GraphicEQ: ")
        }
        #expect(throws: EQError.invalidGraphicEQFormat) {
            _ = try GraphicEQCodec.decode("GraphicEQ: ; ;;")
        }
    }

    @Test("decode：非法行跳过、合法对保留（原实现 continue 语义）")
    func decodeSkipsInvalidPairs() throws {
        let content = "GraphicEQ: 31 0; garbage; 62 0.5; 999; 125 abc"
        let parsed = try GraphicEQCodec.decode(content)
        #expect(parsed.frequencies == [31, 62])
        #expect(parsed.gains == [0, 0.5])
    }

    @Test("decode：首尾多余空白不干扰（trim 后解析）；对内多空格会跳过（原实现语义）")
    func decodeHandlesWhitespace() throws {
        let content = "  GraphicEQ: 31 0; 62 0.5  \n"
        let parsed = try GraphicEQCodec.decode(content)
        #expect(parsed.frequencies == [31, 62])
        #expect(parsed.gains == [0, 0.5])
        // 对内多空格（如 "31   0"）按原实现 components(separatedBy:) 语义跳过该对
        let inner = try GraphicEQCodec.decode("GraphicEQ: 31   0; 62 0.5")
        #expect(inner.frequencies == [62])
    }

    @Test("encode：频率整数化 + 增益原样 + 分号空格分隔")
    func encodeFormat() {
        let text = GraphicEQCodec.encode(frequencies: [31, 62.4, 125], gains: [0, 0.5, -1.5])
        #expect(text == "GraphicEQ: 31 0.0; 62 0.5; 125 -1.5")
    }

    @Test("roundtrip：encode → decode 还原频率/增益（整数频率无损）")
    func roundTrip() throws {
        let frequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        let gains: [Double] = [0, 0.5, -1.5, 3, -2, 1, 0.25, -0.75, 2.5, -1]
        let text = GraphicEQCodec.encode(frequencies: frequencies, gains: gains)
        let parsed = try GraphicEQCodec.decode(text)
        #expect(parsed.frequencies == frequencies)
        #expect(parsed.gains == gains)
    }
}
