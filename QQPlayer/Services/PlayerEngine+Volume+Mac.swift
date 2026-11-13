//
//  PlayerEngine+Volume+Mac.swift
//  QQPlayer
//
//  macOS App 级音量：把 PlayerVolumeModel 的语义落到 AVAudioEngine.mainMixerNode。
//  口径（任务包 §3-B）：
//  - 音量数学 / 静音语义只在 PlayerVolumeModel，持久化只在 PlayerVolumePersistence；
//    本文件只做「模型 → audioEngine」的应用与对外单一入口。
//  - 与系统输出音量完全独立：不碰 NSSound.systemVolume、不引入 MPVolumeView。
//  - 引擎重建 / 首启后由 ensureMacAudioEngineSetup 调 reapplyStoredVolume() 重新应用
//    （唯一挂点，不在每个 play() 里重复设）。
//
#if os(macOS)
    import AVFoundation
    import Foundation

    extension PlayerEngine {
        // MARK: - 对外入口（播放条 / 快捷键 / 菜单共用）

        /// 当前 App 音量（0…1）。
        var volume: Double { volumeModel.volume }

        /// 是否静音。
        var isMuted: Bool { volumeModel.isMuted }

        /// 设置绝对音量（滑块）。
        func setVolume(_ value: Double) {
            commitVolume { $0.setVolume(value) }
        }

        /// 步进（音量键 / 菜单；正负均可）。
        func adjustVolume(by delta: Double) {
            commitVolume { $0.adjust(by: delta) }
        }

        /// 静音 ⇄ 恢复。
        func toggleMute() {
            commitVolume { $0.toggleMute() }
        }

        /// 引擎（重）建后的唯一重新应用挂点：把已存音量写回混音器。
        /// 不写 UserDefaults（值未变），不参与数学——纯回放。
        func reapplyStoredVolume() {
            audioEngine.mainMixerNode.outputVolume = Float(volumeModel.volume)
        }

        // MARK: - 内部

        /// 变更 → 应用 → 持久化（三者同源；模型相等说明被夹住到边/非法输入，直接跳过）。
        private func commitVolume(_ mutate: (inout PlayerVolumeModel) -> Void) {
            var model = volumeModel
            mutate(&model)
            guard model != volumeModel else { return }
            storeVolumeModel(model)
            audioEngine.mainMixerNode.outputVolume = Float(model.volume)
            PlayerVolumePersistence.save(model)
        }
    }
#endif
