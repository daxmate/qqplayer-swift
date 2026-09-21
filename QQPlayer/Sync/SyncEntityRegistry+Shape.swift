//
//  SyncEntityRegistry+Shape.swift
//  QQPlayer
//
//  实体登记表的「形状」类型：同步承诺等级 / 通道 / 本地真值 / 装配点与登记项（自 SyncEntityRegistry.swift 拆出）。
//  同族：SyncEntityRegistry.swift（唯一声明处：实体清单字面量 + 平台常量）、
//        SyncEntityRegistry+Assembly.swift（共享装配点与派生访问器）。
//

import Foundation

// MARK: - 登记的形状

/// 实体在跨端同步里的「同步承诺」等级。
/// 依据 `docs/sync-contract.md` §0.2：**「不承诺」也是承诺**——契约写明「不做」的，
/// 任何人不得实现它（防止再出现「承诺了做不到」或「没承诺却偷偷做」）。
enum SyncEntitySyncMode: Equatable, Sendable {
    /// 无条件承诺：连接就绪自动跑 + 面板手动可再跑。
    case synced
    /// 有条件承诺：由用户开关门控（开关关 = 零出站零入站，见 INV-26）。
    case gatedBySetting(reason: String)
    /// 不承诺（契约明写「不做」）：只登记、不实现，理由必须写清。
    case notSynced(reason: String)

    /// 是否「不承诺」（CI 用它断言这类实体不得出现在任何同步实现点上）。
    var isNotSynced: Bool {
        if case .notSynced = self { return true }
        return false
    }

    /// 是否进 `SyncChangeEntity.v1Synced`（v1 **无条件**同步清单）。
    /// `gatedBySetting` 不进：门控实体是否同步取决于开关，不是无条件承诺。
    var isListedInV1Synced: Bool { self == .synced }
}

/// 实体的载荷走哪条通道。
enum SyncEntityChannel: Equatable, Sendable {
    /// 变更日志通道（帧 8/9，`sync_outbox` + LWW 对账）。
    case changeLog
    /// 文件帧通道（帧 4/5/6 + 清单 10/11；随歌搬字节，不改业务状态）。
    case fileFrames
    /// 无跨端通道（不承诺 / 搭别的实体载荷但不独立传输）。
    case none
}

/// 实体的本地真值与行键形态（回答 INV-1：「本地真值在哪张表、由谁补发」）。
struct SyncEntityLocalTruth: Equatable, Sendable {
    /// 业务真值表名（载体不是 DB 行 = nil）。
    let table: String?
    /// 跨端行键（`sync_outbox.row_key`）形态。
    let rowKeyShape: String
    /// 载体补充说明（非 DB 行时写清楚载体在哪）。
    let carrierNote: String?
}

/// 一个装配点的**静态断言载荷**（CI 扫源码口径，回答 INV-16 的「协议支持 ≠ 有实现 ≠ 已装配」）。
///
/// 为什么声明在注册表里：断言此前是 `QQPlayerTests/SyncWiringContractTests.swift` 里的
/// **手写清单**，与注册表的 `assemblyPoints` 两处各自表达同一件事（「同一语义多处手工维护」
/// 的形状）→ 注册表删一条装配点、断言那份清单不会跟着红。收口后断言**从装配点派生**
/// （`SyncWiringContract.requirements` 的生成源），申报装配点 = 自动获得断言。
struct SyncEntityAssemblyAssertion: Equatable, Sendable {
    /// 断言 id（测试名 / 失败信息用）。
    let id: String
    /// 仓库相对路径：`.swift` 文件（单文件断言）或目录（目录下**任一**文件满足即可）。
    let path: String
    /// 必须**全部**出现的标记（子串匹配）。
    let requiredMarkers: [String]
    /// 候选标记组：每组**至少命中一个**（空数组 = 该组不约束）。
    let alternativeMarkers: [[String]]
    /// 断言语义（这条在钉什么）+ 不成立时的可操作指引。
    let guidance: String
}

/// 一个装配点（回答 INV-16：「协议支持 ≠ 有实现 ≠ 已装配」）。
///
/// 一份申报两处用途（同一份声明，不做第二份名单）：
/// - `assertion`：**静态**——CI 扫源码，证明调用点存在（编译期看不见的接线不掉缝）；
/// - `probe`：**运行时**——会话 ready 时回答「本端这次真的装上没有」（如对端 Device ID
///   为空导致静默不装配），见 `SyncWiringSelfCheck`。
struct SyncEntityAssemblyPoint: Equatable, Sendable {
    /// 平台（`SyncEntityRegistry.platformMac` / `platformIOS`；nil = 与平台无关，如通道级）。
    let platform: String?
    /// 帧号（不走帧 = nil）。
    let frame: Int?
    /// 装配点说明（哪个类型在哪被构造）——运行时缺口里「缺了什么」用的就是它。
    let detail: String
    /// 静态断言；nil = 该装配点与同类装配点**共用**断言（登记里写明了「同 X」）。
    let assertion: SyncEntityAssemblyAssertion?
    /// 运行时自检探针；nil = 只做静态断言（该能力不依赖会话期运行时状态）。
    let probe: SyncWiringProbe?
}

/// 一条实体登记。字段只增不减：新增能力时补字段 = 编译期逼所有条目表态。
struct SyncEntityRegistryEntry: Equatable, Sendable {
    /// L0 契约编号（`docs/sync-contract.md` 的 `### <编号> ...` 标题；CI 去文档里核）。
    let l0ID: String
    /// 变更日志通道（帧 8/9）上的实体；不走该通道（文件帧 / 不参与同步）= nil。
    let entity: SyncChangeEntity?
    /// 契约里的用户可见短名。
    let title: String
    let syncMode: SyncEntitySyncMode
    let channel: SyncEntityChannel
    let localTruth: SyncEntityLocalTruth
    /// 是否引用歌曲（= 需要跨端身份键 `content_hash`，INV-4 / INV-6）。
    let referencesTrack: Bool
    /// 本地写入点是否记 outbox（INV-1 出站方向）。
    let writesOutbox: Bool
    /// 是否有「本地真值 → outbox」补发（INV-1 入站方向，`reconcileLocalTruth`）。
    let reconcilesLocalTruth: Bool
    /// 是否参与出站悬空引用修复（`repairDanglingRows`；只有引用歌曲的实体才可能悬空）。
    let repairsDanglingReferences: Bool
    let assemblyPoints: [SyncEntityAssemblyPoint]
}
