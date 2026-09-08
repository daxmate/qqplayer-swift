//
//  SyncFrameTests.swift
//  QQPlayerTests
//
//  S2 M2a：帧协议编解码纯逻辑防回归。
//  - 编解码 roundtrip（全类型/空 payload/encrypted 位）
//  - 越界保护：编码拒 >16MB、解码拒 length 前缀 >16MB
//  - 损坏输入：magic 错 / 帧头截断 / payload 截断 / type 非法
//  - 流式拼帧 SyncFrameDecoder：任意分块喂入输出完整帧、残缺滞留、
//    坏流抛错（调用方终结连接）
//  - 帧头字节布局（magic/大端 length/type/flags 偏移）逐字节锁定
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncFrameTests {
    // MARK: - 工具

    /// 手工构造一帧的线上字节（独立于被测 encode，用于解码侧断言）
    private static func rawFrame(
        type: SyncFrameType = .ping,
        flags: UInt8 = 0,
        payload: [UInt8] = []
    ) -> Data {
        var data = Data(SyncFrame.magic)
        data.append(UInt8((payload.count >> 24) & 0xFF))
        data.append(UInt8((payload.count >> 16) & 0xFF))
        data.append(UInt8((payload.count >> 8) & 0xFF))
        data.append(UInt8(payload.count & 0xFF))
        data.append(type.rawValue)
        data.append(flags)
        data.append(contentsOf: payload)
        return data
    }

    // MARK: - roundtrip

    @Test("encode/decode roundtrip：全类型 + encrypted 位 + 空 payload")
    func roundtripAllTypes() throws {
        for type in SyncFrameType.allCases {
            let flags: SyncFrameFlags = type == .ping ? [.encrypted] : []
            let frame = SyncFrame(type: type, flags: flags, payload: Data("payload-\(type.rawValue)".utf8))
            let encoded = try frame.encode()
            let (decoded, consumed) = try SyncFrame.decode(from: encoded)
            #expect(decoded == frame)
            #expect(consumed == encoded.count)
        }
        let empty = SyncFrame(type: .bye, payload: Data())
        let (decodedEmpty, consumedEmpty) = try SyncFrame.decode(from: try empty.encode())
        #expect(decodedEmpty == empty)
        #expect(consumedEmpty == SyncFrame.headerLength)
    }

    @Test("帧头字节布局：magic 4B + length 4B 大端 + type + flags")
    func headerLayout() throws {
        let payload = Data("hello".utf8) // 5 字节
        let frame = SyncFrame(type: .fileChunk, flags: [.encrypted], payload: payload)
        let bytes = try frame.encode()
        #expect(bytes.count == SyncFrame.headerLength + 5)
        #expect(bytes.prefix(4) == Data("QQP1".utf8))
        // length 大端 = 5
        #expect(bytes[4] == 0 && bytes[5] == 0 && bytes[6] == 0 && bytes[7] == 5)
        #expect(bytes[8] == SyncFrameType.fileChunk.rawValue)
        #expect(bytes[9] == SyncFrameFlags.encrypted.rawValue)
        #expect(bytes.suffix(5) == payload)
    }

    @Test("decode 忽略尾部多余字节（供流式解码器复用）")
    func decodeIgnoresTrailing() throws {
        let frame = SyncFrame(type: .ping, payload: Data([1, 2, 3]))
        var data = try frame.encode()
        data.append(contentsOf: [9, 9, 9])
        let (decoded, consumed) = try SyncFrame.decode(from: data)
        #expect(decoded == frame)
        #expect(consumed == SyncFrame.headerLength + 3)
    }

    // MARK: - 越界保护

    @Test("编码拒绝超 16MB payload")
    func encodeRejectsOversize() {
        let big = Data(count: SyncFrame.maxPayloadSize + 1)
        #expect(throws: SyncFrameError.self) {
            _ = try SyncFrame(type: .fileChunk, payload: big).encode()
        }
        // 恰好 16MB 允许
        let atLimit = Data(count: SyncFrame.maxPayloadSize)
        let encoded = try? SyncFrame(type: .fileChunk, payload: atLimit).encode()
        #expect(encoded?.count == SyncFrame.headerLength + SyncFrame.maxPayloadSize)
    }

    @Test("解码拒绝 length 前缀超 16MB")
    func decodeRejectsOversizePrefix() {
        var bytes = Data(SyncFrame.magic)
        bytes.append(contentsOf: [0x01, 0x00, 0x00, 0x00]) // 16MB+1 大端
        bytes.append(SyncFrameType.fileChunk.rawValue)
        bytes.append(0)
        #expect(throws: SyncFrameError.self) {
            _ = try SyncFrame.decode(from: bytes)
        }
    }

    // MARK: - 损坏输入

    @Test("坏 magic 拒绝")
    func badMagicRejected() {
        var bytes = Data("XXXX".utf8)
        bytes.append(contentsOf: [0, 0, 0, 1, SyncFrameType.ping.rawValue, 0])
        #expect(throws: SyncFrameError.self) {
            _ = try SyncFrame.decode(from: bytes)
        }
    }

    @Test("帧头截断（<10B）拒绝")
    func truncatedHeaderRejected() {
        let short = Data(SyncFrame.magic) + Data([0, 0])
        #expect(throws: SyncFrameError.self) {
            _ = try SyncFrame.decode(from: short)
        }
    }

    @Test("payload 截断（声明 5 只给 2）拒绝")
    func truncatedPayloadRejected() throws {
        var bytes = Self.rawFrame(type: .ping, payload: [1, 2, 3, 4, 5])
        bytes.removeLast(3)
        #expect(throws: SyncFrameError.self) {
            _ = try SyncFrame.decode(from: bytes)
        }
    }

    @Test("type 非法字节拒绝")
    func invalidTypeRejected() {
        let bytes = Self.rawFrame(type: .ping)
        var bad = bytes
        bad[8] = 0xEE // 不在枚举内
        #expect(throws: SyncFrameError.self) {
            _ = try SyncFrame.decode(from: bad)
        }
    }

    // MARK: - 流式拼帧

    @Test("任意分块喂入 → 完整帧集合一致")
    func streamDecoderChunked() throws {
        let frames = [
            SyncFrame(type: .handshake, payload: Data("hello-abc".utf8)),
            SyncFrame(type: .pairRequest, payload: Data()),
            SyncFrame(type: .fileChunk, flags: [.encrypted], payload: Data(count: 100)),
        ]
        let stream = try frames.map { try $0.encode() }.reduce(Data(), +)

        var decoder = SyncFrameDecoder()
        var decoded: [SyncFrame] = []
        // 逐字节喂（最苛刻分块）
        for byte in stream {
            decoded += try decoder.feed(Data([byte]))
        }
        #expect(decoded == frames)
        #expect(decoder.bufferedCount == 0)
    }

    @Test("残缺帧滞留缓冲，补全后解出")
    func streamDecoderPartialKept() throws {
        let frame = SyncFrame(type: .fileMeta, payload: Data("meta-payload".utf8))
        let stream = try frame.encode()
        let cut = stream.prefix(SyncFrame.headerLength + 3) // 帧体缺 8 字节
        var decoder = SyncFrameDecoder()
        #expect(try decoder.feed(Data(cut)).isEmpty)
        #expect(decoder.bufferedCount == cut.count)
        // 补剩余
        let rest = stream.dropFirst(cut.count)
        let frames = try decoder.feed(Data(rest))
        #expect(frames == [frame])
        #expect(decoder.bufferedCount == 0)
    }

    @Test("多帧合流一次喂入")
    func streamDecoderMultipleInOne() throws {
        let a = SyncFrame(type: .ping, payload: Data([1]))
        let b = SyncFrame(type: .bye, payload: Data("x".utf8))
        let stream = try a.encode() + b.encode()
        var decoder = SyncFrameDecoder()
        let frames = try decoder.feed(stream)
        #expect(frames == [a, b])
    }

    @Test("流中坏 magic → 抛错（调用方终结连接）")
    func streamDecoderBadMagicThrows() throws {
        let a = SyncFrame(type: .ping, payload: Data([1]))
        var stream = try a.encode()
        stream.replaceSubrange(0 ..< 4, with: Data("NOPE".utf8))
        var decoder = SyncFrameDecoder()
        #expect(throws: SyncFrameError.self) {
            _ = try decoder.feed(stream)
        }
    }
}
