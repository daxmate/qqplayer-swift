//
//  LibraryIndexerModels.swift
//  QQPlayer
//
//  LibraryIndexer 的顶层值类型：错误/外部导入结果语义 + 解析中间结构。
//  纯搬家自 LibraryIndexer.swift（无行为变化；ParsedAudioFile / FileFingerprint
//  原为 file-private，跨文件使用后放宽为 internal）。
//

import AVFoundation
import Combine
import CryptoKit
import Foundation
import GRDB
import SFBAudioEngine

enum LibraryIndexerError: Error {
    case parseTimeout
    case metadataParsingFailed
}

/// 外部文件导入的**唯一结果语义**（反屎山 B1）。
///
/// 旧 `processExternalFile -> Bool` 把 4 条不同路径压成同一个 `false`
/// （已在库 / 被排除 / 解析落库出错 / 已在库但重解析），消费方（导入面板）
/// 只能把 `false` 一律说成「already in library」——**面板主动说谎**，用户不会重试。
/// 本枚举由 `LibraryIndexer.processExternalFileOutcome` 唯一产出，别处不得再判定一份。
enum ExternalImportOutcome: Equatable {
    /// 新入库（旧 Bool 语义里唯一返回 `true` 的路径）。
    case imported
    /// 已在库、但指纹变了 → 重新解析并覆盖元数据（旧实现返回 `false`，但不是「已在库」）。
    case updatedExisting
    /// 已在库且元数据最新（旧 `return false`）。
    case alreadyPresent
    /// 曾被用户从库中移除（排除），且未要求重导（旧 `return false`）。
    case excluded
    /// 没能导入（旧 `return false`）：含目录拒绝、超时、解析/落库报错。
    case failed(ExternalImportFailure)
}

/// `ExternalImportOutcome.failed` 的失败原因，逐条对应 `processExternalFileOutcome` 里的真实分支。
enum ExternalImportFailure: Equatable {
    /// 非本地文件（http/https/ftp/sftp），根本没进解析。
    case unsupportedLocation
    /// 解析超时（`LibraryIndexerError.parseTimeout`）。
    case parseTimeout
    /// 解析或落库抛错（`catch` 兜底分支）。
    case processing
}

/// 分片后跨文件可见（原 private）
struct ParsedAudioFile {
    let track: Track
    let trackArtistIds: [Int64]
    let albumArtistIds: [Int64]
}

/// 分片后跨文件可见（原 private）
struct FileFingerprint {
    let modificationDate: Int64?
    let fileSize: Int64?
}
