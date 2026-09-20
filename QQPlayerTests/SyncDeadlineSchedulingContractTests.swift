//
//  SyncDeadlineSchedulingContractTests.swift
//  QQPlayerTests
//
//  「一次性截止时间调度」唯一入口契约（2026-09-20 立，flaky 用例收口同批）。
//
//  为什么需要：ack 超时 / 握手超时原先各自直接
//  `DispatchQueue.global(qos: .utility).asyncAfter(...)` —— 把「超时**何时**被判定」
//  交给了全局队列的线程池状态。池被占满时工作项过了 deadline 也拿不到线程执行
//  （本机实测：池占满后 0.05s 的 deadline 在 11s 窗口内一次都没落地），于是：
//    - `SyncTransferIdentityTests.senderTimesOutWithoutAck` 假失败（2026-09-20 CI
//      run 35478148288：0.15s 的超时在 60s 轮询窗口内都没落地，卡红了无关 PR）；
//    - `SyncPeerSessionTests.handshakeTimeout` 更早因「asyncAfter 从未触发」被
//      `.disabled`（2026-09-09）。
//  收口后超时判定只走 `SyncDeadlineScheduling`（**可注入** ⇒ 用例显式触发，与 runner
//  调度解耦；生产默认实现仍是 GCD 全局 `.utility` 队列，行为不变）。
//
//  本契约把三件事钉死在 CI（不然下次又会有人在消费点里顺手写回 asyncAfter）：
//    ① 唯一实现：`QQPlayer/Sync/**` 里 `schedule(after:` 的实现只允许出现在入口文件；
//    ② 消费点不许直连：`SyncFileSender` / `SyncPeerSession` 不得直接 `asyncAfter`；
//    ③ 消费点必须**真的持有**调度器（防「把超时删掉换绿灯」——删掉超时也能让超时用例变绿）。
//
//  口径：先剥注释与字符串再判（注释里的示例代码/说明文字会误计，同
//  `DangerousOperatorContractTests` 的教训）；本文件自带反向自证用例。
//

import Foundation
import Testing

private enum SyncDeadlineContract {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 唯一入口（实现 `SyncDeadlineScheduling` 的地方）。
    static let entryPointPath = "QQPlayer/Sync/SyncDeadlineScheduler.swift"

    /// 扫描范围：同步子系统（本次收口的目标）。
    static let scannedDirectory = "QQPlayer/Sync"

    /// 必须走入口的消费点（= 原先各自 asyncAfter 的两处）。
    static let consumerPaths = [
        "QQPlayer/Sync/SyncFileSender.swift",
        "QQPlayer/Sync/SyncPeerSession.swift",
    ]

    /// 剥掉行注释与字符串字面量（扫描统一口径）。
    static func strippedCode(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)
        var isInString = false
        var isEscaped = false
        var isInLineComment = false
        var previous: Character?

        for character in source {
            if isInLineComment {
                if character == "\n" {
                    isInLineComment = false
                    out.append(character)
                }
                previous = character
                continue
            }
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
                previous = character
                continue
            }
            if character == "\"" {
                isInString = true
                previous = character
                continue
            }
            if character == "/", previous == "/" {
                if out.hasSuffix("/") { out.removeLast() }
                isInLineComment = true
                previous = character
                continue
            }
            out.append(character)
            previous = character
        }
        return out
    }

    /// 读某个仓库相对路径的源码（读不到 → 抛错 = fail-closed，不允许静默通过）。
    static func source(_ relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw ContractError.unreadable(relativePath)
        }
    }

    /// 扫描目录下所有 .swift（仓库相对路径 + 剥注释后的源码）。
    static func scannedSources() throws -> [(path: String, code: String)] {
        let directory = repositoryRoot.appendingPathComponent(scannedDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw ContractError.directoryUnreadable(scannedDirectory)
        }
        var result: [(path: String, code: String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let relative = url.path.replacingOccurrences(of: repositoryRoot.path + "/", with: "")
            result.append((relative, strippedCode(try source(relative))))
        }
        return result.sorted { $0.path < $1.path }
    }

    enum ContractError: Error, CustomStringConvertible {
        case unreadable(String)
        case directoryUnreadable(String)

        var description: String {
            switch self {
            case .unreadable(let path): return "源码读不到（fail-closed）：\(path)"
            case .directoryUnreadable(let path): return "目录无法枚举（fail-closed）：\(path)"
            }
        }
    }
}

@Suite("同步超时调度契约")
struct SyncDeadlineSchedulingContractTests {
    /// ① 唯一实现：`schedule(after:` 只允许在入口文件里被实现。
    @Test("schedule(after:) 的实现只允许出现在唯一入口")
    func deadlineSchedulingHasSingleImplementation() throws {
        let declaration = "func schedule(after"
        var offenders: [String] = []
        for file in try SyncDeadlineContract.scannedSources() {
            guard file.path != SyncDeadlineContract.entryPointPath else { continue }
            if file.code.contains(declaration) {
                offenders.append(file.path)
            }
        }
        #expect(offenders.isEmpty, "第二实现（应改为复用 SyncDeadlineScheduling）：\(offenders)")

        // 入口本身必须真的实现（防「删掉入口、契约仍绿」）
        let entryPath = SyncDeadlineContract.entryPointPath
        let entry = SyncDeadlineContract.strippedCode(try SyncDeadlineContract.source(entryPath))
        #expect(entry.contains(declaration))
        #expect(entry.contains("protocol SyncDeadlineScheduling"))
    }

    /// ② 消费点不许直连 `asyncAfter`（必须走入口）。
    @Test("消费点不得直接 asyncAfter 排定截止时间")
    func consumersDoNotScheduleDirectly() throws {
        for path in SyncDeadlineContract.consumerPaths {
            let code = SyncDeadlineContract.strippedCode(try SyncDeadlineContract.source(path))
            #expect(!code.contains("asyncAfter"), "\(path) 直接排定截止时间了——请走 SyncDeadlineScheduling")
        }
    }

    /// ③ 消费点必须真的持有调度器（防「删掉超时」式假绿）。
    @Test("消费点必须经注入的调度器排定截止时间")
    func consumersHoldScheduler() throws {
        for path in SyncDeadlineContract.consumerPaths {
            let code = SyncDeadlineContract.strippedCode(try SyncDeadlineContract.source(path))
            #expect(code.contains("SyncDeadlineScheduling"), "\(path) 未持有调度器")
            #expect(code.contains("schedule(after:"), "\(path) 未真正排定截止时间（超时被删掉了？）")
        }
    }

    /// 反向自证：剥注释/字符串的口径必须真的生效（否则上面三条可能是假绿）。
    @Test("扫描口径自证：注释与字符串里的写法不算")
    func scannerIgnoresCommentsAndStrings() {
        let commented = """
        // 下面这行是说明，不是代码：queue.asyncAfter(deadline: .now())
        let text = "asyncAfter 只是字符串，func schedule(after: 也只是文字"
        """
        let stripped = SyncDeadlineContract.strippedCode(commented)
        #expect(!stripped.contains("asyncAfter"))
        #expect(!stripped.contains("func schedule(after"))

        // 正对照：真代码必须仍然被看见
        let real = "queue.asyncAfter(deadline: .now() + 1) {}"
        #expect(SyncDeadlineContract.strippedCode(real).contains("asyncAfter"))
    }
}
