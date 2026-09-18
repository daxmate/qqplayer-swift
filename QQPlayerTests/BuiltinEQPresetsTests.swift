//
//  BuiltinEQPresetsTests.swift
//  QQPlayerTests
//
//  10 段图形 EQ 常用预设：数据完整性 + 增益解析纯函数。
//  数据层照搬桌面端 frontend/src/composables/useEq.ts，数值必须一致。
//

import Foundation
import Testing

@testable import QQPlayer

struct BuiltinEQPresetsTests {
    @Test("内置预设含 7 个且 key 唯一（flat/pop/rock/jazz/classical/bass/vocal）")
    func sevenPresetsWithUniqueKeys() {
        let keys = BuiltinEQPresets.all.map { $0.key }
        #expect(keys.count == 7)
        #expect(Set(keys).count == 7)
        #expect(keys.contains("flat"))
        #expect(keys.contains("pop"))
        #expect(keys.contains("rock"))
        #expect(keys.contains("jazz"))
        #expect(keys.contains("classical"))
        #expect(keys.contains("bass"))
        #expect(keys.contains("vocal"))
    }

    @Test("每个预设都是 10 段增益")
    func tenBandsPerPreset() {
        for preset in BuiltinEQPresets.all {
            #expect(preset.gains.count == 10, "预设 \(preset.key) 应为 10 段")
        }
    }

    @Test("所有增益在 ±12dB 范围内")
    func gainsWithinRange() {
        for preset in BuiltinEQPresets.all {
            for gain in preset.gains {
                #expect(gain >= -12.0 && gain <= 12.0, "预设 \(preset.key) 增益 \(gain) 超出 ±12")
            }
        }
    }

    @Test("10 段频点与桌面端一致")
    func bands10MatchDesktop() {
        #expect(BuiltinEQPresets.bands10 == [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000])
    }

    @Test("各预设增益与桌面端 useEq.ts 一致（照抄勿改）")
    func presetValuesMatchDesktop() {
        let expected: [String: [Double]] = [
            "flat": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            "pop": [-1, 0, 1.5, 2.5, 3, 2.5, 1.5, 0, -0.5, -1],
            "rock": [4, 3, 1.5, 0, -1, 0, 1.5, 3, 3.5, 4],
            "jazz": [3, 2, 1, 1, -0.5, -1, 0, 1, 2, 3],
            "classical": [3, 2, 1, -0.5, -1, -1, -0.5, 1, 2, 3],
            "bass": [6, 4.5, 3, 1.5, 0, 0, 0, 0, 0, 0],
            "vocal": [-1.5, -1, 0, 1, 2.5, 3.5, 3, 1.5, 0, -1],
        ]
        for (key, gains) in expected {
            let preset = BuiltinEQPresets.preset(for: key)
            #expect(preset != nil, "缺少预设 \(key)")
            #expect(preset?.gains == gains, "预设 \(key) 数值与桌面端不一致")
        }
    }

    @Test("gains(for:) 已知预设 key 返回对应增益")
    func gainsForKnownKey() {
        let gains = BuiltinEQPresets.gains(for: "pop")
        #expect(gains == [-1, 0, 1.5, 2.5, 3, 2.5, 1.5, 0, -0.5, -1])
    }

    @Test("gains(for:) custom 返回持久化增益（无数据时 nil）")
    func gainsForCustom() {
        let stored: [Double] = [1.5, -2, 0, 3, 0, 0, 0, 0, 0, 0.5]
        #expect(BuiltinEQPresets.gains(for: "custom", storedCustomGains: stored) == stored)
        #expect(BuiltinEQPresets.gains(for: "custom", storedCustomGains: nil) == nil)
    }

    @Test("gains(for:) 未知 key 返回 nil")
    func gainsForUnknownKey() {
        #expect(BuiltinEQPresets.gains(for: "nonexistent") == nil)
    }
}
