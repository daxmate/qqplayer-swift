//
//  DocumentsRootTestSupport.swift
//  QQPlayerTests
//
//  「Documents 根 → 临时目录」的**注入式**测试基建。
//
//  为什么存在（2026-09-22 CI 实证，run `35704744895`，7 条红）：
//  旧做法是写一个**进程级全局静态** `LibraryRoot.documentsRootOverride` 来改 Documents 根。
//  但 Swift Testing 里 **不同套件之间仍然并行**（`.serialized` 只约束同一套件内的用例），
//  于是并行套件互相改写/复位那个静态根 ⇒ 被测用例「看不见自己搭的文件」：
//   · `LibraryLayoutMigrationTests` 两条：断言落点在自己临时根，文件却去了**别的套件的根**；
//   · `StateManagerTests.playerStateRoundTrip ×4`：写在本套件的根、读时静态已被复位 ⇒ nil；
//   · `StateManagerTests.playlistGetAll`：`playlist-a.json` 落**别的套件的临时根**、
//     `playlist-b.json` 落**真容器 Documents** ⇒ 枚举只看到一条。
//
//  修法（本文件）：删掉那个全局静态，改为**按用例注入**一个 `FileManager` 子类 —— 只把
//  `.documentDirectory` 的**解析**重定向到用例自己的临时根，其余查询全部 `super`。
//  测试之间因此**不再共享任何可变静态**，跨套件并发也无法互相污染。
//
//  口径：注入的 `FileManager` 只负责「目录解析」；实际 IO 落在绝对路径上，用默认
//  `FileManager` 亦可（临时根是真实目录）。
//

import Foundation

/// 把 `.documentDirectory`（`.userDomainMask`）解析重定向到指定根的 `FileManager`。
///
/// 用法：把它传进生产已有的注入缝（`LibraryLayoutMigrator.init(fileManager:)` /
/// `LibraryLayoutMigrationV2Migrator.init(fileManager:)` / `StateManager.*(fileManager:)` /
/// `LibraryRoot.*(fileManager:)`）。其余搜索路径与全部文件操作走 `super`（行为不变）。
final class DocumentsRootFileManager: FileManager {
    /// 本实例解析出的 Documents 根（绝对路径）。
    let documentsRoot: URL

    /// `.documentDirectory` 解析次数 —— **「注入 FM 是否真被走到」的判据**
    /// （`DocumentsDerivedPathGuardTests` 用）。
    ///
    /// 为什么需要它：若生产链内部改用 `FileManager.default` 解析 Documents 根，
    /// 结果会指向**真机容器**而不是注入根 —— 那种情况下本计数**不会增长**，
    /// 守卫因此判红（2026-09-22 CI 事故：DB 身份派生链正是这样绕开了注入 FM）。
    private(set) var documentDirectoryResolutionCount = 0

    init(documentsRoot: URL) {
        self.documentsRoot = documentsRoot
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        if directory == .documentDirectory, domainMask.contains(.userDomainMask) {
            documentDirectoryResolutionCount += 1
            return [documentsRoot]
        }
        return super.urls(for: directory, in: domainMask)
    }
}
