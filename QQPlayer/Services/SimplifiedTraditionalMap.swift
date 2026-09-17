//
//  SimplifiedTraditionalMap.swift
//  QQPlayer
//
//  简体→繁体单字映射表（用于歌词搜索繁体源补搜）。
//  数据源: OpenCC STCharacters.txt（Apache-2.0，https://github.com/BYVoid/OpenCC）
//  特例: 台→台（台湾惯用，lrclib 等源收录「電台」而非「電臺」）
//  生成方式: scripts 外脚本从 STCharacters.txt 生成（2026-08-29）。
//
import Foundation

//
//  2026-09-17（P2-①）：原 3881 条 Swift 字面量下沉为资源文件 + 懒加载（数据一字未改）。
//  - 数据：QQPlayer/Resources/SimplifiedToTraditional.tsv（TSV，键/值各一个 Unicode 标量）；
//    由 scripts/gen-character-maps.sh --ref <字面量版> 从原字面量 dump 生成。
//  - 基线夹具 + SHA-256：QQPlayerTests/Fixtures/simplified-to-traditional.baseline.tsv
//    （与资源文件字节一致；CharacterMapResourceTests 逐键 + 哈希断言「加载结果 == 基线」）。
//  - 读盘/解析/缓存/fail-closed 唯一入口：CharacterMapResourceLoader（本文件只剩声明）。
//  - 本声明是全局 `let`：Swift 全局 let 默认惰性 + once → 首次使用时加载一次。

/// 简体→繁体单字映射（OpenCC 数据 + 特例修正）；未收录的字原样保留
let simplifiedToTraditionalMap: [Character: Character] = CharacterMapResourceLoader.load(.simplifiedToTraditional)
