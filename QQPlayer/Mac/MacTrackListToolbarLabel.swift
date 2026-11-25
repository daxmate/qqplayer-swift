//
//  MacTrackListToolbarLabel.swift
//  QQPlayer
//  QQPlayerMac target only.
//
//  「定位当前播放」按钮的标题视图（2026-11-25 从 MacTrackListView 外移：那个文件已经贴到
//  600 行结构预算上限，本批修复需要新增约束代码，按 MacTrackColumnFit 的先例外移，行为不变）。
//
//  为什么不能直接用 `Label`：中栏约 380pt 时右侧控件（维度切换 162 / 排序约 60 /
//  视图模式 80，均 `fixedSize()`）已占满整行，Label 是唯一可压缩项 → Text 被压到一字宽后
//  逐字换行，行高从一行撑成六行（2026-11-25 回归）。
//
//  三条约束缺一不可：
//    - `.lineLimit(1)`：任何情况下都只占一行（兜底，防逐字竖排）；
//    - `.fixedSize(horizontal: true, vertical: false)`：不自缩 → ViewThatFits 按**理想宽度**
//      判「放得下」，而不是把文字压成省略号也算放得下；
//    - `ViewThatFits` 第二分支：整句放不下时退化为纯图标，语义由按钮外层 `.help` 承载。
//

import SwiftUI

/// 「定位当前播放」按钮标题：整句单行；空间不足退化为纯图标。
/// 调用方负责按钮样式、禁用态与 `.help`（见 MacTrackListView.toolbarRow）。
struct MacTrackListToolbarLabel: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            Label(Localized.locatePlayingTrack, systemImage: "location")
                .font(.callout)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "location")
                .font(.callout)
        }
    }
}
