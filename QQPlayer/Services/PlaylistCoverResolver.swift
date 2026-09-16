//
//  PlaylistCoverResolver.swift
//  QQPlayer
//
//  歌单自定义封面**路径解析的唯一入口**（INV-22 另一半：依附内容在目标端定位不到时
//  不得静默——歌词丢弃已有记账，封面同理）。
//
//  ════════════════════════════════════════════════════════════════════════════
//  为什么要有这个文件（2026-09-16）
//  ════════════════════════════════════════════════════════════════════════════
//  「`customCoverImagePath` → 共享容器里的文件 URL → 能不能读」这段逻辑此前在 **4 个
//  消费点**各写一遍（歌单卡片 / 歌单详情 / 歌单详情「移除封面」/ CarPlay），且**失败路径
//  全是静默**：
//    `guard let data = try? Data(contentsOf: url) else { return }` ——
//  文件被删 / 容器不可达 / 路径来自对端设备时，用户只会看到「自定义封面没了」，
//  没有任何地方说得清为什么（矩阵 H⑥ 的「封面加载失败无任何计数/披露」）。
//
//  按纪律（**行为单一事实源 + 同类消费点全查**）：解析收敛到本文件，失败**登记进**
//  `PlaylistCoverLoadFailuresStore`（按歌单去重 → 计数 → 投影上屏），消费点只做
//  「渲染 + 申报」两件事。
//
//  纯逻辑（零 UIKit / 零 SwiftUI / 零 DB）：容器 URL 可注入 → 可无模拟器、可单测。
//
// target: ios-only（消费点都在 iOS UI：歌单卡片 / 详情 / CarPlay / 设置页；Mac 侧没有歌单自定义封面消费点）
//

import Foundation

/// 自定义封面路径 → 可用文件（唯一入口）。
enum PlaylistCoverResolver {
    /// 共享容器标识。
    ///
    /// ⚠️ 该字面量全仓另有若干处（Widget / `UserDefaults(suiteName:)` 等）；把**全部**
    /// 消费点收敛到一处属独立清理（不在本次范围）——本文件只保证「封面路径解析」这一类
    /// 消费点走同一个入口，别再各写一遍。
    static let appGroupIdentifier = "group.com.daxmate.qqplayer.ios"

    /// 解析结论。
    enum Resolution: Equatable {
        /// 没配自定义封面（正常路径：走歌单内歌曲封面自动合成）
        case none
        /// 配了、文件可读
        case available(URL)
        /// 配了但**读不到**（容器不可达 / 文件缺失 / 不是常规文件 / 解码失败）
        /// —— **必须申报**（`PlaylistCoverLoadFailuresStore`），不许静默回落
        case unavailable(reason: String)
    }

    /// 失败原因码（本地字符串常量，跨版本可加不可改）。
    enum Reason {
        /// 共享容器不可达（App Group 未配置 / 容器被系统清理）
        static let containerUnavailable = "container_unavailable"
        /// 文件不存在（被删除 / 路径来自对端设备 / 容器迁移）
        static let fileMissing = "file_missing"
        /// 路径存在但不是常规文件（目录 / 断链）
        static let notRegularFile = "not_regular_file"
        /// 文件在、但字节解不出图片（解码失败；由消费点判定后申报）
        static let decodeFailed = "decode_failed"
    }

    /// 共享容器 URL（拿不到 = nil）。生产用；测试注入可绕过。
    static func appGroupContainerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// 失败登记键：优先 DB `id`（稳定），回落 `slug`（id 尚未落库的过渡态）。
    static func playlistKey(id: Int64?, slug: String) -> String {
        if let id { return "id:\(id)" }
        return "slug:\(slug)"
    }

    /// **唯一解析入口**（显式容器版本：纯逻辑，可单测）。
    /// - 空 / nil / 全空白路径 = `.none`（没配封面，**不是**失败）
    /// - 容器拿不到 / 文件不在 / 不是常规文件 = `.unavailable(reason:)`
    static func resolve(
        customCoverImagePath: String?,
        containerURL: URL?,
        fileManager: FileManager = .default
    ) -> Resolution {
        guard let raw = customCoverImagePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return .none }
        guard let containerURL else { return .unavailable(reason: Reason.containerUnavailable) }
        let fileURL = containerURL.appendingPathComponent(raw)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            return .unavailable(reason: Reason.fileMissing)
        }
        guard !isDirectory.boolValue else { return .unavailable(reason: Reason.notRegularFile) }
        return .available(fileURL)
    }

    /// 生产便利入口（容器自动取 App Group；App Group 不可达时照 `.unavailable` 申报）。
    static func resolve(
        customCoverImagePath: String?,
        fileManager: FileManager = .default
    ) -> Resolution {
        resolve(
            customCoverImagePath: customCoverImagePath,
            containerURL: appGroupContainerURL(fileManager: fileManager),
            fileManager: fileManager
        )
    }
}
