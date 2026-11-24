//
//  MacWindowChromeShapeContractTests.swift
//  QQPlayerTests
//
// target: ios-only
//
//  macOS 整窗玻璃的**形状契约**（2026-11-24，用户拍板：别再让人肉回归）。
//
//  为什么是「纯文本契约」而不是行为测试：2026-11-23 一天连踩三个只能靠肉眼发现的回归，
//  其中两个的根因是**改了实现路线**——
//    ① 为摘掉侧栏的系统 Liquid Glass 而「换列」（remove/insertSplitViewItem）→
//       丢 `.sidebar` behavior → 工具栏右侧分区垮掉，4 个按钮从最右跑到中间；
//    ③ `sharedBackgroundVisibility` 只改数据、不重排 item viewer → 冷启动后胶囊残留。
//  行为断言（见 `scripts/run-mac-window-chrome-tests.sh`）能证明「今天这版对」，
//  但挡不住下一个人再换一次路线；形状契约负责把**路线本身**锁死。
//
//  三条守卫（全部 fail-closed：文件/仓库根读不到 = 红，绝不静默通过）：
//    ① `MacWindowGlass.swift` 禁止出现换列 API（`removeSplitViewItem(` / `insertSplitViewItem(`）；
//    ② `MacLibraryView.swift` 的 `sharedBackgroundVisibility(` 必须**无条件**挂在
//       `isWindowGlassActive` 判定上（关玻璃必须还原 .visible，外观与改动前一致）；
//    ③ `MacWindowGlassChrome.swift` 必须保留侧栏切换 item 的 `isBordered` 处理。
//
//  扫描逻辑全部放在 `MacWindowChromeShapeContract`（纯 Foundation），
//  不依赖 App 类型——这样同一份判定也能在无模拟器环境下复算（见本文件底部注释）。
//

import Foundation
import Testing

@testable import QQPlayer

// MARK: - 判定逻辑（纯 Foundation）

enum MacWindowChromeShapeContract {
    /// 仓库根（本文件在 `QQPlayerTests/` 下）。
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static let glassPath = "QQPlayer/Mac/MacWindowGlass.swift"
    static let libraryViewPath = "QQPlayer/Mac/MacLibraryView.swift"
    static let chromePath = "QQPlayer/Mac/MacWindowGlassChrome.swift"

    /// 读生产源码；读不到 → 抛错（调用方必须让测试红，不许 try? 吞掉）。
    static func read(_ relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ContractError.missingFile(url.path)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    enum ContractError: Error, CustomStringConvertible {
        case missingFile(String)

        var description: String {
            switch self {
            case let .missingFile(path):
                return "契约扫描的文件不存在：\(path)（fail-closed：读不到就是红，绝不静默通过）"
            }
        }
    }

    // MARK: ① 禁止换列

    static let forbiddenColumnSwapAPIs = ["removeSplitViewItem(", "insertSplitViewItem("]

    /// 返回违规明细（空 = 通过）。
    static func glassViolations(in text: String) -> [String] {
        forbiddenColumnSwapAPIs.compactMap { api in
            text.contains(api)
                ? """
                发现 \(api)——禁止在 MacWindowGlass.swift 里换列：\
                换掉第 0 个 split item 会丢 `.sidebar` behavior，\
                工具栏右侧分区随之垮掉，4 个业务按钮会从最右跑到中间（2026-11-23 实测）。\
                侧栏玻璃请用「摘玻璃、不换列」（把玻璃本体移进隐藏容器）。
                """
                : nil
        }
    }

    // MARK: ② sharedBackgroundVisibility 必须挂在玻璃判定上

    static let visibilityToken = "sharedBackgroundVisibility"

    /// 每个 `sharedBackgroundVisibility` 出现点后面（允许换行/空白）都必须紧跟
    /// `isWindowGlassActive ?`——防止有人无条件写 `.hidden`，破坏「关玻璃外观不变」。
    static func libraryViewViolations(in text: String) -> [String] {
        var violations: [String] = []
        let occurrences = ranges(of: visibilityToken, in: text)
        if occurrences.isEmpty {
            violations.append("\(libraryViewPath) 不再包含 \(visibilityToken)(：玻璃开时工具栏 item 底衬会残留（2026-11-23 回归 ③）")
            return violations
        }
        for range in occurrences {
            let tail = text[range.upperBound...].prefix(160)
            let normalized = tail.replacingOccurrences(of: "\n", with: " ")
            let matched = normalized.range(
                of: #"^\s*\(\s*isWindowGlassActive\s*\?"#,
                options: .regularExpression
            ) != nil
            if !matched {
                violations.append("\(visibilityToken)( 出现点没有挂在 `isWindowGlassActive ?` 上：\n      附近文本：\(normalized.prefix(90))")
            }
        }
        return violations
    }

    // MARK: ③ 侧栏切换 item 的 isBordered 处理

    static let chromeRequiredTokens = ["isBordered"]

    static func chromeViolations(in text: String) -> [String] {
        var violations: [String] = []
        for token in chromeRequiredTokens where !text.contains(token) {
            violations.append("\(chromePath) 缺少 \(token)：侧栏切换按钮在玻璃开时仍带底衬（胶囊残留）")
        }
        let identifierTokens = ["toggleSidebar", "sidebarToggleItemIdentifier"]
        if !identifierTokens.contains(where: { text.contains($0) }) {
            violations.append("\(chromePath) 缺少侧栏切换 item 的 identifier 常量（\(identifierTokens.joined(separator: " / "))）：找不到要改的 item")
        }
        return violations
    }

    // MARK: 工具

    static func ranges(of needle: String, in haystack: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchStart = haystack.startIndex
        while let found = haystack.range(of: needle, range: searchStart ..< haystack.endIndex) {
            result.append(found)
            searchStart = found.upperBound
        }
        return result
    }
}

// MARK: - 测试

@Suite("macOS 窗口 chrome 形状契约")
struct MacWindowChromeShapeContractTests {
    private typealias Contract = MacWindowChromeShapeContract

    @Test("MacWindowGlass.swift 禁止换列 API（换列会丢 .sidebar behavior）")
    func glassFileForbidsColumnSwap() throws {
        let text = try Contract.read(Contract.glassPath)
        let violations = Contract.glassViolations(in: text)
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }

    @Test("MacLibraryView.swift 的 sharedBackgroundVisibility 必须挂在 isWindowGlassActive 上")
    func libraryViewGatesSharedBackgroundVisibility() throws {
        let text = try Contract.read(Contract.libraryViewPath)
        let violations = Contract.libraryViewViolations(in: text)
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }

    @Test("MacWindowGlassChrome.swift 必须保留侧栏切换 item 的 isBordered 处理")
    func chromeFileKeepsSidebarToggleBordered() throws {
        let text = try Contract.read(Contract.chromePath)
        let violations = Contract.chromeViolations(in: text)
        #expect(violations.isEmpty, "\(violations.joined(separator: "\n"))")
    }

    // 判定逻辑自证：用假文本证明三条守卫**能变红**（不依赖真实文件当前状态）。
    @Test("形状守卫自证：换列 / 无条件隐藏 / 丢 isBordered 都必须被抓到")
    func guardsCatchRegressions() {
        let swapText = "split.removeSplitViewItem(item)\nsplit.insertSplitViewItem(plain, at: 0)"
        #expect(!Contract.glassViolations(in: swapText).isEmpty)

        let unconditional = "toolbarItems.sharedBackgroundVisibility(.hidden)"
        #expect(!Contract.libraryViewViolations(in: unconditional).isEmpty)

        let wrapped = "toolbarItems\n    .sharedBackgroundVisibility(\n        isWindowGlassActive ? .hidden : .visible\n    )"
        #expect(Contract.libraryViewViolations(in: wrapped).isEmpty)

        #expect(!Contract.chromeViolations(in: "func apply(active: Bool) {}").isEmpty)
        #expect(Contract.chromeViolations(in: "item.isBordered = false; let id = sidebarToggleItemIdentifier").isEmpty)
    }
}

// 无模拟器复算（本地反向验证用）：把上面 `enum MacWindowChromeShapeContract` 原样抽出，
// 配一个读真实仓库文件的 driver 即可复算同一份判定——见任务报告里的命令与输出。
