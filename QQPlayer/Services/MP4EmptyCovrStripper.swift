//
//  MP4EmptyCovrStripper.swift
//  QQPlayer
//
//  清理 SFB 写 MP4 产生的损坏空 covr atom（E1 刮削批 2026-09 发现）。
//
//  背景：SFBAudioEngine 0.13.0 写 MP4/M4A 标签时（SFBAudioMetadata+TagLibMP4Tag.mm
//  setMP4TagFromMetadata，setAlbumArt 默认 true），即使没有任何封面数据也会
//  `tag->setItem("covr", 空 CoverArtList)`；TagLib renderCovr 对空列表渲染出
//  一个只有 8 字节头、没有 data 子原子的 covr item——这是损坏的 MP4 metadata
//  atom。AVFoundation 解析到该空壳会放弃整个 iTunes metadata 解析（allMetadata
//  返回空），导致 album/year/trackNumber 全部读不到（S0 冒烟带封面写入所以
//  covr 有 data 正常，未暴露；无封面写入场景 CI 首红定位）。
//
//  本工具：写标签完成后调用，若 moov.udta.meta.ilst 中存在 size==8（无 data
//  子原子）的 covr item，则删除该 item 并逐级修正 ilst/meta/udta/moov 的
//  size 字段。正常封面（covr 带 data）不受影响。

import Foundation

enum MP4EmptyCovrStripper {
    /// 删除 moov.udta.meta.ilst 中的空 covr item（若存在）。非 MP4 或结构不符时静默跳过。
    static func stripEmptyCovrIfPresent(from url: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count > 16 else { return }

        // 顶层找 moov
        guard let moov = findAtom(in: data, type: "moov", range: 0 ..< data.count) else { return }
        let moovBody = (moov.offset + headerSize(data, at: moov.offset)) ..< moov.offset + moov.size

        // moov → udta
        guard let udta = findAtom(in: data, type: "udta", range: moovBody) else { return }
        let udtaBody = (udta.offset + headerSize(data, at: udta.offset)) ..< udta.offset + udta.size

        // udta → meta（meta 是 full atom：header 后还有 4 字节 version/flags）
        guard let meta = findAtom(in: data, type: "meta", range: udtaBody) else { return }
        let metaBody = (meta.offset + headerSize(data, at: meta.offset) + 4) ..< meta.offset + meta.size

        // meta → ilst
        guard let ilst = findAtom(in: data, type: "ilst", range: metaBody) else { return }
        let ilstBody = (ilst.offset + headerSize(data, at: ilst.offset)) ..< ilst.offset + ilst.size

        // ilst 中找空 covr（size 仅 8 字节头，无任何子 atom）
        var i = ilstBody.lowerBound
        var emptyCovrOffset: Int?
        while i + 8 <= ilstBody.upperBound {
            let size = Int(readUInt32(data, at: i))
            guard size >= 8, i + size <= ilstBody.upperBound else { break }
            let type = String(data: data.subdata(in: i + 4 ..< i + 8), encoding: .ascii)
            if type == "covr" {
                // covr item 内应有 data 子 atom；空壳 = size 恰好 8（或子区域不足一个 data 头）
                if size == 8 || i + size - (i + 8) < 8 {
                    emptyCovrOffset = i
                }
                break
            }
            i += size
        }
        guard let covrOffset = emptyCovrOffset else { return }

        // 删除 covr item（8 字节），并修正 ilst/meta/udta/moov 的 size（各 -8）
        var fixed = data
        let delta = 8
        fixed.removeSubrange(covrOffset ..< covrOffset + delta)
        for containerOffset in [ilst.offset, meta.offset, udta.offset, moov.offset] {
            let old = readUInt32(fixed, at: containerOffset)
            writeUInt32(old - UInt32(delta), to: &fixed, at: containerOffset)
        }
        try fixed.write(to: url, options: .atomic)
    }

    // MARK: - MP4 atom helpers

    /// 在 range 内查找指定类型的子 atom；返回 (offset, size)。找不到返回 nil。
    private static func findAtom(in data: Data, type: String, range: Range<Int>) -> (offset: Int, size: Int)? {
        var i = range.lowerBound
        while i + 8 <= range.upperBound {
            let size = Int(readUInt32(data, at: i))
            guard size >= 8, i + size <= range.upperBound else { break }
            let atomType = String(data: data.subdata(in: i + 4 ..< i + 8), encoding: .ascii)
            if atomType == type {
                return (i, size)
            }
            i += size
        }
        return nil
    }

    /// atom header 长度（支持 64 位扩展 size==1）
    private static func headerSize(_ data: Data, at offset: Int) -> Int {
        let size = readUInt32(data, at: offset)
        if size == 1 { return 16 }
        if size == 0 { return 8 }
        return 8
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.subdata(in: offset ..< offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    }

    private static func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        guard offset + 4 <= data.count else { return }
        var v = value.bigEndian
        withUnsafeBytes(of: &v) { bytes in
            data.replaceSubrange(offset ..< offset + 4, with: bytes)
        }
    }
}
