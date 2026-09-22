//
//  SyncConnectDiag.swift
//  QQPlayer
//
//  同步连接链路的真机落盘诊断（2026-09-17 立，长期保留）。
//
//  为什么保留（不是一次性取证）：真机 `print()` 取不到（见 ios-device-forensics：
//  `devicectl process launch --console` 报 CoreDeviceError 10002、macOS `log` 不支持
//  设备），而「发现不到桌面端 / 连上的是别的主机」这类问题在 2026-09-16↔17 连着咬了
//  两次（先 NWBrowser 不交付结果，再增量发现抢跑）。这里把链路关键事实落盘到 App
//  容器 `Documents/sync-diag.log`，用
//  `xcrun devicectl device copy from --domain-type appDataContainer --domain-identifier
//  com.daxmate.qqplayer.ios --source Documents/sync-diag.log` 拉回即可读
//  —— 与 `DatabaseManager.dbDiag`（db-debug.log）同口径。
//
//  记录什么：DNS-SD 浏览失败/回调错误、合并后的发现集、候选与未试候选、选中的连接目标、
//  会话关闭原因、发现超时。都是低频决策点（每轮几行），不进收帧热路径。
//
//  约束：纯观测（每个调用点只记一行，不改业务分支）；写盘失败静默；环形截断
//  （超 256KB 留尾部 64KB）。
//
//  文件传输计时（2026-09-18 提速）也走本入口（`log(metrics.logLine)`），**每文件一行**
//  （不逐块刷屏）：两端各记一行，同一 fileID 可对照。
//
//  ⚙️ 目标归属（2026-09-18 改）：本文件**两端都编**（原为 ios-only）。
//  为什么：文件传输的计时日志发送端在 Mac（推送/拉取的发起方）、接收端在 iOS，
//  同一份「同步诊断」语义不该按平台分家（两端各写一份 = 多处手工维护）。
//  落点按平台取各自**已有**的通道：
//    - iOS：App 容器 `Documents/sync-diag.log`（真机 print 取不到，必须落盘；用
//      `xcrun devicectl device copy from` 拉回）
//    - macOS：`print` → `~/Library/Logs/QQPlayerMac/stdout.log`（QQPlayerMacApp 启动时
//      已把 stdout 重定向到该文件，与 scan.log/stderr.log 同口径）
//
// target: shared（两端都编；见上「目标归属」）
//

import Foundation
import Network

enum SyncConnectDiag {
    /// 总开关（需要静默时置 false）。
    static let enabled = true

    private static let queue = DispatchQueue(label: "com.daxmate.qqplayer.sync.diag")

    // MARK: 落点（唯一出口）

    /// 记一行同步诊断（唯一出口；调用方不关心平台落点）。
    static func log(_ message: String) {
        guard enabled else { return }
        let line = "[\(timestamp())] \(message)\n"
        #if os(iOS)
            queue.async {
                guard let url = logFileURL() else { return }
                append(line, to: url)
            }
        #else
            // macOS：走既有 stdout 重定向（print 即落到 stdout.log；无额外文件 IO）
            print(line, terminator: "")
        #endif
    }

    private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    #if os(iOS)
        /// 落点覆盖（测试注入；默认 nil ⇒ App 容器 `Documents/sync-diag.log`）。
        ///
        /// 为什么留这个缝：落点原本写死在 App 容器里，环形截断（超 256KB 留尾部 64KB）
        /// 这一行为在测试内**无法确定性观察**（全进程共享单文件 + 真机容器路径）——
        /// 真机出问题时只能靠人肉拉日志推断。缝只影响落点解析，不改任何业务分支。
        /// `nonisolated(unsafe)` 与 `LyricsManager.manualLyricsDirectoryOverride` 同款：
        /// 只由测试在用例内写入（串行用例 + 结束即复原），生产只读。
        nonisolated(unsafe) static var logFileURLOverride: URL?

        /// 落点解析（唯一出口）。
        static func logFileURL() -> URL? {
            if let logFileURLOverride { return logFileURLOverride }
            // 2026-09-22 曲库文件夹化：诊断日志统一落 `Documents/Logs/`。
            return LibraryRoot.plannedDirectoryURL(LibraryRoot.logsDirectoryName)?
                .appendingPathComponent("sync-diag.log")
        }

        /// 环形截断 + 追加（同步实现：`log()` 在诊断队列上调用它）。
        /// 超 256KB → 先留尾部 64KB，再追加本次这一行。
        static func append(_ line: String, to url: URL) {
            do {
                if FileManager.default.fileExists(atPath: url.path),
                   let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int,
                   size > 256_000 {
                    if let handle = try? FileHandle(forReadingFrom: url) {
                        defer { _ = try? handle.close() }
                        try? handle.seek(toOffset: UInt64(max(0, size - 64_000)))
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
                try line.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                // 诊断失败不影响同步主流程
            }
        }
    #endif

    // MARK: endpoint 描述（含类型/域/接口，用于判 endpoint 是否合法）

    static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case let .hostPort(host, port):
            return "hostPort(\(host):\(port))"
        case let .service(name, type, domain, interface):
            let scope = interface.map { "\($0.name):\($0.type)" } ?? "nil"
            return "service(name=\(name) type=\(type) domain=\(domain) if=\(scope))"
        case let .unix(path):
            return "unix(\(path))"
        case let .url(url):
            return "url(\(url))"
        default:
            return "\(endpoint)"
        }
    }
}
