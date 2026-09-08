//
//  DeviceStore.swift
//  QQPlayer
//
//  已配对设备（PeerDevice）CRUD + GRDB 持久化（sync_device 表，docs §7）。
//
//  表结构（DatabaseManager.createTables 建，iOS+Mac 同库路径幂等迁移）：
//    peer_id TEXT PRIMARY KEY         对方 Device ID（全量）
//    peer_public_key TEXT NOT NULL    对方 Ed25519 公钥 base64
//    display_name TEXT NOT NULL
//    role TEXT NOT NULL               PeerRole rawValue（host/client）
//    paired_at / last_seen_at INTEGER NOT NULL   epoch 秒
//    notes TEXT
//    updated_at INTEGER NOT NULL      记录变更时间（每次 upsert 刷新；
//                                     重复配对=替换路径的落库时间，M2 设备列表同步参考）
//  存储走 DatabaseManager 读写缝（shared 生产 / 注入内存库测试），
//  与 iOS/macOS 共用 schema 与迁移路径；PeerDevice 作 GRDB Record 读写。
//

import Foundation
@preconcurrency import GRDB

final class DeviceStore: @unchecked Sendable {
    private let database: DatabaseManager

    init(database: DatabaseManager = .shared) {
        self.database = database
    }

    /// 新增或整体替换配对记录（同 peerID 重配对走替换确认路径后落库即整体替换；
    /// updated_at 恒刷新为当前时间）。
    func upsert(_ device: PeerDevice) throws {
        let updatedAt = Int64(Date().timeIntervalSince1970)
        try database.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_device
                    (peer_id, peer_public_key, display_name, role,
                     paired_at, last_seen_at, notes, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(peer_id) DO UPDATE SET
                    peer_public_key = excluded.peer_public_key,
                    display_name = excluded.display_name,
                    role = excluded.role,
                    paired_at = excluded.paired_at,
                    last_seen_at = excluded.last_seen_at,
                    notes = excluded.notes,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    device.peerID,
                    device.peerPublicKey,
                    device.displayName,
                    device.role.rawValue,
                    device.pairedAt,
                    device.lastSeenAt,
                    device.notes,
                    updatedAt,
                ]
            )
        }
    }

    /// 删除配对记录（= 撤销配对）。peerID 不存在时幂等成功。
    func remove(peerID: String) throws {
        _ = try database.write { db in
            try PeerDevice
                .filter(Column("peer_id") == peerID)
                .deleteAll(db)
        }
    }

    /// 全部配对记录（按 displayName 排序，稳定展示顺序）。
    func all() throws -> [PeerDevice] {
        try database.read { db in
            try PeerDevice
                .order(Column("display_name"), Column("peer_id"))
                .fetchAll(db)
        }
    }

    /// 按 peerID 查单条记录。
    func byPeerID(_ peerID: String) throws -> PeerDevice? {
        try database.read { db in
            try PeerDevice
                .filter(Column("peer_id") == peerID)
                .fetchOne(db)
        }
    }
}
