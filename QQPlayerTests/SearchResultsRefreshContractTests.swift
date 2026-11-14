//
//  SearchResultsRefreshContractTests.swift
//  QQPlayerTests
//
//  形状契约（2026-11-14）：**搜索结果必须在曲库变更后重跑查询**。
//
//  为什么需要它：iOS 搜索结果（`SearchView` 的 `@State searchResults`）是一次性 DB 查询快照，
//  只在 `performSearch(query:)` 里更新。曲目删除走唯一入口 `TrackDeletionService.delete(items:)`，
//  末尾 post `.libraryNeedsRefresh`；Mac 侧 `MacLibraryView` 订阅该通知后重跑 `performSearch`，
//  iOS 侧曾经没有订阅 ⇒ 删歌后结果行残留（2026-11-14 用户反馈）。行为测试要真删库才能覆盖，
//  形状测试静态兜住「订阅在位 + 订阅闭包里真的重跑查询」（防「订了但没重跑」的假修复）。
//
//  设计要点（照 AppNotificationContractTests / TrackDeletionShapeContractTests 的写法）：
//  - 注释剥离**复用** `AppNotificationContract.stripComments(source:)`（同一测试 target），不另写一份。
//  - 扫描规则收敛在纯函数里、不碰文件系统 ⇒ 可用合成源码自证「该抓的会红、改坏会红」（防契约空转）。
//  - 读不到源码 = 抛错 = 测试红（fail-closed），不静默跳过。
//

import Foundation
import Testing

@testable import QQPlayer

/// 搜索结果刷新形状：`SearchView` 订阅 `.libraryNeedsRefresh`，且在订阅闭包里重跑查询。
enum SearchResultsRefreshContract {
    /// 被守护的视图源码（相对仓库根）。
    static let searchViewPath = "QQPlayer/Views/Library/SearchView.swift"

    /// 通知订阅锚点：`.publisher(for: .libraryNeedsRefresh)`。
    static let subscriptionAnchor = ".publisher(for: .libraryNeedsRefresh)"

    /// 重跑查询锚点：订阅闭包里必须出现 `performSearch(query:`。
    static let rerunAnchor = "performSearch(query:"

    static let repositoryRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    enum ContractError: Error, CustomStringConvertible {
        case sourceUnreadable(String)
        case blockCommentUnterminated(String)

        var description: String {
            switch self {
            case .sourceUnreadable(let path):
                return "契约测试读不到源码（fail-closed）：\(path)"
            case .blockCommentUnterminated(let path):
                return "源码块注释未闭合，剥离器不可信（fail-closed）：\(path)"
            }
        }
    }

    /// 读真实源码并剥掉注释；读不到 / 剥离异常一律抛错（红）。
    static func searchViewCode() throws -> String {
        let url = repositoryRoot.appendingPathComponent(searchViewPath)
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw ContractError.sourceUnreadable(url.path)
        }
        return try codeOnly(source: source, path: url.path)
    }

    /// 剥注释（复用 AppNotificationContract 的唯一实现）；块注释未闭合视为剥离器失效。
    static func codeOnly(source: String, path: String = "<memory>") throws -> String {
        let stripped = AppNotificationContract.stripComments(source: source)
        guard !stripped.unterminatedBlockComment else {
            throw ContractError.blockCommentUnterminated(path)
        }
        return stripped.code
    }

    /// 取订阅闭包体：锚点之后第一个 `{` 起、按花括号配平到对应 `}` 为止。
    /// 未订阅 → nil。字符串内容已被剥成空格，花括号计数不受串内字符干扰。
    static func subscriptionBody(in code: String) -> String? {
        guard let anchor = code.range(of: subscriptionAnchor) else { return nil }
        guard let openBrace = code[anchor.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = openBrace
        while index < code.endIndex {
            let character = code[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    let bodyStart = code.index(after: openBrace)
                    return String(code[bodyStart ..< index])
                }
            }
            index = code.index(after: index)
        }
        return nil
    }

    /// 订阅在位。
    static func hasSubscription(in code: String) -> Bool {
        subscriptionBody(in: code) != nil
    }

    /// 订阅闭包里真的重跑查询（防「订了但没重跑」的假修复）。
    static func rerunsSearchAfterRefresh(in code: String) -> Bool {
        guard let body = subscriptionBody(in: code) else { return false }
        return body.contains(rerunAnchor)
    }
}

struct SearchResultsRefreshContractTests {
    // MARK: - 真实源码

    @Test func searchViewSubscribesLibraryNeedsRefresh() throws {
        let code = try SearchResultsRefreshContract.searchViewCode()
        #expect(
            SearchResultsRefreshContract.hasSubscription(in: code),
            "SearchView 必须订阅 .libraryNeedsRefresh（删歌后搜索结果不刷新的根因）"
        )
    }

    @Test func searchViewRerunsQueryInsideSubscription() throws {
        let code = try SearchResultsRefreshContract.searchViewCode()
        let body = SearchResultsRefreshContract.subscriptionBody(in: code)
        #expect(body != nil, "SearchView 必须订阅 .libraryNeedsRefresh")
        #expect(
            SearchResultsRefreshContract.rerunsSearchAfterRefresh(in: code),
            "订阅闭包内必须调用 performSearch(query:)，否则只是刷新了设置/状态、结果仍旧是旧快照"
        )
    }

    // MARK: - 合成源码自证（契约不许空转）

    @Test func syntheticHealthySourcePasses() throws {
        let source = """
        struct FakeView: View {
            var body: some View {
                content
                    .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
                        let query = debouncedSearchText
                        guard !SearchQuery.isEmpty(query) else { return }
                        performSearch(query: query)
                    }
            }
        }
        """
        let code = try SearchResultsRefreshContract.codeOnly(source: source)
        #expect(SearchResultsRefreshContract.hasSubscription(in: code))
        #expect(SearchResultsRefreshContract.rerunsSearchAfterRefresh(in: code))
    }

    @Test func syntheticMissingSubscriptionFails() throws {
        let source = """
        struct FakeView: View {
            var body: some View {
                content
                    .onReceive(NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)) { _ in
                        settings = DeleteSettings.load()
                    }
            }
        }
        """
        let code = try SearchResultsRefreshContract.codeOnly(source: source)
        #expect(!SearchResultsRefreshContract.hasSubscription(in: code))
        #expect(!SearchResultsRefreshContract.rerunsSearchAfterRefresh(in: code))
    }

    @Test func syntheticSubscriptionWithoutRerunFails() throws {
        let source = """
        struct FakeView: View {
            var body: some View {
                content
                    .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
                        settings = DeleteSettings.load()
                    }
            }
        }
        """
        let code = try SearchResultsRefreshContract.codeOnly(source: source)
        #expect(SearchResultsRefreshContract.hasSubscription(in: code))
        #expect(
            !SearchResultsRefreshContract.rerunsSearchAfterRefresh(in: code),
            "只订阅不重跑必须被判失败"
        )
    }

    @Test func commentedOutSubscriptionDoesNotCount() throws {
        let source = """
        struct FakeView: View {
            var body: some View {
                content
                    // .onReceive(NotificationCenter.default.publisher(for: .libraryNeedsRefresh)) { _ in
                    //     performSearch(query: debouncedSearchText)
                    // }
            }
        }
        """
        let code = try SearchResultsRefreshContract.codeOnly(source: source)
        #expect(!SearchResultsRefreshContract.hasSubscription(in: code), "注释掉的订阅不算数")
    }
}
