//
//  LibraryIndexerCancellationTests.swift
//  QQPlayerTests
//
//  审计 🔵-9 回归：LibraryIndexer.stop() 取消在途扫描任务。
//
//  修复前 stop() 只 `indexingGeneration &+= 1; isIndexing = false`——扫描内的
//  `guard generation == indexingGeneration` 只让闭包 return，withTaskGroup 仍会等
//  已入队文件跑完（点「停止/切离线」后继续处理已入队文件、浪费 IO/电量）。
//  修复后 stop() 取消在途任务（activeScanTask 为修复新增的可见缝），
//  取消向子任务传播 + 扫描内 Task.isCancelled 检查早退。
//

import Foundation
import Testing

@testable import QQPlayer

@MainActor
struct LibraryIndexerCancellationTests {
    @Test("stop() 取消在途扫描任务（修复前无在途任务引用、无从取消）")
    func stopCancelsInFlightScanTask() {
        let indexer = LibraryIndexer()
        indexer.start()

        let scanTask = indexer.activeScanTask
        #expect(scanTask != nil)

        indexer.stop()

        #expect(scanTask?.isCancelled == true)
        #expect(indexer.activeScanTask == nil)
        #expect(indexer.isIndexing == false)
    }

    @Test("stop() 后重新 start() 注册的是新任务，旧任务保持已取消")
    func restartRegistersFreshTask() {
        let indexer = LibraryIndexer()
        indexer.start()
        let first = indexer.activeScanTask
        indexer.stop()

        indexer.start()
        let second = indexer.activeScanTask
        // 立即收掉第二轮：本用例只验证任务注册/取消语义，不真跑扫描
        indexer.stop()

        #expect(first?.isCancelled == true)
        #expect(second != nil)
        #expect(second?.isCancelled == true)
        #expect(indexer.isIndexing == false)
    }
}
