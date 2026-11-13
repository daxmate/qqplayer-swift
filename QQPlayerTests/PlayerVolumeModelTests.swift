//
//  PlayerVolumeModelTests.swift
//  QQPlayerTests
//
//  App 级音量模型防回归测试（2026-11-13 macOS 播放条音量控制）。
//  PlayerVolumeModel 是音量数学 / 静音语义的唯一事实源（播放条、快捷键、菜单、
//  引擎全部经由它），这里锁定：夹取、两位小数、步进边界、静音记忆与恢复、
//  lastNonZero 下限、以及两个 UserDefaults 键的 round-trip（注入 suite，不污染标准域）。
//
//  快捷键形状：三条音量 def 的默认组合引用 MacShortcutLogic 的 shipped 常量
//  （allDefs 与单测共用同一处定义），并验证它们参与既有冲突检测。
//  未覆盖（环境限制）：整张 allDefs 表的「无重复组合」断言需要 MacKeyboardShortcuts
//  （AppKit，只在 QQPlayerMac target），而 QQPlayerTests 只对 iOS target 编译。
//

import Foundation
import Testing

@testable import QQPlayer

/// 独立的 UserDefaults suite：单测绝不写标准域（否则会改到真机/模拟器上的 App 设置）。
/// 每个用例一个**唯一**域名——Swift Testing 默认并行跑，共用域名会互相清域/覆盖。
private struct VolumeTestDefaults {
    let name: String
    let defaults: UserDefaults

    init() {
        name = "QQPlayerTests.PlayerVolumeModel.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: name)
    }
}

struct PlayerVolumeModelTests {
    // MARK: - 夹取与精度

    @Test("夹取：低于 0 / 高于 1 都被夹住")
    func clampsOutOfRange() {
        var model = PlayerVolumeModel()
        model.setVolume(-0.5)
        #expect(model.volume == 0)
        #expect(model.isMuted)

        model.setVolume(3)
        #expect(model.volume == 1)
        #expect(!model.isMuted)
    }

    @Test("非法输入（NaN / ∞）忽略且不崩")
    func ignoresNonFiniteValues() {
        var model = PlayerVolumeModel(volume: 0.4)
        model.setVolume(.nan)
        #expect(model.volume == 0.4)

        model.setVolume(.infinity)
        #expect(model.volume == 0.4)

        model.adjust(by: .nan)
        #expect(model.volume == 0.4)
    }

    @Test("保留两位小数：0.1234 → 0.12，0.005 → 0.01")
    func roundsToTwoDecimals() {
        var model = PlayerVolumeModel()
        model.setVolume(0.1234)
        #expect(model.volume == 0.12)

        model.setVolume(0.005)
        #expect(model.volume == 0.01)
    }

    // MARK: - 步进

    @Test("步进：0.05 一档，两端夹住不回绕")
    func stepsAndClampsAtBounds() {
        var model = PlayerVolumeModel(volume: 0.95)
        model.adjust(by: PlayerVolumeModel.step)
        #expect(model.volume == 1)

        model.adjust(by: PlayerVolumeModel.step)
        #expect(model.volume == 1)

        model.setVolume(0.03)
        model.adjust(by: -PlayerVolumeModel.step)
        #expect(model.volume == 0)
        #expect(model.isMuted)
    }

    @Test("静音状态下上调音量：直接解除静音")
    func adjustFromMutedUnmutes() {
        var model = PlayerVolumeModel(volume: 0.5)
        model.toggleMute()
        #expect(model.volume == 0)

        model.adjust(by: PlayerVolumeModel.step)
        #expect(model.volume == 0.05)
        #expect(!model.isMuted)
    }

    // MARK: - 静音语义

    @Test("静音记住当前音量，取消静音恢复原值")
    func muteRemembersAndRestores() {
        var model = PlayerVolumeModel(volume: 0.8)
        model.toggleMute()
        #expect(model.volume == 0)
        #expect(model.isMuted)
        #expect(model.lastNonZeroVolume == 0.8)

        model.toggleMute()
        #expect(model.volume == 0.8)
        #expect(!model.isMuted)
    }

    @Test("lastNonZero 下限 5%：不会恢复成 0")
    func restorableVolumeHasFloor() {
        var model = PlayerVolumeModel(volume: 0.01)
        model.toggleMute()
        #expect(model.lastNonZeroVolume == PlayerVolumeModel.minRestorableVolume)

        model.toggleMute()
        #expect(model.volume == PlayerVolumeModel.minRestorableVolume)
    }

    @Test("静音判据恒等于 volume == 0（模型不变量）")
    func muteInvariantHolds() {
        var model = PlayerVolumeModel()
        for value in [1.0, 0.5, 0.0, 0.07, 0.0] {
            model.setVolume(value)
            #expect(model.isMuted == (model.volume == 0))
        }
    }

    // MARK: - 持久化

    @Test("持久化 round-trip：音量 + 静音两个键都记住")
    func persistenceRoundTrip() {
        let store = VolumeTestDefaults()
        defer { store.cleanUp() }
        let defaults = store.defaults

        var model = PlayerVolumeModel(volume: 0.6)
        PlayerVolumePersistence.save(model, to: defaults)

        var loaded = PlayerVolumePersistence.load(from: defaults)
        #expect(loaded.volume == 0.6)
        #expect(!loaded.isMuted)
        #expect(loaded == model)

        // 静音后落盘：启动仍是静音，但「记住的音量」还在 → 取消静音能回到 0.6
        model.toggleMute()
        PlayerVolumePersistence.save(model, to: defaults)

        loaded = PlayerVolumePersistence.load(from: defaults)
        #expect(loaded.volume == 0)
        #expect(loaded.isMuted)
        #expect(loaded.lastNonZeroVolume == 0.6)

        loaded.toggleMute()
        #expect(loaded.volume == 0.6)
    }

    @Test("首次启动（无键）默认 100% 不静音")
    func defaultsWhenNothingStored() {
        let store = VolumeTestDefaults()
        defer { store.cleanUp() }
        let defaults = store.defaults

        let model = PlayerVolumePersistence.load(from: defaults)
        #expect(model.volume == 1)
        #expect(!model.isMuted)
    }

    @Test("脏数据兜底：存了越界值也不会炸")
    func clampsCorruptedStoredValues() {
        let store = VolumeTestDefaults()
        defer { store.cleanUp() }
        let defaults = store.defaults

        defaults.set(2.5, forKey: PlayerVolumePersistence.volumeKey)
        #expect(PlayerVolumePersistence.load(from: defaults).volume == 1)

        defaults.set(-1.0, forKey: PlayerVolumePersistence.volumeKey)
        #expect(PlayerVolumePersistence.load(from: defaults).volume == PlayerVolumeModel.minRestorableVolume)
    }
}
/// 快捷键形状：三条音量 def 的默认组合（引用 shipped 常量，防 allDefs / 单测两处手写漂移）。
struct PlayerVolumeShortcutShapeTests {
    private func combo(_ keyCode: Int, _ flags: Int = 0) -> ShortcutCombo {
        ShortcutCombo(keyCode: keyCode, flags: flags, display: "")
    }

    @Test("默认组合：⌘↑ = 126 + command，⌘↓ = 125 + command，M = 46 无修饰")
    func defaultCombos() {
        let up = MacShortcutLogic.volumeUpDefaultCombo
        #expect(up == combo(126, ShortcutModifier.command))
        #expect(up.flags == ShortcutModifier.command)
        #expect(up.display == "⌘↑")

        let down = MacShortcutLogic.volumeDownDefaultCombo
        #expect(down == combo(125, ShortcutModifier.command))
        #expect(down.display == "⌘↓")

        let mute = MacShortcutLogic.muteToggleDefaultCombo
        #expect(mute == combo(46))
        #expect(mute.flags == 0)
        #expect(mute.display == "M")
    }

    /// 复用 MacShortcutLogic.findConflict（不另写冲突算法）：三条默认组合互不相撞，
    /// 且别的快捷键若录成 ⌘↑ 会被判给 volumeUp。
    @Test("findConflict：三条音量默认组合互不冲突，且参与冲突检测")
    func volumeCombosParticipateInConflictDetection() {
        let defs: [(id: String, defaultCombo: ShortcutCombo)] = [
            ("playPause", combo(49)),
            ("volumeUp", MacShortcutLogic.volumeUpDefaultCombo),
            ("volumeDown", MacShortcutLogic.volumeDownDefaultCombo),
            ("muteToggle", MacShortcutLogic.muteToggleDefaultCombo),
        ]

        for (id, defaultCombo) in defs where id != "playPause" {
            #expect(MacShortcutLogic.findConflict(id: id, combo: defaultCombo, defs: defs, overrides: [:]) == nil)
        }
        #expect(
            MacShortcutLogic.findConflict(
                id: "playPause",
                combo: MacShortcutLogic.volumeUpDefaultCombo,
                defs: defs,
                overrides: [:]
            ) == "volumeUp"
        )
    }

    /// 用户 2026-11-13 拍板：音量 ± 与系统音量键手感一致——按住连续走档；
    /// 静音是 toggle，连发会来回抖动，必须过滤（沿用既有 repeat 白名单）。
    @Test("长按连发：音量 ± 允许 repeat，静音只在首按执行")
    func volumeShortcutsRepeatPolicy() {
        for id in ["volumeUp", "volumeDown"] {
            #expect(MacShortcutLogic.repeatableShortcutIds.contains(id))
            #expect(MacShortcutLogic.shouldRunAction(id: id, isARepeat: false))
            #expect(MacShortcutLogic.shouldRunAction(id: id, isARepeat: true))
        }

        #expect(!MacShortcutLogic.repeatableShortcutIds.contains("muteToggle"))
        #expect(MacShortcutLogic.shouldRunAction(id: "muteToggle", isARepeat: false))
        #expect(!MacShortcutLogic.shouldRunAction(id: "muteToggle", isARepeat: true))
    }
}
