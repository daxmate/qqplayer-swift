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
//  （超 256KB 留尾部 64KB）；只编 iOS（文件头 `// target: ios-only` 标记，
//  Mac target 完全不受影响）。
//
// target: ios-only
//

import Foundation
import Network

#if os(iOS)
    enum SyncConnectDiag {
        /// 总开关（需要静默时置 false）。
        static let enabled = true

        private static let queue = DispatchQueue(label: "com.daxmate.qqplayer.sync.diag")

        // MARK: 落盘

        static func log(_ message: String) {
            guard enabled else { return }
            let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(message)\n"
            queue.async { append(line) }
        }

        private static func append(_ line: String) {
            guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
                .first?.appendingPathComponent("sync-diag.log") else { return }
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
#endif
