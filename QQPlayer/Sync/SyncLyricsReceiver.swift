//
//  SyncLyricsReceiver.swift
//  QQPlayer
//
//  R1b-1（2026-09-11）同步方向改造 · 被动侧能力——**接收到的 aligned 歌词安装编排**
//  （控制器与被动端共用同一实现，避免第二套歌词落库路径）。
//
//  语义（docs/lan-sync-design.md §6.3 + §12b 决策 7）：
//  - 只有 aligned 歌词随歌同步；收到的是 wire 路径 `@lyrics/{歌曲 content_hash}.json`
//    的字节 → 经 content_hash → 本端 stableId 映射 → 交给 `AlignedLyricsStore` 安装
//    （不落进曲库根、不写孤儿文件）。
//  - **本端歌曲还没入库**（同一轮里歌比歌词先到 / 后到）：先暂存，收尾时再试一次映射；
//    仍解析不出 → **丢弃**（歌词是依附歌曲的内容，不留孤儿），下次同步会从对端
//    manifest 重新拉到（自愈），不引入第二套挂起队列。
//  - 收尾之后再到的歌词：不暂存，直接按「映射得到就装、映射不到就丢」处理。
//  - **不传播删除**：本类型不存在删除本端歌词的路径。
//
//  调用方（SyncLibrarySyncController / SyncLibraryPassiveHost）只负责把 Outcome
//  计入自己的账目与回调，不再各自实现一遍安装/暂存/丢弃逻辑。
//

import Foundation

/// 接收歌词的安装编排（线程安全；调用方在会话线程同步驱动）。
final class SyncLyricsReceiver: @unchecked Sendable {
    /// 一次接收/重试的结论。
    enum Outcome: Equatable, Sendable {
        /// 已写进本端歌词库（值 = wire 路径）
        case installed(String)
        /// 本端还没有对应歌曲 → 已暂存，待收尾时重试
        case pending(String)
        /// 本端无对应歌曲（收尾后仍未映射到）→ 已丢弃临时文件；下次同步自愈
        case discarded(String)
        /// 解码/写盘失败（值 = wire 路径）
        case failed(String)
    }

    private let lyricsStore: AlignedLyricsStore
    private let lyricsMapping: SyncLyricsContentMapping
    private let fileManager: FileManager
    private let lock = NSLock()

    /// 已收到但本端歌曲尚未入库的歌词（收尾时再试一次映射）
    private var pending: [(wirePath: String, fileURL: URL)] = []
    /// 是否已收尾（收尾后到的歌词不再暂存，直接丢弃 + 记账）
    private var finalized = false

    init(
        lyricsStore: AlignedLyricsStore,
        lyricsMapping: SyncLyricsContentMapping,
        fileManager: FileManager = .default
    ) {
        self.lyricsStore = lyricsStore
        self.lyricsMapping = lyricsMapping
        self.fileManager = fileManager
    }

    /// 是否已收尾。
    var isFinalized: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finalized
    }

    /// 当前暂存（本端还没入库的歌对应的歌词）条数。
    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    /// 收到一个歌词文件（临时文件 URL + 其 wire 路径）。
    func receive(tempURL: URL, wirePath: String) -> Outcome {
        switch install(tempURL, wirePath: wirePath) {
        case .installed:
            return .installed(wirePath)
        case .failed:
            try? fileManager.removeItem(at: tempURL)
            return .failed(wirePath)
        case .orphan:
            lock.lock()
            let alreadyFinalized = finalized
            if !alreadyFinalized {
                pending.append((wirePath: wirePath, fileURL: tempURL))
            }
            lock.unlock()
            if alreadyFinalized {
                // 不放孤儿文件；下次同步对端 manifest 仍在 → 重新拉到（自愈）
                try? fileManager.removeItem(at: tempURL)
                return .discarded(wirePath)
            }
            return .pending(wirePath)
        }
    }

    /// 轮次收尾：暂存歌词再试一次映射，仍不行则丢弃。
    /// 收尾后本类型进入终态（后续 `receive` 不再暂存，映射不到直接丢）。
    func flushPending() -> [Outcome] {
        lock.lock()
        finalized = true
        let items = pending
        pending = []
        lock.unlock()

        return items.map { item in
            switch install(item.fileURL, wirePath: item.wirePath) {
            case .installed:
                return .installed(item.wirePath)
            case .orphan:
                try? fileManager.removeItem(at: item.fileURL)
                return .discarded(item.wirePath)
            case .failed:
                try? fileManager.removeItem(at: item.fileURL)
                return .failed(item.wirePath)
            }
        }
    }

    /// 丢弃所有暂存临时文件（会话关闭 / 服务停止；已落库的歌词不受影响）。
    func cancel() {
        lock.lock()
        let items = pending
        pending = []
        lock.unlock()
        for item in items {
            try? fileManager.removeItem(at: item.fileURL)
        }
    }

    // MARK: 单次安装尝试

    private enum InstallOutcome {
        case installed
        /// 本端还没有对应歌曲
        case orphan
        case failed
    }

    private func install(_ tempURL: URL, wirePath: String) -> InstallOutcome {
        guard let songHash = SyncLyricsNamespace.songContentHash(fromWirePath: wirePath),
              let stableId = lyricsMapping.stableIdForContentHash(songHash)
        else { return .orphan }
        do {
            try lyricsStore.install(receivedFileAt: tempURL, forStableId: stableId)
            return .installed
        } catch {
            return .failed
        }
    }
}
