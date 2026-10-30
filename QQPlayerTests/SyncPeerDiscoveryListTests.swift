//
//  SyncPeerDiscoveryListTests.swift
//  QQPlayerTests
//
//  批 1（2026-10-30）发现列表纯逻辑：新增 / 离线移除 / 去重 / 排除本机 / 已配对标注 / 排序。
//

import Foundation
import Testing

@testable import QQPlayer

struct SyncPeerDiscoveryListTests {
    @Test("发现：上新设备出现在列表，且按名字稳定排序")
    func addPeers() {
        let entries = SyncPeerDiscoveryList.entries(
            names: ["xmacbook", "xhome"],
            excludingSelf: nil,
            pairedNames: []
        )
        #expect(entries.map(\.name) == ["xhome", "xmacbook"])
        #expect(entries.allSatisfy { !$0.isPaired })
    }

    @Test("发现：设备离线（从结果里消失）即从列表移除")
    func removePeer() {
        let two = SyncPeerDiscoveryList.entries(
            names: ["xhome", "xmacbook"],
            excludingSelf: nil,
            pairedNames: []
        )
        #expect(two.count == 2)
        let one = SyncPeerDiscoveryList.entries(
            names: ["xhome"],
            excludingSelf: nil,
            pairedNames: []
        )
        #expect(one.map(\.name) == ["xhome"])
    }

    @Test("发现：同名重复只留一条；空名忽略")
    func dedupeAndIgnoreEmpty() {
        let entries = SyncPeerDiscoveryList.entries(
            names: ["xhome", "xhome", "  ", "xmacbook"],
            excludingSelf: nil,
            pairedNames: []
        )
        #expect(entries.map(\.name) == ["xhome", "xmacbook"])
    }

    @Test("发现：剔除本机自己的广播（服务名 == 本机展示名）")
    func excludeSelf() {
        let entries = SyncPeerDiscoveryList.entries(
            names: ["xhome", "self-mac"],
            excludingSelf: "self-mac",
            pairedNames: []
        )
        #expect(entries.map(\.name) == ["xhome"])
    }

    @Test("发现：信任库里有同名设备才标已配对")
    func pairedFlag() {
        let entries = SyncPeerDiscoveryList.entries(
            names: ["xhome", "xmacbook"],
            excludingSelf: nil,
            pairedNames: ["xhome"]
        )
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.isPaired) })
        #expect(byName["xhome"] == true)
        #expect(byName["xmacbook"] == false)
    }

    @Test("发现：名字两端空白被裁剪后再比对")
    func trimsWhitespace() {
        let entries = SyncPeerDiscoveryList.entries(
            names: [" xhome "],
            excludingSelf: "xhome",
            pairedNames: []
        )
        #expect(entries.isEmpty)
    }
}
