//
//  TrackDeletionService.swift
//  QQPlayer
//
// target: ios-only
//
//  （Mac 端删除走 MacTrashService：trash + 失败保留曲目。两套语义是否合流是独立决策，
//   不在此处顺手拉进来；合流时再改本行与 mac-whitelist。）
//
//  曲目删除的唯一入口（2026-09-17 P0 收口）。
//
//  背景（审计 2026-09-12 · views 模块）：同一段「删除一首歌」的仪式在视图层抄了 **7 份**——
//    ① 读 `DeleteSettings.deleteFromLibraryOnly`
//    ② 是 → `DeleteSettings.addExcludedTrack`；否 → `FileManager.removeItem`
//    ③ `DatabaseManager.deleteTrack(byStableId:)`
//    ④ post `.libraryNeedsRefresh`
//  7 份还各不相同（有的 `try` 有的 `try?`，单曲路径报错、批量路径静默），
//  属于「同一语义多处手工维护」——漏一处就是静默不一致（AGENTS.md 2026-09-15 纪律）。
//
//  这里把它收成一个入口：视图只负责「把哪些曲目打包成 Item」，其余全在此处。
//
//  行为（**逐字保留修复前的可观察行为**，只做去重，不改语义）：
//  - `libraryOnly == true`：只加排除标记（文件留在磁盘，下次扫描不再入库），不删文件；
//  - `libraryOnly == false`：删文件；文件删失败只记数 + 打日志，**不影响** DB 引用删除
//    （与 iOS 侧既有实现一致；macOS 的「trash 失败则保留曲目」是另一套语义，
//     见 `MacTrashService`，后续批次再决定是否合流）；
//  - DB 删除失败 → 该曲目计 failed，其余照常继续；
//  - 每次调用只 post **一次** `.libraryNeedsRefresh`（单曲=1 次，批量=末尾 1 次，同现状）。
//
//  依赖注入（4 个闭包）只为可测：生产走 `delete(items:)`，测试走 `delete(items:...)` 核心。
//

import Foundation

enum TrackDeletionService {
    /// 一首待删除曲目（只带执行所需字段，避免搬运整个 Track）。
    struct Item: Sendable, Equatable {
        let stableId: String
        let path: String

        init(stableId: String, path: String) {
            self.stableId = stableId
            self.path = path
        }

        init(track: Track) {
            self.stableId = track.stableId
            self.path = track.path
        }
    }

    /// 批次结论（供调用方决定要不要提示用户；语义固定，不随调用点变化）。
    struct Outcome: Sendable, Equatable {
        /// 文件（或排除标记）与 DB 引用都处理完成的曲目数。
        var deleted: Int = 0
        /// DB 引用删除失败（曲目仍在库）的曲目数。
        var failed: Int = 0
        /// 走「只从曲库移除、保留文件」分支的曲目数（含在 `deleted` 内）。
        var excludedFromLibrary: Int = 0
        /// 磁盘文件删除失败的曲目数（DB 引用照常删除，故不并入 `failed`）。
        var fileRemovalFailed: Int = 0

        var deletedAny: Bool { deleted > 0 }
    }

    // MARK: - 唯一入口（生产路径）

    /// 删除若干曲目。视图层只调这一个方法，不再自己读设置 / 碰文件 / 碰数据库。
    @MainActor
    @discardableResult
    static func delete(items: [Item]) -> Outcome {
        let settings = DeleteSettings.load()
        let outcome = delete(
            items: items,
            libraryOnly: settings.deleteFromLibraryOnly,
            excludeFromLibrary: { DeleteSettings.addExcludedTrack($0) },
            removeFile: { path in
                try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
            },
            deleteReference: { stableId in
                try DatabaseManager.shared.deleteTrack(byStableId: stableId)
            }
        )
        NotificationCenter.default.post(name: .libraryNeedsRefresh, object: nil)
        return outcome
    }

    // MARK: - 核心（依赖注入，测试用）

    /// 逐首执行删除；**不做隔离假设**，调用方决定在哪个 actor 上跑。
    static func delete(
        items: [Item],
        libraryOnly: Bool,
        excludeFromLibrary: (String) -> Void,
        removeFile: (String) throws -> Void,
        deleteReference: (String) throws -> Void
    ) -> Outcome {
        var outcome = Outcome()
        for item in items {
            if libraryOnly {
                excludeFromLibrary(item.stableId)
                outcome.excludedFromLibrary += 1
            } else {
                do {
                    try removeFile(item.path)
                } catch {
                    outcome.fileRemovalFailed += 1
                    print("⚠️ Could not remove file from disk: \(error.localizedDescription)")
                }
            }

            do {
                try deleteReference(item.stableId)
                outcome.deleted += 1
            } catch {
                outcome.failed += 1
                print("❌ Failed to delete track \(item.stableId): \(error)")
            }
        }
        return outcome
    }
}
