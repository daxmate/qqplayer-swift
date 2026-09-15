//
//  SyncEntityRegistry.swift
//  QQPlayer
//
//  L0 契约 → **实体注册表（唯一声明处）**。
//
//  ════════════════════════════════════════════════════════════════════════════
//  为什么需要这个文件
//  ════════════════════════════════════════════════════════════════════════════
//  「某个实体具备哪些同步能力」此前散在多处**各自维护的名单**里：
//  `SyncChangeEntity.v1Synced`（上线清单）/ `reconcilableEntities`（本地真值 → outbox
//  补发）/ `repairableEntities`（出站悬空引用修复）/ `SyncTrackReference.referencesTrack`
//  （身份键要求）……每处都是一份手写清单，**漏一处即静默**（2026-09-14 收藏「从来没
//  同步过」事故就是这个形状：业务行在、outbox 没有对应 upsert、零报错）。
//
//  本文件把这些「同一件事的多处表达」收成**一处声明 + 派生访问器**：新增实体 =
//  加一条登记；新增能力 = 加一个字段（编译期逼所有条目表态）。散落名单不得再手写
//  第二份，由 `QQPlayerTests/SyncWiringContractTests.swift` 的
//  `SyncEntityRegistryContract`（CI 遍历断言）静态守住。
//
//  ════════════════════════════════════════════════════════════════════════════
//  登记口径（硬规矩：**行为零变化**）
//  ════════════════════════════════════════════════════════════════════════════
//  以**当前代码事实**为准登记，不按契约理想登记。契约说该有、代码实际没有的，
//  按现状登记（字段 = false）并在报告里单独列出——那是「功能缺口」，另开包补，
//  不在这里顺手改行为。
//
//  对应关系（每个字段 → 断言）：
//  - `entity`        ↔ `SyncChangeEntity.allCases` **每个 case 都必须有登记**（CI 遍历）
//  - `l0ID`          ↔ `docs/sync-contract.md` 里必须真实存在同编号标题（文档 ↔ 代码对齐）
//  - `syncMode`      ↔ `.notSynced` 不得出现在任何 outbox 写入点 / 补发名单 / 上线清单
//  - 其余能力字段    ↔ 派生名单由注册表算出，静态扫描禁止第二份手写清单
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

/// 一个装配点（回答 INV-16：「协议支持 ≠ 有实现 ≠ 已装配」）。
struct SyncEntityAssemblyPoint: Equatable, Sendable {
    /// 平台（"Mac" / "iOS"）。
    let platform: String
    /// 帧号（不走帧 = nil）。
    let frame: Int?
    /// 装配点说明（哪个类型在哪被构造）。
    let detail: String
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

// MARK: - 注册表（唯一声明处）

/// 全部同步实体登记。**这是「实体 × 能力」的唯一声明处**：散落名单从这里派生，
/// 不要在任何其它文件里手写第二份清单（CI 静态守住）。
enum SyncEntityRegistry {
    /// 帧 8/9（变更日志通道）的帧号——装配点里重复出现，抽成常量防写错。
    static let changeLogFrameNumbers = (pull: 8, push: 9)

    static let entries: [SyncEntityRegistryEntry] = [
        SyncEntityRegistryEntry(
            l0ID: "A",
            entity: .favorite,
            title: "收藏（favorite）",
            syncMode: .synced,
            channel: .changeLog,
            localTruth: SyncEntityLocalTruth(
                table: "favorite",
                rowKeyShape: "track_stable_id（= 本端 stableId；跨端身份键 = 歌曲 content_hash）",
                carrierNote: nil
            ),
            referencesTrack: true,
            writesOutbox: true,
            reconcilesLocalTruth: true,
            repairsDanglingReferences: true,
            assemblyPoints: [
                SyncEntityAssemblyPoint(
                    platform: "Mac",
                    frame: 8,
                    detail: "发起端：MacSyncDataViewModel 构造 SyncDataSyncCoordinator（面板手动入口 + 会话就绪自动一轮）"
                ),
                SyncEntityAssemblyPoint(
                    platform: "iOS",
                    frame: 8,
                    detail: "被动端：IOSPassiveSyncCenter.attachDataSync 构造 SyncChangeLogPeer"
                ),
            ]
        ),
        SyncEntityRegistryEntry(
            l0ID: "B",
            entity: .playHistory,
            title: "播放历史（playHistory）",
            syncMode: .synced,
            channel: .changeLog,
            localTruth: SyncEntityLocalTruth(
                table: "play_history",
                rowKeyShape: "track_stable_id|played_at（复合键：歌 + 开始时刻；两端同一事件同键）",
                carrierNote: nil
            ),
            referencesTrack: true,
            writesOutbox: true,
            reconcilesLocalTruth: true,
            repairsDanglingReferences: true,
            assemblyPoints: [
                SyncEntityAssemblyPoint(
                    platform: "Mac",
                    frame: 8,
                    detail: "发起端：同 A（帧 8/9 处理器在两端共享，实体维度不另装配）"
                ),
                SyncEntityAssemblyPoint(
                    platform: "iOS",
                    frame: 8,
                    detail: "被动端：同 A"
                ),
            ]
        ),
        SyncEntityRegistryEntry(
            l0ID: "C",
            entity: .playlist,
            title: "歌单结构（playlist：名称 / 结构）",
            syncMode: .synced,
            channel: .changeLog,
            localTruth: SyncEntityLocalTruth(
                table: "playlist",
                rowKeyShape: "slug（本地创建时派生、rename 不改 ⇒ 跨端稳定）",
                carrierNote: "folder-synced 歌单由本地扫描派生（folder_path 是设备本地路径），不入跨端同步（补发与写入侧同一口径）"
            ),
            // 不引用歌曲：不得被判「未定位」（INV-6），走 passThrough；因此也没有可悬空的引用。
            referencesTrack: false,
            writesOutbox: true,
            reconcilesLocalTruth: true,
            repairsDanglingReferences: false,
            assemblyPoints: [
                SyncEntityAssemblyPoint(
                    platform: "Mac",
                    frame: 8,
                    detail: "发起端：同 A"
                ),
                SyncEntityAssemblyPoint(
                    platform: "iOS",
                    frame: 8,
                    detail: "被动端：同 A"
                ),
            ]
        ),
        SyncEntityRegistryEntry(
            l0ID: "D",
            entity: .playlistItem,
            title: "歌单成员（playlistItem）",
            syncMode: .synced,
            channel: .changeLog,
            localTruth: SyncEntityLocalTruth(
                table: "playlist_item",
                rowKeyShape: "playlist_slug|track_stable_id（position 是载荷字段，不入键）",
                carrierNote: nil
            ),
            referencesTrack: true,
            writesOutbox: true,
            reconcilesLocalTruth: true,
            repairsDanglingReferences: true,
            assemblyPoints: [
                SyncEntityAssemblyPoint(
                    platform: "Mac",
                    frame: 8,
                    detail: "发起端：同 A"
                ),
                SyncEntityAssemblyPoint(
                    platform: "iOS",
                    frame: 8,
                    detail: "被动端：同 A"
                ),
            ]
        ),
        SyncEntityRegistryEntry(
            l0ID: "E",
            entity: .playbackPosition,
            title: "跨端续播（playbackPosition）",
            syncMode: .gatedBySetting(
                reason: "默认关（`DeleteSettings.syncPlaybackPositionEnabled` 兜底 false）；"
                    + "关 = 零出站零入站（捕获直接 return、落点直接拒），见 INV-26"
            ),
            channel: .changeLog,
            localTruth: SyncEntityLocalTruth(
                table: nil,
                rowKeyShape: "track_stable_id（= 歌）",
                carrierNote: "UserDefaults `QQPlayerState` 的播放位置（非 DB 行）——没有「表 → outbox」补发语义，"
                    + "故不进 reconcilableEntities"
            ),
            referencesTrack: true,
            writesOutbox: true,
            reconcilesLocalTruth: false,
            repairsDanglingReferences: false,
            assemblyPoints: [
                SyncEntityAssemblyPoint(
                    platform: "Mac",
                    frame: 8,
                    detail: "发起端：同 A；捕获挂点 = PlayerEngine.savePlayerState → PlaybackPositionCapture.recordIfEnabled"
                ),
                SyncEntityAssemblyPoint(
                    platform: "iOS",
                    frame: 8,
                    detail: "被动端：同 A；落点 = PlaybackPositionResumeSink（只改 playbackTime，绝不改 isPlaying）"
                ),
            ]
        ),
        SyncEntityRegistryEntry(
            l0ID: "F1",
            // 不承诺跨端：无 outbox 实体、无通道、不装配（契约 §2 F1）。
            entity: nil,
            title: "网络下载歌词",
            syncMode: .notSynced(
                reason: "契约明写不承诺跨端：重新下载成本极低、数据量小、单首播放时按需获取"
            ),
            channel: .none,
            localTruth: SyncEntityLocalTruth(
                table: nil,
                rowKeyShape: "—（无跨端行键）",
                carrierNote: "网络下载的歌词只在本端使用，无跨端载体"
            ),
            referencesTrack: false,
            writesOutbox: false,
            reconcilesLocalTruth: false,
            repairsDanglingReferences: false,
            assemblyPoints: []
        ),
        SyncEntityRegistryEntry(
            l0ID: "F2",
            entity: nil,
            title: "对齐歌词（本地对齐产物）",
            syncMode: .synced,
            channel: .fileFrames,
            localTruth: SyncEntityLocalTruth(
                table: nil,
                rowKeyShape: "@lyrics/{歌曲 content_hash}.json（命名空间键 = 歌曲身份，INV-21）",
                carrierNote: "Documents/lyrics-manual/{stableId}.json（端内 stableId 只在本端使用）"
            ),
            referencesTrack: true,
            writesOutbox: false,
            reconcilesLocalTruth: false,
            repairsDanglingReferences: false,
            assemblyPoints: [
                SyncEntityAssemblyPoint(
                    platform: "Mac",
                    frame: 4,
                    detail: "发起端：SyncCollectionSyncCoordinator 产出 lyricsEntries → 文件帧 4/5/6 随歌传输"
                ),
                SyncEntityAssemblyPoint(
                    platform: "iOS",
                    frame: 4,
                    detail: "被动端：SyncLibraryPassiveHost / SyncLibraryPullController 构造 SyncLyricsReceiver 接收"
                ),
            ]
        ),
        SyncEntityRegistryEntry(
            l0ID: "G",
            entity: nil,
            title: "曲库音频文件",
            syncMode: .synced,
            channel: .fileFrames,
            localTruth: SyncEntityLocalTruth(
                table: nil,
                rowKeyShape: "曲库相对路径（跨端统一）+ content_hash（判定用，不用 mtime / 大小）",
                carrierNote: "曲库根文件系统（不是 DB 行）"
            ),
            referencesTrack: true,
            writesOutbox: false,
            reconcilesLocalTruth: false,
            repairsDanglingReferences: false,
            assemblyPoints: [
                SyncEntityAssemblyPoint(
                    platform: "Mac",
                    frame: 10,
                    detail: "发起端：SyncLibraryPushController + SyncManifestGenerator（内容权威在 Mac）"
                ),
                SyncEntityAssemblyPoint(
                    platform: "iOS",
                    frame: 10,
                    detail: "被动端：SyncLibraryPassiveHost / SyncFileReceiver（纯被动，绝不跨端删文件）"
                ),
            ]
        ),
        SyncEntityRegistryEntry(
            l0ID: "H",
            // 不承诺跨端：封面是派生数据（由歌单内歌曲封面合成），无独立通道。
            entity: nil,
            title: "歌单自定义封面",
            syncMode: .notSynced(
                reason: "契约明写不承诺跨端：封面由歌单内歌曲封面自动合成 = 派生数据，两端各自合成，无可同步之物"
            ),
            channel: .none,
            localTruth: SyncEntityLocalTruth(
                table: nil,
                rowKeyShape: "—（不得作为跨端值传输）",
                carrierNote: "`playlist.custom_cover_image_path` 是**设备本地相对路径**，随 C 的载荷搭车但无独立通道；"
                    + "历史事故：对端必然加载不出"
            ),
            referencesTrack: false,
            writesOutbox: false,
            reconcilesLocalTruth: false,
            repairsDanglingReferences: false,
            assemblyPoints: []
        ),
    ]

    // MARK: - 派生访问器（散落名单只准从这里取，不得手写第二份）

    /// 某实体的登记（未登记 = nil）。
    static func entry(for entity: SyncChangeEntity) -> SyncEntityRegistryEntry? {
        entries.first { $0.entity == entity }
    }

    /// 该实体是否引用歌曲（= 上线时需要跨端身份键）。
    ///
    /// 语义与收口前 `entity != .playlist` **逐项相同**：未登记的 case 取 `true`
    /// （默认「引用」= 保守，缺身份键会被计数披露而不会静默错落库）。
    /// 「每个 case 都必须有登记」由 CI 的 `everyEntityCaseIsRegistered` 保证。
    static func referencesTrack(_ entity: SyncChangeEntity) -> Bool {
        entry(for: entity)?.referencesTrack ?? true
    }

    // 以下派生清单的**顺序 = 注册表声明顺序**（调用方依赖顺序时行为与收口前一致）。

    /// v1 **无条件**同步清单（`SyncChangeEntity.v1Synced` 的唯一来源）。
    static var v1SyncedEntities: [SyncChangeEntity] {
        entries.filter(\.syncMode.isListedInV1Synced).compactMap(\.entity)
    }

    /// 「本地真值 → outbox」补发清单（`reconcileLocalTruth` 的参与实体）。
    static var reconcilableEntities: [SyncChangeEntity] {
        entries.filter(\.reconcilesLocalTruth).compactMap(\.entity)
    }

    /// 出站悬空引用修复清单（`repairDanglingRows` 的参与实体）。
    static var danglingRepairableEntities: [SyncChangeEntity] {
        entries.filter(\.repairsDanglingReferences).compactMap(\.entity)
    }

    /// 「跟歌走」携带的歌维度实体（= 无条件同步 ∩ 引用歌曲；playlist 不是歌维度）。
    static var trackScopedSyncedEntities: [SyncChangeEntity] {
        entries.filter { $0.syncMode.isListedInV1Synced && $0.referencesTrack }.compactMap(\.entity)
    }
}
