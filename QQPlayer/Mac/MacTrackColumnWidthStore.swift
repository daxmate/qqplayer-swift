//
//  MacTrackColumnWidthStore.swift
//  QQPlayer
//
//  曲目列表三根弹性列（标题 / 艺人 / 专辑）列宽的 UserDefaults 持久化（Mac 专属，2026-11-24）。
//
//  为什么单独一个 store：拖拽结束（MacTrackColumnResizer.mouseUp → onCommit）是**唯一**写入
//  时机，运行时真相仍只有视图里那份 @State；要让重启后回到用户拖出来的宽度，就得把
//  「读 / 写 / 夹紧」这套口径钉在一处，视图 body / updateNSView 一律不碰盘（渲染期写盘会
//  掉帧，且容易写成死循环）。
//
//  key：`mac.trackList.columnWidths.v1.<列>` 三个 Double 分键（不用一个 JSON Data）。
//  理由：① 某一列缺失/损坏只回落该列初始宽度，不必整块作废；② 以后改口径只需换版本号后缀，
//  旧键自然失效，不需要迁移代码。
//
//  夹紧规则（读与写共用 `sanitized(_:for:)`，保证写进去的一定是读得回来的值）：
//    · 非有限值（NaN / ±infinity）→ 回落该列 InitialWidth；
//    · 低于 MacTrackColumnLayout.minWidth(ofColumn:) → 抬到最小宽度（拖拽已保证，防历史脏数据）；
//    · 高于上限 4000 → 压到 4000（防脏数据把列撑到不可用、把固定列挤出屏幕）。
//  缺失或类型不对（例如存成了字符串）→ 回落该列 InitialWidth。
//  例外：布尔值经 NSNumber 桥接读成 1/0，会被当作极小宽度夹到 minWidth（不会回落初始值）。
//

import Foundation

struct MacTrackColumnWidthStore {
    /// 列宽 key 前缀；具体列见 `Column.defaultsKey`。
    static let keyPrefix = "mac.trackList.columnWidths.v1"
    /// 单列宽度上限：超过它几乎必然是脏数据（窗口宽度量级也就几千点）。
    static let maximumColumnWidth: CGFloat = 4_000

    private let defaults: UserDefaults

    /// `defaults` 可注入：单测用独立 suite，生产用 `.standard`。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读上次拖出来的三列宽度；任何一列缺失/非法都只回落该列。
    func load() -> MacTrackColumnWidths {
        MacTrackColumnWidths(
            title: storedWidth(for: .title),
            artist: storedWidth(for: .artist),
            album: storedWidth(for: .album)
        )
    }

    /// 写三列宽度（已夹紧）。只在拖拽结束回调里调用。
    func save(_ widths: MacTrackColumnWidths) {
        defaults.set(Double(sanitized(widths.title, for: .title)), forKey: Column.title.defaultsKey)
        defaults.set(Double(sanitized(widths.artist, for: .artist)), forKey: Column.artist.defaultsKey)
        defaults.set(Double(sanitized(widths.album, for: .album)), forKey: Column.album.defaultsKey)
    }

    // MARK: - 内部

    /// 三根弹性列的持久化元数据（列序 / 初始宽度仍以 MacTrackColumnLayout 为唯一真相源）。
    enum Column: String, CaseIterable {
        case title
        case artist
        case album

        var defaultsKey: String { "\(MacTrackColumnWidthStore.keyPrefix).\(rawValue)" }

        var index: Int {
            switch self {
            case .title: MacTrackColumnLayout.titleIndex
            case .artist: MacTrackColumnLayout.artistIndex
            case .album: MacTrackColumnLayout.albumIndex
            }
        }

        var initialWidth: CGFloat {
            switch self {
            case .title: MacTrackColumnLayout.titleInitialWidth
            case .artist: MacTrackColumnLayout.artistInitialWidth
            case .album: MacTrackColumnLayout.albumInitialWidth
            }
        }
    }

    private func storedWidth(for column: Column) -> CGFloat {
        // 用 object(forKey:) 而不是 double(forKey:)：后者在 key 缺失时返回 0，
        // 分辨不出「没存过」和「真的存了 0」，而 0 宽度列是不可用的。
        guard let number = defaults.object(forKey: column.defaultsKey) as? NSNumber else {
            return column.initialWidth
        }
        return sanitized(CGFloat(number.doubleValue), for: column)
    }

    private func sanitized(_ raw: CGFloat, for column: Column) -> CGFloat {
        guard raw.isFinite else { return column.initialWidth }
        let minimum = MacTrackColumnLayout.minWidth(ofColumn: column.index)
        return min(max(raw, minimum), Self.maximumColumnWidth)
    }
}
