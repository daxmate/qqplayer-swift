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
        append(message, to: logURL)
    }

    /// 诊断基建（2026-09-02）：启动时重定向 stderr 落盘。Xcode Run 的 app
    /// 其 print/fatal error 只进 Xcode 控制台（外部不可见）；重定向后
    /// ~/Library/Logs/QQPlayerMac/stderr.log 可随时读取定位运行时报错。
    static func redirectStderr() {
        let url = logURL.deletingLastPathComponent().appendingPathComponent("stderr.log")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {}
        freopen(url.path, "a+", stderr)
    }

    /// print() 实际写 stdout 而非 stderr——只重定向 stderr 会让 🗑️/🗃️ print 日志
    /// 全部丢失（2026-09-02 删除不刷新排查发现的盲区）。启动时一并重定向 stdout。
    static func redirectStdout() {
        let url = logURL.deletingLastPathComponent().appendingPathComponent("stdout.log")
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {}
        freopen(url.path, "a+", stdout)
    }

    /// 追加一行到指定日志文件（scan.log / trash.log 共用同一实现）
    fileprivate static func append(_ message: String, to url: URL) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path),
               let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                try? handle.close()
            } else {
                try line.data(using: .utf8)?.write(to: url)
            }
        } catch {
            print("⚠️ Logger failed: \(error)")
        }
    }
}

// MARK: - 删除/移废纸篓诊断（2026-09-02 A4 用户反馈删除不刷新后补）
// trash.log 记录每步：目标文件 → trashItem 结果 → deleteTrack 结果（含错误详情）。
// 之前 print 只进 stdout（Xcode 控制台外不可见），失败原因全靠猜——落盘后可读。
enum MacTrashLogger {
    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/QQPlayerMac", isDirectory: true)
            .appendingPathComponent("trash.log")
    }

    static func log(_ message: String) {
        MacScanLogger.append(message, to: logURL)
    }
}
