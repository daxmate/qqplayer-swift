//
//  LyricAlignmentService.swift
//  QQPlayer
//
//  对齐编排：取歌词行 → 认语言 → ASR 转写 → 单调对齐 → 写 aligned 歌词库。
//  依赖全部注入（引擎工厂 + 写库协议），单测不需要真机/真模型。
//

import Foundation

/// aligned 歌词落库的最小协议（测试注入临时目录 store）。
protocol AlignedLyricsWriting: Sendable {
    func write(_ lyrics: Lyrics, forStableId stableId: String) throws
}

extension AlignedLyricsStore: AlignedLyricsWriting {}

/// 歌词时间轴自动对齐服务。
///
/// 落库位置 = AlignedLyricsStore（Documents/lyrics-aligned/{stableId}.json），
/// 文本/翻译/罗马音原样保留，只替换每行 timestamp。
actor LyricAlignmentService {
    /// 引擎工厂：按识别语言创建引擎（真机 = AppleSpeechLyricsEngine；测试 = 假引擎）。
    typealias EngineFactory = @Sendable (Locale) throws -> any LyricsSpeechEngine

    static let shared = LyricAlignmentService()

    private let engineFactory: EngineFactory
    private let store: any AlignedLyricsWriting

    /// 注入引擎工厂（测试用假引擎）。
    init(
        engineFactory: @escaping EngineFactory,
        store: any AlignedLyricsWriting = AlignedLyricsStore.shared
    ) {
        self.engineFactory = engineFactory
        self.store = store
    }

    /// 生产实例：用系统引擎（iOS 26 / macOS 26 以下在调用时抛 unsupportedSystem）。
    ///
    /// 工厂写成显式闭包而不是直接传 makeDefaultEngine 函数值：
    /// 直接传会让编译器报「non-Sendable function value → @Sendable」（零警告纪律）。
    init(store: any AlignedLyricsWriting = AlignedLyricsStore.shared) {
        self.engineFactory = { locale in
            try LyricAlignmentService.makeDefaultEngine(for: locale)
        }
        self.store = store
    }

    /// 生产引擎工厂：iOS 26 / macOS 26 以下直接不支持。
    static func makeDefaultEngine(for locale: Locale) throws -> any LyricsSpeechEngine {
        _ = locale
        if #available(iOS 26.0, macOS 26.0, *) {
            return AppleSpeechLyricsEngine()
        }
        throw LyricAlignmentError.unsupportedSystem
    }

    // MARK: - 入口

    @discardableResult
    func align(
        track: Track,
        currentLyrics: Lyrics,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> LyricAlignmentReport {
        do {
            return try await run(track: track, currentLyrics: currentLyrics, progress: progress)
        } catch is CancellationError {
            throw LyricAlignmentError.cancelled
        }
    }

    private func run(
        track: Track,
        currentLyrics: Lyrics,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> LyricAlignmentReport {
        let lines = Self.alignmentLines(from: currentLyrics)
        guard !lines.isEmpty else { throw LyricAlignmentError.lyricsEmpty }

        let lyricsText = lines.map(\.text).joined(separator: "\n")
        let languageCode = LyricAlignmentLanguageDetector.detectLanguageCode(in: lyricsText)
        let locale = Locale(identifier: languageCode)

        guard !track.path.isEmpty, FileManager.default.fileExists(atPath: track.path) else {
            throw LyricAlignmentError.audioUnreadable
        }

        progress(0.02)
        let engine = try engineFactory(locale)
        let tokens: [AsrToken]
        do {
            tokens = try await engine.transcribe(
                fileURL: URL(fileURLWithPath: track.path),
                locale: locale
            ) { value in
                progress(0.05 + value * 0.75)
            }
        } catch is CancellationError {
            throw LyricAlignmentError.cancelled
        }

        try Task.checkCancellation()
        progress(0.85)

        let outcome = try LyricAlignmentAligner.align(
            lines: lines,
            tokens: tokens,
            duration: Double(track.durationMs ?? 0) / 1000,
            simplifyChinese: languageCode == "zh"
        )
        progress(0.95)

        let alignedLyrics = Self.applying(outcome.lines, to: currentLyrics)
        try store.write(alignedLyrics, forStableId: track.stableId)
        progress(1)

        return LyricAlignmentReport(
            lineCount: lines.count,
            matchedCount: outcome.matchedCount,
            matchedCharacters: outcome.matchedCharacters,
            characterCount: outcome.characterCount,
            medianOffset: outcome.medianOffset,
            localeIdentifier: locale.identifier,
            warnings: outcome.warnings
        )
    }

    // MARK: - 歌词行

    /// 对齐输入：有 synced 歌词就保留原时间当先验；只有 plain 就按行切、先验为 nil。
    static func alignmentLines(from lyrics: Lyrics) -> [LyricAlignmentAligner.LineInput] {
        if !lyrics.syncedLyrics.isEmpty {
            return lyrics.syncedLyrics.map {
                LyricAlignmentAligner.LineInput(text: $0.text, priorStart: $0.timestamp)
            }
        }
        return plainLines(from: lyrics).map {
            LyricAlignmentAligner.LineInput(text: $0, priorStart: nil)
        }
    }

    /// plain 歌词切行：去首尾空行（中间空行保留，作为分隔行）。
    static func plainLines(from lyrics: Lyrics) -> [String] {
        var lines = lyrics.plainLyrics
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// 把对齐时间写回 Lyrics：文本/翻译/罗马音原样保留，只换 timestamp。
    static func applying(_ aligned: [AlignedLyricLine], to lyrics: Lyrics) -> Lyrics {
        let timestamps = aligned
            .sorted { $0.index < $1.index }
            .map(\.start)

        if !lyrics.syncedLyrics.isEmpty {
            let updated = lyrics.syncedLyrics.enumerated().map { index, line in
                LyricsLine(
                    timestamp: index < timestamps.count ? timestamps[index] : line.timestamp,
                    text: line.text,
                    translation: line.translation,
                    roman: line.roman
                )
            }
            return Lyrics(
                plainLyrics: lyrics.plainLyrics,
                syncedLyrics: updated,
                isInstrumental: lyrics.isInstrumental,
                source: lyrics.source
            )
        }

        let plain = plainLines(from: lyrics)
        let rebuilt = plain.enumerated().map { index, text in
            LyricsLine(
                timestamp: index < timestamps.count ? timestamps[index] : nil,
                text: text,
                translation: nil,
                roman: nil
            )
        }
        return Lyrics(
            plainLyrics: lyrics.plainLyrics,
            syncedLyrics: rebuilt,
            isInstrumental: lyrics.isInstrumental,
            source: lyrics.source
        )
    }
}

// MARK: - 语言判定

/// 按歌词文本的书写系统判定识别语言（纯函数，可单测）。
enum LyricAlignmentLanguageDetector {
    /// 返回 ISO 639-1 语言码；判断不出来时用系统语言。
    static func detectLanguageCode(
        in text: String,
        systemLanguageCode: String? = nil
    ) -> String {
        var kana = 0
        var hangul = 0
        var han = 0
        var latin = 0

        for scalar in text.lowercased().unicodeScalars {
            switch scalar.value {
            case 0x3040 ... 0x309F, 0x30A0 ... 0x30FF, 0x31F0 ... 0x31FF:
                kana += 1
            case 0x1100 ... 0x11FF, 0x3130 ... 0x318F, 0xAC00 ... 0xD7AF:
                hangul += 1
            case 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xF900 ... 0xFAFF:
                han += 1
            case 0x0041 ... 0x005A, 0x0061 ... 0x007A, 0x00C0 ... 0x024F:
                latin += 1
            default:
                break
            }
        }

        if kana > 0 { return "ja" }
        if hangul > 0 { return "ko" }
        if han > 0, han >= latin { return "zh" }
        if latin > 0 { return "en" }
        return systemLanguageCode
            ?? Locale.current.language.languageCode?.identifier
            ?? "en"
    }
}
