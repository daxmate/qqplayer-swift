//
//  MacTrashService.swift
//  QQPlayer
//
//  批量「移到废纸篓」执行层（2026-09-12 审计批次 B4 · H1/M1；无 AppKit 依赖 →
//  QQPlayerMac 与 iOS 共享，可在 iOS 测试 target 单测）。
//
//  缺陷（审计 H1）：批量删除原先整批在 `@MainActor` 的 `Task` 里逐首同步执行
//  `FileManager.trashItem` + `DatabaseManager.deleteTrack`。前者对 iCloud/dataless
//  文件与外接卷会走网络往返（本仓库已有 dataless 补扫逻辑，用户库内确实存在此类
//  文件），后者是同步 DB 写；右键多选一次可传数百首 → 主线程被占满数十秒，
//  窗口无响应且期间无法取消。
//
//  设计：把「逐首处理 + 计数」下沉为本文件的 `nonisolated` async 函数——
//  SE-0338 保证它在全局执行器上跑（不是调用方 actor），磁盘/DB 一律经注入的
//  闭包访问，故既能真正离开主线程，也能在测试里用假文件系统/假 DB 覆盖全部分支。
//  调用方只负责：把 @State 落表与通知 hop 回主线程。
//
//  删除语义（web 版「移到废纸篓」对齐，逐字保留修复前实现）：
//  - 文件不存在（磁盘已丢）→ 照常清理 DB 引用，计入 deleted；
//  - trash 失败且文件还在 → 计 failed 并保留曲目（**不**删 DB 引用）；
//  - DB 删除失败 → 计 failed。
//  可取消：逐首之间检查取消状态，取消后剩余曲目不再处理（已处理的照常计入结论）。
//

import Foundation

enum MacTrashService {
    /// 一首待删除曲目（只带执行所需字段，避免跨隔离搬运整个 Track）。
    struct Item: Sendable, Equatable {
        let stableId: String
        let title: String
        let path: String
    }

    /// 进度（供调用方在主线程展示「12/300」）。
    struct Progress: Sendable, Equatable {
        var done: Int
        var total: Int
    }

    /// 单首结论（日志/诊断用）。
    enum ItemOutcome: Sendable, Equatable {
        /// 磁盘（或文件已丢）+ DB 引用均处理完成
        case deleted
        /// trash 失败（文件仍在）或 DB 删除失败
        case failed
    }

    /// 批次结论（`failedCount` / `deletedAny` 与修复前的局部计数同义）。
    struct BatchResult: Sendable, Equatable {
        var failedCount = 0
        var deletedAny = false
        /// 实际处理（含失败）的曲目数 = 取消时的进度
        var processedCount = 0
        /// 逐首之间被取消（剩余曲目未处理）
        var cancelled = false
    }

    /// 执行环境：生产走系统 FileManager + DatabaseManager，测试注入假实现。
    /// 闭包一律 `@Sendable`——本类型会在非主 actor 上执行。
    struct Environment: Sendable {
        var fileExists: @Sendable (String) -> Bool
        var trashItem: @Sendable (String) throws -> Void
        var deleteRecord: @Sendable (String) throws -> Void
        var log: @Sendable (String) -> Void
        /// 逐首之间的取消检查（生产 = `Task.isCancelled`；测试注入计数/条件）
        var isCancelled: @Sendable () -> Bool

        /// 生产实现：系统废纸篓 + 曲库 DB。日志出口由调用方注入——
        /// `MacTrashLogger` 定义在 Mac-only 的 `Mac/MacScanLogger.swift`，
        /// 共享层（iOS target 也编译本文件）不得引用。
        static func live(log: @escaping @Sendable (String) -> Void) -> Environment {
            Environment(
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                trashItem: { try FileManager.default.trashItem(at: URL(fileURLWithPath: $0), resultingItemURL: nil) },
                deleteRecord: { try DatabaseManager.shared.deleteTrack(byStableId: $0) },
                log: log,
                isCancelled: { Task.isCancelled }
            )
        }
    }

    /// 逐首处理整批曲目（`nonisolated async` → 不占主线程；可取消；可测试）。
    /// - Parameters:
    ///   - items: 待删除曲目（顺序 = 处理顺序）
    ///   - environment: 执行环境（生产传 `.live`）
    ///   - onItemProcessed: 每首处理完回调（诊断/进度日志）
    ///   - onProgress: 每首处理完回调（done, total）——调用方自行 hop 主线程落 @State
    /// - Returns: 批次结论
    static func trash(
        items: [Item],
        environment: Environment,
        onItemProcessed: (@Sendable (Item, ItemOutcome) -> Void)? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> BatchResult {
        var result = BatchResult()
        guard !items.isEmpty else { return result }
        let total = items.count

        for item in items {
            if environment.isCancelled() {
                result.cancelled = true
                break
            }

            environment.log("开始处理: \(item.title) | path=\(item.path)")
            // web 语义：磁盘文件不存在（已丢）→ 照常清理引用计入 deleted；
            // trash 失败且文件还在 → errors（保留曲目）
            if environment.fileExists(item.path) {
                do {
                    try environment.trashItem(item.path)
                    environment.log("trashItem 成功: \(item.title)")
                } catch {
                    result.failedCount += 1
                    let msg = "🗑️ moveToTrash failed for \(item.title): \(error)"
                    print(msg)
                    environment.log(msg)
                    result.processedCount += 1
                    onItemProcessed?(item, .failed)
                    onProgress?(result.processedCount, total)
                    continue
                }
            } else {
                environment.log("文件不存在(磁盘已丢): \(item.path)")
            }

            do {
                try environment.deleteRecord(item.stableId)
                result.deletedAny = true
                environment.log("deleteTrack 成功: \(item.title)")
                result.processedCount += 1
                onItemProcessed?(item, .deleted)
            } catch {
                result.failedCount += 1
                let msg = "🗑️ deleteTrack failed for \(item.title): \(error)"
                print(msg)
                environment.log(msg)
                result.processedCount += 1
                onItemProcessed?(item, .failed)
            }
            onProgress?(result.processedCount, total)
        }

        return result
    }
}
