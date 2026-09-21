//
//  SyncEntityRegistry.swift
//  QQPlayer
//
//  L0 契约 → **实体注册表（唯一声明处）**：登记表 `entries` 与四个派生访问器在本文件；
//  登记形状类型见 `SyncEntityRegistry+Shape.swift`，平台常量 / 共享装配点 / 装配类访问器见
//  `SyncEntityRegistry+Assembly.swift`。
//
//  为什么需要这个文件：「某个实体具备哪些同步能力」此前散在多处**各自维护的名单**里：
//  `SyncChangeEntity.v1Synced`（上线清单）/ `reconcilableEntities`（本地真值 → outbox 补发）/
//  `repairableEntities`（出站悬空引用修复）/ `SyncTrackReference.referencesTrack`（身份键要求）；
//  每处都是手写清单，**漏一处即静默**（2026-09-14 收藏「从来没同步过」事故：业务行在、outbox
//  没有对应 upsert、零报错）。本文件把这些「同一件事的多处表达」收成**一处声明 + 派生访问器**：
//  新增实体 = 加一条登记、新增能力 = 加一个字段（编译期逼所有条目表态）；散落名单不得再手写
//  第二份，由 `QQPlayerTests/SyncWiringContractTests.swift` 的 `SyncEntityRegistryContract` 静态守住。
//  登记口径（硬规矩：**行为零变化**）：以**当前代码事实**为准登记，不按契约理想登记；契约说该有、
//  代码实际没有的按现状登记（字段 = false）并在报告里单独列出——那是「功能缺口」，另开包补。
//  对应关系（每个字段 → 断言）：`entity` ↔ `SyncChangeEntity.allCases` 每个 case 都必有登记；
//  `l0ID` ↔ `docs/sync-contract.md` 同编号标题真实存在；`syncMode` ↔ `.notSynced` 不得出现在任何
//  outbox 写入点 / 补发名单 / 上线清单；其余能力字段 ↔ 派生名单只准由注册表算出、禁手写第二份。
//

import Foundation

// MARK: - 注册表（唯一声明处）

/// 全部同步实体登记。**这是「实体 × 能力」的唯一声明处**：散落名单从这里派生，
/// 不要在任何其它文件里手写第二份清单（CI 静态守住）。
enum SyncEntityRegistry {
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
                        // B2 拆分（2026-09-21）：装配簇（attachDataSync）随 DataSync 搬进 `+DataSync.swift`。
                        path: "QQPlayer/Services/IOSPassiveSyncCenter+DataSync.swift",
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
                        // B2 拆分（2026-09-21）：落点（makePassiveApplier）随 DataSync 搬进 `+DataSync.swift`。
                        path: "QQPlayer/Services/IOSPassiveSyncCenter+DataSync.swift",
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

    // MARK: - 派生访问器（散落名单只准从这里取，不得手写第二份）

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
