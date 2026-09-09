//
//  SyncFileChecksum.swift
//  QQPlayer
//
//  局域网同步（S2, M2b）SHA-256 助手：文件走流式（FileHandle 1MB 窗口分段读，
//  大文件不整进内存），另提供 Data 入口 + 小写 hex 输出（协议 sha256Hex 格式）。
//

import CryptoKit
import Foundation

enum SyncFileChecksum {
    /// 空数据 SHA-256（0 字节文件校验/幂等判断用）。
    static let emptyHex = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    static func sha256Hex(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// 流式计算文件 SHA-256（不存在/读失败抛 Cocoa 错误，由调用方映射）。
    static func sha256Hex(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let window = try handle.read(upToCount: 1_048_576) ?? Data()
            if window.isEmpty { break }
            hasher.update(data: window)
        }
        return hex(hasher.finalize())
    }

    /// 小写 hex。
    static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 协议 sha256Hex 格式校验（64 位小写 hex；大小写不敏感收）。
    static func isValidSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}
