//
//  AutoScrapeRefreshContractTests.swift
//  QQPlayerTests
//
//  形状契约（2026-11-14）：**下载后自动刮削写完文件必须刷新界面**。
//
//  为什么需要它：用户口径「自动刮削完成后，要刷新一下界面」——
//  `MacAutoScrapeWorker` 写完标签 / 改名 / 单文件入库之后，曲库列表、歌单/专辑/艺人视图、
//  正在播放条（标题/封面）都要立刻跟随。原实现只从**后台** post `.libraryFolderContentChanged`：
//  MacLibraryView 收到它会起一次整库重扫（列表要等扫完），而播放上下文（当前曲目/队列）
//  根本没人跟随——正在播放条的标题/封面停在旧值。
//
//  行为测试要真下载 + 刮削 + 改文件才能覆盖，所以这里静态兜住**形状**：
//    ① 收尾必须发 `.libraryNeedsRefresh`（与标签保存同一信号）；
//    ② 不许回到 `.libraryFolderContentChanged`（整库重扫那条路）；
//    ③ `MainActor.run` 必须在 `.libraryNeedsRefresh` 之前的同一收尾块里（主线程发通知）；
//    ④ 必须走共享入口 `AppCoordinator.shared.followRenamedTrack`（播放上下文跟随不许被静默删掉）；
//    ⑤ 标签保存路径不得再有第二份私有实现（跟随只在 AppCoordinator 一处）。
//
//  设计要点（照 SearchResultsRefreshContractTests 的写法）：
//  - 注释剥离**复用** `AppNotificationContract.stripComments(source:)`（同一测试 target），不另写一份。
//  - 判据收敛在纯函数里、不碰文件系统 ⇒ 可用合成源码自证「该抓的会红、该绿的会绿」（防契约空转）。
//  - 读不到源码 = 抛错 = 测试红（fail-closed），不静默跳过。
//

import Foundation
import Testing

@testable import QQPlayer

/// 自动刮削刷新形状：主线程跟随播放上下文 + 发 `.libraryNeedsRefresh`，且不再触发整库重扫信号。
enum AutoScrapeRefreshContract {
    /// 被守护的收尾实现（相对仓库根）。
    static let autoScrapePath = "QQPlayer/Services/MacAutoScrapeService.swift"

    /// 标签保存路径（第二份实现的发源地，现在只许调用共享入口）。
    static let tagEditorSavePath = "QQPlayer/Mac/MacTagEditorView+RenameSave.swift"

    /// 列表刷新信号（与标签保存路径同一个）。
    static let needsRefreshAnchor = ".libraryNeedsRefresh"

    /// 整库重扫信号（**禁止**出现在自动刮削收尾里）。
    static let folderChangedAnchor = ".libraryFolderContentChanged"

    /// 主线程收尾锚点。
    static let mainActorAnchor = "MainActor.run"

    /// 播放上下文跟随的共享入口（非视图层唯一的可达写法）。
    static let followEntryAnchor = "AppCoordinator.shared.followRenamedTrack"

    /// 已收口的旧私有实现名（出现即意味着两份实现并存）。
    static let legacyFollowAnchor = "followRenamedTrackInPlayback"

    /// 标签保存路径调用共享入口的形状。
    static let sharedCallAnchor = ".followRenamedTrack(oldStableId:"

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
    static func code(relativePath: String = autoScrapePath) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
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

    /// 锚点首次出现位置（nil = 没出现）；字符串内容已被剥成空格，锚点不会误命中字面量。
    static func firstIndex(of anchor: String, in code: String) -> String.Index? {
        code.range(of: anchor)?.lowerBound
    }

    /// ① 收尾发的是列表刷新信号。
    static func postsLibraryNeedsRefresh(in code: String) -> Bool {
        code.contains(needsRefreshAnchor)
    }

    /// ② 没有退回「整库重扫」信号。
    static func avoidsFullRescanSignal(in code: String) -> Bool {
        !code.contains(folderChangedAnchor)
    }

    /// ③ 刷新在主线程收尾块里发（锚点顺序：MainActor.run 在 .libraryNeedsRefresh 之前）。
    static func postsRefreshOnMainActor(in code: String) -> Bool {
        guard let runIndex = firstIndex(of: mainActorAnchor, in: code),
              let postIndex = firstIndex(of: needsRefreshAnchor, in: code)
        else { return false }
        return runIndex < postIndex
    }

    /// ④ 播放上下文跟随走共享入口。
    static func followsPlaybackContext(in code: String) -> Bool {
        code.contains(followEntryAnchor)
    }

    /// ⑤ 标签保存路径不再有第二份私有实现。
    static func hasNoSecondFollowImplementation(in code: String) -> Bool {
        !code.contains(legacyFollowAnchor)
    }

    /// ⑤b 标签保存路径仍然调用共享入口（删实现的同时不许把跟随一起删掉）。
    static func tagSaveRoutesToSharedEntry(in code: String) -> Bool {
        code.contains(sharedCallAnchor)
    }
}

struct AutoScrapeRefreshContractTests {
    // MARK: - 真实源码

    @Test func autoScrapePostsLibraryNeedsRefresh() throws {
        let code = try AutoScrapeRefreshContract.code()
        #expect(
            AutoScrapeRefreshContract.postsLibraryNeedsRefresh(in: code),
            "自动刮削收尾必须发 .libraryNeedsRefresh（否则列表/正在播放条要等整库重扫才更新）"
        )
    }

    @Test func autoScrapeDoesNotTriggerFullRescan() throws {
        let code = try AutoScrapeRefreshContract.code()
        #expect(
            AutoScrapeRefreshContract.avoidsFullRescanSignal(in: code),
            "自动刮削收尾不得再发 .libraryFolderContentChanged（会触发整库重扫，且原实现是从后台线程发的）"
        )
    }

    @Test func autoScrapePostsRefreshOnMainActor() throws {
        let code = try AutoScrapeRefreshContract.code()
        #expect(
            AutoScrapeRefreshContract.postsRefreshOnMainActor(in: code),
            "刷新必须在 MainActor.run 收尾块里发（通知消费者是视图/主线程状态）"
        )
    }

    @Test func autoScrapeFollowsPlaybackContext() throws {
        let code = try AutoScrapeRefreshContract.code()
        #expect(
            AutoScrapeRefreshContract.followsPlaybackContext(in: code),
            "自动刮削必须走 AppCoordinator.shared.followRenamedTrack（改名后正在播放条/队列要跟随）"
        )
    }

    @Test func tagSaveHasNoSecondFollowImplementation() throws {
        let code = try AutoScrapeRefreshContract.code(relativePath: AutoScrapeRefreshContract.tagEditorSavePath)
        #expect(
            AutoScrapeRefreshContract.hasNoSecondFollowImplementation(in: code),
            "MacTagEditorView+RenameSave 不得再保留私有 followRenamedTrackInPlayback（跟随只在 AppCoordinator 一处）"
        )
    }

    @Test func tagSaveRoutesToSharedEntry() throws {
        let code = try AutoScrapeRefreshContract.code(relativePath: AutoScrapeRefreshContract.tagEditorSavePath)
        #expect(
            AutoScrapeRefreshContract.tagSaveRoutesToSharedEntry(in: code),
            "MacTagEditorView+RenameSave 必须调用共享入口 .followRenamedTrack(oldStableId:newTrack:)"
        )
    }

    // MARK: - 合成源码自证（契约不许空转）

    @Test func syntheticHealthySourcePasses() throws {
        let source = """
        enum FakeWorker {
            static func process() async {
                let indexed = await LibraryIndexer.shared.processExternalFile(result.finalURL)
                await MainActor.run {
                    if let oldStableId, let fresh = try? LibraryReads.track(path: result.finalURL.path) {
                        AppCoordinator.shared.followRenamedTrack(oldStableId: oldStableId, newTrack: fresh)
                    }
                    NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)
                }
            }
        }
        """
        let code = try AutoScrapeRefreshContract.codeOnly(source: source)
        #expect(AutoScrapeRefreshContract.postsLibraryNeedsRefresh(in: code))
        #expect(AutoScrapeRefreshContract.avoidsFullRescanSignal(in: code))
        #expect(AutoScrapeRefreshContract.postsRefreshOnMainActor(in: code))
        #expect(AutoScrapeRefreshContract.followsPlaybackContext(in: code))
    }

    @Test func syntheticOldBehaviourFails() throws {
        // 修复前的形状：后台只发 folderChanged、没人跟随播放上下文。
        let source = """
        enum FakeWorker {
            static func process() async {
                let indexed = await LibraryIndexer.shared.processExternalFile(result.finalURL)
                NotificationCenter.default.post(name: .libraryFolderContentChanged, object: nil)
            }
        }
        """
        let code = try AutoScrapeRefreshContract.codeOnly(source: source)
        #expect(!AutoScrapeRefreshContract.postsLibraryNeedsRefresh(in: code), "只发 folderChanged 必须判红")
        #expect(!AutoScrapeRefreshContract.avoidsFullRescanSignal(in: code), "回退到整库重扫必须判红")
        #expect(!AutoScrapeRefreshContract.postsRefreshOnMainActor(in: code))
        #expect(!AutoScrapeRefreshContract.followsPlaybackContext(in: code), "不跟随播放上下文必须判红")
    }

    @Test func syntheticRefreshOutsideMainActorFails() throws {
        // 订了刷新但顺序反了（先发通知再 hop 主线程）→ 不是「主线程收尾块里发」。
        let source = """
        enum FakeWorker {
            static func process() async {
                NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)
                await MainActor.run {
                    AppCoordinator.shared.followRenamedTrack(oldStableId: id, newTrack: fresh)
                }
            }
        }
        """
        let code = try AutoScrapeRefreshContract.codeOnly(source: source)
        #expect(!AutoScrapeRefreshContract.postsRefreshOnMainActor(in: code), "先发通知后 hop 主线程必须判红")
    }

    @Test func syntheticCommentedOutRefreshDoesNotCount() throws {
        let source = """
        enum FakeWorker {
            static func process() async {
                // await MainActor.run {
                //     AppCoordinator.shared.followRenamedTrack(oldStableId: id, newTrack: fresh)
                // }
                // NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)
            }
        }
        """
        let code = try AutoScrapeRefreshContract.codeOnly(source: source)
        #expect(!AutoScrapeRefreshContract.postsLibraryNeedsRefresh(in: code), "注释掉的刷新不算数")
        #expect(!AutoScrapeRefreshContract.followsPlaybackContext(in: code), "注释掉的跟随不算数")
    }

    @Test func syntheticSecondImplementationFails() throws {
        let source = """
        extension FakeView {
            @MainActor
            private func followRenamedTrackInPlayback(oldStableId: String, newTrack: Track) {
                appCoordinator.followRenamedTrack(oldStableId: oldStableId, newTrack: newTrack)
            }
        }
        """
        let code = try AutoScrapeRefreshContract.codeOnly(source: source)
        #expect(
            !AutoScrapeRefreshContract.hasNoSecondFollowImplementation(in: code),
            "出现私有 followRenamedTrackInPlayback = 两份实现并存，必须判红"
        )
    }

    // MARK: - fail-closed

    @Test func missingSourceFileFailsClosed() throws {
        #expect(throws: AutoScrapeRefreshContract.ContractError.self) {
            _ = try AutoScrapeRefreshContract.code(relativePath: "QQPlayer/Services/__no_such_file__.swift")
        }
    }
}
