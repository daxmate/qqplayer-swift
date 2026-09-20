//  SFBAudioEngineManager.swift
//  QQPlayer
//
//  Manages SFBAudioEngine playback for Opus, Vorbis, and DSD formats
//
//  Split into domain extensions (behavior-identical refactor):
//    SFBAudioEngineManager+Playback.swift  playback control/seek/rate/time
//    SFBAudioEngineManager+Queue.swift     progress/format compatibility
//
import AVFoundation
#if os(iOS)
    import CarPlay
#endif
import Foundation
import Observation
import SFBAudioEngine
#if os(iOS)
    import UIKit
#endif

private struct AVAudioUnitEQBox: @unchecked Sendable {
    let node: AVAudioUnitEQ
}

@MainActor
@Observable
class SFBAudioEngineManager: NSObject, AudioPlayer.Delegate {
    static let shared = SFBAudioEngineManager()

    // 非 UI 状态（迁移前即非 @Published ⇒ 不参与刷新信号）：保留 @ObservationIgnored，刷新时机与迁移前一致。
    @ObservationIgnored var audioPlayer: AudioPlayer?
    @ObservationIgnored var currentTrack: SFBTrack?
    @ObservationIgnored var updateTimer: Timer?
    @ObservationIgnored private var eqAttachmentFailed = false

    nonisolated private func configureDefaultSFBBands(for equalizer: AVAudioUnitEQ) {
        let numberOfBands = equalizer.bands.count
        let minFreq = 20.0
        let maxFreq = 20000.0

        for i in 0 ..< numberOfBands {
            let band = equalizer.bands[i]
            let frequency = minFreq * pow(maxFreq / minFreq, Double(i) / Double(numberOfBands - 1))
            band.frequency = Float(frequency)
            band.gain = 0.0
            band.bandwidth = 1.0
            band.filterType = .parametric
            band.bypass = false
        }
    }

    func cleanupEqualizer() {
        if let equalizer = sfbEqualizer {
            audioPlayer?.modifyProcessingGraph { [weak self] engine in
                guard let self else { return }
                if engine.attachedNodes.contains(equalizer) {
                    self.removeEqualizer(equalizer, from: engine)
                }
            }
        }
        sfbEqualizer = nil
    }

    nonisolated private func removeEqualizer(_ equalizer: AVAudioUnitEQ, from engine: AVAudioEngine) {
        guard engine.attachedNodes.contains(equalizer) else {
            AppLog.info(.general, "ℹ️ EQ node already detached")
            return
        }

        let mixerConnection = engine.inputConnectionPoint(for: engine.mainMixerNode, inputBus: 0)
        let isEQFeedingMixer = mixerConnection?.node === equalizer

        let upstreamConnection = engine.inputConnectionPoint(for: equalizer, inputBus: 0)
        let upstreamNode = upstreamConnection?.node

        if isEQFeedingMixer, let upstreamNode {
            let upstreamBus = upstreamConnection?.bus ?? 0
            let reconnectFormat = upstreamNode.outputFormat(forBus: upstreamBus)

            engine.disconnectNodeInput(engine.mainMixerNode)
            engine.disconnectNodeOutput(equalizer)
            engine.disconnectNodeInput(equalizer)
            engine.detach(equalizer)

            engine.connect(upstreamNode, to: engine.mainMixerNode, format: reconnectFormat)
            AppLog.info(.general, "🔗 Restored \(upstreamNode) → mainMixerNode after EQ removal")
        } else {
            engine.disconnectNodeOutput(equalizer)
            engine.disconnectNodeInput(equalizer)
            engine.detach(equalizer)
            AppLog.info(.general, "🧹 Removed SFBAudioEngine EQ (no upstream reconnection needed)")
        }
    }

    func attachEqualizerToEngine(with format: AVAudioFormat?, retryCount: Int = 0) {
        guard let player = audioPlayer else { return }

        // Skip EQ if not enabled by user
        guard eqManager.isEnabled else {
            AppLog.info(.general, "ℹ️ EQ not enabled by user - skipping attachment")
            return
        }

        // Skip EQ if previous attachment failed (prevents repeated crashes)
        if eqAttachmentFailed {
            AppLog.warn(.general, "⚠️ EQ attachment previously failed - skipping to prevent crash")
            return
        }

        let maxRetries = 3
        let eqEnabled = eqManager.isEnabled
        let globalGain = Float(eqManager.globalGain)

        guard formatSupportsSFBEQ(format) else {
            AppLog.warn(.general, "⚠️ SFBAudioEngine EQ not supported for format: \(format?.description ?? "nil")")
            player.modifyProcessingGraph { [weak self] engine in
                guard let self else { return }
                if let existing = engine.attachedNodes.compactMap({ $0 as? AVAudioUnitEQ }).first {
                    self.removeEqualizer(existing, from: engine)
                }
            }
            Task { @MainActor [weak self] in self?.sfbEqualizer = nil }
            return
        }

        // 闭包在 AVAudioEngine 内部串行队列执行，不能直接读 MainActor 隔离的
        // sfbEqualizer（数据竞争，Swift 6 编译期不检查，2026-08-29 审计 #8）：
        // 在 MainActor 侧预拷贝为 @unchecked Sendable 的 box，闭包内只用 box。
        let existingEqualizerBox = sfbEqualizer.map { AVAudioUnitEQBox(node: $0) }
        player.modifyProcessingGraph { [weak self] engine in
            guard let self else { return }

            var equalizer = existingEqualizerBox?.node

            if equalizer == nil {
                equalizer = engine.attachedNodes.compactMap { $0 as? AVAudioUnitEQ }.first
            }

            if equalizer == nil {
                let newEQ = AVAudioUnitEQ(numberOfBands: 16)
                newEQ.globalGain = globalGain
                newEQ.bypass = !eqEnabled
                self.configureDefaultSFBBands(for: newEQ)
                engine.attach(newEQ)
                equalizer = newEQ
                AppLog.info(.general, "✅ EQ node attached via modifyProcessingGraph")
            } else if let eq = equalizer, !engine.attachedNodes.contains(where: { $0 === eq }) {
                engine.attach(eq)
                AppLog.info(.general, "✅ Reattached existing SFBAudioEngine EQ node")
            }

            guard let equalizer else { return }

            let eqBox = AVAudioUnitEQBox(node: equalizer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sfbEqualizer = eqBox.node
                self.applySFBEQSettings()
            }

            let eqConnectedToMain = engine.outputConnectionPoints(for: equalizer, outputBus: 0)
                .contains(where: { $0.node === engine.mainMixerNode })

            if eqConnectedToMain {
                AppLog.info(.general, "🎛️ SFBAudioEngine EQ already present in graph")
                return
            }

            if let connection = engine.inputConnectionPoint(for: engine.mainMixerNode, inputBus: 0),
               let upstreamNode = connection.node,
               upstreamNode !== equalizer {
                let bus = connection.bus
                // Prefer the node's actual render format - the decoder format can
                // differ from what the player node outputs, and a mismatched
                // connect throws
                let nodeFormat = upstreamNode.outputFormat(forBus: bus)
                let connectFormat = nodeFormat.sampleRate > 0 ? nodeFormat : format
                engine.disconnectNodeInput(engine.mainMixerNode)

                // Try to connect - if it fails, mark EQ as failed
                do {
                    try ObjCExceptionCatcher.tryCatch({
                        engine.connect(equalizer, to: engine.mainMixerNode, format: connectFormat)
                        engine.connect(upstreamNode, to: equalizer, format: connectFormat)
                    })
                } catch {
                    AppLog.error(.general, "❌ EQ connection failed in attachEqualizerToEngine: \(error.localizedDescription)")
                    // CRITICAL: the mixer input was already disconnected above.
                    // Restore the original connection or ALL SFB playback
                    // (Opus/Vorbis/DSD) stays silent (issue #75).
                    try? ObjCExceptionCatcher.tryCatch({
                        engine.disconnectNodeOutput(equalizer)
                        engine.connect(upstreamNode, to: engine.mainMixerNode, format: nodeFormat.sampleRate > 0 ? nodeFormat : nil)
                    })
                    AppLog.info(.general, "🔗 Restored direct connection after EQ failure")
                    Task { @MainActor [weak self] in
                        self?.eqAttachmentFailed = true
                    }
                    return
                }

                AppLog.info(.general, "🔗 Inserted EQ between \(upstreamNode) and mainMixerNode")
                return
            }

            let fallbackNode = engine.attachedNodes.first(where: { node in
                if node === equalizer || node === engine.mainMixerNode || node === engine.outputNode { return false }
                let className = String(describing: type(of: node))
                return className.contains("SFBAudioPlayerNode") || node is AVAudioPlayerNode
            })

            if let sourceNode = fallbackNode {
                let nodeFormat = sourceNode.outputFormat(forBus: 0)
                let connectFormat = nodeFormat.sampleRate > 0 ? nodeFormat : format
                engine.disconnectNodeInput(engine.mainMixerNode)
                engine.disconnectNodeOutput(sourceNode)

                // Try to connect - if it fails, mark EQ as failed
                do {
                    try ObjCExceptionCatcher.tryCatch({
                        engine.connect(sourceNode, to: equalizer, format: connectFormat)
                        engine.connect(equalizer, to: engine.mainMixerNode, format: connectFormat)
                    })
                } catch {
                    AppLog.error(.general, "❌ EQ connection failed (fallback): \(error.localizedDescription)")
                    // CRITICAL: restore the direct connection or SFB playback
                    // stays silent (issue #75)
                    try? ObjCExceptionCatcher.tryCatch({
                        engine.disconnectNodeOutput(equalizer)
                        engine.connect(sourceNode, to: engine.mainMixerNode, format: nodeFormat.sampleRate > 0 ? nodeFormat : nil)
                    })
                    AppLog.info(.general, "🔗 Restored direct connection after EQ failure (fallback)")
                    Task { @MainActor [weak self] in
                        self?.eqAttachmentFailed = true
                    }
                    return
                }

                AppLog.info(.general, "🔗 Inserted EQ between \(sourceNode) and mainMixerNode (fallback)")
                return
            }

            AppLog.warn(.general, "⚠️ Unable to locate upstream node for SFBAudioEngine EQ insertion")

            if retryCount < maxRetries {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard let self else { return }
                    self.attachEqualizerToEngine(with: format, retryCount: retryCount + 1)
                }
            }
        }
    }

    /// 把 EQManager 的运行时数据（频率/增益/带宽）应用到 SFB 的 EQ 节点。
    /// 平台无关（iOS/macOS 共用一份，行为单一事实源——2026-09-01 从 iOS 分支提取）。
    private func configureSFBEQBands(_ equalizer: AVAudioUnitEQ) {
        // Apply frequency-specific gains from EQManager
        let eqFrequencies = eqManager.currentEQFrequencies
        let eqGains = eqManager.currentEQGains
        let eqBandwidths = eqManager.currentEQBandwidths

        if !eqFrequencies.isEmpty && !eqGains.isEmpty {
            // Use EQManager's exact frequencies and gains
            let availableBands = equalizer.bands.count
            let inputBandCount = min(eqFrequencies.count, eqGains.count)

            if inputBandCount <= availableBands {
                // Direct mapping - use exactly what we have
                for i in 0 ..< inputBandCount {
                    let band = equalizer.bands[i]
                    band.frequency = Float(eqFrequencies[i])
                    band.gain = Float(eqGains[i])
                    let bandwidth = i < eqBandwidths.count ? eqBandwidths[i] : 1.0
                    band.bandwidth = Float(max(0.05, min(5.0, bandwidth)))
                    band.filterType = .parametric
                    band.bypass = false
                }

                // Bypass remaining bands
                for i in inputBandCount ..< availableBands {
                    equalizer.bands[i].bypass = true
                }

                AppLog.info(.general, "🎛️ Direct mapping: Using all \(inputBandCount) EQ bands")
            } else {
                // More input bands than available - group and average
                AppLog.info(.general, "🔄 Reducing \(inputBandCount) bands to \(availableBands) bands")

                let bandsPerGroup = Double(inputBandCount) / Double(availableBands)

                for i in 0 ..< availableBands {
                    // Calculate the range of input bands for this output band
                    let startIndex = Int(Double(i) * bandsPerGroup)
                    let endIndex = min(Int(Double(i + 1) * bandsPerGroup), inputBandCount)

                    // Average the frequencies and gains for this group
                    var avgFrequency = 0.0
                    var avgGain = 0.0
                    var avgBandwidth = 0.0
                    var groupSize = 0

                    for j in startIndex ..< endIndex {
                        if j < eqFrequencies.count && j < eqGains.count {
                            avgFrequency += eqFrequencies[j]
                            avgGain += eqGains[j]
                            avgBandwidth += j < eqBandwidths.count ? eqBandwidths[j] : 1.0
                            groupSize += 1
                        }
                    }

                    if groupSize > 0 {
                        avgFrequency /= Double(groupSize)
                        avgGain /= Double(groupSize)
                        avgBandwidth /= Double(groupSize)
                    }

                    let band = equalizer.bands[i]
                    band.frequency = Float(avgFrequency)
                    band.gain = Float(avgGain)
                    band.bandwidth = Float(max(0.05, min(5.0, avgBandwidth)))
                    band.filterType = .parametric
                    band.bypass = false

                    if AppLog.isEnabled(.debug, .general) {
                        AppLog.debug(.general, "  Band \(i): \(Int(avgFrequency))Hz, \(String(format: "%.1f", avgGain))dB (avg of \(groupSize) bands)")
                    }
                }

                AppLog.info(.general, "✅ Applied frequency grouping and averaging")
            }
        } else {
            // No EQ data - configure with default geometric spacing
            let minFreq = 20.0
            let maxFreq = 20000.0
            let bandCount = equalizer.bands.count

            for i in 0 ..< bandCount {
                let band = equalizer.bands[i]
                let frequency = minFreq * pow(maxFreq / minFreq, Double(i) / Double(bandCount - 1))

                band.frequency = Float(frequency)
                band.gain = 0.0
                band.bandwidth = 1.0
                band.filterType = .parametric
                band.bypass = false
            }

            AppLog.info(.general, "🎛️ Configured \(bandCount) SFBAudioEngine EQ bands with default frequencies")
        }
    }

    /// 把 EQ 开关/全局增益/预设数据应用到已 attach 的 SFB EQ 节点。
    /// 平台无关（iOS/macOS 共用一份；EQManager 状态变化时被 updateEQSettings 调用）。
    func applySFBEQSettings() {
        guard let equalizer = sfbEqualizer else {
            AppLog.warn(.general, "⚠️ No SFBAudioEngine equalizer to update")
            return
        }

        // Apply enabled state
        equalizer.bypass = !eqManager.isEnabled

        // Apply global gain
        equalizer.globalGain = Float(eqManager.globalGain)

        // Reconfigure bands with current EQ settings
        configureSFBEQBands(equalizer)

        AppLog.info(.general, "🎛️ SFBAudioEngine EQ updated: enabled=\(eqManager.isEnabled), globalGain=\(eqManager.globalGain)dB")
    }

    // Store decoder properties for seeking when AudioFile properties are unavailable
    @ObservationIgnored var decoderFrameLength: Int64 = 0
    @ObservationIgnored var decoderSampleRate: Double = 0

    // EQ integration for SFBAudioEngine (native approach following wiki)
    @ObservationIgnored let eqManager = EQManager.shared
    @ObservationIgnored var sfbEqualizer: AVAudioUnitEQ?
    // Track last sample rate to avoid unnecessary changes
    @ObservationIgnored var lastConfiguredSampleRate: Double = 0

    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0

    // CarPlay environment detection
    #if os(iOS)
        var isCarPlayEnvironment = false
    #endif

    private override init() {
        super.init()
        #if os(iOS)
            isCarPlayEnvironment = Self.detectCarPlay()
            AppLog.info(.general, "🔄 SFBAudioEngine Manager initialized - CarPlay: \(isCarPlayEnvironment)")
        #endif
    }

    #if os(iOS)
        /// Detects if the app is running in a CarPlay environment
        private static func detectCarPlay() -> Bool {
            // Check if a CarPlay template scene is connected. The scene exists
            // before AVAudioSession necessarily exposes a `.carAudio` route.
            if #available(iOS 13.0, *) {
                for scene in UIApplication.shared.connectedScenes {
                    if scene is CPTemplateApplicationScene
                        || scene.session.role == .carTemplateApplication {
                        AppLog.info(.general, "🚗 CarPlay scene detected: \(scene)")
                        return true
                    }
                }
            }

            // Additional check: CarPlay audio routes
            let audioSession = AVAudioSession.sharedInstance()
            let currentRoute = audioSession.currentRoute
            AppLog.info(.general, "🎧 Current audio route: \(currentRoute.outputs.map { "\($0.portName) (\($0.portType))" }.joined(separator: ", "))")

            for output in currentRoute.outputs where output.portType == .carAudio {
                AppLog.info(.general, "🚗 CarPlay audio route detected: \(output.portName)")
                return true
            }

            return false
        }

        /// Re-check CarPlay status (call when audio route changes)
        func updateCarPlayStatus() {
            let wasCarPlay = isCarPlayEnvironment
            isCarPlayEnvironment = Self.detectCarPlay()

            if wasCarPlay != isCarPlayEnvironment {
                if isCarPlayEnvironment {
                    AppLog.info(.general, "🚗 Switched to CarPlay - stopping SFBAudioEngine")
                    stop()
                    audioPlayer = nil
                } else {
                    AppLog.info(.general, "📱 Switched from CarPlay - SFBAudioEngine available again")
                }
            }
        }
    #endif

    func setupAudioPlayer() {
        guard audioPlayer == nil else { return }

        #if os(iOS)
            // Don't initialize SFBAudioEngine in CarPlay environment
            if isCarPlayEnvironment {
                AppLog.info(.general, "🚗 Skipping SFBAudioEngine setup - running in CarPlay")
                return
            }
        #endif

        // Try to create AudioPlayer
        audioPlayer = AudioPlayer()

        // Verify player was created successfully
        guard audioPlayer != nil else {
            AppLog.warn(.general, "⚠️ SFBAudioEngine AudioPlayer creation returned nil")
            return
        }

        audioPlayer?.delegate = self
        AppLog.info(.general, "🔄 SFBAudioEngine AudioPlayer initialized successfully")
    }

    func resetAudioPlayer() {
        audioPlayer?.stop()
        cleanupEqualizer()
        audioPlayer = nil
        audioPlayer = AudioPlayer()
        audioPlayer?.delegate = self
        AppLog.info(.general, "🔄 SFBAudioEngine AudioPlayer reset")
    }

    nonisolated private func formatSupportsSFBEQ(_ format: AVAudioFormat?) -> Bool {
        guard let format else { return true }
        let streamDescription = format.streamDescription.pointee
        let isLinearPCM = streamDescription.mFormatID == kAudioFormatLinearPCM
        let isFloat = (streamDescription.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        return isLinearPCM && isFloat && streamDescription.mBitsPerChannel == 32
    }

    // MARK: - AudioPlayer.Delegate

    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, reconfigureProcessingGraph engine: AVAudioEngine, with format: AVAudioFormat) -> AVAudioNode {
        AppLog.info(.general, "🔄 SFBAudioEngine processing graph reconfiguration for format: \(format)")
        AppLog.info(.general, "🔍 Engine state - isRunning: \(engine.isRunning), attachedNodes: \(engine.attachedNodes.count)")

        // We can't access MainActor properties from nonisolated context
        // So we always skip EQ in this delegate method and rely on attachEqualizerToEngine instead
        // This prevents crashes and keeps the delegate method simple
        AppLog.info(.general, "ℹ️ Skipping EQ in delegate - EQ will be attached via attachEqualizerToEngine if enabled")
        return engine.mainMixerNode
    }

    // MARK: - Background/Foreground Optimization
    //
    // optimizeForBackground() / optimizeForForeground() 已删除（2026-09-12 审计死代码 ⚰️-6）：
    // 全仓 grep 仅命中定义处、零调用方（它们会改 IO buffer 并 bypass EQ，无法验证的旧方案）。
    // 需要时从 git 历史取回。
}
