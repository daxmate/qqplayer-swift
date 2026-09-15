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

// MARK: - 注册表（唯一声明处）

/// 全部同步实体登记。**这是「实体 × 能力」的唯一声明处**：散落名单从这里派生，
/// 不要在任何其它文件里手写第二份清单（CI 静态守住）。
enum SyncEntityRegistry {
    /// 帧 8/9（变更日志通道）的帧号——装配点里重复出现，抽成常量防写错。
    /// 帧号冻结断言（`frame-8-9-numbers-frozen`）的标记也由它派生：改常量 = 断言自动跟改。
    static let changeLogFrameNumbers = (pull: 8, push: 9)

    /// 平台标识：装配点与运行时自检共用的**唯一口径**（不得在别处手写 "Mac" / "iOS" 字面量）。
    static let platformMac = "Mac"
    static let platformIOS = "iOS"

    /// 帧号冻结断言的标记（**派生自 `changeLogFrameNumbers`**，手写「= 8」不可能与之漂移）。
    static var frozenFrameMarkers: [String] {
        [
            "case changeLogPull = \(changeLogFrameNumbers.pull)",
            "case changeLogPush = \(changeLogFrameNumbers.push)",
        ]
    }

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
                    platform: SyncEntityRegistry.platformMac,
                    frame: SyncEntityRegistry.changeLogFrameNumbers.pull,
                    detail: "发起端：MacSyncDataViewModel 构造 SyncDataSyncCoordinator（面板手动入口 + 会话就绪自动一轮）",
                    assertion: SyncEntityAssemblyAssertion(
                        id: "mac-data-sync-entry-attached",
                        path: "QQPlayer/Mac",
                        requiredMarkers: ["SyncDataSyncCoordinator("],
                        alternativeMarkers: [],
                        guidance: """
                        Mac 侧没有「同步数据」用户入口：核心层 SyncDataSyncCoordinator 写好了但用户点不到 → 能力等于不存在。
                        请检查 MacSyncDataViewModel（或新的 Mac 视图模型）是否构造 SyncDataSyncCoordinator(session:)，并接到同步页的「同步数据」按钮上。
                        """
                    ),
                    probe: .dataSyncEntry
                ),
                SyncEntityAssemblyPoint(
                    platform: SyncEntityRegistry.platformIOS,
                    frame: SyncEntityRegistry.changeLogFrameNumbers.pull,
                    detail: "被动端：IOSPassiveSyncCenter.attachDataSync 构造 SyncChangeLogPeer",
                    assertion: SyncEntityAssemblyAssertion(
                        id: "ios-data-sync-peer-attached",
                        path: "QQPlayer/Services/IOSPassiveSyncCenter.swift",
                        requiredMarkers: ["SyncChangeLogPeer("],
                        alternativeMarkers: [["session.peerHelloValue?.deviceID", "IOSPassiveDataSyncLogic"]],
                        guidance: """
                        iOS 数据同步端没有装配点：Mac 推来的帧 9 被静默丢弃、Mac 的帧 8 无人应答 → 两端播放数据永不通（2026-09-13 那个上线级缺陷）。
                        请检查 IOSPassiveSyncCenter 是否在会话 ready（attachDataSync）时构造 SyncChangeLogPeer，且游标 peerID 取自对端 hello 的 Device ID（session.peerHelloValue?.deviceID，或经 IOSPassiveDataSyncLogic.dataSyncPeerID 同口径）。
                        """
                    ),
                    probe: .changeLogPeer
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
                    platform: SyncEntityRegistry.platformMac,
                    frame: SyncEntityRegistry.changeLogFrameNumbers.pull,
                    detail: "发起端：同 A（帧 8/9 处理器在两端共享，实体维度不另装配；断言与运行时自检由 A 的装配点承担）",
                    assertion: nil,
                    probe: nil
                ),
                SyncEntityAssemblyPoint(
                    platform: SyncEntityRegistry.platformIOS,
                    frame: SyncEntityRegistry.changeLogFrameNumbers.pull,
                    detail: "被动端：同 A（同一处理器；断言与运行时自检由 A 的装配点承担）",
                    assertion: nil,
                    probe: nil
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
                    platform: SyncEntityRegistry.platformMac,
                    frame: SyncEntityRegistry.changeLogFrameNumbers.pull,
                    detail: "发起端：同 A（帧 8/9 处理器在两端共享，实体维度不另装配；断言与运行时自检由 A 的装配点承担）",
                    assertion: nil,
                    probe: nil
                ),
                SyncEntityAssemblyPoint(
                    platform: SyncEntityRegistry.platformIOS,
                    frame: SyncEntityRegistry.changeLogFrameNumbers.pull,
                    detail: "被动端：同 A（同一处理器；断言与运行时自检由 A 的装配点承担）",
                    assertion: nil,
                    probe: nil
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
                    platform: SyncEntityRegistry.platformMac,
                    frame: SyncEntityRegistry.changeLogFrameNumbers.pull,
                    detail: "发起端：同 A（帧 8/9 处理器在两端共享，实体维度不另装配；断言与运行时自检由 A 的装配点承担）",
                    assertion: nil,
                    probe: nil
                ),
                SyncEntityAssemblyPoint(
                    platform: SyncEntityRegistry.platformIOS,
                    frame: SyncEntityRegistry.changeLogFrameNumbers.pull,
                    detail: "被动端：同 A（同一处理器；断言与运行时自检由 A 的装配点承担）",
                    assertion: nil,
                    probe: nil
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
                    platform: SyncEntityRegistry.platformMac,
                    frame: SyncEntityRegistry.changeLogFrameNumbers.pull,
                    detail: "发起端：同 A；捕获挂点 = PlayerEngine.savePlayerState → PlaybackPositionCapture.recordIfEnabled",
                    assertion: SyncEntityAssemblyAssertion(
                        id: "mac-playback-capture-attached",
                        path: "QQPlayer/Services/PlayerEngine.swift",
                        requiredMarkers: ["PlaybackPositionCapture.recordIfEnabled("],
                        alternativeMarkers: [],
                        guidance: """
                        跨端续播的**出站捕获挂点**断了：保存播放位置时不再上报（开关开着也永远推不出东西）→ 另一端永远收不到「上次听到哪」。
                        请检查 PlayerEngine.savePlayerState 里是否仍调用 PlaybackPositionCapture.recordIfEnabled(...)（开关关时该函数自己直接 return，挂点本身必须常驻）。
                        """
                    ),
                    probe: nil
                ),
                SyncEntityAssemblyPoint(
                    platform: SyncEntityRegistry.platformIOS,
                    frame: SyncEntityRegistry.changeLogFrameNumbers.pull,
                    detail: "被动端：同 A；落点 = PlaybackPositionResumeSink（只改 playbackTime，绝不改 isPlaying）",
                    assertion: SyncEntityAssemblyAssertion(
                        id: "ios-playback-position-sink-attached",
                        path: "QQPlayer/Services/IOSPassiveSyncCenter.swift",
                        requiredMarkers: ["PlaybackPositionResumeSink.apply"],
                        alternativeMarkers: [],
                        guidance: """
                        跨端续播的**入站落点**没接上：Mac 推来的播放位置行会被判「未支持」丢弃（开关开着也续不了播）。
                        请检查 IOSPassiveSyncCenter.makePassiveApplier 是否在开关开启时注入 applier.playbackPositionSink = { PlaybackPositionResumeSink.apply($0) }。
                        """
                    ),
                    probe: .playbackPositionSink
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
                    platform: SyncEntityRegistry.platformMac,
                    frame: 4,
                    detail: "发起端：SyncCollectionSyncCoordinator 产出 lyricsEntries → 文件帧 4/5/6 随歌传输",
                    assertion: SyncEntityAssemblyAssertion(
                        id: "mac-lyrics-push-attached",
                        path: "QQPlayer/Sync/SyncLibraryPushController.swift",
                        requiredMarkers: ["descriptor.lyricsEntries()"],
                        alternativeMarkers: [],
                        guidance: """
                        对齐歌词的**出站装配**断了：推送清单里不再包含 lyricsEntries → 歌词永远不随歌到达另一端（歌曲文件照传，用户只看到「歌词没过来」）。
                        请检查 SyncLibraryPushController 的清单构造是否仍调用 descriptor.lyricsEntries()。
                        """
                    ),
                    probe: nil
                ),
                SyncEntityAssemblyPoint(
                    platform: SyncEntityRegistry.platformIOS,
                    frame: 4,
                    detail: "被动端：SyncLibraryPassiveHost / SyncLibraryPullController 构造 SyncLyricsReceiver 接收",
                    assertion: SyncEntityAssemblyAssertion(
                        id: "ios-lyrics-receiver-attached",
                        path: "QQPlayer/Sync/SyncLibraryPassiveHost.swift",
                        requiredMarkers: ["SyncLyricsReceiver("],
                        alternativeMarkers: [],
                        guidance: """
                        被动端没有歌词接收器（INV-16 既有建议、此前一直缺的断言）：对端推来的歌词被当普通文件丢掉或落到未映射位置 → 手机上永远没有对齐歌词。
                        请检查 SyncLibraryPassiveHost 是否构造 SyncLyricsReceiver（映射必须走 SyncLyricsContentMapping 入口，不得自行解析身份）。
                        """
                    ),
                    probe: nil
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
                    platform: SyncEntityRegistry.platformMac,
                    frame: 10,
                    detail: "发起端：SyncLibraryPushController + SyncManifestGenerator（内容权威在 Mac）",
                    assertion: SyncEntityAssemblyAssertion(
                        id: "mac-library-push-attached",
                        path: "QQPlayer/Sync/SyncCollectionSyncCoordinator.swift",
                        requiredMarkers: ["SyncLibraryPushController(", "SyncManifestGenerator.generate("],
                        alternativeMarkers: [],
                        guidance: """
                        Mac 侧文件推送链路没装配：勾选的歌永远推不出去（用户点了「开始同步」却什么也没发生）。
                        请检查 SyncCollectionSyncCoordinator 是否构造 SyncLibraryPushController 并用 SyncManifestGenerator.generate(...) 生成清单。
                        """
                    ),
                    probe: nil
                ),
                SyncEntityAssemblyPoint(
                    platform: SyncEntityRegistry.platformIOS,
                    frame: 10,
                    detail: "被动端：SyncLibraryPassiveHost / SyncFileReceiver（纯被动，绝不跨端删文件）",
                    assertion: SyncEntityAssemblyAssertion(
                        id: "ios-file-receiver-attached",
                        path: "QQPlayer/Sync/SyncLibraryPassiveHost.swift",
                        requiredMarkers: ["SyncFileReceiver("],
                        alternativeMarkers: [],
                        guidance: """
                        被动端文件接收器没装配：Mac 推来的歌落不了盘（面板显示已连接、进度永远不动）。
                        请检查 SyncLibraryPassiveHost 是否构造 SyncFileReceiver 并在 attach 时接上会话。
                        """
                    ),
                    probe: .libraryPassiveHost
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

    // MARK: - 共享装配点（不属任何一条实体登记）

    /// **跨实体的装配点**：通道级（帧 8/9 的处理器与线上帧号）与平台级编排（Mac 跟歌走携带）。
    ///
    /// 与实体装配点**同一类型、同一份申报**：静态断言（`assertion`）与运行时自检（`probe`）
    /// 走同一条推导路径——此前这几条活在 `SyncWiringContractTests` 的手写清单里，正是
    /// 「同一语义多处手工维护」的另一半。
    static let sharedAssemblyPoints: [SyncEntityAssemblyPoint] = [
        SyncEntityAssemblyPoint(
            platform: nil,
            frame: changeLogFrameNumbers.push,
            detail: "帧 8/9 的分发处理器：SyncChangeLogPeer 的帧分发表（两端共用同一处理器）",
            assertion: SyncEntityAssemblyAssertion(
                id: "frame-8-9-handler-present",
                path: "QQPlayer/Sync/SyncChangeLogPeer.swift",
                requiredMarkers: ["case .changeLogPull:", "case .changeLogPush:"],
                alternativeMarkers: [],
                guidance: """
                帧 8/9 的唯一处理器没了（分支被删 / 改名）：全仓再没有地方响应播放数据同步帧 → 帧 8/9 变成死协议。
                请检查 SyncChangeLogPeer 的帧分发表是否仍有 case .changeLogPull: / case .changeLogPush: 两个分支（类型本身存在于 QQPlayer/Sync/SyncChangeLogPeer.swift）。
                """
            ),
            probe: nil
        ),
        SyncEntityAssemblyPoint(
            platform: nil,
            frame: changeLogFrameNumbers.pull,
            detail: "帧 8/9 的线上帧号：SyncFrame 的 changeLogPull / changeLogPush（两端版本可能不同步升级）",
            assertion: SyncEntityAssemblyAssertion(
                id: "frame-8-9-numbers-frozen",
                path: "QQPlayer/Sync/SyncFrame.swift",
                // 标记**派生自 `changeLogFrameNumbers`**：改常量 = 断言里期望的号自动跟着变。
                requiredMarkers: frozenFrameMarkers,
                alternativeMarkers: [],
                guidance: """
                帧号被改动了：帧 8/9 是跨端线上契约（两端版本可能不同步升级），改号 = 老版本对端解错帧、同步静默错乱。
                请把 SyncFrame.FrameType 的 changeLogPull 恢复到 = 8、changeLogPush 恢复到 = 9（新增帧只能用未占用的号段）。
                """
            ),
            probe: nil
        ),
        SyncEntityAssemblyPoint(
            platform: nil,
            frame: nil,
            detail: "歌曲身份解析入口：SyncContentHashResolver 遵守 SyncIdentityResolving，歌词映射从入口构造（两端共用）",
            assertion: SyncEntityAssemblyAssertion(
                id: "identity-entry-implemented-and-wired",
                path: "QQPlayer/Sync/SyncChangeLogMapping.swift",
                requiredMarkers: [
                    "extension SyncContentHashResolver: SyncIdentityResolving",
                    "SyncLyricsContentMapping(identity:",
                ],
                alternativeMarkers: [],
                guidance: """
                歌曲身份解析的入口实现断了：`SyncContentHashResolver` 不再声明遵守 `SyncIdentityResolving`，
                或歌词映射不再从入口构造（`SyncLyricsContentMapping(identity:)`）——两条都是「入口空转」的形状：
                编译能过（协议可选遵守）、下游各自拿闭包，漏接线一处就静默。
                请检查 QQPlayer/Sync/SyncChangeLogMapping.swift：`SyncContentHashResolver` 必须有 `: SyncIdentityResolving` 遵守声明，
                `.live(database:libraryRoot:)` 必须走 `SyncLyricsContentMapping(identity: SyncContentHashResolver(database:libraryRoot:))`。
                """
            ),
            probe: nil
        ),
        SyncEntityAssemblyPoint(
            platform: platformMac,
            frame: nil,
            detail: "跟歌走携带：MacSyncCoordinatorFactory 把 SyncPlaybackCarryPeer 装配进 SyncCollectionSyncCoordinator（R3b；对端 Device ID 为空则不装）",
            assertion: SyncEntityAssemblyAssertion(
                id: "mac-playback-carry-attached",
                path: "QQPlayer/Mac/MacSyncCoordinatorFactory.swift",
                requiredMarkers: ["SyncPlaybackCarryPeer("],
                alternativeMarkers: [],
                guidance: """
                跟歌走链路失去装配：推 / 拉歌时播放数据不再跟随传输 → R3b 能力静默失效（要用户重新同步数据才补回来）。
                请检查 MacSyncCoordinatorFactory 里 SyncCollectionSyncCoordinator 的 playbackCarry 实参是否仍传 SyncPlaybackCarryPeer(session:libraryRoot:peerID:)。
                """
            ),
            probe: .playbackCarry
        ),
    ]

    // MARK: - 派生访问器（散落名单只准从这里取，不得手写第二份）

    /// **全部装配点**（实体维度 + 共享维度）——静态装配断言与运行时自检的唯一来源。
    static var allAssemblyPoints: [SyncEntityAssemblyPoint] {
        entries.flatMap(\.assemblyPoints) + sharedAssemblyPoints
    }

    /// 全部 **(能力标识, 装配点)**：实体装配点的标识 = 登记的 L0 编号；共享装配点的标识 = 断言 id。
    /// 静态断言与运行时自检都从这里取（一处声明，两处消费）。
    static var capabilityAssemblyPoints: [(capabilityID: String, point: SyncEntityAssemblyPoint)] {
        entries.flatMap { entry in
            entry.assemblyPoints.map { (entry.l0ID, $0) }
        } + sharedAssemblyPoints.map { ($0.assertion?.id ?? "shared", $0) }
    }

    /// 某平台声明的装配点（顺序 = 注册表声明顺序；`nil` 平台 = 与平台无关，不在此列）。
    static func assemblyPoints(platform: String) -> [SyncEntityAssemblyPoint] {
        allAssemblyPoints.filter { $0.platform == platform }
    }

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
