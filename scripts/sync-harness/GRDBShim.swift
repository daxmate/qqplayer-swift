//
//  GRDBShim.swift — harness 专用最小 GRDB 模块桩（**不参与 App target 编译**）
//
//  生产源码里 QQPlayer/Sync/PairingModels.swift 只用到 GRDB 的两个 Record 协议
//  （PeerDevice: Codable, Equatable, FetchableRecord, PersistableRecord），其余
//  GRDB 交互都在 DatabaseManager/DeviceStore（harness 已用桩替换）。因此本地直编
//  只需给出同名空协议，即可编译**未改动的**生产源码。
//
//  编译方式见 scripts/run-local-sync-tests.sh：单独编为 module GRDB 后 link。
//

public protocol FetchableRecord {}
public protocol PersistableRecord {}
