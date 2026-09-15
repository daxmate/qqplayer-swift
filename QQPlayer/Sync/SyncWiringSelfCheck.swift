//
//  SyncWiringSelfCheck.swift
//  QQPlayer
//
//  L5 装配层：**运行时装配自检**（INV-16 的后半句）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  为什么需要（静态断言抓不到的那一半）
//  ════════════════════════════════════════════════════════════════════════════
//  静态断言（`SyncWiringContract.requirements`）证明「调用点在源码里存在」；它证明不了
//  **这一次真的装上了**。下面这些路径代码全对、调用点也在，只是运行时没接上：
//    - 对端 hello 没有 Device ID → `IOSPassiveSyncCenter.attachDataSync` 直接 return
//      （`dataSyncPeer == nil`：帧 8/9 收不到，两端播放数据永不通）；
//    - iOS `SyncLibraryPassiveHost.attach` 失败 → 被动端根本没接上（文件落不了盘）；
//    - Mac `MacSyncCoordinatorFactory` 的 peerID 为空 → 跟歌走携带不装（R3b 静默失效）。
//  这些分支此前**只 print 一行**，用户在面板上看不出「我声明了这个能力，但它没装上」。
//
//  ════════════════════════════════════════════════════════════════════════════
//  形状（单一事实源：声明在注册表，事实在装配点，判定是纯函数）
//  ════════════════════════════════════════════════════════════════════════════
//  - **声明**（本平台该有哪些装配点、各由哪个探针回答）只来自 `SyncEntityRegistry`
//    的 `assemblyPoints[].probe`——本文件不手写第二份名单（形状断言守着）。
//  - **事实**（本端这次真的装上没有）由各装配点在**装配发生的那一刻**写入
//    `SyncWiringFactsStore`：iOS 在 `IOSPassiveSyncCenter`，Mac 在 `SyncHostCenter` /
//    `MacSyncCoordinatorFactory` 的调用方。
//  - **判定**是纯函数 `SyncWiringSelfCheck.gaps(items:)`：输入 = 各能力装配状态，
//    输出 = 缺口列表；UI 只呈现（`SyncWiringSelfCheckPresenter`），不判断。
//  - **门控语义**（INV-26）：门控关（跨端续播默认关）= 该能力**本来就不该装** →
//    事实记「不适用」（缺键），不计缺口。把「设计如此」报成缺口 = 面板变噪音机。
//

import Combine
import Foundation

// MARK: - 探针

/// 运行时装配自检的探针：注册表的装配点用它声明「本端该检查哪一项」。
/// 新增探针 = 加一个 case（`SyncEntityRegistryContract` 的形状断言会要求至少一条装配点引用它，
/// 防止枚举里积压没人检查的项）。
enum SyncWiringProbe: String, CaseIterable, Equatable, Sendable {
    /// 帧 8/9 处理器（`SyncChangeLogPeer`）在会话 ready 时已构造
    case changeLogPeer
    /// 被动端文件接收宿主（`SyncLibraryPassiveHost`）已接上会话
    case libraryPassiveHost
    /// 播放位置落点（`PlaybackPositionResumeSink`）已注入（门控关 = 不适用）
    case playbackPositionSink
    /// 跟歌走携带（`SyncPlaybackCarryPeer`）已装配（对端 Device ID 为空则不装）
    case playbackCarry
    /// Mac「同步数据」协调器（会话 ready 自动一轮）已装配
    case dataSyncEntry

    /// 面板展示名（五语齐，见 `QQPlayer/Resources/*.lproj/Localizable.strings`）。
    var labelKey: String {
        switch self {
        case .changeLogPeer: return "sync_wiring_probe_change_log_peer"
        case .libraryPassiveHost: return "sync_wiring_probe_library_passive_host"
        case .playbackPositionSink: return "sync_wiring_probe_playback_position_sink"
        case .playbackCarry: return "sync_wiring_probe_playback_carry"
        case .dataSyncEntry: return "sync_wiring_probe_data_sync_entry"
        }
    }
}

// MARK: - 自检项与缺口

/// 自检项：注册表声明的装配点 + 本端这次的探针事实。
struct SyncWiringSelfCheckItem: Equatable, Sendable {
    /// 能力标识：实体登记编号（A…H）/ 共享装配点的断言 id（如 `mac-playback-carry-attached`）。
    let capabilityID: String
    let platform: String
    let frame: Int?
    /// 装配点说明（注册表原文；缺口写日志用——「缺了什么」）。
    let detail: String
    let probe: SyncWiringProbe
    /// 本端实际是否装配；`nil` = 本次不适用（门控关等），不计缺口。
    let isAttached: Bool?
}

/// 一条缺口：注册表声明了、本端这次没装配上。
struct SyncWiringGap: Equatable, Sendable, Identifiable {
    let capabilityID: String
    let platform: String
    let frame: Int?
    let detail: String
    let probe: SyncWiringProbe

    var id: String { "\(capabilityID)|\(platform)|\(probe.rawValue)" }

    /// 日志一行（说明缺了什么 / 影响哪个能力）。
    var logLine: String {
        let frameText = frame.map { "帧 \($0)" } ?? "无帧"
        return "\(capabilityID)·\(platform)·\(frameText)：\(detail)"
    }
}

// MARK: - 纯逻辑（可单测）

/// 运行时装配自检（无 IO / 无状态 / 无 UI）。
enum SyncWiringSelfCheck {
    /// **纯函数**：各能力装配状态 → 缺口列表。
    /// `nil`（不适用）不计缺口；顺序 = 输入顺序（= 注册表声明顺序）。
    static func gaps(items: [SyncWiringSelfCheckItem]) -> [SyncWiringGap] {
        items.filter { $0.isAttached == false }.map { item in
            SyncWiringGap(
                capabilityID: item.capabilityID,
                platform: item.platform,
                frame: item.frame,
                detail: item.detail,
                probe: item.probe
            )
        }
    }

    /// 本平台声明的探针（来自注册表，登记顺序；有重复则按声明逐条保留）。
    static func probes(platform: String) -> [SyncWiringProbe] {
        SyncEntityRegistry.capabilityAssemblyPoints.compactMap { entry in
            entry.point.platform == platform ? entry.point.probe : nil
        }
    }

    /// 注册表（本平台声明）× 本端事实 → 自检项。
    /// 事实里有、注册表没声明的探针**不进结果**：声明才是唯一来源。
    static func items(platform: String, facts: [SyncWiringProbe: Bool]) -> [SyncWiringSelfCheckItem] {
        SyncEntityRegistry.capabilityAssemblyPoints.compactMap { entry -> SyncWiringSelfCheckItem? in
            let point = entry.point
            guard point.platform == platform, let probe = point.probe else { return nil }
            return SyncWiringSelfCheckItem(
                capabilityID: entry.capabilityID,
                platform: platform,
                frame: point.frame,
                detail: point.detail,
                probe: probe,
                isAttached: facts[probe]
            )
        }
    }
}

// MARK: - 展示（纯函数；UI 只呈现）

/// 缺口 → 面板展示。**缺口 = 0 → nil = 空态（不显示任何行）**。
enum SyncWiringSelfCheckPresenter {
    /// 面板一行：标签（缺口数）+ 说明（缺了哪些能力）。
    struct GapRow: Equatable {
        /// 行标签 key（带 `%d` = 缺口数）。
        let labelKey: String
        /// 缺口数。
        let count: Int
        /// 说明 key（带一个 `%@` = 缺失能力名列表）。
        let hintKey: String
        /// 缺失能力名（本地化 key，顺序 = 注册表声明顺序，按探针去重）。
        let probeLabelKeys: [String]
    }

    static let gapLabelKey = "sync_wiring_gap_label"
    static let gapHintKey = "sync_wiring_gap_hint"

    static func gapRow(_ gaps: [SyncWiringGap]) -> GapRow? {
        guard !gaps.isEmpty else { return nil }
        var seen: Set<SyncWiringProbe> = []
        var names: [String] = []
        for gap in gaps where seen.insert(gap.probe).inserted {
            names.append(gap.probe.labelKey)
        }
        return GapRow(labelKey: gapLabelKey, count: gaps.count, hintKey: gapHintKey, probeLabelKeys: names)
    }
}

// MARK: - 事实快照（装配点写入，面板 / 日志只读）

/// 运行时自检事实的**进程内快照**：各装配点在装配发生的那一刻写入。
///
/// 单例而不是各端自己算：声明在注册表（共享），本进程只会有一个平台的事实
/// （`currentPlatform` 由编译目标决定）→ store 只负责「攒事实 + 重算 + 写日志」，
/// 判定一律走纯函数 `SyncWiringSelfCheck.gaps(items:)`。
///
/// ⚠️ 只许**装配点**写入（谁装配谁申报）；UI 不得在这里补算任何事实。
@MainActor
final class SyncWiringFactsStore: ObservableObject {
    static let shared = SyncWiringFactsStore()

    /// 本进程所属平台（口径与注册表装配点一致；由编译目标决定，不手写平台字符串）。
    nonisolated static var currentPlatform: String {
        #if os(macOS)
            SyncEntityRegistry.platformMac
        #else
            SyncEntityRegistry.platformIOS
        #endif
    }

    /// 探针事实（**缺键 = 本次不适用**，如门控关：不计缺口）。
    private(set) var facts: [SyncWiringProbe: Bool] = [:]
    /// 缺口（空数组 = 无缺口 → 面板空态）。
    @Published private(set) var gaps: [SyncWiringGap] = []

    private init() {}

    /// 记录一条装配事实。`attached: nil` = 本次不适用（门控关等），不计缺口。
    func record(_ probe: SyncWiringProbe, attached: Bool?, platform: String = SyncWiringFactsStore.currentPlatform) {
        facts[probe] = attached
        recompute(platform: platform)
    }

    /// 全清（会话拆除 / 测试夹具）：事实与缺口一起归零。
    func reset() {
        facts.removeAll()
        recompute(platform: SyncWiringFactsStore.currentPlatform)
    }

    /// 会话拆除 / 断开：本端装配点全归零（**不是缺口**——没有会话就谈不上装配）。
    func clear(platform: String = SyncWiringFactsStore.currentPlatform) {
        for probe in SyncWiringSelfCheck.probes(platform: platform) {
            facts[probe] = nil
        }
        recompute(platform: platform)
    }

    /// 重算 + 写既有日志（只在**状态变化**时打印一行；缺口清单本身写在日志里，
    /// 面板只显示「缺了哪几类能力」的本地化短名）。
    private func recompute(platform: String) {
        let updated = SyncWiringSelfCheck.gaps(
            items: SyncWiringSelfCheck.items(platform: platform, facts: facts)
        )
        guard updated != gaps else { return }
        gaps = updated
        if updated.isEmpty {
            print("ℹ️ 装配自检（\(platform)）：无缺口")
        } else {
            print("⚠️ 装配自检（\(platform)）：\(updated.count) 项已声明但未装配 —— " + updated.map(\.logLine).joined(separator: "；"))
        }
    }
}
