//
//  TrackDeletionService.swift
//  QQPlayer
//
//  （target 归属：两端共享——iOS + QQPlayerMac 白名单，2026-09-18 P1 合流时改）
//
//  曲目删除的**唯一入口**（2026-09-17 P0 收口 iOS 视图层；2026-09-18 P1 与 Mac 合流）。
//
//  背景一（为什么要收口）：同一段「删除一首歌」的仪式在 iOS 视图层抄了 **7 份**——
//    ① 读 `DeleteSettings.deleteFromLibraryOnly`
//    ② 是 → `DeleteSettings.addExcludedTrack`；否 → 删文件
//    ③ `DatabaseManager.deleteTrack(byStableId:)`
//    ④ post `.libraryNeedsRefresh`
//  7 份还各不相同（有的 `try` 有的 `try?`，单曲路径报错、批量路径静默）。
//
//  背景二（为什么要合流）：收口之后仍是**两份实现**——本文件（iOS：`removeItem` 永久删、
//  主线程同步逐首）+ `MacTrashService`（Mac：`trashItem` 可恢复、非主线程 async、可取消、
//  带进度回调）。同一语义两处实现 = 迟早不一致（AGENTS.md 2026-09-15「共享语义唯一入口」），
//  于是把「两份实现」改为「**一个入口 + 显式策略参数**」：
//
//    - `fileAction`：`.trash`（进废纸篓可恢复）/ `.delete`（永久删除）——**默认值按平台**，
//      且默认值本身就是数据（`Policy.ios(libraryOnly:)` / `Policy.mac()`），不是分支判断：
//        · iOS → `.delete`（合流前 iOS 行为，行为零变化。依据：2026-09-18 实测 iOS 容器**没有
//          废纸篓宗卷**，`trashItem` 运行时抛 NSCocoaErrorDomain 3328（"宗卷没有废纸篓"）
//          → 若 iOS 默认 `.trash`，关掉「只从曲库移除」的用户删歌会**永远失败**）
//        · macOS → `.trash`（合流前 Mac 行为，进废纸篓可恢复）
//    - `libraryOnly`：沿用既有开关语义（iOS 读 `DeleteSettings.deleteFromLibraryOnly`）
//    - 进度 / 取消：Mac 既有能力原样保留（`onProgress` / `Environment.isCancelled`）
//
//  平台差异从此只是**调用点传入的数据**；核心逐首仪式只有一份实现，且**没有隐式默认**
//  （`Policy.fileAction` 无默认值、核心 `policy:` 参数无默认值 → 谁也不能默默拾到一个错默认值）。
//
//  语义（2026-09-21 批 E-2 起：「只从曲库移除」的**库内文件**改落点为应用回收区）：
//  - `libraryOnly == true` 且文件在**曲库根之内** → 文件**移入应用回收区**
//    （`<曲库根>/.Trash/<contentHash>.<ext>`，不永久删除、可恢复），加排除标记，再删 DB 引用；
//    为什么（批 E-2 背景）：旧语义把文件留在曲库根里 → 对端 manifest 仍把该文件当「已有」
//    （指纹来自文件回落）→ 差集判「已一致」→ 该删的歌永远传不过去，而用户以为删掉了。
//    移出曲库根后，对端差集这才看得见「本端没有这首」；原件不丢（回收区里可恢复）。
//  - `libraryOnly == true` 且文件在**曲库根之外** → 保持旧语义：**不碰磁盘**（保护用户原件 /
//    设置页添加的外部文件夹），只加排除标记 + 删 DB 引用；
//  - `libraryOnly == false`（iOS 默认）→ 永久删除（行为零变化）；
//  - 文件动作失败 → **保留曲目**（不删 DB 引用）并计 failed——曲目留在库里，用户看得见也删得掉；
//  - 文件已不在磁盘 → 不当失败，照常清 DB 引用（Mac 既有语义）；
//  - DB 删除失败 → 计 failed，其余曲目照常继续；
//  - 取消（仅 Mac 生产路径传 `Task.isCancelled`）：逐首之间检查，剩余曲目不再处理；
//  - iOS 生产路径每次调用只 post **一次** `.libraryNeedsRefresh`（单曲 = 1 次，批量 = 末尾 1 次）。
//
//  文件动作（`FileManager.trashItem` / `FileManager.removeItem` / 回收区移动）**只允许出现在本文件**
//  （`Environment.live` 一处），由形状契约测试
//  `QQPlayerTests/TrackDeletionShapeContractTests.swift` 静态守护（白名单只留本文件）。
//
//  回收区（`DeleteReclaimArea`，本文件末尾）：目录名常量 / 路径派生 / 目标命名 / 移动实现**只此一份**
//  （禁在别处再写 `.Trash` 字面量）；曲库根由调用方传（生产 = `MusicFolderResolver.syncLibraryRoot`，
//  禁手拼 Documents 路径）；文件名里的指纹复用既有入口（`DatabaseManager.contentHashIfFilePresent`，
//  禁新写哈希实现）——口径与复现见 `QQPlayerTests/TrackDeletionReclaimAreaTests.swift`。
//
//  依赖注入（Environment）只为可测：生产走 `delete(items:)`（iOS）/ `trash(items:)`（Mac 批量），
//  测试注入假文件系统 / 假 DB 覆盖全部分支。
//

import Foundation

enum TrackDeletionService {
    // MARK: - 输入

    /// 一首待删除曲目（只带执行所需字段，避免搬运整个 Track）。
    struct Item: Sendable, Equatable {
        let stableId: String
        /// 仅用于日志/诊断（iOS 调用点不传 → 日志回落到 stableId）。
        let title: String
        let path: String

        init(stableId: String, title: String = "", path: String) {
            self.stableId = stableId
            self.title = title
            self.path = path
        }

        init(track: Track) {
            self.stableId = track.stableId
            self.title = track.title
            self.path = track.path
        }

        /// 日志展示名（title 为空时退回 stableId）。
        var logLabel: String { title.isEmpty ? stableId : title }
    }

    // MARK: - 策略（平台/设置差异 = 数据）

    /// 磁盘文件动作。
    enum FileAction: String, Sendable, CaseIterable {
        /// 移到系统废纸篓（可恢复）。
        /// macOS 默认；**iOS 上运行时会失败**（容器无废纸篓宗卷，抛 NSCocoaErrorDomain 3328，
        /// 实测见 `QQPlayerTests/TrackDeletionServiceTests.swift` 的实测套件）——所以 iOS 不默认走它。
        case trash
        /// 永久删除（不可恢复）。iOS 默认。
        case delete
        /// 移入应用回收区（可恢复、且不再留在曲库根里）。
        /// `libraryOnly == true` 的 iOS 默认（2026-09-21 批 E-2）；只对**曲库根之内**的文件生效
        /// （根外文件走旧语义：不碰磁盘，见 `delete(items:policy:environment:)` 核心）。
        case reclaim

        /// 日志标签（沿用 Mac 端历史日志文本 `trashItem 成功` / `removeItem 成功`）。
        var logLabel: String {
            switch self {
            case .trash: return "trashItem"
            case .delete: return "removeItem"
            case .reclaim: return "moveToReclaimArea"
            }
        }
    }

    /// 一次删除的策略（显式传入，不从环境里偷偷读）。
    /// **没有隐式默认值**：默认值就是下面两个工厂，由两个生产适配器各自显式传。
    struct Policy: Sendable {
        /// 磁盘文件动作（无默认——必须显式给，避免某个调用点默默拾到错的动作）。
        var fileAction: FileAction
        /// 沿用既有开关语义（2026-09-21 批 E-2 起落点细分，见 `delete(items:policy:environment:)`）：
        /// true = 只从曲库移除 —— 库内文件移入回收区；库外文件不碰磁盘（连存在性都不查）。
        var libraryOnly: Bool = false

        /// iOS 生产默认：
        /// · `libraryOnly == false` → **永久删除**（= 合流前 iOS 的 `removeItem` 行为，行为零变化）。
        ///   依据（2026-09-18 实测）：iOS 容器没有废纸篓宗卷，`trashItem` 抛 3328 必失败；
        ///   默认 `.trash` 会让「关掉只从曲库移除」的 iOS 用户删歌永远失败（功能回退）。
        /// · `libraryOnly == true` → **移入回收区**（批 E-2 落点变更：库外文件自动退回旧语义）。
        /// `libraryOnly` 由 iOS 设置（`DeleteSettings.deleteFromLibraryOnly`）决定。
        static func ios(libraryOnly: Bool) -> Policy {
            Policy(fileAction: libraryOnly ? .reclaim : .delete, libraryOnly: libraryOnly)
        }

        /// macOS 生产默认：**进废纸篓**（= 合流前 Mac 的 `trashItem` 行为，行为零变化）。
        /// Mac 端没有「只从曲库移除」开关（现状保留），故 `libraryOnly` 固定 false。
        static func mac() -> Policy {
            Policy(fileAction: .trash, libraryOnly: false)
        }
    }

    // MARK: - 结论

    /// 批次结论（供调用方决定要不要提示用户；语义固定，不随调用点变化）。
    struct Outcome: Sendable, Equatable {
        /// 文件动作（或排除标记）与 DB 引用都处理完成的曲目数。
        var deleted: Int = 0
        /// 未能完成的曲目数（文件动作失败 → 保留，或 DB 删除失败）。
        var failed: Int = 0
        /// 走「只从曲库移除、保留文件」分支的曲目数（含在 `deleted` 内）。
        var excludedFromLibrary: Int = 0
        /// 其中因磁盘文件动作失败而保留的曲目数（`failed` 的子集，诊断用）。
        var fileRemovalFailed: Int = 0
        /// 实际移入应用回收区的曲目数（`excludedFromLibrary` 的子集；批 E-2 新增，旧字段含义未变）。
        var movedToReclaim: Int = 0
        /// 实际处理（含失败）的曲目数 = 取消时的进度（Mac 进度语义）。
        var processed: Int = 0
        /// 逐首之间被取消（剩余曲目未处理）。
        var cancelled: Bool = false

        var deletedAny: Bool { deleted > 0 }
    }

    /// 进度（供调用方展示「12/300」）。
    struct Progress: Sendable, Equatable {
        var done: Int
        var total: Int
    }

    /// 单首结论（日志/诊断用）。
    enum ItemOutcome: Sendable, Equatable {
        /// 磁盘（或文件已丢）+ DB 引用均处理完成
        case deleted
        /// 文件动作失败（文件仍在）或 DB 删除失败
        case failed
    }

    // MARK: - 执行环境（唯一允许碰磁盘文件动作的地方）

    /// 执行环境：生产走系统 FileManager + DatabaseManager，测试注入假实现。
    /// 闭包一律 `@Sendable`——Mac 路径会在非主 actor 上执行。
    struct Environment: Sendable {
        var fileExists: @Sendable (String) -> Bool
        /// `fileAction: .trash` 的实现（进废纸篓）。
        var moveToTrash: @Sendable (String) throws -> Void
        /// `fileAction: .delete` 的实现（永久删除）。
        var removePermanently: @Sendable (String) throws -> Void
        /// `fileAction: .reclaim` 的实现（把库内文件移入应用回收区；生产 = `DeleteReclaimArea.move`）。
        var moveToReclaimArea: @Sendable (_ path: String, _ destinationRoot: URL) throws -> Void
        /// `libraryOnly` 分支：加排除标记（不碰磁盘）。
        var excludeFromLibrary: @Sendable (String) -> Void
        /// 清 DB 引用。
        var deleteReference: @Sendable (String) throws -> Void
        /// 曲库根（回收区落点判据的基准：文件是否在根内）。
        /// 生产 = `MusicFolderResolver.syncLibraryRoot`（iOS 侧唯一根访问器）；注入只为可测。
        var libraryRoot: @Sendable () -> URL
        /// 过程日志出口（Mac 写 trash.log；iOS 现状无日志出口 → 传空实现，失败仍 `print`）。
        var log: @Sendable (String) -> Void
        /// 逐首之间的取消检查（生产：iOS 不取消 = 默认 `{ false }`；Mac = `Task.isCancelled`）。
        /// 与「删什么/怎么删」无关——它是执行环境事实，故放这里而不是 Policy。
        var isCancelled: @Sendable () -> Bool

        /// 生产实现：系统废纸篓/永久删除 + 曲库 DB。
        /// 两个动作都实现（策略挑一个）：`.trash` 由 macOS 走，iOS 上运行时必失败（容器无废纸篓）。
        static func live(
            log: @escaping @Sendable (String) -> Void,
            isCancelled: @escaping @Sendable () -> Bool = { false },
            libraryRoot: URL = MusicFolderResolver.syncLibraryRoot
        ) -> Environment {
            Environment(
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                moveToTrash: { path in
                    try FileManager.default.trashItem(
                        at: URL(fileURLWithPath: path),
                        resultingItemURL: nil
                    )
                },
                removePermanently: { path in
                    try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
                },
                moveToReclaimArea: { path, destinationRoot in
                    try DeleteReclaimArea.move(path, into: destinationRoot)
                },
                excludeFromLibrary: { DeleteSettings.addExcludedTrack($0) },
                deleteReference: { try DatabaseManager.shared.deleteTrack(byStableId: $0) },
                libraryRoot: { libraryRoot },
                log: log,
                isCancelled: isCancelled
            )
        }
    }

    // MARK: - 生产路径 · iOS（主线程同步；每次调用一次通知）

    /// 删除若干曲目。iOS 视图层只调这一个方法，不再自己读设置 / 碰文件 / 碰数据库。
    /// 线程语义保留（这一直是主线程同步逐首；iOS 无进度/取消需求）；
    /// 文件动作 = `Policy.ios(...)`：默认（关闭「只从曲库移除」）**永久删除**；
    /// 开启时**库内文件移入回收区**、库外文件不碰磁盘（批 E-2）。
    @MainActor
    @discardableResult
    static func delete(items: [Item]) -> Outcome {
        let settings = DeleteSettings.load()
        let outcome = delete(
            items: items,
            policy: .ios(libraryOnly: settings.deleteFromLibraryOnly),
            environment: .live(log: { _ in })
        )
        NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)
        return outcome
    }

    // MARK: - 生产路径 · Mac（nonisolated async → 不占主线程；可取消；带进度）

    /// 批量「移到废纸篓」（沿用原 `MacTrashService.trash` 语义：非主 actor 逐首执行、
    /// 可取消（由 `environment.isCancelled` 提供探测）、带进度回调；
    /// 文件动作 = `Policy.mac()` = **进废纸篓**，等价于 `Policy(fileAction: .trash, libraryOnly: false)`）。
    ///
    /// - Parameters:
    ///   - items: 待删除曲目（顺序 = 处理顺序）
    ///   - environment: 执行环境（生产传 `.live(log:isCancelled:)`，Mac 传 `{ Task.isCancelled }`）
    ///   - onItemProcessed: 每首处理完回调（诊断/日志）
    ///   - onProgress: 每首处理完回调（done, total）——调用方自行 hop 主线程落 @State
    static func trash(
        items: [Item],
        environment: Environment,
        onItemProcessed: (@Sendable (Item, ItemOutcome) -> Void)? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> Outcome {
        delete(
            items: items,
            policy: .mac(),
            environment: environment,
            onItemProcessed: onItemProcessed,
            onProgress: onProgress
        )
    }

    // MARK: - 核心（依赖注入，测试用；两端生产路径唯一实现）

    /// 逐首执行删除；**不做隔离假设**，调用方决定在哪个 actor 上跑。
    /// `policy` 无默认值：文件动作必须由调用方显式给（见 `Policy.ios(libraryOnly:)` / `Policy.mac()`）。
    static func delete(
        items: [Item],
        policy: Policy,
        environment: Environment,
        onItemProcessed: (@Sendable (Item, ItemOutcome) -> Void)? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) -> Outcome {
        var outcome = Outcome()
        guard !items.isEmpty else { return outcome }
        let total = items.count

        for item in items {
            if environment.isCancelled() {
                outcome.cancelled = true
                break
            }

            environment.log("开始处理: \(item.logLabel) | path=\(item.path)")

            // 存储形态 → 绝对路径（唯一入口）：磁盘动作只认真实路径；相对形态（曲库内文件）
            // 在这里解回曲库根下，Mac 的绝对路径原样透传。
            let absolutePath = LibraryRoot.absolutePath(forStoredPath: item.path)

            if policy.libraryOnly {
                // 「只从曲库移除」的文件落点（2026-09-21 批 E-2）：
                //  · 库内文件 → 移入回收区（不再留在曲库根里，对端差集才看得见这首没了）；
                //  · 库外文件 → 旧语义逐字保留：不碰磁盘（保护用户原件/外部文件夹）。
                let libraryRoot = environment.libraryRoot()
                let isInLibraryRoot = DeleteReclaimArea.isInsideLibraryRoot(
                    absolutePath,
                    libraryRoot: libraryRoot
                )
                if policy.fileAction == .reclaim, isInLibraryRoot {
                    if environment.fileExists(absolutePath) {
                        do {
                            try performFileAction(.reclaim, path: absolutePath, environment: environment)
                            outcome.movedToReclaim += 1
                            environment.log("\(FileAction.reclaim.logLabel) 成功: \(item.logLabel)")
                        } catch {
                            // 移动失败 → **曲目留库里**（与下方「文件动作失败 → 保留」同口径：
                            // 不加排除标记、不删 DB 引用——否则又回到「文件可见、曲目消失」的老 bug）
                            outcome.failed += 1
                            outcome.fileRemovalFailed += 1
                            outcome.processed += 1
                            let message = "⚠️ \(FileAction.reclaim.logLabel) 失败，保留曲目 \(item.stableId)（\(item.logLabel)）：\(error)"
                            environment.log(message)
                            onItemProcessed?(item, .failed)
                            onProgress?(outcome.processed, total)
                            continue
                        }
                    } else {
                        environment.log("文件不存在(磁盘已丢): \(absolutePath)")
                    }
                } else if policy.fileAction == .reclaim {
                    environment.log("文件在曲库根之外，保持旧语义(不碰磁盘): \(absolutePath)")
                }
                environment.excludeFromLibrary(item.stableId)
                outcome.excludedFromLibrary += 1
            } else if environment.fileExists(absolutePath) {
                do {
                    try performFileAction(policy.fileAction, path: absolutePath, environment: environment)
                    environment.log("\(policy.fileAction.logLabel) 成功: \(item.logLabel)")
                } catch {
                    // 文件动作失败 → **曲目留在库里**（旧 iOS 实现会继续删库引用，导致曲目
                    // 从库里消失、文件赖在磁盘上：用户看不见也删不掉。2026-09-17 已纠正）
                    outcome.failed += 1
                    outcome.fileRemovalFailed += 1
                    outcome.processed += 1
                    let message = "⚠️ \(policy.fileAction.logLabel) 失败，保留曲目 \(item.stableId)（\(item.logLabel)）：\(error)"
                    environment.log(message)
                    onItemProcessed?(item, .failed)
                    onProgress?(outcome.processed, total)
                    continue
                }
            } else {
                environment.log("文件不存在(磁盘已丢): \(absolutePath)")
            }
            // 走到这里：文件动作已完成 / 文件本来就不在磁盘 / 只从曲库移除 → 清 DB 引用

            do {
                try environment.deleteReference(item.stableId)
                outcome.deleted += 1
                outcome.processed += 1
                environment.log("deleteTrack 成功: \(item.logLabel)")
                onItemProcessed?(item, .deleted)
            } catch {
                outcome.failed += 1
                outcome.processed += 1
                let message = "❌ Failed to delete track \(item.stableId)（\(item.logLabel)）: \(error)"
                environment.log(message)
                onItemProcessed?(item, .failed)
            }
            onProgress?(outcome.processed, total)
        }

        return outcome
    }

    /// 策略 → 文件动作的唯一分发点（`.trash` / `.delete` / `.reclaim` 三条腿都只在 `Environment.live`
    /// 里落地；本函数是唯一调用点，别的文件不许再碰磁盘文件动作）。
    private static func performFileAction(
        _ action: FileAction,
        path: String,
        environment: Environment
    ) throws {
        switch action {
        case .trash: try environment.moveToTrash(path)
        case .delete: try environment.removePermanently(path)
        case .reclaim:
            // 前置条件：核心已确认该 path 在曲库根之内（根外文件根本不会走到这里）。
            try environment.moveToReclaimArea(
                path,
                DeleteReclaimArea.url(inLibraryRoot: environment.libraryRoot())
            )
        }
    }
}

// MARK: - 应用回收区（「只从曲库移除」保留文件的落点）

/// 「只从曲库移除」（`libraryOnly == true`）保留文件的**落点**：应用回收区。
///
/// 为什么要有它（2026-09-21 批 E-2）：iOS 用户删歌（设置 `deleteFromLibraryOnly` 默认 true）时
/// 文件留在曲库根里 → 对端 manifest 仍按「文件在 + 指纹来自文件回落」把该文件当「已有」→
/// 差集判「已一致」→ 该删的歌永远传不过去，而用户以为删掉了。改落点后：文件移出曲库根
/// （进 `.Trash`），**对端差集这才看得见「本端没有这首」**；文件不永久删除（原件仍可恢复）。
///
/// 唯一入口（禁第二实现）：
///   · 目录名常量 `directoryName`——取 `LibraryRoot.trashDirectoryName`（目录名唯一常量入口，
///     本文件不再自带字面量；形状契约白名单随之为 `LibraryRoot.swift`）；
///   · 路径派生 `url(inLibraryRoot:)`——曲库根由调用方给（生产 = `MusicFolderResolver.syncLibraryRoot`）；
///   · 目标命名 `destinationURL(in:contentHash:pathExtension:isTaken:)`（同名冲突追加 `-1` / `-2` …）；
///   · 移动实现 `move(_:into:)`（唯一碰磁盘的回收区动作，由 `Environment.live` 注入）。
///
/// 隐藏语义（回收区文件不会回到曲库）：目录名以 `.` 开头 = 隐藏目录 → 扫描口径
/// （`MusicDirectoryScanner.audioFilesSync` 的 `.skipsHiddenFiles`）天然不收录它 → 回收区里
/// 的文件不会重新入库、也不进 manifest。
///
/// 指纹：复用既有入口 `DatabaseManager.contentHashIfFilePresent`（SHA-256，与 `content_hash`
/// 同算法）——**不新写哈希实现**；读不到指纹（文件不可读 / iCloud 未下载）→ 抛错 →
/// 调用方按「文件动作失败 → 保留曲目」处理（fail-closed：不猜名字、不硬删）。
///
/// 落点口径与容器内既有事实一致：`Documents/.Trash/<64位hex>.<ext>`。
/// 本批不做回收区查看 / 恢复 UI，也不清理历史遗留残留文件。
enum DeleteReclaimArea {
    /// 回收区目录名（**唯一常量**；隐藏目录，见上方「隐藏语义」）。
    /// 取自 `LibraryRoot`（目录名唯一入口）——全仓该字面量只在 `LibraryRoot.swift` 里存在一份。
    static let directoryName = LibraryRoot.trashDirectoryName

    /// 同名后缀上限（防止病态输入下无界重试；实际不可达——同一个指纹 1000 份）。
    static let maximumConflictSuffix = 999

    /// 曲库根 → 回收区目录 URL（**唯一派生点**：禁在别处手拼 Documents/.Trash）。
    static func url(inLibraryRoot root: URL) -> URL {
        root.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// 文件是否位于曲库根之内。判据复用清单口径 `SyncManifestGenerator.relativePath`
    /// （同一份「是否在根内 / 相对路径」实现，禁另写一份路径前缀比较）；
    /// 入参接受**绝对路径或存储形态相对路径**（相对形态直接就是曲库内）。
    /// 根外（外部文件夹 / 用户原件）→ false ⇒ 调用方保持旧语义（不碰磁盘）。
    static func isInsideLibraryRoot(_ path: String, libraryRoot: URL) -> Bool {
        SyncManifestGenerator.relativePath(
            ofStoredTrackPath: path,
            libraryRoot: libraryRoot
        ) != nil
    }

    /// 目标文件 URL：`<contentHash>.<ext>`；同名冲突追加 `-1` / `-2` …（沿用容器既有命名口径）。
    /// 纯函数（存在性由 `isTaken` 注入）→ 可单测；不碰磁盘。
    static func destinationURL(
        in destinationRoot: URL,
        contentHash: String,
        pathExtension: String,
        isTaken: (String) -> Bool
    ) throws -> URL {
        for suffix in 0 ... maximumConflictSuffix {
            let name: String
            if suffix == 0 {
                name = pathExtension.isEmpty ? contentHash : "\(contentHash).\(pathExtension)"
            } else {
                name = pathExtension.isEmpty
                    ? "\(contentHash)-\(suffix)"
                    : "\(contentHash)-\(suffix).\(pathExtension)"
            }
            let candidate = destinationRoot.appendingPathComponent(name, isDirectory: false)
            if !isTaken(candidate.path) { return candidate }
        }
        throw ReclaimError.exhaustedNames(contentHash)
    }

    /// 把文件移入回收区（**唯一实现**，由 `Environment.live` 注入为 `moveToReclaimArea`）。
    /// - Parameters:
    ///   - path: 源文件路径（调用方已确认在曲库根之内）
    ///   - destinationRoot: 回收区目录（由 `url(inLibraryRoot:)` 派生）
    static func move(_ path: String, into destinationRoot: URL) throws {
        guard let hash = DatabaseManager.contentHashIfFilePresent(atPath: path) else {
            throw ReclaimError.contentHashUnavailable(path)
        }
        let source = URL(fileURLWithPath: path)
        let destination = try destinationURL(
            in: destinationRoot,
            contentHash: hash,
            pathExtension: source.pathExtension,
            isTaken: { FileManager.default.fileExists(atPath: $0) }
        )
        let manager = FileManager.default
        try manager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        try manager.moveItem(at: source, to: destination)
    }

    /// 回收区动作的错误（调用方统一按「文件动作失败 → 保留曲目」处理）。
    enum ReclaimError: Error, CustomStringConvertible {
        /// 指纹不可得（文件读不到 / iCloud 未下载）→ 不猜名字，保留曲目。
        case contentHashUnavailable(String)
        /// 同名后缀用尽（实际不可达；防无界重试的兜底）。
        case exhaustedNames(String)

        var description: String {
            switch self {
            case .contentHashUnavailable(let path):
                return "回收区落点需要内容指纹，但该文件读不到指纹（保留曲目）：\(path)"
            case .exhaustedNames(let hash):
                return "回收区同名后缀用尽（保留曲目）：\(hash)"
            }
        }
    }
}
