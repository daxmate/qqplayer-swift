import Foundation

/// 中断恢复诊断日志（2026-08-30 加，定位"跑步中断后从头播放"间歇 bug）。
///
/// 把中断决策链路的关键状态追加写入 `Documents/intr-debug.log`（环形：
/// 超过上限截断保留尾部），下次真机复现后直接读沙盒文件即可拿到完整
/// 证据链，不需要实时抓 console。
///
/// ⚙️ 默认**不写盘**（2026-09-12 审计 P6）：它曾经在 5 处生产路径同步写盘
/// （中断 began/ended、恢复快照、PLAY FROM BEGINNING、currentTime fallback），
/// 即主线程同步 IO + 把播放位置落盘到用户可见沙盒目录。诊断能力不丢：
///   - 调用点的 `print()` 一直保留（控制台可见，真机抓 console 即可）；
///   - 需要落盘时用环境变量打开（Xcode Scheme → Run → Arguments →
///     Environment Variables 加 `QQPLAYER_INTERRUPTION_DIAGNOSTICS=1`）。
enum InterruptionDiagnostics {
    /// 写盘开关的环境变量名（值必须为 "1"）。
    static let environmentKey = "QQPLAYER_INTERRUPTION_DIAGNOSTICS"

    /// 纯函数：判定环境变量值是否开启写盘（可单测，避免测试直接依赖进程环境）。
    static func shouldWrite(environmentValue: String?) -> Bool {
        environmentValue == "1"
    }

    /// 本进程是否写盘（默认关闭）。
    static let isEnabled = shouldWrite(environmentValue: ProcessInfo.processInfo.environment[environmentKey])

    private static let maxBytes = 200_000
    private static let keepTailBytes = 50_000

    private static var timestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: Date())
    }

    private static var logURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("intr-debug.log")
    }

    /// 追加一行日志（同步写，只在中断/播放决策点低频调用，无性能顾虑）。
    /// 仅在 `isEnabled`（环境变量开关，默认关闭）时写盘；关闭时完全不做文件 IO。
    static func log(_ message: String) {
        guard isEnabled else { return }
        guard let url = logURL else { return }
        let line = "[\(timestamp)] \(message)\n"
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
                   size > maxBytes {
                    // 环形截断：保留尾部，避免文件无限增长
                    if let handle = try? FileHandle(forReadingFrom: url) {
                        defer { _ = try? handle.close() }
                        try? handle.seek(toOffset: UInt64(max(0, size - keepTailBytes)))
                        let tail = handle.readDataToEndOfFile()
                        _ = try? tail.write(to: url, options: .atomic)
                    }
                }
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { _ = try? handle.close() }
                    _ = try? handle.seekToEnd()
                    _ = try? handle.write(contentsOf: Data(line.utf8))
                    return
                }
            }
            try line.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            // 诊断日志失败不影响播放
        }
    }
}
