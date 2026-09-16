//
//  SyncLyricsResend.swift
//  QQPlayer
//
//  F2（2026-09-16）对齐歌词**补发通道**的纯逻辑：对账计划 + 账目形状 + 状态机。
//
//  ════════════════════════════════════════════════════════════════════════════
//  契约（docs/sync-contract.md §2 F2 对齐歌词）
//  ════════════════════════════════════════════════════════════════════════════
//  | 用户可见承诺 | 一端对齐好的歌词，随歌到达另一端 |
//  | 权威端与冲突 | **只补不覆盖**（对端已有对齐结果则保留对端的） |
//  | 触发 | 随歌传输（内容通道）+ **补发通道** |
//  | 失败披露 | 歌词丢弃必须计数上屏 |
//
//  三条缺口（本文件 + `SyncLyricsResendController` + `SyncLyricsReceiver` 一起收口）：
//  ① **触发耦合**：歌词原先只在「整轮文件同步」里当普通文件走（`localEntries()` =
//     曲库 + `descriptor.lyricsEntries()`）→ 新对齐的歌词要等用户下次手动「开始同步」。
//  ② **丢弃无补发**：对端收歌词时歌还没入库 → 直接丢，不登记待补、歌到位也不补。
//  ③ **「只补不覆盖」未实现**：对账器对「同路径内容不同」一律判需传（= 按 G 覆盖）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  方向：**单向（桌面 → 移动）**，不做双向补发
//  ════════════════════════════════════════════════════════════════════════════
//  用户 2026-09-15 拍板、`docs/sync-matrix.md` F① 已记：AI 对齐只在桌面端做，
//  移动端**不生成**对齐歌词 → 补发轮只跑推送方向（手机侧无源可补）。
//  反方向（把设备上的歌词取回本端）保持**显式例外**：用户在面板上选「从设备取回」
//  才发生，走既有 `SyncLibraryPullController`——本文件不新增自动回流。
//
//  ⚠️ 不新增帧、不给帧加字段：线上仍只有既有的 `@lyrics/{歌曲 content_hash}.json`
//  条目；传输复用帧 10/11（manifest）、14（推送声明）、4/5/6（停等传输）。
//  本文件是**纯逻辑**（零 IO / 零平台依赖），可无模拟器直编。
//

import Foundation

// MARK: - 对账计划

/// 一轮补发的对账计划（纯值）。
struct SyncLyricsResendPlan: Equatable, Sendable {
    /// 本端有、对端缺、且**歌在对端** → 该推送的歌词条目（按 wire 路径升序）
    var toPush: [ManifestEntry] = []
    /// 两端都有的 wire 路径（升序）。**内容不同也在这**：F2 只补不覆盖，同路径
    /// 两侧都有就谁也不动（对端保留对端的、本端保留本端的）。
    var present: [String] = []

    /// 本轮无可补内容（幂等重跑判据）。
    var isIdle: Bool { toPush.isEmpty }

    /// 本轮待补条目数。
    var pendingCount: Int { toPush.count }
}

/// 补发方向对账（纯函数）。
///
/// 语义**只在歌词命名空间内**，且与既有两个对账器有一处**刻意不同**：
/// `SyncManifestReconciler` / `SyncLibraryPushPlanner` 都按 `contentMatches`（内容指纹）
/// 判「是否需传」；本计划**只比有无**——因为 F2 的冲突规则是「只补不覆盖」，
/// 同路径两侧都有 = 谁也别动（内容不同也不传）。这是**契约差异**，不是实现疏漏：
/// 合成一个函数会让两条规则互相污染（改 A 就悄悄改了 B）。
///
/// **「歌在对端」是硬前置**：歌词是依附歌曲的内容，对端没有那首歌时推过去只会被
/// 丢弃（`SyncLyricsReceiver.orphan`）→ 面板「歌词丢弃 N」变噪音。所以推送只在
/// **对端 manifest 里出现该歌内容指纹**（音频条目）时进行；歌没到位时由用户下一次
/// 整轮同步（歌 + 歌词一起）负责，补发轮不抢跑。
enum SyncLyricsResendPlanner {
    /// - Parameters:
    ///   - localLyrics: 本端歌词条目（`descriptor.lyricsEntries()`；已是歌词命名空间）
    ///   - remoteEntries: 对端 manifest 全量条目（含音频，用于判「歌在对端」）
    static func plan(
        localLyrics: [ManifestEntry],
        remoteEntries: [ManifestEntry]
    ) -> SyncLyricsResendPlan {
        let remoteLyrics = lyricsEntries(remoteEntries)
        let localPaths = Set(localLyrics.map(\.relativePath))
        let remotePaths = Set(remoteLyrics.map(\.relativePath))
        // 对端持有的**歌曲**内容指纹（音频条目的 contentHash 就是歌曲指纹；歌词条目的
        // contentHash 是歌词文件自身的哈希，故必须排除歌词命名空间）。
        let remoteSongHashes = Set(
            remoteEntries
                .filter { !SyncLyricsNamespace.isLyricsPath($0.relativePath) }
                .compactMap(\.contentHash)
                .filter { !$0.isEmpty }
        )

        var toPush: [ManifestEntry] = []
        for entry in localLyrics where !remotePaths.contains(entry.relativePath) {
            guard let songHash = SyncLyricsNamespace.songContentHash(fromWirePath: entry.relativePath),
                  remoteSongHashes.contains(songHash)
            else { continue }
            toPush.append(entry)
        }

        return SyncLyricsResendPlan(
            toPush: toPush.sorted { $0.relativePath < $1.relativePath },
            present: localPaths.intersection(remotePaths).sorted()
        )
    }

    /// 只取歌词命名空间条目（曲库音频永不进补发通道）。
    static func lyricsEntries(_ entries: [ManifestEntry]) -> [ManifestEntry] {
        entries.filter { SyncLyricsNamespace.isLyricsPath($0.relativePath) }
    }
}

// MARK: - 账目

/// 一轮补发的账目（诊断 / 面板披露 / 测试用）。
///
/// 「待补」（`pendingResend`）是这一轮对缺口 ② 的回答：**没送到的不许悄悄消失**——
/// 本轮未确认送达的条目全部进这里并上屏，下一次机会（重连 / 下一轮）重新对账再送。
struct SyncLyricsResendSummary: Equatable, Sendable {
    /// 计划推送的 wire 路径（升序）
    var plannedPush: [String] = []
    /// 对端**确认送达**的 wire 路径（来自推送子轮的 `completed`）
    var pushed: [String] = []
    /// 推送方向失败
    var failed: [SyncPushFailure] = []
    /// **待补**：本轮未确认送达的 wire 路径（升序）→ 下次机会重试（缺口 ②）
    var pendingResend: [String] = []
    /// 两端都有的歌词条数（只补不覆盖 → 不动；数字进面板/日志）
    var presentCount: Int = 0

    /// 本轮一个字都没动（计划为空）。
    var didNothing: Bool { plannedPush.isEmpty }

    /// 本轮净补上的条数。
    var deliveredCount: Int { pushed.count }

    /// 日志一行（自动轮收尾用）。
    var logLine: String {
        "计划推=\(plannedPush.count) 送达=\(deliveredCount) 待补=\(pendingResend.count)"
            + " 两侧都有=\(presentCount) 失败=\(failed.count)"
    }
}

// MARK: - 状态机（纯逻辑，可单测）

/// 一轮补发的进度状态。
enum SyncLyricsResendState: Equatable, Sendable {
    case idle
    /// 已请求对端 manifest，等应答（对账中）
    case planning
    /// 推送子轮进行中
    case pushing
    case done(SyncLyricsResendSummary)
    case failed(String)
}

/// 状态迁移合法性（纯逻辑，可单测）。
enum SyncLyricsResendStateMachine {
    static func canTransition(from: SyncLyricsResendState, to: SyncLyricsResendState) -> Bool {
        switch (from, to) {
        case (.idle, .planning): return true
        // 对账后：直接收尾（无可补）/ 进推送
        case (.planning, .pushing), (.planning, .done): return true
        case (.pushing, .done): return true
        default:
            if case .failed = to {
                return !isTerminal(from)
            }
            return false
        }
    }

    static func isTerminal(_ state: SyncLyricsResendState) -> Bool {
        switch state {
        case .done, .failed: return true
        default: return false
        }
    }
}

// MARK: - 自动轮判定（纯逻辑，可单测）

/// 「连接就绪要不要自动跑一轮补发」判定（纯函数）。
///
/// 口径与 `SyncDataAutoRunDecision` 一致：已连接 + 有会话 + **本次连接还没自动跑过**。
/// 一次连接自动一次（重连由调用方清标记 → 再跑一轮），避免断线抖动时反复起轮。
enum SyncLyricsResendAutoRunDecision {
    static func shouldStart(
        isConnected: Bool,
        hasSession: Bool,
        didAutoRunForCurrentConnection: Bool
    ) -> Bool {
        guard isConnected, hasSession, !didAutoRunForCurrentConnection else { return false }
        return true
    }
}
