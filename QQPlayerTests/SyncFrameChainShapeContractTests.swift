//
//  SyncFrameChainShapeContractTests.swift
//  QQPlayerTests
//
//  「会话槽位包装层」形状契约（2026-11-12 立，真机 bug 回归）。
//
//  为什么需要：`onApplicationFrame` / `onClosed` 是**单槽**，每个包装层都靠
//  「读旧值 → 写新闭包 → 转发旧值」串成链。只要有人把转发写成
//  `self?.priorAppHandler?(frame)`（而不是强捕获的局部 `priorApp?(frame)`），
//  本层被释放后 `self == nil` → **既不转发也不报错**，链上更早的 handler 在本次会话
//  余下时间全部收不到帧。2026-11-12 真机事故就是这样丢掉了整段 manifest / 文件帧
//  （Mac 端 20s 超时，iPhone 端零日志）。
//
//  契约（扫描口径：先剥注释与字符串再判，同 `SyncDeadlineSchedulingContractTests`）：
//    ① 生产代码里**不得**出现 `?.priorAppHandler` / `?.priorClosedHandler`；
//    ② 已改造的包装层必须仍在，并且用强捕获的 `priorApp?(` / `priorClosed?(` 转发
//      （防「把包装层删掉换绿灯」）；
//    ③ 本文件自带反向自证：注释 / 字符串里的写法不算命中。
//

import Foundation
import Testing

private enum FrameChainShape {
    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// 禁用的转发写法（弱 self 取 prior）。
    static let bannedPatterns = ["?.priorAppHandler", "?.priorClosedHandler"]

    /// 必须存在的包装层 → 其强捕获转发写法（正向对照）。
    static let wrappedFiles: [(path: String, mustContain: [String])] = [
        ("QQPlayer/Sync/SyncChangeLogNotReadyResponder.swift", ["priorApp?(", "priorClosed?("]),
        ("QQPlayer/Sync/SyncChangeLogPeer.swift", ["priorApp?(", "priorClosed?("]),
        ("QQPlayer/Sync/SyncFileReceiver.swift", ["priorApp?(", "priorClosed?("]),
        ("QQPlayer/Sync/SyncFileSender.swift", ["priorApp?(", "priorClosed?("]),
        ("QQPlayer/Sync/SyncLibraryPassiveHost.swift", ["priorApp?(", "priorClosed?("]),
        ("QQPlayer/Sync/SyncLibraryPullController.swift", ["priorApp?("]),
    ]

    /// 剥注释与字符串字面量（口径与 `SyncDeadlineSchedulingContractTests` 一致）。
    static func strippedCode(_ source: String) -> String {
        var result = ""
        var index = source.startIndex
        var isInString = false
        var isEscaped = false
        while index < source.endIndex {
            let character = source[index]
            let next = source.index(after: index)
            if isInString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInString = false
                }
            } else if character == "\"" {
                isInString = true
            } else if character == "/", next < source.endIndex, source[next] == "/" {
                var cursor = next
                while cursor < source.endIndex, source[cursor] != "\n" {
                    cursor = source.index(after: cursor)
                }
                index = cursor
                continue
            } else if character == "/", next < source.endIndex, source[next] == "*" {
                var cursor = source.index(after: next)
                while cursor < source.endIndex {
                    let after = source.index(after: cursor)
                    if source[cursor] == "*", after < source.endIndex, source[after] == "/" {
                        cursor = source.index(after: after)
                        break
                    }
                    cursor = after
                }
                result.append(" ")
                index = cursor
                continue
            } else {
                result.append(character)
            }
            index = next
        }
        return result
    }

    /// 递归收集 `QQPlayer/` 下的 Swift 源文件（相对仓库根）。
    static func productionSources() -> [String] {
        let root = repositoryRoot.appendingPathComponent("QQPlayer", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            paths.append(url.path.replacingOccurrences(of: repositoryRoot.path + "/", with: ""))
        }
        return paths.sorted()
    }

    static func code(at relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        return strippedCode(try String(contentsOf: url, encoding: .utf8))
    }
}

struct SyncFrameChainShapeContractTests {
    @Test("帧链形状契约：包装层不得用 self?.prior 转发（释放后静默吞帧）")
    func wrappersMustNotDereferencePriorThroughWeakSelf() throws {
        let sources = FrameChainShape.productionSources()
        #expect(!sources.isEmpty, "扫描口径失效：QQPlayer/ 下没找到任何 Swift 文件")

        var violations: [String] = []
        for path in sources {
            let code = try FrameChainShape.code(at: path)
            for pattern in FrameChainShape.bannedPatterns where code.contains(pattern) {
                violations.append("\(path) → \(pattern)")
            }
        }
        #expect(violations.isEmpty, "禁用写法：\(violations.joined(separator: "；"))")
    }

    @Test("帧链形状契约：已改造包装层仍在，且用强捕获 prior 转发")
    func wrappedLayersStillForwardWithStrongPrior() throws {
        for entry in FrameChainShape.wrappedFiles {
            let code = try FrameChainShape.code(at: entry.path)
            #expect(code.contains("onApplicationFrame"), "\(entry.path): 找不到槽位装配")
            for needle in entry.mustContain {
                #expect(code.contains(needle), "\(entry.path): 缺少强捕获转发 \(needle)")
            }
        }
    }

    @Test("帧链形状契约：扫描口径自证（注释与字符串里的写法不算命中）")
    func strippedCodeIgnoresCommentsAndStrings() {
        let commented = "// self?.priorAppHandler?(frame)\nlet x = 1"
        let inString = "let label = \"self?.priorAppHandler?(frame)\""
        let block = "/* self?.priorAppHandler?(frame) */\nlet y = 2"
        for sample in [commented, inString, block] {
            let stripped = FrameChainShape.strippedCode(sample)
            #expect(!stripped.contains("?.priorAppHandler"), "剥离不彻底：\(stripped)")
        }
        // 正对照：真代码必须仍然被看见
        let real = "self?.priorAppHandler?(frame)"
        #expect(FrameChainShape.strippedCode(real).contains("?.priorAppHandler"))
    }
}
