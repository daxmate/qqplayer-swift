//
//  LibraryView+ImportSupport.swift
//  QQPlayer
//
//  音乐库主页**导入支撑**：导入结果分桶 `ImportOutcomeTally`（只消费唯一入口
//  `LibraryIndexer.processExternalFileOutcome` 的返回值，不重复判定）与外部文件
//  **书签落库** `storeBookmarkData`（原子写，经 `ExternalFileBookmarkStore` 唯一入口）。
//
//  2026-09-21 从 LibraryView.swift 原样搬出（纯搬家，无逻辑变更）。同族文件：
//    · Views/Library/LibraryView.swift                     — 视图壳：stored property + `body` + 导入入口
//    · Views/Library/LibraryView+ImportSupport.swift       — 导入结果分桶 + 书签落库
//    · Views/Library/LibraryView+SectionRendering.swift    — 首页分区视图（homeSectionView）
//    · Views/Library/LibraryView+SyncFeedback.swift        — 同步反馈 toast + runSync
//    · Views/Library/LibraryView+SectionRow.swift          — 首页分区行（LibrarySectionRowView）
//    · Views/Library/LibraryView+ResponsiveFonts.swift     — View 响应式字号 helper
//
// target: ios-only（LibraryView 分片：消费端全在 iOS；Mac 侧为 MacLibraryView）

import SwiftUI

extension LibraryView {
    /// 导入结果分桶：面板只把**唯一入口**（`LibraryIndexer.processExternalFileOutcome`）
    /// 给出的结果分桶，不在这里重复判定（旧代码把 `false` 一律说成「already in library」）。
    /// 分片：跨文件可见（原 private）
    struct ImportOutcomeTally {
        var added = 0
        var updated = 0
        var alreadyPresent = 0
        var excluded = 0
        var failed = 0

        mutating func record(_ outcome: ExternalImportOutcome) {
            switch outcome {
            case .imported: added += 1
            case .updatedExisting: updated += 1
            case .alreadyPresent: alreadyPresent += 1
            case .excluded: excluded += 1
            case .failed: failed += 1
            }
        }

        /// 一个文件都没走过 → 不弹 toast。
        var isEmpty: Bool {
            added + updated + alreadyPresent + excluded + failed == 0
        }

        /// 曲库内容真的变了（决定要不要触发一次手动同步对齐）。
        var changedLibrary: Bool { added > 0 || updated > 0 }

        /// 只列非零桶；有失败必须说出来。
        var summary: String {
            var parts: [String] = []
            if added > 0 {
                parts.append(
                    added == 1
                        ? "import_result_added_one".localized
                        : String(format: "import_result_added_many".localized, added)
                )
            }
            if updated > 0 {
                parts.append(String(format: "import_result_updated_many".localized, updated))
            }
            if alreadyPresent > 0 {
                parts.append(String(format: "import_result_present_many".localized, alreadyPresent))
            }
            if excluded > 0 {
                parts.append(String(format: "import_result_excluded_many".localized, excluded))
            }
            if failed > 0 {
                parts.append(String(format: "import_result_failed_many".localized, failed))
            }
            return parts.joined(separator: "import_result_separator".localized)
        }

        /// 有失败 → 警示图标（用户才会去重试）。
        var icon: String {
            if failed > 0 { return "exclamationmark.triangle.fill" }
            if added > 0 { return "plus.circle.fill" }
            if updated > 0 { return "checkmark.circle.fill" }
            return "info.circle.fill"
        }

        var color: Color {
            if failed > 0 { return .orange }
            if added > 0 || updated > 0 { return .green }
            return .blue
        }
    }

    /// 分片：跨文件可见（原 private）
    func storeBookmarkData(_ bookmarkData: Data, for url: URL) async {
        // 书签唯一入口：原子写（此前是原地截断写，被杀即整份书签不可解析，见审计 🔴-2）
        guard let store = ExternalFileBookmarkStore.default else {
            AppLog.error(.ui, "Failed to resolve documents directory")
            return
        }

        do {
            // Generate stableId for this file
            let stableId = try libraryIndexer.generateStableId(for: url)

            // Store bookmark using stableId as key (survives file moves)
            try store.upsert(bookmarkData, forStableId: stableId)

            if AppLog.isEnabled(.debug, .ui) { AppLog.debug(.ui, "Stored bookmark for external file: \(url.lastPathComponent) with stableId: \(stableId)") }
        } catch {
            AppLog.error(.ui, "Failed to store bookmark data: \(error)")
        }
    }
}
