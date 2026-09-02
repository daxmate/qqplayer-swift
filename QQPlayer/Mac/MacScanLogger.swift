//
//  MacScanLogger.swift
//  QQPlayer
//
//  macOS 曲库扫描诊断日志（~Library/Logs/QQPlayerMac/scan.log，非沙盒可写）。
//  复现「添加文件夹不导入」类问题时让用户重试一次，直接读日志定位。
//  QQPlayerMac target only。
//

import Foundation

enum MacScanLogger {
    private static let lock = NSLock()

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/QQPlayerMac", isDirectory: true)
            .appendingPathComponent("scan.log")
    }

    static func log(_ message: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        let url = logURL
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try line.data(using: .utf8)?.write(to: url)
            }
        } catch {
            print("⚠️ MacScanLogger failed: \(error)")
        }
    }
}
