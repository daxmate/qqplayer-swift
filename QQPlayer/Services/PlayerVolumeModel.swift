//
//  PlayerVolumeModel.swift
//  QQPlayer
//
//  App 级音量模型（macOS 播放音量）：夹取 / 两位小数 / 步进 / 静音记忆的**唯一事实源**。
//  纯值语义、平台无关（只有 Foundation）——UI、快捷键、菜单、播放引擎全部经由这里，
//  禁止在别处重写这套算术（任务包 §4「不得新增第二实现」）。
//
//  为什么持久化也在这里：QQPlayerTests 只对 iOS target 编译（Mac/ 目录的文件进不了
//  测试包），macOS 专属的 PlayerEngine+Volume+Mac.swift 无法被单测覆盖，因此键名与
//  读写实现放在平台无关的本文件，引擎侧只做调用（唯一调用方，再无第二处持久化）。
//

import Foundation

/// App 级音量状态与数学语义（值类型；每次变更整体替换，便于比对与持久化）。
struct PlayerVolumeModel: Equatable {
    /// 步进档位（音量键 / 快捷键 / 菜单共用；5% 一档）。
    static let step: Double = 0.05
    /// 「记住的音量」下限：避免恢复出 0（静音记忆失效）的死循环。
    static let minRestorableVolume: Double = 0.05

    /// 当前音量（0…1，保留两位小数）。
    private(set) var volume: Double
    /// 最近一次非零音量（静音恢复用；恒 >= minRestorableVolume）。
    private(set) var lastNonZeroVolume: Double
    /// 静音标记；与 `volume == 0` 恒等价（只由 setVolume / toggleMute 维护）。
    private(set) var isMuted: Bool

    /// `lastNonZeroVolume` 缺省时跟随当前音量（>0 用当前值，=0 回落到 100%），
    /// 避免「构造一个 0.6 的模型，静音一次却恢复到 100%」这种反直觉行为。
    init(volume: Double = 1, lastNonZeroVolume: Double? = nil) {
        let normalizedVolume = Self.normalize(volume) ?? 1
        self.volume = normalizedVolume
        let remembered = lastNonZeroVolume.flatMap { Self.normalize($0) }
            ?? (normalizedVolume > 0 ? normalizedVolume : 1)
        self.lastNonZeroVolume = max(Self.minRestorableVolume, remembered)
        isMuted = normalizedVolume == 0
    }

    /// 设置绝对音量：夹取 0…1 并保留两位小数；>0 时解除静音并记住（下限 5%），=0 视为静音。
    /// 非法输入（NaN / ∞）直接忽略——滑块与快捷键都可能传入脏值，宁可不动也不能崩。
    mutating func setVolume(_ value: Double) {
        guard let normalized = Self.normalize(value) else { return }
        volume = normalized
        if normalized > 0 {
            lastNonZeroVolume = max(Self.minRestorableVolume, normalized)
            isMuted = false
        } else {
            isMuted = true
        }
    }

    /// 步进（正负均可）；到边即夹住，不回绕。
    mutating func adjust(by delta: Double) {
        guard delta.isFinite, delta != 0 else { return }
        setVolume(volume + delta)
    }

    /// 静音 ⇄ 恢复：静音时记住当前音量，恢复时取 max(lastNonZeroVolume, 5%)。
    mutating func toggleMute() {
        if isMuted || volume == 0 {
            setVolume(max(lastNonZeroVolume, Self.minRestorableVolume))
        } else {
            lastNonZeroVolume = max(Self.minRestorableVolume, volume)
            volume = 0
            isMuted = true
        }
    }

    /// 夹取 + 两位小数；非有限值返回 nil（调用方决定忽略还是回落默认）。
    private static func normalize(_ value: Double) -> Double? {
        guard value.isFinite else { return nil }
        let clamped = min(max(value, 0), 1)
        return (clamped * 100).rounded() / 100
    }
}

/// 音量持久化（两个 UserDefaults 键，默认域可注入以便单测不污染标准域）。
///
/// 键语义：`volume` 存**非零音量**（静音时也保留，供下次恢复），`muted` 决定启动后的
/// 实际音量——这样静音退出 App、下次启动仍是静音，但一按「取消静音」能回到原音量。
enum PlayerVolumePersistence {
    /// App 级音量（非零值）。
    static let volumeKey = "qqplayer.playback.volume.v1"
    /// 静音状态。
    static let mutedKey = "qqplayer.playback.muted.v1"

    /// 读取：缺省（老用户/首启）为 100% 不静音。
    static func load(from defaults: UserDefaults = .standard) -> PlayerVolumeModel {
        let stored = defaults.object(forKey: volumeKey) as? Double ?? 1
        let restorableVolume = min(max(stored, PlayerVolumeModel.minRestorableVolume), 1)
        let isMuted = defaults.bool(forKey: mutedKey)
        return PlayerVolumeModel(
            volume: isMuted ? 0 : restorableVolume,
            lastNonZeroVolume: restorableVolume
        )
    }

    /// 写入：每次模型变更后调用（唯一写入点）。
    static func save(_ model: PlayerVolumeModel, to defaults: UserDefaults = .standard) {
        defaults.set(model.lastNonZeroVolume, forKey: volumeKey)
        defaults.set(model.isMuted, forKey: mutedKey)
    }
}
