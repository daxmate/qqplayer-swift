//
//  SyncOutcomeTally.swift
//  QQPlayer
//
//  L6（2026-09-15）失败 / 结果**枚举化 + 计数派生 + 两套账目收口**（行为零变化）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  为什么要这一层
//  ════════════════════════════════════════════════════════════════════════════
//  「同一批结果」此前在生产码里有**两套结构**：Mac 的 `SyncDataSyncReport`
//  （`Sync/SyncDataSyncCoordinator.swift`）与 iOS 的 `IOSPassiveDataSyncSummary`
//  （`Services/IOSPassiveSyncCenter.swift`）各自声明一遍分类计数。每类结果要
//  「产生 → 累加 → 映射 → 上屏」四处手工对齐 —— 漏一处即静默：数字算了没上屏
//  （iOS 侧只进 print）、两端口径悄悄漂移、新增类别时某端漏处理都不报错。
//
//  这里把这条链收成两件事（其余文件只消费）：
//    ① `SyncRowOutcome` = 「一条远端行 / 一个键被怎么处置」的**穷尽词表**；
//    ② `SyncOutcomeTally` = 结果计数的**唯一**存储（两端账目都持有它，不再自建）。
//
//  ⚠️ 形状契约（`SyncOutcomeContractTests`）：本文件是生产码里**唯一**允许声明或改写
//  结果计数的文件（`<槽位> +=` / `<槽位> =` 只准出现在这里）；别处只准
//  `tally.accumulate(…)` / `tally.overwrite(…)` / 读访问器。
//
//  ⚠️ 行为零变化（L6 硬要求）：槽位口径与收口前逐字一致——`.outbound` 是「最近一批
//  发出行数」（覆盖写，不累加），其余都是累加；两端面板的数字 / 行序 / 颜色 / hint
//  触发条件一律不变（UI 读的仍是同名属性）。
//

import Foundation

/// 一条远端行 / 一个键在一次「同步数据」（帧 8/9）里的**处置结果**（穷尽枚举）。
///
/// 两端账目（Mac `SyncDataSyncReport` / iOS `IOSPassiveDataSyncSummary`）共用这一份词表：
/// 新增类别时 `accumulate` / `count(for:)` 的 `switch`（都**无 `default`**）编译不过，
/// 不会出现「某端漏处理而静默」。
enum SyncRowOutcome: CaseIterable, Hashable, Sendable {
    /// 远端行本地化后**真的落进本地业务表**的条数（丢弃 / 跳过 / 未支持都不算，INV-20）。
    case applied
    /// 远端行因**本地缺歌**而挂起（歌到位后重放，不丢数据）。
    case suspended
    /// 本端**发出**的 outbox 增量行数（Mac 主动推增量 / iOS 应答对端拉取；含被过滤的 delete）。
    /// 这是**批次事实**（本端发了多少行），不是远端行的处置：口径 = 「最近一批」，多批
    /// **覆盖写**不累加（见 `overwrite`）。
    case outbound
    /// 远端行因**缺身份键**（`content_hash` nil/空）未定位 → 不落库、不挂起。
    case unresolved
    /// 远端行因**父行 / 被引用行不存在**而跳过（歌单结构未到 / 引用歌本地查无）。
    case skippedMissingParent
    /// 远端 `playback_position` 行**没落到本地位置**（跨端续播开关关 = 默认 / 落点未接受）。
    case unsupported
    /// 本端发出去的行里**缺身份键**的条数（对端定位不了；推增量与应答拉取两个方向）。
    case missingIdentity
    /// 远端行是**被忽略的 delete**（删除不跨端传播）。
    case ignoredDelete
}

/// 结果计数的**唯一**存储：一个 `SyncRowOutcome` 一个槽位。
///
/// 两端账目都**持有**它（`var tally = SyncOutcomeTally()`），读数经下面的访问器暴露
/// ——所以面板读的仍是要收口前那些属性名，UI 文件零改动。
struct SyncOutcomeTally: Equatable, Sendable {
    private var appliedCount = 0
    private var suspendedCount = 0
    private var outboundCount = 0
    private var unresolvedCount = 0
    private var skippedMissingParentCount = 0
    private var unsupportedCount = 0
    private var missingIdentityCount = 0
    private var ignoredDeleteCount = 0

    /// 累加一条（或一批）结果。
    ///
    /// `switch` **无 `default`**：新增 `SyncRowOutcome` 类别时编译器在这里强制给槽位。
    mutating func accumulate(_ outcome: SyncRowOutcome, count: Int = 1) {
        switch outcome {
        case .applied: appliedCount += count
        case .suspended: suspendedCount += count
        case .outbound: outboundCount += count
        case .unresolved: unresolvedCount += count
        case .skippedMissingParent: skippedMissingParentCount += count
        case .unsupported: unsupportedCount += count
        case .missingIdentity: missingIdentityCount += count
        case .ignoredDelete: ignoredDeleteCount += count
        }
    }

    /// **覆盖写**一个槽位（口径 = 「最近一批」的批次事实，目前只用于 `.outbound`；
    /// 其余类别是累加语义）。实现 = 「补差额再累加」，与 `accumulate` 共用同一套槽位，
    /// 不新开第二处写入口（否则「怎么改计数」又变成多处手工对齐）。
    mutating func overwrite(_ outcome: SyncRowOutcome, with count: Int) {
        accumulate(outcome, count: count - self.count(for: outcome))
    }

    /// 读一个槽位。
    ///
    /// `switch` **无 `default`**，同 `accumulate`：新增类别必须在这里给出读数。
    func count(for outcome: SyncRowOutcome) -> Int {
        switch outcome {
        case .applied: return appliedCount
        case .suspended: return suspendedCount
        case .outbound: return outboundCount
        case .unresolved: return unresolvedCount
        case .skippedMissingParent: return skippedMissingParentCount
        case .unsupported: return unsupportedCount
        case .missingIdentity: return missingIdentityCount
        case .ignoredDelete: return ignoredDeleteCount
        }
    }
}

// MARK: - 读数（口径与收口前逐字一致）

extension SyncOutcomeTally {
    /// 远端行真的落进本地业务表的条数（「已应用」= 真的落库，INV-20）。
    var appliedEntries: Int { count(for: .applied) }
    /// 本地缺歌挂起的条数（歌到位后重放）。
    var suspendedEntries: Int { count(for: .suspended) }
    /// 本端发出的 outbox 增量行数（最近一批；含被过滤的 delete）。
    var outboundEntries: Int { count(for: .outbound) }
    /// 缺身份键 → 未定位、未落库的条数。
    var unresolvedEntries: Int { count(for: .unresolved) }
    /// 父行 / 被引用行不存在而跳过的条数。
    var skippedMissingParentEntries: Int { count(for: .skippedMissingParent) }
    /// 播放位置行没落到本地位置的条数。
    var unsupportedEntries: Int { count(for: .unsupported) }
    /// 本端发出行里缺身份键的条数（对端定位不了）。
    var missingIdentityEntries: Int { count(for: .missingIdentity) }
    /// 被忽略的远端 delete 条数（删除不跨端传播）。
    var ignoredDeletes: Int { count(for: .ignoredDelete) }
}
