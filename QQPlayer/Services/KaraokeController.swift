//
//  KaraokeController.swift
//  QQPlayer
//
//  跟唱模式控制器：状态 + 句末决策（纯逻辑可单测）+ 与 PlayerEngine 的薄桥。
//
//  语义对齐桌面版（qqplayer 前端 useAbLoop.ts）：
//  - 双击歌词（小歌词窗/全屏歌词页）进入/退出跟唱模式
//  - 跟唱模式默认「句末自动停」：每句播完停回本句句首（方便反复跟读）
//  - 单句循环：句末自动重播本句
//  - AB 循环：长按 AB 按钮（当前句=A，等待点歌词设 B）→ A~B 区间循环
//  - 倍速：仅慢速档 [0.5, 0.6, 0.7, 0.8, 0.9, 1.0]（学唱歌场景，只慢不快）
//
//  契约（勿改 public API，任务包 A 填实现 / B 消费 UI）：
//  - PlayerEngine 每 0.25s 播放 tick 调 handlePlaybackTick(time:duration:)
//  - UI 歌词加载完成后调 setLyrics(_:)
//  - 切歌时 PlayerEngine 调 resetForNewTrack()
//

import Foundation
#if os(iOS)
    import UIKit
#endif

/// AB 循环区间状态（a/b 为歌词行号；b == nil 表示等选终点）
struct ABLoopState: Equatable {
    var a: Int
    var b: Int?
}

/// 播放器执行动作（KaraokeController → PlayerEngine 的薄桥；测试注入 fake）
@MainActor
protocol KaraokeActions {
    /// 跳转到某句句首并保持播放状态（seek 保持播放态）
    func seekAndPlay(to time: TimeInterval) async
    /// 跳转到某句句首并暂停（句末自动停）
    func seekAndPause(to time: TimeInterval) async
    /// 应用倍速到音频链（AVAudioUnitTimePitch.rate）
    func setRate(_ rate: Double)
}

/// 跟唱模式控制器（@MainActor 单例，Swift 6 严格并发）
@MainActor
final class KaraokeController: ObservableObject {
    static let shared = KaraokeController()

    // MARK: - 状态（UI 观察）

    @Published private(set) var isKaraokeOn = false
    @Published private(set) var speed: Double = 1.0
    @Published private(set) var isSingleLineLoop = false
    @Published private(set) var abLoop: ABLoopState?

    /// 倍速档位（只慢不快；1.0 在末尾，从 1.0 点一下回到 0.5 从慢开始练）
    static let speedLevels: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0]

    /// 当前歌词行（UI 歌词加载完成后注入；句末决策依赖）
    private(set) var currentLines: [LyricsLine] = []

    /// 播放器桥（运行时由 PlayerEngine 提供；测试注入 fake）
    var actions: KaraokeActions?

    /// 跳转静默窗口：jumpTo 后 0.3s 内不做句末检测（seek 异步 + tick 读到旧时间
    /// 会误判「旧句句末」重复触发——桌面版 karaokeJumpQuiet 同款，2026-08-23 教训）
    private var jumpQuietUntil: Date = .distantPast

    /// 待完成跳转（2026-08-31 修复「点击歌词行跳转不稳定」竞态根因）：
    /// jumpTo 设目标行后 seek 是异步的（可能需加载文件/启引擎，耗时不可控），
    /// 生效前 tick 读到旧播放位置 → `time < cachedStart` 把 karaokeLine 重定位回旧行；
    /// seek 完成后播放已到目标行但缓存行是旧行 → 下一 tick 误判「旧行播完」
    /// 触发句末自动停/单句循环，把播放拉回旧句句首（用户实测「点一句不能稳定播一句」）。
    /// 修复：pending 期间 tick 跳过重定位与句末检测，直到播放时间到达目标行句首
    /// （seek 生效）或超时（seek 失败，兜底解除并重定位到实际位置）。
    private var pendingJumpLine: Int?
    /// pending 超时时刻：seek 失败/目标行异常时兜底解除，防永久抑制句末检测
    private var pendingJumpDeadline: Date?
    /// seek 生效等待上限（正常 seek 远快于此；超时视为失败降级）
    private static let pendingJumpTimeout: TimeInterval = 2.0

    /// 当前跟唱行缓存（句末检测用，对齐桌面 karaokeState.line 语义）：
    /// 不能用 activeLineIndex 实时算——播放时间刚跨过句末的瞬间 active 已跳到下一句，
    /// 永远检测不到「本句播完」（单句循环/AB 失效根因，2026-08-29 用户实测）。
    /// 只在无缓存 / 时间回退到缓存行句首之前时重定位（seek/点击跳转由 jumpTo 显式更新）。
    private var karaokeLine: Int?

    /// 上次 tick 的播放时间：相邻 tick 间隔 0.25s（自然播放每 tick 前进 ≤0.25s），
    /// 前跳 >1s 只可能是用户主动 seek（进度条拖动，PlayerEngine.seek 不通知本控制器）
    /// → 重定位到当前实际行而不是触发句末自动停（2026-08-29：前向拖进度条被弹回旧句句首）
    private var lastTickTime: TimeInterval?

    /// 歌词整体延迟校准（web 版 lyric offset 对齐，D3）：
    /// >0 = 歌词比声音延后。所有行定位/句末判定用歌词轴时间（音频 t → t - offset）；
    /// 跳句 seek 目标用音频轴时间（歌词 s → s + offset）。iOS 无此设置（恒 0，行为不变）。
    var lyricOffset: TimeInterval = 0

    /// 缓存行无时间戳时的时间下界：播放时间永远不小于它 → 不触发重定位。
    /// （语义同旧 `-Double.greatestFiniteMagnitude` 魔法值，具名后可读）
    private static let noTimestampStart: TimeInterval = -Double.greatestFiniteMagnitude

    private init() {
        actions = PlayerEngineKaraokeActions()
    }

    // MARK: - 模式开关（双击歌词 toggle）

    /// 双击：进入/退出跟唱模式；退出时清理 AB/单句循环并恢复 1.0 倍速
    func toggleKaraokeMode() {
        setKaraokeOn(!isKaraokeOn)
    }

    func setKaraokeOn(_ on: Bool) {
        if isKaraokeOn == on { return }
        isKaraokeOn = on
        if on {
            karaokeLine = nil // 进入跟唱：缓存行重新定位
            lastTickTime = nil
            clearPendingJump()
            applySpeedToEngine()
        } else {
            // 退出跟唱：清理 AB/单句（避免回到正常播放后句子循环/残留 AB 标注），速度恢复 1.0
            abLoop = nil
            isSingleLineLoop = false
            speed = 1.0
            karaokeLine = nil
            lastTickTime = nil
            clearPendingJump()
            applySpeedToEngine()
        }
    }

    /// 切歌：AB 行号失效 → 清 AB；保留跟唱模式/速度/单句循环（换歌继续练）
    func resetForNewTrack() {
        abLoop = nil
        karaokeLine = nil
        lastTickTime = nil
        clearPendingJump()
    }

    /// 歌词行注入（UI 歌词加载/切歌完成后调用）
    func setLyrics(_ lines: [LyricsLine]) {
        currentLines = lines
        karaokeLine = nil // 歌词变化：缓存行失效，重新定位
        lastTickTime = nil
        clearPendingJump()
    }

    // MARK: - 倍速

    /// 循环切换档位（0.5 → 0.6 → … → 1.0 → 0.5）
    func cycleSpeed() {
        let i = Self.speedLevels.firstIndex(of: speed) ?? 0
        setSpeed(Self.speedLevels[(i + 1) % Self.speedLevels.count])
    }

    /// 直接设置速度档位（倍速点选菜单，用户 2026-08-29 拍板）
    func setSpeed(_ level: Double) {
        guard Self.speedLevels.contains(level) else { return }
        speed = level
        applySpeedToEngine()
    }

    /// 把当前 speed 应用到播放引擎
    func applySpeedToEngine() {
        actions?.setRate(speed)
    }

    /// SFB 引擎（Opus/DSD）不支持变速：由 PlayerEngine 在 SFB 曲目加载或用户
    /// 设置倍速时调用，复位 UI 显示为 1.0（避免显示倍速档但实际没变速，
    /// 2026-08-29 审计 #7）。不写回引擎；PlayerEngine.currentPlaybackRate 保留
    /// 用户值，切回 native 曲目时倍速档恢复。
    func resetSpeedForUnsupportedEngine() {
        guard speed != 1.0 else { return }
        speed = 1.0
    }

    // MARK: - 单句循环 / AB 循环

    func toggleSingleLineLoop() {
        isSingleLineLoop.toggle()
        if isSingleLineLoop {
            // 单句循环与 AB 循环互斥（用户 2026-08-29 拍板）：开单句清 AB
            abLoop = nil
        }
    }

    /// 单击 AB 按钮：当前句 = A，等待点击歌词设 B（b == nil）
    /// 与单句循环互斥：进入 AB 关闭单句循环。
    /// 返回是否成功进入（当前行无时间戳/前奏等取不到 A 点时失败并给震动反馈，
    /// 不再静默无反应——此前 guard 直接 return，按钮看起来没反应）。
    @discardableResult
    func enterABLoop(currentLine: Int) -> Bool {
        guard isKaraokeOn,
              currentLine >= 0, currentLine < currentLines.count,
              currentLines[currentLine].timestamp != nil else {
            // 失败反馈：warning 级震动（评估现有机制：KaraokeControlBar 只在
            // 取到 currentLineIndex 时给 light 震动；取不到/行无时间戳时这里补一条）
            #if os(iOS)
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            #endif
            return false
        }
        isSingleLineLoop = false
        abLoop = ABLoopState(a: currentLine, b: nil)
        return true
    }

    /// 单击 AB 按钮（已启用时）：退出 AB 循环
    func exitABLoop() {
        abLoop = nil
    }

    /// 歌词点击统一入口（对齐桌面 clickLine）：
    /// 无 AB → 播放该句；等选终点 → 点击设为 B；区间内 → 跳到该句播放；
    /// 区间外 → 退出 AB 并播放该句
    func clickLine(index: Int) {
        guard isKaraokeOn, currentLines.indices.contains(index) else { return }
        if let ab = abLoop {
            if let b = ab.b {
                if index < ab.a || index > b {
                    exitABLoop()
                    jumpTo(line: index, play: true)
                    return
                }
                jumpTo(line: index, play: true)
                return
            }
            setABEnd(index)
            return
        }
        jumpTo(line: index, play: true)
    }

    /// 上一句 / 下一句（跟唱控制条，用户 2026-08-29 拍板）：跳到当前行 ±1 句首播放。
    /// 当前行取缓存行；无缓存时按播放时间定位。边界（首句上/末句下）不动作。
    func stepLine(delta: Int, currentTime: TimeInterval) {
        guard isKaraokeOn, !currentLines.isEmpty else { return }
        let current = karaokeLine ?? LyricTiming.activeLineIndex(
            time: currentTime - lyricOffset,
            in: currentLines
        )
        guard let current else { return }
        let target = current + delta
        guard currentLines.indices.contains(target),
              currentLines[target].timestamp != nil else { return }
        jumpTo(line: target, play: true)
    }

    /// 等选终点：点击句设为 B（终点在起点前自动交换；点起点本身忽略）
    private func setABEnd(_ lineIndex: Int) {
        guard var ab = abLoop, ab.b == nil,
              currentLines.indices.contains(lineIndex) else { return }
        if lineIndex == ab.a { return }
        var a = ab.a
        var b = lineIndex
        if b < a { swap(&a, &b) }
        ab.a = a
        ab.b = b
        abLoop = ab
    }

    // MARK: - 句末决策（PlayerEngine 播放 tick 每 0.25s 调用）

    /// 播放 tick：跟唱模式下检测句末并执行 句末自动停 / 单句循环 / AB 循环
    func handlePlaybackTick(time: TimeInterval, duration: TimeInterval) {
        guard isKaraokeOn, !currentLines.isEmpty else { return }
        // 歌词轴时间：tick 的行定位/句末判定统一用（音频时间 - 歌词 offset）。
        // offset>0 时句末判定延后等价——唱歌比歌词慢时不被误判提前停（web lyricTime 语义）。
        let tickTime = time - lyricOffset
        // 待完成跳转：seek 异步生效前，tick 一律跳过（不重定位、不句末检测）。
        // 否则 tick 读到旧播放位置会把 karaokeLine 重定位回旧行，seek 生效后
        // 基于旧行误触发句末自动停，把播放拉回旧句（2026-08-31 点击跳转竞态根因）。
        if let pending = pendingJumpLine {
            // seek 已生效：播放时间到达目标行句首 → 解除 pending，走正常检测
            if let ts = currentLines.indices.contains(pending) ? currentLines[pending].timestamp : nil,
               tickTime >= ts {
                pendingJumpLine = nil
                pendingJumpDeadline = nil
            } else if let deadline = pendingJumpDeadline, Date() > deadline {
                // seek 失败/超时（如目标行无时间戳、音频未加载）：解除 pending 降级，
                // 缓存行重定位到实际播放位置，不阻塞后续句末检测
                print("⏭️ Karaoke pending jump timed out (line \(pending)) - relocating to actual position")
                pendingJumpLine = nil
                pendingJumpDeadline = nil
                karaokeLine = LyricTiming.activeLineIndex(time: tickTime, in: currentLines)
            } else {
                return
            }
        }
        guard Date() > jumpQuietUntil else { return }
        // 用户主动前向 seek（进度条拖动）：相比上一 tick 大幅前跳（>1s；自然播放每 tick
        // 最多前进 0.25s，1x/慢速都远小于阈值）→ 重定位到当前实际行，不触发句末自动停。
        // 否则前向拖进度条会被「句末自动停」弹回旧句句首并暂停（2026-08-29 用户实测）。
        if let last = lastTickTime, tickTime - last > 1.0 {
            karaokeLine = LyricTiming.activeLineIndex(time: tickTime, in: currentLines)
            lastTickTime = tickTime
            return
        }
        lastTickTime = tickTime
        // 重定位：无缓存行，或时间回退到缓存行句首之前（前奏/回退；点击跳转走 jumpTo 显式更新）
        if let cachedLine = karaokeLine {
            let cachedStart = currentLines.indices.contains(cachedLine)
                ? (currentLines[cachedLine].timestamp ?? Self.noTimestampStart)
                : Self.noTimestampStart
            if tickTime < cachedStart {
                karaokeLine = LyricTiming.activeLineIndex(time: tickTime, in: currentLines)
            }
        } else {
            karaokeLine = LyricTiming.activeLineIndex(time: tickTime, in: currentLines)
        }
        guard let line = karaokeLine else { return }
        // 句末未知（duration 未解析为 0 且是最后一句）→ 不判定句末，避免「time >= 0 恒真」
        // 每 tick 都触发句末自动停（点播放立刻又停，2026-08-29 用户实测）
        guard let end = lineEndTime(line: line, duration: duration) else { return }
        guard tickTime >= end else { return }
        handleLineEnd(line)
    }

    /// 本句结束时间 = 下一句句首时间戳；最后一句 = 歌曲时长。
    /// duration 未知（<=0）时最后一句无句末 → 返回 nil（不触发句末自动停）
    private func lineEndTime(line: Int, duration: TimeInterval) -> TimeInterval? {
        if line + 1 < currentLines.count, let next = currentLines[line + 1].timestamp {
            return next
        }
        guard duration > 0 else { return nil }
        return duration
    }

    /// 句末处理（对齐桌面 handleKaraokeTick）：
    /// AB 激活 → 按 AB 规则；否则单句循环 → 重播本句；否则句末自动停 → 回句首暂停
    private func handleLineEnd(_ line: Int) {
        if let ab = abLoop {
            if ab.b == nil {
                // 等选终点：任何句播完都跳回 A 循环（桌面同款）
                jumpTo(line: ab.a, play: true)
                return
            }
            if let b = ab.b {
                if line < b {
                    // 区间中间句：推进缓存行到下一句（自然播放，下个 tick 检测下一句末）
                    karaokeLine = line + 1
                    return
                }
                if line == b {
                    // B 终点播完 → 跳回 A 重播
                    jumpTo(line: ab.a, play: true)
                    return
                }
            }
            // line > b（seek 跳出区间）：落到单句/自动停
        }
        if isSingleLineLoop {
            jumpTo(line: line, play: true)
        } else {
            jumpTo(line: line, play: false)
        }
    }

    // MARK: - 跳转

    /// 跳转到某句句首；play=false 时跳完暂停（句末自动停）
    /// 同步更新缓存行（karaokeLine = 目标行）：seek 后 tick 不误判旧行句末
    private func jumpTo(line: Int, play: Bool) {
        guard currentLines.indices.contains(line),
              let ts = currentLines[line].timestamp else {
            return
        }
        karaokeLine = line
        lastTickTime = ts // seek 到目标时间，避免静默窗口过后首个 tick 被误判为前向 seek
        // 设置待完成跳转：seek 生效前 tick 跳过重定位/句末检测（竞态修复 2026-08-31）
        pendingJumpLine = line
        pendingJumpDeadline = Date().addingTimeInterval(Self.pendingJumpTimeout)
        jumpQuietUntil = Date().addingTimeInterval(0.3)
        // 目标行句首在音频轴 = 歌词时间 + offset（web audioTime 语义：校准后跳到歌词对应的声音位置）
        let target = ts + lyricOffset
        Task { @MainActor in
            if play {
                await actions?.seekAndPlay(to: target)
            } else {
                await actions?.seekAndPause(to: target)
            }
        }
    }

    /// 清理待完成跳转（模式开关/切歌/歌词变化时调用）
    private func clearPendingJump() {
        pendingJumpLine = nil
        pendingJumpDeadline = nil
    }
}

/// PlayerEngine 桥（KaraokeController 默认 actions）
/// setRate 依赖 PlayerEngine.setPlaybackRate（任务包 A 实现：AVAudioUnitTimePitch 接入）
private struct PlayerEngineKaraokeActions: KaraokeActions {
    func seekAndPlay(to time: TimeInterval) async {
        await PlayerEngine.shared.seek(to: time)
        // 暂停态点击上一句/下一句/歌词行也要自动播放（用户 2026-08-29 拍板）：
        // seek 只更新位置不改变播放态，这里补 play()
        if !PlayerEngine.shared.isPlaying {
            PlayerEngine.shared.play()
        } else {
        }
    }

    func seekAndPause(to time: TimeInterval) async {
        await PlayerEngine.shared.seek(to: time)
        PlayerEngine.shared.pause()
    }

    func setRate(_ rate: Double) {
        PlayerEngine.shared.setPlaybackRate(rate)
    }
}
