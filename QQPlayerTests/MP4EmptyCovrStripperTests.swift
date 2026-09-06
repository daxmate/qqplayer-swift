//
//  MP4EmptyCovrStripperTests.swift
//  QQPlayerTests
//
//  MP4EmptyCovrStripper 防回归测试（E1 刮削批 2026-09 修复组件）。
//
//  背景：SFBAudioEngine 0.13.0 写 MP4/M4A 标签时，即使无封面也会写入空的 covr item
//  （仅 8 字节头、无 data 子 atom），AVFoundation 解析到该空壳会放弃整个 iTunes
//  metadata 解析（album/year/trackNumber 全读不到）。本组件删除空 covr 并逐级修正
//  moov/udta/meta/ilst 的 size。当时只在 S0 冒烟间接验证，此处用构造的 MP4 atom
//  fixture 锁定：空 covr 删除 + size 修正 / 正常封面不动 / 无 covr 不动 / 非 MP4
//  与不存在文件静默跳过。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - MP4 atom fixture 构造（大端）

private func atom(_ type: String, payload: Data) -> Data {
    var data = Data()
    appendUInt32(UInt32(payload.count + 8), to: &data)
    data.append(contentsOf: type.utf8)
    data.append(payload)
    return data
}

/// 大端 UInt32 写入（Data 无 UInt32 overload）
private func appendUInt32(_ value: UInt32, to data: inout Data) {
    var v = value.bigEndian
    withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
}

/// full atom（meta）：header 8 + version/flags 4 + payload
private func fullAtom(_ type: String, versionFlags: UInt32, payload: Data) -> Data {
    var data = Data()
    appendUInt32(UInt32(payload.count + 12), to: &data)
    data.append(contentsOf: type.utf8)
    appendUInt32(versionFlags, to: &data)
    data.append(payload)
    return data
}

/// 正常带 data 子 atom 的 covr item
private func normalCovrItem() -> Data {
    let dataPayload = Data([0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4]) // version/flags + locale + 数据
    return atom("covr", payload: atom("data", payload: dataPayload))
}

/// 构造一个含空 covr（可选）的 MP4：ftyp + moov(udta(meta(ilst(…))))
private func makeMP4(ilstItems: [Data]) -> Data {
    let ilst = ilstItems.reduce(Data()) { $0 + $1 }
    let meta = fullAtom("meta", versionFlags: 0, payload: atom("ilst", payload: ilst))
    let udta = atom("udta", payload: meta)
    let moov = atom("moov", payload: udta)
    let ftyp = atom("ftyp", payload: Data("isom".utf8))
    return ftyp + moov
}

// 测试内镜像解析 helper（与生产 findAtom 同构，仅用于断言结果结构）
private func findAtom(_ data: Data, _ type: String, in range: Range<Int>) -> (offset: Int, size: Int)? {
    var i = range.lowerBound
    while i + 8 <= range.upperBound {
        let size = Int(readUInt32(data, i))
        guard size >= 8, i + size <= range.upperBound else { break }
        let t = String(data: data.subdata(in: i + 4 ..< i + 8), encoding: .ascii)
        if t == type { return (i, size) }
        i += size
    }
    return nil
}

private func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
    data.subdata(in: offset ..< offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
}

private func ilstCovrCount(_ data: Data) -> Int {
    guard let moov = findAtom(data, "moov", in: 0 ..< data.count) else { return 0 }
    let moovBody = moov.offset + 8 ..< moov.offset + moov.size
    guard let udta = findAtom(data, "udta", in: moovBody) else { return 0 }
    let udtaBody = udta.offset + 8 ..< udta.offset + udta.size
    guard let meta = findAtom(data, "meta", in: udtaBody) else { return 0 }
    let metaBody = meta.offset + 12 ..< meta.offset + meta.size // header 8 + version/flags 4
    guard let ilst = findAtom(data, "ilst", in: metaBody) else { return 0 }
    let ilstBody = ilst.offset + 8 ..< ilst.offset + ilst.size
    var count = 0
    var i = ilstBody.lowerBound
    while i + 8 <= ilstBody.upperBound {
        let size = Int(readUInt32(data, i))
        guard size >= 8, i + size <= ilstBody.upperBound else { break }
        let t = String(data: data.subdata(in: i + 4 ..< i + 8), encoding: .ascii)
        if t == "covr" { count += 1 }
        i += size
    }
    return count
}

struct MP4EmptyCovrStripperTests {
    /// 写临时文件并执行 strip
    private func strip(_ bytes: Data) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp4strip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.m4a")
        try bytes.write(to: url)
        try MP4EmptyCovrStripper.stripEmptyCovrIfPresent(from: url)
        return try Data(contentsOf: url)
    }

    @Test("空 covr（仅 8 字节头）→ 被删除且 moov/udta/meta/ilst size 各减 8")
    func stripsEmptyCovr() throws {
        // 真实场景：SFB 写出的 ilst 中首个（唯一）covr 即空壳。生产解析遍历 ilst
        // 找到第一个 covr 即 break → 空 covr 必须在正常 covr 之前才能被测到删除；
        // 多 covr（正常在前空壳在后）不在生产支持语义内，不测。
        let emptyCovr = atom("covr", payload: Data())
        let original = makeMP4(ilstItems: [emptyCovr, normalCovrItem()])
        #expect(ilstCovrCount(original) == 2)

        let result = try strip(original)

        #expect(ilstCovrCount(result) == 1) // 只剩正常 covr
        #expect(result.count == original.count - 8)

        // moov size 修正：原 moov 大小 - 8
        let moovBefore = findAtom(original, "moov", in: 0 ..< original.count)!
        let moovAfter = findAtom(result, "moov", in: 0 ..< result.count)!
        #expect(moovAfter.size == moovBefore.size - 8)
    }

    @Test("空 covr 是 ilst 唯一 item → 删除后 ilst 内无任何 covr")
    func stripsSoleEmptyCovr() throws {
        let emptyCovr = atom("covr", payload: Data())
        let original = makeMP4(ilstItems: [emptyCovr])
        #expect(ilstCovrCount(original) == 1)

        let result = try strip(original)

        #expect(ilstCovrCount(result) == 0)
        #expect(result.count == original.count - 8)
    }

    @Test("空 covr 前有正常 item（©nam）→ ©nam 保留，只删空 covr")
    func keepsOtherItems() throws {
        let nam = atom("©nam", payload: atom("data", payload: Data([0, 0, 0, 0, 0, 0, 0, 0]) + Data("song".utf8)))
        let emptyCovr = atom("covr", payload: Data())
        let original = makeMP4(ilstItems: [nam, emptyCovr])

        let result = try strip(original)

        #expect(ilstCovrCount(result) == 0)
        // ©nam 仍在
        let bytes = Array(result)
        let namBytes = Array("©nam".utf8)
        // ilst 内找 ©nam type 标记（4 字节）
        let found = (0 ..< bytes.count - namBytes.count).contains { offset in
            Array(bytes[offset ..< offset + namBytes.count]) == namBytes
        }
        #expect(found)
    }

    @Test("正常 covr（带 data 子 atom）→ 文件原样不动")
    func keepsNormalCovr() throws {
        let original = makeMP4(ilstItems: [normalCovrItem()])
        let result = try strip(original)
        #expect(result == original)
    }

    @Test("ilst 无 covr → 文件原样不动")
    func noCovrNoChange() throws {
        let nam = atom("©nam", payload: atom("data", payload: Data([0, 0, 0, 0, 0, 0, 0, 0])))
        let original = makeMP4(ilstItems: [nam])
        let result = try strip(original)
        #expect(result == original)
    }

    @Test("非 MP4（无 moov atom）→ 静默跳过，原样不动")
    func nonMP4SilentlySkipped() throws {
        var junk = Data()
        appendUInt32(16, to: &junk)
        junk.append(contentsOf: "junk".utf8)
        junk.append(contentsOf: Data(repeating: 0, count: 8))
        let result = try strip(junk)
        #expect(result == junk)
    }

    @Test("文件不存在 → 静默返回不抛错")
    func missingFileSilent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp4strip-\(UUID().uuidString)")
            .appendingPathComponent("nope.m4a")
        try MP4EmptyCovrStripper.stripEmptyCovrIfPresent(from: url) // 不应抛
    }
}
