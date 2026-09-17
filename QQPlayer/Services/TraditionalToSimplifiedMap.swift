//
//  TraditionalToSimplifiedMap.swift
//  QQPlayer
//
//  **繁→简**单字映射表（显示层字形归一的繁→简方向唯一数据源；未收录的字形原样保留）。
//  数据源: OpenCC TSCharacters.txt（Apache-2.0, https://github.com/BYVoid/OpenCC）
//  生成: scripts/gen-traditional-to-simplified.py --input TSCharacters.txt
//  输入指纹: 737c21c66f55
//
//  ⚠️ 不要再由 SimplifiedTraditionalMap.swift（简→繁）运行时反转出反查表：
//     多个简体字对应同一繁体字（开/𫔭 → 開 共 27 组），反转结果取决于 Dictionary 的
//     哈希顺序（每进程随机）→ 同一首歌可能显示「火力全开」或「火力全𫔭」（非 BMP，
//     字体无字形 = 豆腐块 囗）；且 為/髮/臺/隻 等次选字形在简→繁表里根本没有反查项。
//     事故与修法记录：2026-09-16。本文件是**唯一**繁→简数据源（形状测试守着这条）。
//
//  生成规则: 每行取 OpenCC 首选值；跳过首选值为非 BMP 的行（生僻异体，字体无字形）；
//            跳过 繁=简 的恒等行；按码点升序（生成结果稳定、diff 可读）。
//
import Foundation

//
//  2026-09-17（P2-①）：原 2995 条 Swift 字面量下沉为资源文件 + 懒加载（数据一字未改）。
//  - 数据：QQPlayer/Resources/TraditionalToSimplified.tsv（TSV，键/值各一个 Unicode 标量）；
//    由 scripts/gen-character-maps.sh --ref <字面量版> 从原字面量 dump 生成。
//  - 基线夹具 + SHA-256：QQPlayerTests/Fixtures/traditional-to-simplified.baseline.tsv
//    （与资源文件字节一致；CharacterMapResourceTests 逐键 + 哈希断言「加载结果 == 基线」）。
//  - 读盘/解析/缓存/fail-closed 唯一入口：CharacterMapResourceLoader（本文件只剩声明）。
//  - 本声明是全局 `let`：Swift 全局 let 默认惰性 + once → 首次使用时加载一次。

/// 繁→简单字映射（OpenCC TSCharacters 首选值）
let traditionalToSimplifiedMap: [Character: Character] = CharacterMapResourceLoader.load(.traditionalToSimplified)
