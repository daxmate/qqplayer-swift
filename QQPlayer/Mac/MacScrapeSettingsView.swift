//
//  MacScrapeSettingsView.swift
//  QQPlayer
//
//  设置「刮削」分类面板（web ScrapeSettingsPanel.vue 移植，E1 刮削批 2026-09）。
//  骨架：S4（UI 批）实现。挂载：MacSettingsView 新分类 .scraping（含图标/本地化）。
//
//  功能契约（web ScrapeSettingsPanel + 设置 scraping namespace 对齐）：
//  - 重命名模板：文本输入 + 占位符提示（{artist}/{title}/{album}/{track}/{year}、
//    '/' = 子目录）+ 实时预览（取当前选中/首曲渲染，web renamePreview）
//  - 源优先级：source_order 上下移排序（默认 netease, musicbrainz）
//  - 批量刮削开关：batch_enabled 默认关（web 拍板）；开 → 显示「一键补全整库
//    year+genre」按钮 + 进行中进度（ScrapeBatchService library 模式，逐首状态列表/
//    汇总；取消支持）
//  - 存储：DeleteSettings 扩展（scraping namespace：renameTemplate/sourceOrder/
//    batchEnabled），decode 兜底默认值
//  - 本地化 key ×5（en/zh-Hans/zh-Hant/fr/ru）

import SwiftUI

struct MacScrapeSettingsView: View {
    var body: some View {
        // S4 实现
        EmptyView()
    }
}
