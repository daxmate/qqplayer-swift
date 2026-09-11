//
//  MacSyncCoordinatorFactory.swift
//  QQPlayer
//
//  M6（T2，2026-09-11）Mac 侧同步编排**装配工厂**（契约 C2；QQPlayerMac target only）。
//
//  职责：把一个 ready 会话 + 用户选择集，装配成一个可直接 `start()` 的
//  `SyncCollectionSyncCoordinator`（R3a 编排引擎，本身不含任何装配知识）。
//
//  ⚠️ 曲库根**只允许一个事实源**（封面解析散落 5 处的教训）：本文件统一走
//  `MusicFolderResolver.macDefaultFolderURL(homeDirectory:)`（与 `MacSyncLibraryHost`
//  的默认曲库根同源），绝不在这里另写一份路径拼装。
//
//  装配口径与 `MacSyncLibraryHost.init` 完全一致：
//  - descriptor：`SyncLocalLibraryDescriptor.live(libraryRoot:)`（默认 database /
//    fileManager / lyricsStore / mapping 全走生产默认，即 M4-2a 映射）
//  - facts：`DatabaseSyncCollectionFacts`（本端库事实，M6 缺口 2 的生产实现）
//  - sink：`LibraryIndexerSyncSink`（唯一落库出口，无删除出口）
//  - lyricsStore：`AlignedLyricsStore.shared`（aligned 歌词库同根）
//  - playbackCarry：`SyncPlaybackCarryPeer`（R3b「跟歌走」；peerID = 对端 Device ID）
//
//  peerID 取值来源：`SyncPeerSession.peerHelloValue?.deviceID` —— 对端 hello 里携带的
//  对端长期 Device ID（会话模块内的既有字段，就是 `PairRequest.clientDeviceID` /
//  `SyncChangeLogPeer` 游标用的那个"对端视角"键）。会话进入 ready 时该值必然已有
//  （握手先于 ready）。
//  为空（理论不可达）→ **不装配 carry**：（`SyncPlaybackCarryDriving` 缺省 = 不携带），
//  比拿空串当游标键写脏数据安全。
//
//  为什么不做单测：本文件属 `QQPlayer/Mac/`（iOS target 排除，仓库也无 macOS 单测
//  target），靠编译 + 代码审查覆盖（M6 契约 A3）。其中真正需要单测的纯逻辑
//  （`DatabaseSyncCollectionFacts` / `SyncSelectionStore` / `SyncHostGate`）已按 A3
//  放在共享 Core 并被 QQPlayerTests 覆盖。
//

import Foundation

/// Mac 同步编排装配工厂。
enum MacSyncCoordinatorFactory {
    /// 生产入口：曲库根 = macOS 默认曲库（与 `MacSyncLibraryHost` 同源）。
    static func make(
        session: SyncPeerSession,
        selection: SyncCollectionSelection
    ) -> SyncCollectionSyncCoordinator {
        make(
            session: session,
            selection: selection,
            libraryRoot: MusicFolderResolver.macDefaultFolderURL(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
        )
    }

    /// 可注入曲库根的版本（诊断/联调/harness 复用）。
    static func make(
        session: SyncPeerSession,
        selection: SyncCollectionSelection,
        libraryRoot: URL
    ) -> SyncCollectionSyncCoordinator {
        let database = DatabaseManager.shared
        // 歌词跨端映射：**一处创建、三处共用**（descriptor 的 manifest 侧 / facts 的
        // 「本端有无该歌词」判定 / 拉取侧 SyncLyricsReceiver 的落库映射），
        // 避免三处各建一套而口径漂移。
        let lyricsMapping = SyncLyricsContentMapping.live(database: database)
        let descriptor = SyncLocalLibraryDescriptor.live(
            libraryRoot: libraryRoot,
            database: database,
            lyricsMapping: lyricsMapping
        )
        let facts = DatabaseSyncCollectionFacts(
            database: database,
            libraryRoot: libraryRoot,
            lyricsMapping: lyricsMapping
        )
        let peerID = session.peerHelloValue?.deviceID ?? ""

        return SyncCollectionSyncCoordinator(
            session: session,
            descriptor: descriptor,
            selection: selection,
            facts: facts,
            sink: LibraryIndexerSyncSink(),
            lyricsStore: .shared,
            // ⚠️ 必须显式传映射：coordinator 缺省是 `.unresolved`（两端都解析不出），
            // 会让拉取侧 `SyncLyricsReceiver.install` 把对端发来的歌词全判为 orphan
            // → iPhone 的歌同步到 Mac 时歌词永远不落库。
            lyricsMapping: lyricsMapping,
            playbackCarry: peerID.isEmpty
                ? nil
                : SyncPlaybackCarryPeer(session: session, libraryRoot: libraryRoot, peerID: peerID)
        )
    }
}
