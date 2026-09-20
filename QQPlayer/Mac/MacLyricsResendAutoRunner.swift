//
//  MacLyricsResendAutoRunner.swift
//  QQPlayer
//
//  F2（2026-09-16）对齐歌词**补发通道**的 Mac 侧自动触发（QQPlayerMac target only）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  为什么放在 `QQPlayer/Mac/`
//  ════════════════════════════════════════════════════════════════════════════
//  发起方恒为桌面端（docs/lan-sync-design.md §6.1）：移动端纯被动，所以「补发」只能由
//  Mac 发起。本文件只是**触发器 + 事实申报**（曲库根 / DB / 歌词库一律复用
//  `MacSyncCoordinatorFactory` 同源的装配口径）；纯逻辑在共享 Core 的
//  `SyncLyricsResend.swift` / `SyncLyricsResendController.swift`（有单测）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  触发时机（契约 F2「触发」列）
//  ════════════════════════════════════════════════════════════════════════════
//  **连接就绪 → 自动跑一轮**（与「同步数据」的自动轮同口径：面板没打开也要跑）；
//  一次连接自动一次（`SyncLyricsResendAutoRunDecision`），重连会重新允许。
//
//  这一轮补的是缺口 ①：此前歌词只在**整轮文件同步**里当普通文件走，新对齐的歌词要等
//  用户在面板上手动「开始同步」；现在连接一就绪就自动对账 `@lyrics/*`（两个方向）。
//
//  **前置门**（唯一判定 = `IndexingGate.isReadyForChangeLogSync`，与 changeLog 同步
//  同一道）：曲库索引未到终态时 track 表正在重建 → 本端「这首歌在不在」的事实不稳定，
//  此刻对账会把「暂时查不到」当成「本端没有」→ 拉回来必然被 `SyncLyricsReceiver`
//  判 orphan 丢弃（面板「歌词丢弃 N」变噪音）。所以门未开时**不跑**，订阅终态信号
//  等终态到了再补跑（与 iOS `IOSPassiveSyncCenter.observeIndexingTerminalState` 同形）。
//
//  ⚠️ 本文件不做单测（`QQPlayer/Mac/**` 被 iOS target 排除，仓库也无 macOS 单测 target）：
//  纯逻辑（计划 / 状态机 / 判定）全部在共享 Core 并被 QQPlayerTests 覆盖。
//

import Combine
import Foundation
import Observation

/// 最近一轮补发的事实（面板只读；由 runner 在这一轮收尾时写入）。
///
/// 面板不自己算任何数字：行与文案 key 由唯一投影 `SyncEntityOutcomeDisclosure.lyricsRows`
/// 给出，本 store 只负责把**账目**搬到 UI 能取到的地方（与 `SyncWiringFactsStore` 同风格）。
/// 面板不自己算任何数字：行与文案 key 由唯一投影 `SyncEntityOutcomeDisclosure.lyricsRows`
/// 给出，本 store 只负责把**账目**搬到 UI 能取到的地方（与 `SyncWiringFactsStore` 同风格）。
///
/// 2026-09-20 批 6-8：`ObservableObject` → `@Observable`（判定依据：唯一 `@Published` 是
/// `lastSummary`，**全仓 0 处跨文件订阅**（无 `$lastSummary` / `objectWillChange` 消费点），
/// 写入方 `MacLyricsResendAutoRunner` 只是写入不观察 ⇒ 与 `SyncWiringFactsStore` 同款，
/// 只需视图侧改环境注入 + 按属性追踪）。
@MainActor
@Observable
final class MacLyricsResendFactsStore {
    static let shared = MacLyricsResendFactsStore()

    /// 最近一轮补发的账目（nil = 本次连接还没跑过 / 已清）。
    private(set) var lastSummary: SyncLyricsResendSummary?

    private init() {}

    func record(_ summary: SyncLyricsResendSummary) {
        lastSummary = summary
    }

    /// 会话拆除 / 断开：本轮事实清空（不是缺口——没有会话就谈不上补发）。
    func clear() {
        lastSummary = nil
    }
}

/// 一轮补发的自动触发（Mac；`@MainActor` 与 `MacDataSyncAutoRunner` 同口径：
/// 调用点都在主线程的会话回调里，判定又必须摸 `IndexingGate`（@MainActor））。
@MainActor
final class MacLyricsResendAutoRunner {
    static let shared = MacLyricsResendAutoRunner()

    private var controller: SyncLyricsResendController?
    private var didAutoRunForCurrentConnection = false
    /// 待跑的会话（前置门未开时留着，终态一到补跑）
    private var pendingSession: SyncPeerSession?
    private var pendingLibraryRoot: URL?
    private var terminalStateCancellable: AnyCancellable?

    private init() {}

    /// 会话就绪：自动跑一轮补发（一次连接一次；前置门未开则等终态补跑）。
    func sessionDidBecomeReady(_ session: SyncPeerSession, libraryRoot: URL) {
        pendingSession = session
        pendingLibraryRoot = libraryRoot
        startIfPossible()
    }

    /// 真跑一轮（幂等：已跑过 / 无待跑会话 / 会话不再 ready → 什么都不做）。
    private func startIfPossible() {
        guard let session = pendingSession, let libraryRoot = pendingLibraryRoot, session.isReady else { return }
        guard SyncLyricsResendAutoRunDecision.shouldStart(
            isConnected: true,
            hasSession: true,
            didAutoRunForCurrentConnection: didAutoRunForCurrentConnection
        ) else { return }
        guard IndexingGate.isReadyForChangeLogSync(LibraryIndexer.shared) else {
            print("⏸️ MacLyricsResendAutoRunner: 曲库索引未到终态，等终态后补跑歌词补发")
            observeIndexingTerminalState()
            return
        }
        didAutoRunForCurrentConnection = true

        let database = DatabaseManager.shared
        let lyricsMapping = SyncLyricsContentMapping.live(database: database, libraryRoot: libraryRoot)
        let descriptor = SyncLocalLibraryDescriptor.live(
            libraryRoot: libraryRoot,
            database: database,
            lyricsMapping: lyricsMapping
        )
        let controller = SyncLyricsResendController(
            session: session,
            descriptor: descriptor
        )
        self.controller = controller
        controller.onStateChange = { [weak self] state in
            guard case let .done(summary) = state else { return }
            print("ℹ️ MacLyricsResendAutoRunner: 歌词补发收尾（\(summary.logLine)）")
            Task { @MainActor in
                MacLyricsResendFactsStore.shared.record(summary)
                self?.controller = nil
            }
        }
        print("ℹ️ MacLyricsResendAutoRunner: 连接就绪 → 自动跑一轮对齐歌词补发")
        do {
            try controller.start()
        } catch {
            print("⚠️ MacLyricsResendAutoRunner: 启动失败 \(error)")
            self.controller = nil
        }
    }

    /// 订阅「曲库索引终态」事实：终态一到重走唯一判定入口（幂等）。
    private func observeIndexingTerminalState() {
        guard terminalStateCancellable == nil else { return }
        terminalStateCancellable = LibraryIndexer.shared.indexingTerminalStatePublisher
            .sink { [weak self] in
                Task { @MainActor in self?.startIfPossible() }
            }
    }

    /// 会话下线：标记归位（下次连上再自动跑一轮）+ 取消未收尾的轮 + 清面板事实。
    func sessionDidClose() {
        didAutoRunForCurrentConnection = false
        pendingSession = nil
        pendingLibraryRoot = nil
        terminalStateCancellable = nil
        controller?.cancel()
        controller = nil
        MacLyricsResendFactsStore.shared.clear()
    }
}
