//
//  LyricOffsetStore.swift
//  QQPlayer
//
//  歌词时间偏移（延迟补偿）的 iOS 唯一入口。
//
//  为什么需要：车里听歌时「看到的」和「听到的」之间有几十到几百毫秒的差——无线 CarPlay 的
//  音频要经 WiFi 送到车机解码播放，画面也要经编码/传输/车机解码，再加上我们自己的 0.5s 刷新粒度。
//  要让歌词跟耳朵对齐，就得把「当前句判定用的时间」整体挪一点。
//
//  设计：
//   - 偏移**按输出路由分开存**（车机 / 蓝牙 / 有线耳机量级差很多，同一副耳机才谈得上复用）；
//   - 没手动校准时用**系统初值** `AVAudioSession.outputLatency`（只对带传输延迟的路由生效，
//     并夹在 0…0.5s——系统偶有怪值，别让它把歌词拽歪）；
//   - 路由变化（上下车 / 插拔 / 切蓝牙）自动重取；
//   - 只影响「歌词行号判定 + 播放页进度时间」，**不动播放器时钟**（否则锁屏/控制中心进度条会跟着错）。
//
//  消费点：CarPlay+PlayerPage.swift（车里那页，2026-09-16 接入）。iOS App 内歌词页与 Mac 端
//  仍用各自入口，待迁移——迁移时也只读这里的 effectiveOffset，别在页面层再算一遍。
//
// target: ios-only
//
import AVFoundation
import Combine
import Foundation
import Observation

// MARK: - 路由

/// 输出路由分组：偏移量在这里分开存
enum LyricOffsetRoute: String, CaseIterable {
    case carPlay
    case bluetooth
    case airPlay
    case wired
    case speaker
    case other

    init(portType: AVAudioSession.Port) {
        switch portType {
        case .carAudio: self = .carPlay
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: self = .bluetooth
        case .airPlay: self = .airPlay
        case .usbAudio, .headphones, .lineOut, .HDMI: self = .wired
        case .builtInSpeaker, .builtInReceiver: self = .speaker
        default: self = .other
        }
    }

    /// 这条路由是否有值得补偿的传输延迟（扬声器 / 有线耳机基本可忽略）
    var hasTransportLatency: Bool {
        switch self {
        case .carPlay, .bluetooth, .airPlay: return true
        case .wired, .speaker, .other: return false
        }
    }
}

// MARK: - 偏移解算（纯逻辑）

/// 偏移怎么算（纯函数：只吃值，不碰 AVAudioSession / 设置 → 可单测）
enum LyricOffsetResolution {
    /// 自动初值上限：系统报的 outputLatency 偶有怪值，夹住别把歌词拽飞
    static let maximumAutoOffset: TimeInterval = 0.5

    /// 自动初值 = min(max(系统延迟, 0), 上限)，且只对带传输延迟的路由生效
    static func autoOffset(systemLatency: TimeInterval, route: LyricOffsetRoute) -> TimeInterval {
        guard route.hasTransportLatency else { return 0 }
        return min(max(systemLatency, 0), maximumAutoOffset)
    }

    /// 生效偏移 = 当前路由手动值 ?? 全局手动值（Mac/web 那个「歌词延迟」） ?? 自动初值
    static func effectiveOffset(manual: Double?, global: Double, auto: TimeInterval) -> TimeInterval {
        if let manual { return manual }
        if global != 0 { return global }
        return auto
    }
}

// MARK: - 当前路由 + 偏移

/// 当前输出路由、系统延迟、手动校准值（视图读；设置页要跟着变）
///
/// 2026-09-19（视图层单例收口「下降预算」批 2）：`ObservableObject` → `@Observable`。
/// 唯一视图消费点（iOS 设置页歌词延迟区）不再 `@ObservedObject … = .shared`，
/// 改由 iOS 组合根（`QQPlayerApp` 的 `WindowGroup` 根）`.environment(...)` 注入、
/// `@Environment(LyricOffsetStore.self)` 取。
/// 刷新路径核对：视图读的后 4 个存储属性（`route` / `routeName` / `systemLatency` / `manualOffset`）
/// 全在设置页 `body` 可达路径上（行文案 + Slider 绑定）→ 按属性追踪后刷新不变；
/// 路由变化由 `AVAudioSession.routeChangeNotification` 驱动写入，机制未变。
@MainActor
@Observable
final class LyricOffsetStore {
    static let shared = LyricOffsetStore()

    /// 当前输出路由
    private(set) var route: LyricOffsetRoute = .other
    /// 当前输出端口名（系统已本地化，如 "CarPlay"）
    private(set) var routeName: String?
    /// 系统给的输出延迟（设置页用于说明「初值多少」）
    private(set) var systemLatency: TimeInterval = 0
    /// 当前路由的手动校准值（nil = 没校准过 → 用自动初值）
    private(set) var manualOffset: Double?

    private var cancellables = Set<AnyCancellable>()
    /// 设置快照：effectiveOffset 会被 0.5s tick 读到，别在里面做 UserDefaults 读取
    private var settings = DeleteSettings.load()

    /// 生效偏移（消费点只读这个）
    var effectiveOffset: TimeInterval {
        LyricOffsetResolution.effectiveOffset(
            manual: manualOffset,
            global: settings.lyricOffset,
            auto: LyricOffsetResolution.autoOffset(systemLatency: systemLatency, route: route)
        )
    }

    /// 系统给的自动初值（设置页展示用）
    var autoOffset: TimeInterval {
        LyricOffsetResolution.autoOffset(systemLatency: systemLatency, route: route)
    }

    private init() {
        settings = DeleteSettings.load()
        refreshRoute()

        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refreshRoute() }
            }
            .store(in: &cancellables)

        // 设置页改动（Mac/web 的全局 lyricOffset、本页写入）→ 重新取快照
        NotificationCenter.default.publisher(for: .qqplayerSettingsDidChange)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.settings = DeleteSettings.load()
                    self.refreshManualOffset()
                }
            }
            .store(in: &cancellables)
    }

    /// 手动校准当前路由的偏移（正值 = 歌词比引擎时钟延后，即补偿「声音到得晚」）
    func setManualOffset(_ value: Double) {
        var updated = settings
        updated.lyricOffsetsByRoute[route.rawValue] = value
        updated.save()
        settings = updated
        manualOffset = value
    }

    /// 退回自动初值
    func clearManualOffset() {
        var updated = settings
        updated.lyricOffsetsByRoute.removeValue(forKey: route.rawValue)
        updated.save()
        settings = updated
        manualOffset = nil
    }

    // MARK: - 路由

    private func refreshRoute() {
        let session = AVAudioSession.sharedInstance()
        let output = session.currentRoute.outputs.first
        route = output.map { LyricOffsetRoute(portType: $0.portType) } ?? .other
        routeName = output?.portName
        systemLatency = session.outputLatency
        refreshManualOffset()
    }

    private func refreshManualOffset() {
        manualOffset = settings.lyricOffsetsByRoute[route.rawValue]
    }
}
