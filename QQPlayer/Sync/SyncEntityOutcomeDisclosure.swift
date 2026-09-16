//
//  SyncEntityOutcomeDisclosure.swift
//  QQPlayer
//
//  L6 续（2026-09-15，INV-18 剩余项）：**账目 → 面板**的唯一投影。
//
//  ════════════════════════════════════════════════════════════════════════════
//  为什么需要这个文件
//  ════════════════════════════════════════════════════════════════════════════
//  INV-18 的前半句（缺口必须计数并上屏）此前只做到「总数上屏」：面板显示
//  「未定位 110」，用户不可能知道是收藏、歌单项还是播放历史出的问题，也就不知道该修
//  哪条通道。后半句要求「**区分实体**」。
//
//  收口方式（与 `SyncOutcomeTally` 的分工）：
//  - `SyncOutcomeTally` = 计数的**唯一存储**（含 (实体, 结果) 二维分桶）；
//  - 本文件 = 计数 → 面板行的**唯一投影**：结果类别的展示归属（缺口 / 计数行）、
//    按实体披露的行、以及行文案的 i18n key。
//
//  ⚠️ 两端（Mac `MacSyncView` 的「同步数据」区 / iOS 设置页的「播放数据」区）都只准
//  从这里取，UI 文件里**不得**自算数字、不得自行枚举实体（`SyncEntityDisclosureContract`
//  静态扫描守住；合成自证证明断言不空转）。
//
//  ⚠️ 实体维度（哪些实体、什么顺序）来自注册表 `SyncEntityRegistry`（唯一声明处），
//  这里不手写实体名单。
//

import Foundation

/// 一类结果在面板上的**展示归属**。
enum SyncOutcomePlacement: Equatable {
    /// 缺口行：计数 > 0 才出现（附一句说明文案）。
    case gap(labelKey: String, hintKey: String)
    /// 正常计数行：恒出现（已应用 / 挂起 / 发出 / 忽略删除）。
    case count(labelKey: String)
}

/// 账目 → 面板行的**唯一投影**（两端面板共用；纯逻辑、零 IO、可单测）。
enum SyncEntityOutcomeDisclosure {
    // MARK: - 一行的形状

    /// 一条「按实体披露」的明细：某条实体的某类异常占多少条。
    struct Row: Equatable {
        var outcome: SyncRowOutcome
        var entity: SyncChangeEntity
        var count: Int
    }

    // MARK: - 结果类别的展示归属（唯一映射）

    /// 结果类别 → 展示归属（`switch` **无 `default`**：新增 `SyncRowOutcome` 类别时这里
    /// 编译不过，不会出现「新类别静默不上屏」）。
    /// key 复用两端面板已有文案（不新增汇总文案）。
    static func placement(of outcome: SyncRowOutcome) -> SyncOutcomePlacement {
        switch outcome {
        case .unresolved:
            return .gap(
                labelKey: "sync_run_data_result_unresolved",
                hintKey: "sync_run_data_unresolved_hint"
            )
        case .applyFailed:
            return .gap(
                labelKey: "sync_run_data_apply_failed",
                hintKey: "sync_run_data_apply_failed_hint"
            )
        case .ambiguousIdentity:
            return .gap(
                labelKey: "sync_run_data_ambiguous_identity",
                hintKey: "sync_run_data_ambiguous_identity_hint"
            )
        case .skippedMissingParent:
            return .gap(
                labelKey: "sync_run_data_skipped_parent",
                hintKey: "sync_run_data_skipped_parent_hint"
            )
        case .unsupported:
            return .gap(
                labelKey: "sync_run_data_unsupported",
                hintKey: "sync_run_data_unsupported_hint"
            )
        case .missingIdentity:
            return .gap(
                labelKey: "sync_run_data_result_missing_identity",
                hintKey: "sync_run_data_missing_identity_hint"
            )
        case .applied:
            return .count(labelKey: "sync_run_data_result_applied")
        case .suspended:
            return .count(labelKey: "sync_run_data_result_pending")
        case .outbound:
            return .count(labelKey: "sync_run_data_result_sent")
        case .ignoredDelete:
            return .count(labelKey: "sync_run_data_result_skipped")
        }
    }

    /// 缺口行展示顺序（严重度：未定位 → 应用失败 → 身份歧义 → 缺依赖 → 未支持 → 缺指纹）。
    /// ⚠️ 与 `countOrder` 合起来必须**恰好覆盖** `SyncRowOutcome.allCases`（有用例钉住）。
    static let gapOrder: [SyncRowOutcome] = [
        .unresolved,
        .applyFailed,
        .ambiguousIdentity,
        .skippedMissingParent,
        .unsupported,
        .missingIdentity,
    ]

    /// 正常计数行展示顺序（已应用 / 挂起 / 发送 / 忽略删除）。
    static let countOrder: [SyncRowOutcome] = [
        .applied,
        .suspended,
        .outbound,
        .ignoredDelete,
    ]

    // MARK: - 按实体披露（INV-18 后半句）

    /// 该类结果**要不要按实体披露**（`switch` **无 `default`**：新增类别必须在这里表态
    /// ——要么进 `entityDisclosureOrder`，要么明确「不按实体披露」）。
    ///
    /// 判据 = 「这条数字对用户意味着**有东西没落本地**」：未定位 / 应用失败 / 身份歧义 /
    /// 缺依赖 / 未支持 / 缺指纹 / 挂起。已应用（正常落库）、发出（出站事实）、忽略删除
    /// （删除不传播 = 设计行为，不是缺陷）不按实体披露。
    static func disclosesByEntity(_ outcome: SyncRowOutcome) -> Bool {
        switch outcome {
        case .unresolved, .applyFailed, .ambiguousIdentity, .skippedMissingParent,
             .unsupported, .missingIdentity, .suspended:
            return true
        case .applied, .outbound, .ignoredDelete:
            return false
        }
    }

    /// 按实体披露的顺序（严重度；与 `gapOrder` 同序，末尾补上「挂起」——挂起是**可自愈**
    /// 的暂态，排在最后）。⚠️ 必须**恰好等于** `allCases.filter(disclosesByEntity)` 的
    /// 集合（有用例钉住：新增类别漏表态 / 重复表态即红）。
    static let entityDisclosureOrder: [SyncRowOutcome] = [
        .unresolved,
        .applyFailed,
        .ambiguousIdentity,
        .skippedMissingParent,
        .unsupported,
        .missingIdentity,
        .suspended,
    ]

    /// 披露行 = **只出计数 > 0 的 (结果, 实体) 组合**（正常实体不占行；别做成恒零噪音表）。
    ///
    /// 顺序 = 结果严重度（`entityDisclosureOrder`）× 实体（注册表声明顺序）。
    /// 数字一律走 `tally`（UI 层不得补算，INV-19）。
    static func rows(_ tally: SyncOutcomeTally) -> [Row] {
        var rows: [Row] = []
        for outcome in entityDisclosureOrder {
            for group in tally.entityGroups(for: outcome) {
                rows.append(Row(outcome: outcome, entity: group.entity, count: group.count))
            }
        }
        return rows
    }

    // MARK: - 文案 key（View 只负责取本地化值并显示）

    /// 按实体披露区的标题 key。
    static let breakdownTitleKey = "sync_run_data_entity_breakdown"

    /// 一行文案的组合格式 key（`%1$@` = 结果类别名，`%2$@` = 实体名）。
    /// 顺序与分隔符放进 .strings（不在代码里硬拼，避免各语言语序不同时无处可改）。
    static let rowFormatKey = "sync_run_data_entity_row"

    /// 实体名 key：由 `SyncChangeEntity.rawValue` 派生（**新增实体 = 新增一个 key**；
    /// 五语齐全由用例遍历 `allCases` 守住，也不会与注册表名单漂移）。
    static func entityLabelKey(_ entity: SyncChangeEntity) -> String {
        "sync_run_data_entity_\(entity.rawValue)"
    }

    /// 结果类别名 key（取自 `placement`，不另立第二份映射）。
    static func outcomeLabelKey(_ outcome: SyncRowOutcome) -> String {
        switch placement(of: outcome) {
        case let .gap(labelKey, _): return labelKey
        case let .count(labelKey): return labelKey
        }
    }

    /// 缺口类别的说明文案 key（恒出现计数行 = nil）。
    static func outcomeHintKey(_ outcome: SyncRowOutcome) -> String? {
        guard case let .gap(_, hintKey) = placement(of: outcome) else { return nil }
        return hintKey
    }

    /// 一行文案（结果类别名 · 实体名）。两端面板共用，避免各写一套拼接。
    static func rowLabel(_ row: Row) -> String {
        rowFormatKey.localized(
            with: outcomeLabelKey(row.outcome).localized,
            entityLabelKey(row.entity).localized
        )
    }

    // MARK: - 文件层（歌词）披露（F2「歌词丢弃必须计数上屏」，2026-09-16）

    /// 文件层披露行：一条**非 changeLog 实体**的计数（目前唯一 = 对齐歌词）。
    ///
    /// 为什么不塞进 `Row`：那里的维度是 changeLog **实体**（收藏 / 播放历史 / 歌单…，
    /// 来自注册表），而对齐歌词是**文件层**事实（依附歌曲的内容），没有实体归属；
    /// 硬凑一个实体 case 会把「注册表 = 实体唯一声明处」这条口径弄脏。
    /// 两者共用同一条纪律：**数字由账目给、行文案 key 由投影给，界面层不自算**。
    struct FileRow: Equatable {
        /// 行标签 key（文案自带 `%d` 占位时由调用方 `localized(with:)` 填数）
        var labelKey: String
        /// 说明 key（缺口类才有；正常计数行为 nil）
        var hintKey: String?
        /// 是否算缺口（界面据此上色；颜色本身属界面层）
        var isGap: Bool
        var count: Int
    }

    /// 区标题 key（「对齐歌词」）。
    static let lyricsSectionTitleKey = "sync_lyrics_section"
    /// 一行行文案 key。
    static let lyricsDiscardedLabelKey = "sync_lyrics_discarded"
    static let lyricsDiscardedHintKey = "sync_lyrics_discarded_hint"
    static let lyricsPendingResendLabelKey = "sync_lyrics_pending_resend"
    static let lyricsPendingResendHintKey = "sync_lyrics_pending_resend_hint"
    static let lyricsKeptLocalLabelKey = "sync_lyrics_kept_local"

    /// 文件层（歌词）需要五语齐全的 key（契约测试遍历它；新增 key 即红）。
    static let lyricsKeys: [String] = [
        lyricsSectionTitleKey,
        lyricsDiscardedLabelKey,
        lyricsDiscardedHintKey,
        lyricsPendingResendLabelKey,
        lyricsPendingResendHintKey,
        lyricsKeptLocalLabelKey,
    ]

    /// 区标题 key（「歌单自定义封面」）。
    static let coverSectionTitleKey = "sync_cover_section"
    /// 「读不到」行 key（文案自带 `%d`）。
    static let coverUnavailableLabelKey = "sync_cover_unavailable"
    /// 该行说明 key（自带 `%d`）。
    static let coverUnavailableHintKey = "sync_cover_unavailable_hint"

    /// 文件层（封面）需要五语齐全的 key（契约测试遍历它；新增 key 即红）。
    static let coverKeys: [String] = [
        coverSectionTitleKey,
        coverUnavailableLabelKey,
        coverUnavailableHintKey,
    ]

    /// 歌单自定义封面账目 → 披露行（**只出计数 > 0**；缺口类）。
    ///
    /// 数字来源 = `PlaylistCoverLoadFailuresStore.count`（按歌单去重：几个歌单的封面出问题），
    /// 界面层不得自己数（同一纪律见 `lyricsRows`）。
    static func coverRows(unavailable: Int) -> [FileRow] {
        guard unavailable > 0 else { return [] }
        return [FileRow(
            labelKey: coverUnavailableLabelKey,
            hintKey: coverUnavailableHintKey,
            isGap: true,
            count: unavailable
        )]
    }

    /// 歌词账目 → 披露行（**只出计数 > 0 的行**；顺序 = 丢弃 → 待补 → 保留本端）。
    ///
    /// 三个数字的口径（都来自账目，界面层不得补算）：
    /// - `discarded`：收到但本端还没有对应歌曲 → 已丢弃（下一轮自动补发）
    /// - `pendingResend`：本轮没确认送达的补发条目（下次机会重试）
    /// - `keptLocal`：本端已有对齐结果 → 按 F2「只补不覆盖」保留本端（正常计数行，非缺口）
    static func lyricsRows(discarded: Int, pendingResend: Int, keptLocal: Int) -> [FileRow] {
        var rows: [FileRow] = []
        if discarded > 0 {
            rows.append(FileRow(
                labelKey: lyricsDiscardedLabelKey,
                hintKey: lyricsDiscardedHintKey,
                isGap: true,
                count: discarded
            ))
        }
        if pendingResend > 0 {
            rows.append(FileRow(
                labelKey: lyricsPendingResendLabelKey,
                hintKey: lyricsPendingResendHintKey,
                isGap: true,
                count: pendingResend
            ))
        }
        if keptLocal > 0 {
            rows.append(FileRow(
                labelKey: lyricsKeptLocalLabelKey,
                hintKey: nil,
                isGap: false,
                count: keptLocal
            ))
        }
        return rows
    }
}
