//
//  DatabaseManager+Diagnostics.swift
//  QQPlayer
//
//  身份缺失普查（只读诊断）：身份键缺口的三个面。
//
//  2026-09-19 从 DatabaseManager.swift 原样搬出（纯搬家）。
//
import Foundation
@preconcurrency import GRDB

extension DatabaseManager {
    // MARK: - 身份缺失普查（诊断，只读）

    /// 身份缺失普查（**只读**：绝不删除/修改任何行，孤儿行清理由 maintainer 单独执行）。
    /// 供启动时打印汇总与测试直调。
    func identityCensus() throws -> IdentityCensus {
        try read { db in try Self.identityCensus(db) }
    }

    /// 事务内版本（纯读；调用方须自行保证所在事务不接受写操作）。
    static func identityCensus(_ db: Database) throws -> IdentityCensus {
        func count(_ sql: String) throws -> Int {
            try Int.fetchOne(db, sql: sql) ?? 0
        }
        return IdentityCensus(
            nullHash: try count(
                "SELECT COUNT(*) FROM track WHERE content_hash IS NULL OR content_hash = ''"
            ),
            danglingHistory: try count("""
            SELECT COUNT(*) FROM play_history h
            WHERE NOT EXISTS (SELECT 1 FROM track t WHERE t.stable_id = h.track_stable_id)
            """),
            danglingFavorite: try count("""
            SELECT COUNT(*) FROM favorite f
            WHERE NOT EXISTS (SELECT 1 FROM track t WHERE t.stable_id = f.track_stable_id)
            """),
            danglingItem: try count("""
            SELECT COUNT(*) FROM playlist_item i
            WHERE NOT EXISTS (SELECT 1 FROM track t WHERE t.stable_id = i.track_stable_id)
            """)
        )
    }
}
