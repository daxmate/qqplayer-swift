//
//  CloudFileAvailabilityTests.swift
//  QQPlayerTests
//
//  iCloud 本地可用性唯一判定（CloudFileAvailability）测试。语义必须与
//  LibraryIndexer.partitionLocalFiles 原有逻辑一致：非 iCloud → 可用；
//  iCloud 且状态 ∈ {.downloaded, .current} → 可用；其余（含状态 nil）→ 不可用。
//

import Foundation
import Testing

@testable import QQPlayer

struct CloudFileAvailabilityTests {
    // MARK: - 纯函数全分支

    @Test("非 iCloud 文件（isUbiquitousItem 为 nil / false）→ 可用")
    func nonUbiquitousItemIsAvailable() {
        #expect(CloudFileAvailability.isLocallyAvailable(isUbiquitousItem: nil, downloadingStatus: nil))
        #expect(
            CloudFileAvailability.isLocallyAvailable(
                isUbiquitousItem: false,
                downloadingStatus: .notDownloaded
            )
        )
        #expect(
            CloudFileAvailability.isLocallyAvailable(
                isUbiquitousItem: false,
                downloadingStatus: nil
            )
        )
    }

    @Test("iCloud 文件 + 下载状态 .current / .downloaded → 可用")
    func ubiquitousDownloadedIsAvailable() {
        #expect(
            CloudFileAvailability.isLocallyAvailable(
                isUbiquitousItem: true,
                downloadingStatus: .current
            )
        )
        #expect(
            CloudFileAvailability.isLocallyAvailable(
                isUbiquitousItem: true,
                downloadingStatus: .downloaded
            )
        )
    }

    @Test("iCloud 文件 + 未下载状态（.notDownloaded）→ 不可用")
    func ubiquitousNotDownloadedIsUnavailable() {
        #expect(
            !CloudFileAvailability.isLocallyAvailable(
                isUbiquitousItem: true,
                downloadingStatus: .notDownloaded
            )
        )
    }

    @Test("iCloud 文件 + 下载状态为 nil → 不可用（保守：宁可不读也不阻塞）")
    func ubiquitousWithNilStatusIsUnavailable() {
        #expect(
            !CloudFileAvailability.isLocallyAvailable(
                isUbiquitousItem: true,
                downloadingStatus: nil
            )
        )
    }

    // MARK: - URL 重载（读元数据）

    @Test("URL 重载：本地普通文件 → 可用")
    func urlOverloadForLocalFileIsAvailable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudFileAvailabilityTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("local.bin")
        try Data(repeating: 0x5A, count: 64).write(to: url)

        #expect(CloudFileAvailability.isLocallyAvailable(url))
    }

    @Test("URL 重载：读不到元数据（路径不存在）→ 按可用（保守回退，保持旧行为）")
    func urlOverloadFallsBackToAvailableWhenMetadataUnreadable() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudFileAvailabilityTests-missing-\(UUID().uuidString).bin")
        #expect(CloudFileAvailability.isLocallyAvailable(missing))
    }
}
