//
//  SyncLibrarySink.swift
//  QQPlayer
//
//  R1b-2（2026-09-11）同步方向改造 · 落库出口（平台无关，两端共用）。
//
//  历史：本协议原先与 iOS 主动拉取控制器同处 `SyncLibrarySyncController.swift`；
//  R1b-2 退役旧主动链路时把**唯一落库出口**搬到这里——被动端（`SyncLibraryPassiveHost`）
//  与 Mac 拉取控制器（`SyncLibraryPullController`）共用同一实现，不新造第二条索引路径。
//
//  语义：**无删除出口**（docs/lan-sync-design.md §6.1 + §12b 决策 7「删除不跨端传播」）。
//  协议只有「一个文件已落位 → 走既有入库入口」这一个方法；任何同步链路都不得
//  经由本协议删除曲库文件 / 曲库行 / 歌词。
//

import Foundation

/// 同步结果的本地副作用：入库（走既有入口）。
/// 非 async：会话线程同步驱动，实现内部自行 hop 主线程（fire-and-forget）。
protocol SyncLibrarySyncSink: Sendable {
    /// 一个文件已落盘到位 → 走既有入库入口。
    func indexLandedFile(at url: URL)
}

/// 生产实现：入库复用 LibraryIndexer 既有入口。
/// **无删除出口**（§6 语义修订 2026-09-10：删除不传播）。
final class LibraryIndexerSyncSink: SyncLibrarySyncSink, @unchecked Sendable {
    func indexLandedFile(at url: URL) {
        Task { @MainActor in
            _ = await LibraryIndexer.shared.processExternalFile(url)
        }
    }
}
