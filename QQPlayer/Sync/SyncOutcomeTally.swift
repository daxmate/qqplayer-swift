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
//  发出行数」（覆盖写，不累加），其余都是累加；两端面板的**汇总**数字 / 行序 / 颜色 /
//  hint 触发条件一律不变（UI 读的仍是同名属性）。
//
//  ⚠️ 二维分桶（2026-09-15，INV-18 剩余项）：槽位从「一个结果一个整数」升级为
//  「一个结果 × 一个实体」，**总数仍是派生值**（未归属 + 各实体桶之和）。有计划的行为
//  变化只有一处：两端面板新增「按实体披露」的明细行（> 0 才出现，正常实体不占行）；
//  汇总行 / 旧读数名 / 收尾语义（哪个回调到达算「对端已应答」）逐字未变。
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
    /// 远端行因**缺身份键**（两把键都拿不到）未定位 → 不落库、不挂起。
    case unresolved
    /// 远端行的**第二身份（曲库相对路径）命中多首本地曲目**（身份歧义）→ 不落库、
    /// 不挂起（选哪首都是猜），只计数披露。
    case ambiguousIdentity
    /// 远端行因**父行 / 被引用行不存在**而跳过（歌单结构未到 / 引用歌本地查无）。
    case skippedMissingParent
    /// 远端 `playback_position` 行**没落到本地位置**（跨端续播开关关 = 默认 / 落点未接受）。
    case unsupported
    /// 本端发出去的行里**缺身份键**的条数（对端定位不了；推增量与应答拉取两个方向）。
    case missingIdentity
    /// 远端行是**被忽略的 delete**（删除不跨端传播）。
    case ignoredDelete
    /// 远端行**应用失败**（载荷解不开 / 落库抛错）——按**实体**计数上屏（2026-09-15
    /// INV-18 按实体披露包）。此前这类失败只进日志：对端面板看不到「是歌单结构还是
    /// 收藏出的问题」（歌单级失败尤其如此，INV-18 的 C 格）。批次中断语义不变。
    case applyFailed
}

/// 一个 **(实体, 计数)** 分组：某类结果里某条实体占多少条。
///
/// 用途 = 账目 → 面板的**唯一**中转形状：会话层按它上报（一类结果可能横跨多个实体），
/// 面板按它披露。`entity` 非空——「不属任何实体」的计数不进分组（见 `SyncOutcomeSlot`）。
struct SyncEntityOutcomeCount: Equatable, Sendable {
    let entity: SyncChangeEntity
    let count: Int
}

/// 一个结果类别的**计数槽**：按实体分桶存，总数**派生**。
///
/// 为什么不是「一个总量字段 + 一个 `[SyncChangeEntity: Int]`」：两处各自累加必然漂移
/// （改一处漏一处 → 面板总数与明细对不上）。这里总量是**算出来的**。
struct SyncOutcomeSlot: Equatable, Sendable {
    /// 不属任何实体的计数（批次事实 / 调用方未申报实体）。
    private var unattributedCount = 0
    /// 按实体分桶（实体词表只有 A–E 五条，字典足够小）。
    private var entityCounts: [SyncChangeEntity: Int] = [:]

    /// 总数 = 未归属 + 各实体桶之和（派生，不另存）。
    var total: Int { unattributedCount + entityCounts.values.reduce(0, +) }

    /// 累加到一个桶（`entity == nil` = 未归属桶）。
    mutating func add(entity: SyncChangeEntity?, count: Int) {
        guard let entity else {
            unattributedCount += count
            return
        }
        entityCounts[entity, default: 0] += count
    }

    /// 读一个桶（`entity == nil` = 未归属桶）。
    func count(entity: SyncChangeEntity?) -> Int {
        guard let entity else { return unattributedCount }
        return entityCounts[entity] ?? 0
    }

    /// **有计数的实体桶**（> 0），顺序 = **注册表声明顺序**（`SyncEntityRegistry.entityOrder`
    /// 是实体词表的唯一声明处）——分桶维度与展示顺序都从注册表来，本文件不手写实体名单。
    var nonZeroEntityCounts: [SyncEntityOutcomeCount] {
        SyncEntityRegistry.entityOrder.compactMap { entity in
            guard let count = entityCounts[entity], count > 0 else { return nil }
            return SyncEntityOutcomeCount(entity: entity, count: count)
        }
    }
}

/// 结果计数的**唯一**存储：**(实体, 结果) 二维分桶**。
///
/// 两端账目都**持有**它（`var tally = SyncOutcomeTally()`），读数经下面的访问器暴露
/// ——面板读的名字仍是收口前那些（汇总行零改动），新增的明细行走唯一投影
/// `SyncEntityOutcomeDisclosure`。
///
/// 两个维度：
/// - **结果**（`SyncRowOutcome`）= 一条远端行 / 一个键被怎么处置；
/// - **实体**（`SyncChangeEntity`）= 这条处置属于哪条同步实体（A–E）；`nil` = 不属任何
///   实体的批次事实（如出站行数）或调用方未申报实体（归入「未归属」桶，仍进总数）。
struct SyncOutcomeTally: Equatable, Sendable {
    private var appliedCounts = SyncOutcomeSlot()
    private var suspendedCounts = SyncOutcomeSlot()
    private var outboundCounts = SyncOutcomeSlot()
    private var unresolvedCounts = SyncOutcomeSlot()
    private var ambiguousIdentityCounts = SyncOutcomeSlot()
    private var skippedMissingParentCounts = SyncOutcomeSlot()
    private var unsupportedCounts = SyncOutcomeSlot()
    private var missingIdentityCounts = SyncOutcomeSlot()
    private var ignoredDeleteCounts = SyncOutcomeSlot()
    private var applyFailedCounts = SyncOutcomeSlot()

    /// 累加一条（或一批）结果；`entity` = 这条处置属于哪条实体（nil = 未归属）。
    ///
    /// `switch` **无 `default`**：新增 `SyncRowOutcome` 类别时编译器在这里强制给槽位。
    mutating func accumulate(_ outcome: SyncRowOutcome, entity: SyncChangeEntity? = nil, count: Int = 1) {
        switch outcome {
        case .applied: appliedCounts.add(entity: entity, count: count)
        case .suspended: suspendedCounts.add(entity: entity, count: count)
        case .outbound: outboundCounts.add(entity: entity, count: count)
        case .unresolved: unresolvedCounts.add(entity: entity, count: count)
        case .ambiguousIdentity: ambiguousIdentityCounts.add(entity: entity, count: count)
        case .skippedMissingParent: skippedMissingParentCounts.add(entity: entity, count: count)
        case .unsupported: unsupportedCounts.add(entity: entity, count: count)
        case .missingIdentity: missingIdentityCounts.add(entity: entity, count: count)
        case .ignoredDelete: ignoredDeleteCounts.add(entity: entity, count: count)
        case .applyFailed: applyFailedCounts.add(entity: entity, count: count)
        }
    }

    /// **覆盖写**一个槽位（口径 = 「最近一批」的批次事实，目前只用于 `.outbound`；
    /// 其余类别是累加语义）。实现 = 「补差额再累加」，与 `accumulate` 共用同一套槽位，
    /// 不新开第二处写入口（否则「怎么改计数」又变成多处手工对齐）。
    /// 覆盖粒度 = **该实体桶**；调用方不给实体时覆盖「未归属」桶（`.outbound` 正是不分
    /// 实体的批次事实）。
    mutating func overwrite(_ outcome: SyncRowOutcome, entity: SyncChangeEntity? = nil, with count: Int) {
        accumulate(outcome, entity: entity, count: count - self.count(for: outcome, entity: entity))
    }

    /// 读一个结果的**总数**（= 未归属 + 各实体桶之和；派生，不另存一份）。
    ///
    /// `switch` **无 `default`**，同 `accumulate`：新增类别必须在这里给出读数。
    func count(for outcome: SyncRowOutcome) -> Int {
        switch outcome {
        case .applied: return appliedCounts.total
        case .suspended: return suspendedCounts.total
        case .outbound: return outboundCounts.total
        case .unresolved: return unresolvedCounts.total
        case .ambiguousIdentity: return ambiguousIdentityCounts.total
        case .skippedMissingParent: return skippedMissingParentCounts.total
        case .unsupported: return unsupportedCounts.total
        case .missingIdentity: return missingIdentityCounts.total
        case .ignoredDelete: return ignoredDeleteCounts.total
        case .applyFailed: return applyFailedCounts.total
        }
    }

    /// 读**一个实体桶**的计数（`entity == nil` = 未归属桶）。
    ///
    /// `switch` **无 `default`**：新增类别必须在这里表态。
    func count(for outcome: SyncRowOutcome, entity: SyncChangeEntity?) -> Int {
        switch outcome {
        case .applied: return appliedCounts.count(entity: entity)
        case .suspended: return suspendedCounts.count(entity: entity)
        case .outbound: return outboundCounts.count(entity: entity)
        case .unresolved: return unresolvedCounts.count(entity: entity)
        case .ambiguousIdentity: return ambiguousIdentityCounts.count(entity: entity)
        case .skippedMissingParent: return skippedMissingParentCounts.count(entity: entity)
        case .unsupported: return unsupportedCounts.count(entity: entity)
        case .missingIdentity: return missingIdentityCounts.count(entity: entity)
        case .ignoredDelete: return ignoredDeleteCounts.count(entity: entity)
        case .applyFailed: return applyFailedCounts.count(entity: entity)
        }
    }

    /// 一类结果的**实体分组**（只出 > 0 的桶；顺序 = 注册表实体顺序）。
    /// 会话层按它上报、面板按它披露（同一个形状，不各自造一份）。
    ///
    /// `switch` **无 `default`**：新增类别必须在这里表态。
    func entityGroups(for outcome: SyncRowOutcome) -> [SyncEntityOutcomeCount] {
        switch outcome {
        case .applied: return appliedCounts.nonZeroEntityCounts
        case .suspended: return suspendedCounts.nonZeroEntityCounts
        case .outbound: return outboundCounts.nonZeroEntityCounts
        case .unresolved: return unresolvedCounts.nonZeroEntityCounts
        case .ambiguousIdentity: return ambiguousIdentityCounts.nonZeroEntityCounts
        case .skippedMissingParent: return skippedMissingParentCounts.nonZeroEntityCounts
        case .unsupported: return unsupportedCounts.nonZeroEntityCounts
        case .missingIdentity: return missingIdentityCounts.nonZeroEntityCounts
        case .ignoredDelete: return ignoredDeleteCounts.nonZeroEntityCounts
        case .applyFailed: return applyFailedCounts.nonZeroEntityCounts
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
    /// 身份键歧义（第二身份相对路径命中多行）→ 未落库、未挂起的条数。
    var ambiguousIdentityEntries: Int { count(for: .ambiguousIdentity) }
    /// 父行 / 被引用行不存在而跳过的条数。
    var skippedMissingParentEntries: Int { count(for: .skippedMissingParent) }
    /// 播放位置行没落到本地位置的条数。
    var unsupportedEntries: Int { count(for: .unsupported) }
    /// 本端发出行里缺身份键的条数（对端定位不了）。
    var missingIdentityEntries: Int { count(for: .missingIdentity) }
    /// 被忽略的远端 delete 条数（删除不跨端传播）。
    var ignoredDeletes: Int { count(for: .ignoredDelete) }
    /// 应用失败的远端行条数（载荷解不开 / 落库抛错；按实体披露）。
    var applyFailedEntries: Int { count(for: .applyFailed) }
}
