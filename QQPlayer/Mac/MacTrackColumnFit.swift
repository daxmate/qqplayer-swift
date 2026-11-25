//
//  MacTrackColumnFit.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  曲目列表三根弹性列的渲染期宽度收敛（2026-11-25 从 MacTrackColumnResizer.swift 拆出，
//  控结构预算；判定逻辑未改）。纯逻辑：不碰 AppKit 视图，只做数值夹紧，
//  由 scripts/mac-column-width-harness 直编断言。
//

import CoreGraphics

// MARK: - 列宽口径（唯一真相源）

/// 三根弹性列的宽度（**单一真相源**，语义见文件头）。
struct MacTrackColumnWidths: Equatable {
    var title = MacTrackColumnLayout.titleInitialWidth
    var artist = MacTrackColumnLayout.artistInitialWidth
    var album = MacTrackColumnLayout.albumInitialWidth
}

/// 列布局口径：列序 / 最小宽度 / 可拖边界。列序与 TableColumn 声明顺序一致。
enum MacTrackColumnLayout {
    // 列序：0 封面(固定) / 1 标题 / 2 艺人 / 3 专辑 / 4 时长(固定) / 5 ♥(固定)
    static let titleIndex = 1
    static let artistIndex = 2
    static let albumIndex = 3
    static let minimumColumnCount = 6

    static let titleInitialWidth: CGFloat = 300
    static let artistInitialWidth: CGFloat = 140
    static let albumInitialWidth: CGFloat = 180

    static let titleMinWidth: CGFloat = 120
    static let artistMinWidth: CGFloat = 60
    static let albumMinWidth: CGFloat = 60

    /// 热区半宽：边界 ±4pt
    static let boundaryHitHalfWidth: CGFloat = 4

    /// 一条可拖边界 = 相邻两列的列序
    struct Boundary {
        let left: Int
        let right: Int
    }

    /// 只接「两根都是弹性列」的边界：标题|艺人、艺人|专辑。
    /// 固定列（封面/时长/♥）的边界不接管——拖动它们没有合理语义。
    static let boundaries = [
        Boundary(left: titleIndex, right: artistIndex),
        Boundary(left: artistIndex, right: albumIndex),
    ]

    static func minWidth(ofColumn index: Int) -> CGFloat {
        switch index {
        case titleIndex: titleMinWidth
        case artistIndex: artistMinWidth
        case albumIndex: albumMinWidth
        default: 0
        }
    }

    /// 三根弹性列的最小宽度（渲染期夹紧的下界）
    static var minimumWidths: MacTrackColumnWidths {
        MacTrackColumnWidths(title: titleMinWidth, artist: artistMinWidth, album: albumMinWidth)
    }

    // MARK: 固定列宽（唯一口径；MacTrackListMetrics 直接引用这里，避免两处数值漂移）

    /// 行内封面列（封面 34 + 左右各 6）
    static let artworkColumnWidth: CGFloat = 46
    /// 时长列（右对齐、等宽数字、不可拉伸）
    static let durationColumnWidth: CGFloat = 56
    /// 行尾悬停操作列（♥ 槽位）
    static let actionColumnWidth: CGFloat = 40

    /// 固定列合计宽：不参与弹性列宽分配
    static var fixedColumnsWidth: CGFloat {
        artworkColumnWidth + durationColumnWidth + actionColumnWidth
    }

    /// 列宽收敛的余量：NSTableView 的单元格间距不是 0，留一点点避免「正好卡满」时出横向滚动条
    static let columnFitSlack: CGFloat = 12
}

/// 渲染期列宽夹紧（纯逻辑，见 `scripts/mac-column-width-harness`）。
///
/// 为什么需要：三根弹性列的持久化宽是「用户意图宽」（初始 300 / 140 / 180），
/// 中栏可用宽只有 320–600；总宽一旦超过可用宽，macOS 15 的 NSTableView 会直接
/// 出现横向滚动条并把艺人名截成「李宗」「梁咏」。这里只压不放：
/// 窗口只是变宽时不会被这里撑出用户没拖过的宽度，所以**不回写**持久化。
enum MacTrackColumnFit {
    /// 把三根弹性列的宽度压进 `availableWidth - fixedWidth`。
    ///
    /// 语义（顺序即优先级）：
    /// 1. 总宽 ≤ 预算：原样（只向下取整，避免半像素累积出滚动条）；
    /// 2. 总宽 > 预算：先压「高出最小宽的那部分」（等比）→ 各列都保住最小宽；
    /// 3. 连最小宽都放不下（窗口极窄）：按最小宽比例硬压 → **保证不出横向滚动条**。
    static func fitted(
        _ desired: MacTrackColumnWidths,
        availableWidth: CGFloat,
        fixedWidth: CGFloat,
        minimums: MacTrackColumnWidths
    ) -> MacTrackColumnWidths {
        let budget = (availableWidth - fixedWidth).rounded(.down)
        guard budget > 0 else { return MacTrackColumnWidths(title: 0, artist: 0, album: 0) }

        let desiredValues = [sanitized(desired.title), sanitized(desired.artist), sanitized(desired.album)]
        guard totals(desiredValues) > budget else {
            return pack(desiredValues.map { $0.rounded(.down) })
        }

        let minimumValues = [sanitized(minimums.title), sanitized(minimums.artist), sanitized(minimums.album)]
        let slackValues = zip(desiredValues, minimumValues).map { max(0, $0 - $1) }
        let slackTotal = totals(slackValues)
        let deficit = totals(desiredValues) - budget

        if slackTotal > 0, slackTotal >= deficit {
            let keep = (slackTotal - deficit) / slackTotal
            return pack(zip(minimumValues, slackValues).map { ($0 + $1 * keep).rounded(.down) })
        }

        let minimumTotal = totals(minimumValues)
        guard minimumTotal > 0 else { return MacTrackColumnWidths(title: 0, artist: 0, album: 0) }
        let ratio = budget / minimumTotal
        return pack(minimumValues.map { ($0 * ratio).rounded(.down) })
    }

    /// 三列合计宽（测试与调用方共用口径）
    static func total(of widths: MacTrackColumnWidths) -> CGFloat {
        totals([widths.title, widths.artist, widths.album])
    }

    private static func sanitized(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }

    private static func totals(_ values: [CGFloat]) -> CGFloat {
        values.reduce(0, +)
    }

    private static func pack(_ values: [CGFloat]) -> MacTrackColumnWidths {
        MacTrackColumnWidths(
            title: values.isEmpty ? 0 : values[0],
            artist: values.count > 1 ? values[1] : 0,
            album: values.count > 2 ? values[2] : 0
        )
    }
}
