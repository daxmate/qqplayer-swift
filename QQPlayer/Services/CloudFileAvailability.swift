//
//  CloudFileAvailability.swift
//  QQPlayer
//
//  iCloud 文件"本地可用性"唯一判定（单一事实源）。
//
//  为什么需要：iCloud Drive 的 dataless（云端未下载）文件在文件系统里有条目，
//  但 FileHandle.read / 哈希流式读取会**触发云端下载并长时间阻塞**（实测 macOS
//  启动路径 read() 20+ 分钟不返回 → 主线程卡死、App 无响应）。扫描器
//  LibraryIndexer.partitionLocalFiles 早已有 dataless 跳过判定，回填路径却没有，
//  同一行为两处实现 → 本文件收敛为唯一判定，所有消费点共用。
//
//  判定语义（与 LibraryIndexer.partitionLocalFiles 原逻辑逐字一致）：
//  - isUbiquitousItem != true（普通本地文件 / 读不到元数据）→ 可用
//  - iCloud 文件且下载状态 ∈ {.downloaded, .current} → 可用
//  - 其余（.notDownloaded 等，含状态为 nil）→ 不可用（调用方应跳过，勿读）
//

import Foundation

enum CloudFileAvailability {
    /// 纯函数判定（可单测，不触文件系统）。
    static func isLocallyAvailable(
        isUbiquitousItem: Bool?,
        downloadingStatus: URLUbiquitousItemDownloadingStatus?
    ) -> Bool {
        guard isUbiquitousItem == true else { return true }
        guard let status = downloadingStatus else { return false }
        return status == .downloaded || status == .current
    }

    /// 读 URL 元数据后转调纯函数；读不到元数据时按可用（保守，保持旧行为）。
    static func isLocallyAvailable(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ])
        return isLocallyAvailable(
            isUbiquitousItem: values?.isUbiquitousItem,
            downloadingStatus: values?.ubiquitousItemDownloadingStatus
        )
    }
}
