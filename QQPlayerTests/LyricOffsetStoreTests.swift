//
//  LyricOffsetStoreTests.swift
//  QQPlayerTests
//
//  歌词延迟补偿契约（纯逻辑，不碰 AVAudioSession / UserDefaults）：
//  - 输出路由分组映射（车机 / 蓝牙 / AirPlay / 有线 / 扬声器 / 其它）
//  - 自动初值只对带传输延迟的路由生效，并夹在 0…上限
//  - 生效偏移优先级：当前路由手动值 → 全局手动值 → 自动初值
//

import AVFoundation
import Testing

@testable import QQPlayer

struct LyricOffsetResolutionTests {
    // MARK: - 路由映射

    @Test("输出端口 → 偏移分组")
    func routeMapping() {
        #expect(LyricOffsetRoute(portType: .carAudio) == .carPlay)
        #expect(LyricOffsetRoute(portType: .bluetoothA2DP) == .bluetooth)
        #expect(LyricOffsetRoute(portType: .bluetoothHFP) == .bluetooth)
        #expect(LyricOffsetRoute(portType: .airPlay) == .airPlay)
        #expect(LyricOffsetRoute(portType: .usbAudio) == .wired)
        #expect(LyricOffsetRoute(portType: .headphones) == .wired)
        #expect(LyricOffsetRoute(portType: .builtInSpeaker) == .speaker)
        #expect(LyricOffsetRoute(portType: AVAudioSession.Port(rawValue: "ZZZ")) == .other)
    }

    @Test("只有带传输延迟的路由参与补偿（扬声器/有线耳机不补）")
    func transportLatencyRoutes() {
        #expect(LyricOffsetRoute.carPlay.hasTransportLatency)
        #expect(LyricOffsetRoute.bluetooth.hasTransportLatency)
        #expect(LyricOffsetRoute.airPlay.hasTransportLatency)
        #expect(!LyricOffsetRoute.wired.hasTransportLatency)
        #expect(!LyricOffsetRoute.speaker.hasTransportLatency)
        #expect(!LyricOffsetRoute.other.hasTransportLatency)
    }

    // MARK: - 自动初值

    @Test("自动初值：车机/蓝牙取系统延迟，夹在 0…上限")
    func autoOffsetClamps() {
        #expect(LyricOffsetResolution.autoOffset(systemLatency: 0.3, route: .carPlay) == 0.3)
        #expect(LyricOffsetResolution.autoOffset(systemLatency: 3.0, route: .carPlay) == LyricOffsetResolution.maximumAutoOffset)
        #expect(LyricOffsetResolution.autoOffset(systemLatency: -1, route: .carPlay) == 0)
    }

    @Test("自动初值：扬声器/有线路由恒为 0（系统延迟是硬件缓冲，不是听觉差）")
    func autoOffsetIgnoredWithoutTransportLatency() {
        #expect(LyricOffsetResolution.autoOffset(systemLatency: 0.3, route: .speaker) == 0)
        #expect(LyricOffsetResolution.autoOffset(systemLatency: 0.3, route: .wired) == 0)
    }

    // MARK: - 生效偏移优先级

    @Test("生效偏移：当前路由手动值优先")
    func manualWins() {
        let offset = LyricOffsetResolution.effectiveOffset(manual: 0.4, global: 0.9, auto: 0.2)
        #expect(offset == 0.4)
    }

    @Test("生效偏移：没手动值就用全局（Mac/web 那个设置），全局为 0 才用自动初值")
    func globalThenAuto() {
        #expect(LyricOffsetResolution.effectiveOffset(manual: nil, global: 0.9, auto: 0.2) == 0.9)
        #expect(LyricOffsetResolution.effectiveOffset(manual: nil, global: 0, auto: 0.2) == 0.2)
    }

    @Test("手动校准为 0 是「明确不补」，不会掉回自动初值")
    func explicitZeroIsRespected() {
        #expect(LyricOffsetResolution.effectiveOffset(manual: 0, global: 0.9, auto: 0.3) == 0)
    }
}
