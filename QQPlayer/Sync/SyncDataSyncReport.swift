//
//  SyncDataSyncReport.swift
//  QQPlayer
//
//  「同步数据」的状态 / 账目模型（2026-11-12 T1 从 SyncDataSyncCoordinator.swift 抽出）：
//  协调器文件已到 600 行结构预算上限（StructuralBudgetContractTests），账目模型是纯数据、
//  与编排逻辑无耦合，抽成独立文件；行为逐字不变（同文件同类型，仅迁移）。
//

import Foundation

/// 一次「同步数据」的阶段。
enum SyncDataSyncPhase: Equatable, Sendable {
    case idle
    /// 正在推送本端增量（帧 9）
    case pushing
    /// 已发起拉取（帧 8），等对端应答帧 9
    case pulling
    /// 收尾（成功或失败，见 report.failureMessage）
    case finished
}

/// 一次「同步数据」的账目（调用方只消费，不参与决策）。
///
/// ⚠️ 计数**不在这里维护**：唯一存储 = `tally`（`SyncOutcomeTally`，与 iOS 面板**同一类型**），
/// 下面这些读数是它的投影——面板读的名字不变（UI 零改动），但「谁来加这个数」全仓只剩
/// `tally.accumulate(…)` 一处（L6：失败/结果枚举化 + 两套账目收口）。
struct SyncDataSyncReport: Equatable, Sendable {
    /// **唯一**结果账目（见 `SyncRowOutcome` / `SyncOutcomeTally`）。
    var tally = SyncOutcomeTally()
    /// 本端 outbox 增量行数（含被过滤的 delete，口径同 `handlePull` 的计数）；空增量 = 0
    var pushedEntries: Int { tally.outboundEntries }
    /// 对端推来的帧 9 中实际落到本地业务表的行数
    var appliedEntries: Int { tally.appliedEntries }
    /// 对端推来的行里因本地缺歌而挂起的行数（歌到位后重放，不丢数据）
    var suspendedEntries: Int { tally.suspendedEntries }
    /// 拉取方向：对端推来的行里因**缺身份键**（两把键都拿不到）而**未落库**的行数
    /// （无法定位到本地歌曲 → 落库也永远不可见；见 `SyncEntryLocalization.unresolved`）
    var unresolvedEntries: Int { tally.unresolvedEntries }
    /// 拉取方向：对端推来的行里因**身份歧义**（第二身份相对路径命中多首本地曲目）
    /// 而未落库的行数（不落库、不挂起——选哪首都是猜）
    var ambiguousIdentityEntries: Int { tally.ambiguousIdentityEntries }
    /// 拉取方向：对端推来的 `playback_position` 行里**没有落到本地位置**的行数
    /// （跨端续播开关关 = 默认，或开关开但本端落点未接；见 `SyncChangeLogApplier`）。
    /// ⚠️ 这些行**不计入 `appliedEntries`**——「已应用」= 真的落了本地（INV-20）。
    var unsupportedEntries: Int { tally.unsupportedEntries }
    /// 拉取方向：对端推来的行里因**父行/被引用行不存在**而跳过的行数
    /// （歌单结构未到 / 引用歌本地查无；矩阵三级 #8：以前静默失败，现在必须可见）
    var skippedMissingParentEntries: Int { tally.skippedMissingParentEntries }
    /// 推送方向：本端发出去的行里缺身份键的条数（对端定位不了它们；含主动推增量
    /// 与应答对方拉取两个方向）
    var pushedMissingIdentityEntries: Int { tally.missingIdentityEntries }
    /// 对端推来的行里被忽略的 delete 行数（删除不跨端传播）
    var ignoredDeletes: Int { tally.ignoredDeletes }
    /// 对端推来的行里**应用失败**的行数（载荷解不开 / 落库抛错；不落库、计入缺口）
    var applyFailedEntries: Int { tally.applyFailedEntries }
    /// 失败原因的本地化 key（新路径；nil = 用 failureMessage 原文——旧文案保持不变）。
    var failureKey: String?
    /// 等待对端的提示 key（nil = 不在等待；UI 按 key 取文案）。
    var waitingKey: String?
    /// 本次拉取已发出的 change_log_pull 次数（1 = 只发了首次；>1 = 同轮内重发过）。
    var pullAttempts: Int = 0
    /// 已发出的 pull 帧总数（含同轮重发；SYNCDIAG pullSent 的唯一出处）。
    var pullSent: Int = 0
    /// 已收到的应答批次数（含迟到 / 重复；SYNCDIAG pullRecv）。
    var pullRecv: Int = 0
    /// 收尾后才到达的应答批次数（INV-36：照常累加账目，只是不再二次收尾）。
    var pullLate: Int = 0
    /// 重复批次数（已应用过的批重复到达；不重复应用，只记账）。
    var pullDuplicates: Int = 0
    /// 对端 notReady 的原因（nil = 旧端未带 / 未知）。
    var notReadyReason: SyncChangeLogNotReadyReason?
    /// 下一次自动重试的倒计时（秒；nil = 不在退避中）。面板据此显示「X 秒后自动重试」。
    var retryCountdownSeconds: Int?
    /// 失败原因（nil = 未失败；「缺 peerID / 推失败 / 发拉取失败 / 对端无应答」/ cancelled）
    var failureMessage: String?
    /// 是否已收尾（与 `phase == .finished` 同义；冗余存一份便于调用方只读 report）
    var isFinished: Bool = false
}
