//
//  SyncPeerDiscoveryList.swift
//  QQPlayer
//
//  局域网同步 · 批 1（2026-10-30）**发现列表纯逻辑**（可单测，平台无关）。
//
//  职责：把 Bonjour 发现结果（服务名列表）加工成 UI 直接可用的行：
//  - 剔除本机自己（服务名 == 本机展示名 ⇒ 自己）；
//  - 按名字去重（同名只留一条，后到的覆盖）；
//  - 与信任库比对标注「已配对」（client 侧落库 displayName = 对端展示名 = 服务名）；
//  - 稳定排序（本地化标序），避免每次刷新行序跳动。
//
//  ⚠️ 这里只做「值 → 值」，不碰网络与 UI（Mac 侧装配见 Mac/MacPeerClientCenter.swift）。
//

import Foundation

/// 发现列表一行（值类型；视图只读）。
struct SyncPeerDiscoveryEntry: Equatable, Sendable {
    /// Bonjour 服务名（展示与连接都用它）
    let name: String
    /// 信任库里已有同名已配对设备
    let isPaired: Bool
}

enum SyncPeerDiscoveryList {
    /// 由发现结果（服务名序列）生成列表行。
    /// - Parameters:
    ///   - names: Bonjour 服务名（可重复、无序）
    ///   - selfName: 本机展示名（同名条目被剔除；nil = 不剔除）
    ///   - pairedNames: 信任库里的对端展示名集合
    static func entries(
        names: [String],
        excludingSelf selfName: String?,
        pairedNames: Set<String>
    ) -> [SyncPeerDiscoveryEntry] {
        var seen: [String: SyncPeerDiscoveryEntry] = [:]
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let selfName, trimmed == selfName { continue }
            seen[trimmed] = SyncPeerDiscoveryEntry(
                name: trimmed,
                isPaired: pairedNames.contains(trimmed)
            )
        }
        return seen.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
