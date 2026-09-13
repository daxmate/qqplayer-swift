//
//  ArtworkCacheEncodingTests.swift
//  QQPlayerTests
//
//  审计 🔵-2 配套：封面落盘缓存的共用编码/降采样入口。
//
//  修复前 macOS 分支 `saveToDiskCache` 是 no-op（只打一行 print），因此封面永不
//  落盘、每次冷启动都要重新解包内嵌封面；修复把 macOS 接回与 iOS 同一条路径，
//  为此新增了两个平台无关的静态入口：
//    - `ArtworkManager.downsampled(_:maxPixelSize:)`（macOS 分支改为真缩放）
//    - `ArtworkManager.jpegData(_:compressionQuality:)`（macOS 用 NSBitmapImageRep）
//
//  说明：iOS 测试 target 无法编译/执行 `#if os(macOS)` 分支，故本文件锁定的是
//  两端共用入口的契约（封顶 + 可解码 JPEG），macOS 分支由 QQPlayerMac 编译覆盖。
//

import Foundation
import Testing
import UIKit

@testable import QQPlayer

struct ArtworkCacheEncodingTests {
    private func makeImage(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test("downsampled 把超限图片按最长边封顶到上限")
    func downsampledCapsLargestSide() {
        let image = makeImage(width: 2048, height: 1024)

        let capped = ArtworkManager.downsampled(image, maxPixelSize: ArtworkManager.maxFullArtworkPixelSize)

        #expect(max(capped.size.width, capped.size.height) <= ArtworkManager.maxFullArtworkPixelSize)
    }

    @Test("未超限的图片不被缩放（cap 只在超限时生效）")
    func downsampledKeepsSmallImage() {
        let image = makeImage(width: 100, height: 100)

        let capped = ArtworkManager.downsampled(image, maxPixelSize: ArtworkManager.maxFullArtworkPixelSize)

        #expect(capped.size.width == 100)
        #expect(capped.size.height == 100)
    }

    @Test("jpegData 返回可解码的 JPEG 数据（落盘缓存写入前必须拿到编码结果）")
    func jpegDataEncodesImage() throws {
        let image = makeImage(width: 64, height: 64)

        let data = try #require(ArtworkManager.jpegData(image, compressionQuality: 0.85))

        #expect(!data.isEmpty)
        #expect(Data(data.prefix(2)) == Data([0xFF, 0xD8])) // JPEG SOI
        #expect(UIImage(data: data) != nil)
    }
}
