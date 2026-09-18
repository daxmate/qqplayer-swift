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
//    - `fileAction`：`.trash`（默认，进废纸篓可恢复）/ `.delete`（永久删除）——用户 2026-09-18 拍板
//    - `libraryOnly`：沿用既有开关语义（iOS 读 `DeleteSettings.deleteFromLibraryOnly`）
//    - 进度 / 取消：Mac 既有能力原样保留（`onProgress` / `Environment.isCancelled`）
//
//  平台差异从此是**数据**（Policy），不再是第二份代码。
//
//  语义（两端逐条保留，唯一变化 = 用户拍板的「默认文件动作改为进废纸篓」）：
//  - `libraryOnly == true`：只加排除标记（文件留在磁盘，下次扫描不再入库），再删 DB 引用；
//  - 文件动作失败 → **保留曲目**（不删 DB 引用）并计 failed——曲目留在库里，用户看得见也删得掉；
//  - 文件已不在磁盘 → 不当失败，照常清 DB 引用（Mac 既有语义）；
//  - DB 删除失败 → 计 failed，其余曲目照常继续；
//  - 取消（仅 Mac 生产路径传 `Task.isCancelled`）：逐首之间检查，剩余曲目不再处理；
//  - iOS 生产路径每次调用只 post **一次** `.libraryNeedsRefresh`（单曲 = 1 次，批量 = 末尾 1 次）。
//
//  文件动作（`FileManager.trashItem` / `FileManager.removeItem`）**只允许出现在本文件**
//  （`Environment.live` 一处），由形状契约测试
//  `QQPlayerTests/TrackDeletionShapeContractTests.swift` 静态守护（白名单只留本文件）。
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
        /// 移到系统废纸篓（可恢复）——**生产默认**（用户 2026-09-18 拍板：可恢复优先）。
        case trash
        /// 永久删除（不可恢复）。
        case delete

        /// 日志标签（沿用 Mac 端历史日志文本 `trashItem 成功` / `removeItem 成功`）。
        var logLabel: String {
            switch self {
            case .trash: return "trashItem"
            case .delete: return "removeItem"
            }
        }
    }

    /// 一次删除的策略（显式传入，不从环境里偷偷读）。
    struct Policy: Sendable {
        /// 磁盘文件动作（默认进废纸篓）。
        var fileAction: FileAction = .trash
        /// 沿用既有开关语义：true = 只从曲库移除，不碰磁盘（连存在性都不查）。
        var libraryOnly: Bool = false

        /// 生产默认：进废纸篓 + 全删。`libraryOnly` 由调用点按设置覆盖。
        static let `default` = Policy()
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
        /// `libraryOnly` 分支：加排除标记（不碰磁盘）。
        var excludeFromLibrary: @Sendable (String) -> Void
        /// 清 DB 引用。
        var deleteReference: @Sendable (String) throws -> Void
        /// 过程日志出口（Mac 写 trash.log；iOS 现状无日志出口 → 传空实现，失败仍 `print`）。
        var log: @Sendable (String) -> Void
        /// 逐首之间的取消检查（生产：iOS 不取消 = 默认 `{ false }`；Mac = `Task.isCancelled`）。
        /// 与「删什么/怎么删」无关——它是执行环境事实，故放这里而不是 Policy。
        var isCancelled: @Sendable () -> Bool

        /// 生产实现：系统废纸篓/永久删除 + 曲库 DB。
        /// `trashItem` 在 iOS 18 SDK 与 macOS 同样可用（2026-09-18 实测：两端均可编译）。
        static func live(
            log: @escaping @Sendable (String) -> Void,
            isCancelled: @escaping @Sendable () -> Bool = { false }
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
                excludeFromLibrary: { DeleteSettings.addExcludedTrack($0) },
                deleteReference: { try DatabaseManager.shared.deleteTrack(byStableId: $0) },
                log: log,
                isCancelled: isCancelled
            )
        }
    }

    // MARK: - 生产路径 · iOS（主线程同步；每次调用一次通知）

    /// 删除若干曲目。iOS 视图层只调这一个方法，不再自己读设置 / 碰文件 / 碰数据库。
    /// 线程语义保留（这一直是主线程同步逐首；iOS 无进度/取消需求）。
    @MainActor
    @discardableResult
    static func delete(items: [Item]) -> Outcome {
        let settings = DeleteSettings.load()
        let outcome = delete(
            items: items,
            policy: Policy(
                fileAction: .trash,
                libraryOnly: settings.deleteFromLibraryOnly
            ),
            environment: .live(log: { _ in })
        )
        NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)
        return outcome
    }

    // MARK: - 生产路径 · Mac（nonisolated async → 不占主线程；可取消；带进度）

    /// 批量「移到废纸篓」（沿用原 `MacTrashService.trash` 语义：非主 actor 逐首执行、
    /// 可取消（由 `environment.isCancelled` 提供探测）、带进度回调；
    /// 等价于 `Policy(fileAction: .trash, libraryOnly: false)` 的核心调用）。
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
            policy: Policy(fileAction: .trash, libraryOnly: false),
            environment: environment,
            onItemProcessed: onItemProcessed,
            onProgress: onProgress
        )
    }

    // MARK: - 核心（依赖注入，测试用；两端生产路径唯一实现）

    /// 逐首执行删除；**不做隔离假设**，调用方决定在哪个 actor 上跑。
    static func delete(
        items: [Item],
        policy: Policy = .default,
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

            if policy.libraryOnly {
                environment.excludeFromLibrary(item.stableId)
                outcome.excludedFromLibrary += 1
            } else if environment.fileExists(item.path) {
                do {
                    try performFileAction(policy.fileAction, path: item.path, environment: environment)
                    environment.log("\(policy.fileAction.logLabel) 成功: \(item.logLabel)")
                } catch {
                    // 文件动作失败 → **曲目留在库里**（旧 iOS 实现会继续删库引用，导致曲目
                    // 从库里消失、文件赖在磁盘上：用户看不见也删不掉。2026-09-17 已纠正）
                    outcome.failed += 1
                    outcome.fileRemovalFailed += 1
                    outcome.processed += 1
                    let message = "⚠️ \(policy.fileAction.logLabel) 失败，保留曲目 \(item.stableId)（\(item.logLabel)）：\(error)"
                    print(message)
                    environment.log(message)
                    onItemProcessed?(item, .failed)
                    onProgress?(outcome.processed, total)
                    continue
                }
            } else {
                environment.log("文件不存在(磁盘已丢): \(item.path)")
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
                print(message)
                environment.log(message)
                onItemProcessed?(item, .failed)
            }
            onProgress?(outcome.processed, total)
        }

        return outcome
    }

    /// 策略 → 文件动作的唯一分发点（`.trash` / `.delete` 两条腿都只在 `Environment.live` 里落地）。
    private static func performFileAction(
        _ action: FileAction,
        path: String,
        environment: Environment
    ) throws {
        switch action {
        case .trash: try environment.moveToTrash(path)
        case .delete: try environment.removePermanently(path)
        }
    }
}
