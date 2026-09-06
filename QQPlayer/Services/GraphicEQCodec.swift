//
//  GraphicEQCodec.swift
//  QQPlayer
//
//  GraphicEQ 文本格式编解码（EQ 预设导入/导出的纯逻辑，可单测）。
//
//  格式："GraphicEQ: <freq> <gain>; <freq> <gain>; ..."（频率整数、增益浮点；
//  与 EqualizerAPO / 桌面 web 版 GraphicEQ 语义对齐）。
//
//  2026-09-07 从 EQManager.parseGraphicEQString 上收为纯逻辑（决策上收、执行下沉）：
//  EQManager.exportPreset / importGraphicEQPreset 经此编解码，行为零变化。
//

import Foundation

enum GraphicEQCodec {
    struct GraphicEQContent: Equatable, Sendable {
        let frequencies: [Double]
        let gains: [Double]
    }

    /// 频率/增益数组 → "GraphicEQ: ..." 文本（频率转整数显示，增益原样）
    static func encode(frequencies: [Double], gains: [Double]) -> String {
        precondition(frequencies.count == gains.count, "frequencies 与 gains 数量必须一致")
        let pairs = zip(frequencies, gains).map { "\(Int($0)) \($1)" }
        return "GraphicEQ: " + pairs.joined(separator: "; ")
    }

    /// 解析 GraphicEQ 文本 → 频率/增益数组。
    /// - 无 "GraphicEQ:" 行或解析后无任何有效对 → 抛 EQError.invalidGraphicEQFormat
    /// - 非法行（无法解析为两个数字）跳过，合法对保留（原实现语义）
    static func decode(_ content: String) throws -> GraphicEQContent {
        let lines = content.components(separatedBy: .newlines)
        guard let graphicEQLine = lines.first(where: { $0.contains("GraphicEQ:") }) else {
            throw EQError.invalidGraphicEQFormat
        }
        guard let colonIndex = graphicEQLine.firstIndex(of: ":") else {
            throw EQError.invalidGraphicEQFormat
        }

        let dataString = String(graphicEQLine[graphicEQLine.index(after: colonIndex)...])
            .trimmingCharacters(in: .whitespaces)
        let pairs = dataString.components(separatedBy: ";")

        var frequencies: [Double] = []
        var gains: [Double] = []

        for pair in pairs {
            let trimmedPair = pair.trimmingCharacters(in: .whitespaces)
            let components = trimmedPair.components(separatedBy: .whitespaces)
            guard components.count >= 2,
                  let frequency = Double(components[0]),
                  let gain = Double(components[1]) else {
                continue
            }
            frequencies.append(frequency)
            gains.append(gain)
        }

        guard !frequencies.isEmpty else {
            throw EQError.invalidGraphicEQFormat
        }
        return GraphicEQContent(frequencies: frequencies, gains: gains)
    }
}
