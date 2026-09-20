//
//  LyricsParsing.swift
//  QQPlayer
//
//  歌词解析：LRC 时间戳解析、内嵌歌词二进制提取（ID3v2/Vorbis/FLAC）、编码解码。
//

import AVFoundation
import Foundation

extension LyricsManager {
    nonisolated func extractAVFoundationLyrics(from url: URL) async -> String? {
        let asset = AVURLAsset(url: url)

        do {
            let commonMetadata = try await asset.load(.commonMetadata)
            let allMetadata = try await asset.load(.metadata)
            let metadataGroups = [commonMetadata, allMetadata]

            for metadata in metadataGroups.flatMap({ $0 }) {
                let commonKey = metadata.commonKey?.rawValue.lowercased()
                let identifier = metadata.identifier?.rawValue.lowercased()
                let keySpace = metadata.keySpace?.rawValue.lowercased()
                let rawKey = (metadata.key as? String)?.lowercased()

                let looksLikeLyrics =
                    commonKey == "description" ||
                    commonKey == "lyrics" ||
                    rawKey?.contains("lyrics") == true ||
                    rawKey?.contains("\u{00A9}lyr") == true ||
                    identifier?.contains("lyrics") == true ||
                    identifier?.contains("uslt") == true ||
                    identifier?.contains("\u{00A9}lyr") == true ||
                    keySpace?.contains("lyrics") == true

                guard looksLikeLyrics,
                      let lyricsText = try? await metadata.load(.stringValue),
                      isUsableLyricsText(lyricsText) else {
                    continue
                }

                return lyricsText
            }
        } catch {
            AppLog.warn(.general, "⚠️ Failed to read AVFoundation lyrics metadata for \(url.lastPathComponent): \(error)")
        }

        return nil
    }

    nonisolated func extractFlacLyrics(from url: URL) async -> String? {
        guard let data = await readFileData(url) else { return nil }
        guard data.count >= 4,
              data[0] == 0x66, data[1] == 0x4C, data[2] == 0x61, data[3] == 0x43 else {
            return nil
        }

        var offset = 4

        while offset + 4 <= data.count {
            let blockHeader = data[offset]
            let isLast = (blockHeader & 0x80) != 0
            let blockType = blockHeader & 0x7F
            let blockSize = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            offset += 4

            guard blockSize >= 0, offset + blockSize <= data.count else {
                return nil
            }

            if blockType == 4 {
                let commentData = data.subdata(in: offset ..< offset + blockSize)
                let comments = parseVorbisComments(commentData)
                if let lyrics = chooseVorbisLyrics(from: comments) {
                    return lyrics
                }
            }

            offset += blockSize
            if isLast { break }
        }

        return nil
    }

    nonisolated func extractScannedVorbisLyrics(from url: URL) async -> String? {
        guard let data = await readFileData(url) else { return nil }
        return scanTextTags(
            in: data,
            keys: ["SYNCEDLYRICS", "SYNCLYRICS", "LYRICS", "UNSYNCEDLYRICS"]
        )
    }

    nonisolated func extractID3Lyrics(from url: URL) async -> String? {
        guard let data = await readFileData(url), data.count >= 10 else { return nil }
        return parseID3Lyrics(from: data, offset: 0)
    }

    nonisolated func extractScannedID3Lyrics(from url: URL) async -> String? {
        guard let data = await readFileData(url),
              let id3Range = data.range(of: Data([0x49, 0x44, 0x33])) else {
            return nil
        }

        return parseID3Lyrics(from: data, offset: id3Range.lowerBound)
    }

    nonisolated func extractDSFLyrics(from url: URL) async -> String? {
        guard let data = await readFileData(url),
              data.count >= 28,
              data[0] == 0x44, data[1] == 0x53, data[2] == 0x44, data[3] == 0x20 else {
            return nil
        }

        let metadataPointer = readLittleEndianUInt64(from: data, offset: 20)
        guard metadataPointer > 0, metadataPointer < UInt64(data.count) else {
            return nil
        }

        return parseID3Lyrics(from: data, offset: Int(metadataPointer))
    }

    private nonisolated func readFileData(_ url: URL) async -> Data? {
        var coordinatorError: NSError?
        var readData: Data?
        var readError: Error?
        let coordinator = NSFileCoordinator()

        coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinatorError) { readingURL in
            do {
                readData = try Data(contentsOf: readingURL, options: .mappedIfSafe)
            } catch {
                readError = error
            }
        }

        if let error = coordinatorError {
            AppLog.warn(.general, "⚠️ Failed to coordinate lyrics metadata read from \(url.lastPathComponent): \(error)")
        } else if let error = readError {
            AppLog.warn(.general, "⚠️ Failed to read lyrics metadata from \(url.lastPathComponent): \(error)")
        }

        return readData
    }

    private nonisolated func parseVorbisComments(_ data: Data) -> [String: [String]] {
        var comments: [String: [String]] = [:]
        var offset = 0

        guard offset + 4 <= data.count else { return comments }

        let vendorLength = readLittleEndianUInt32(from: data, offset: offset)
        offset += 4 + Int(vendorLength)

        guard offset + 4 <= data.count else { return comments }

        let commentCount = Int(readLittleEndianUInt32(from: data, offset: offset))
        offset += 4

        for _ in 0 ..< commentCount {
            guard offset + 4 <= data.count else { break }

            let commentLength = Int(readLittleEndianUInt32(from: data, offset: offset))
            offset += 4

            guard commentLength >= 0, offset + commentLength <= data.count else { break }

            if let commentString = String(data: data.subdata(in: offset ..< offset + commentLength), encoding: .utf8) {
                let parts = commentString.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if parts.count == 2 {
                    let key = String(parts[0]).uppercased()
                    let value = String(parts[1])
                    comments[key, default: []].append(value)
                }
            }

            offset += commentLength
        }

        return comments
    }

    private nonisolated func chooseVorbisLyrics(from comments: [String: [String]]) -> String? {
        for key in ["SYNCEDLYRICS", "SYNCLYRICS", "LYRICS", "UNSYNCEDLYRICS"] {
            if let value = comments[key]?.first(where: isUsableLyricsText) {
                return value
            }
        }

        return nil
    }

    private nonisolated func scanTextTags(in data: Data, keys: [String]) -> String? {
        // 只转换文件头 scanTextHeaderBytes：Vorbis 注释/ID3v2 都在文件头部，
        // 整文件转 String 会让大文件内存翻倍（mapped Data 是懒页，堆上 String 是全量副本）
        let header = data.prefix(Self.scanTextHeaderBytes)
        guard let text = String(data: header, encoding: .utf8) ?? String(data: header, encoding: .isoLatin1) else {
            return nil
        }

        for key in keys {
            guard let keyRange = text.range(of: "\(key)=", options: [.caseInsensitive]) else {
                continue
            }

            let valueStart = keyRange.upperBound
            let remaining = String(text[valueStart...])
            let nextTagRange = remaining.range(
                of: #"(?i)(SYNCEDLYRICS|SYNCLYRICS|UNSYNCEDLYRICS|LYRICS|TITLE|ARTIST|ALBUM|TRACKNUMBER|DATE)="#,
                options: .regularExpression
            )
            let rawValue = nextTagRange.map { String(remaining[..<$0.lowerBound]) } ?? remaining
            let cleanedValue = rawValue.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))

            if isUsableLyricsText(cleanedValue) {
                return cleanedValue
            }
        }

        return nil
    }

    private nonisolated func parseID3Lyrics(from data: Data, offset: Int) -> String? {
        guard offset >= 0,
              offset + 10 <= data.count,
              data[offset] == 0x49, data[offset + 1] == 0x44, data[offset + 2] == 0x33 else {
            return nil
        }

        let majorVersion = data[offset + 3]
        guard majorVersion == 3 || majorVersion == 4 else {
            return nil
        }

        let tagSize = readSynchsafeUInt32(from: data, offset: offset + 6)
        var frameOffset = offset + 10
        let endOffset = min(data.count, offset + 10 + Int(tagSize))

        while frameOffset + 10 <= endOffset {
            let frameId = String(data: data.subdata(in: frameOffset ..< frameOffset + 4), encoding: .ascii) ?? ""
            if frameId.trimmingCharacters(in: .controlCharacters).isEmpty {
                break
            }

            let frameSize: UInt32
            if majorVersion == 4 {
                frameSize = readSynchsafeUInt32(from: data, offset: frameOffset + 4)
            } else {
                frameSize = readBigEndianUInt32(from: data, offset: frameOffset + 4)
            }

            frameOffset += 10

            guard frameSize > 0, frameOffset + Int(frameSize) <= endOffset else {
                break
            }

            let frameData = data.subdata(in: frameOffset ..< frameOffset + Int(frameSize))

            if frameId == "USLT", let lyrics = parseUnsyncedLyricsFrame(frameData), isUsableLyricsText(lyrics) {
                return lyrics
            }

            if frameId == "SYLT", let lyrics = parseSimpleSyncedLyricsFrame(frameData), isUsableLyricsText(lyrics) {
                return lyrics
            }

            frameOffset += Int(frameSize)
        }

        return nil
    }

    private nonisolated func parseUnsyncedLyricsFrame(_ data: Data) -> String? {
        guard data.count > 4 else { return nil }

        let encoding = data[0]
        let payloadStart = 4

        guard let descriptorEnd = findStringTerminator(in: data, from: payloadStart, encoding: encoding) else {
            return nil
        }

        let lyricsStart = descriptorEnd + terminatorLength(for: encoding)
        guard lyricsStart < data.count else { return nil }

        return decodeText(data.subdata(in: lyricsStart ..< data.count), encoding: encoding)
    }

    private nonisolated func parseSimpleSyncedLyricsFrame(_ data: Data) -> String? {
        guard data.count > 6 else { return nil }

        let encoding = data[0]
        let timestampFormat = data[4]
        guard timestampFormat == 2 else { return nil }

        var offset = 6

        guard let descriptorEnd = findStringTerminator(in: data, from: offset, encoding: encoding) else {
            return nil
        }

        offset = descriptorEnd + terminatorLength(for: encoding)
        var lrcLines: [String] = []

        while offset < data.count {
            guard let textEnd = findStringTerminator(in: data, from: offset, encoding: encoding) else {
                break
            }

            let textData = data.subdata(in: offset ..< textEnd)
            offset = textEnd + terminatorLength(for: encoding)

            guard offset + 4 <= data.count else { break }

            let timestampMs = readBigEndianUInt32(from: data, offset: offset)
            offset += 4

            guard let text = decodeText(textData, encoding: encoding), !text.isEmpty else {
                continue
            }

            let timestamp = Double(timestampMs) / 1000.0
            let minutes = Int(timestamp / 60)
            let seconds = Int(timestamp.truncatingRemainder(dividingBy: 60))
            let centiseconds = Int((timestamp - floor(timestamp)) * 100)
            lrcLines.append(String(format: "[%02d:%02d.%02d]%@", minutes, seconds, centiseconds, text))
        }

        return lrcLines.isEmpty ? nil : lrcLines.joined(separator: "\n")
    }

    private nonisolated func findStringTerminator(in data: Data, from start: Int, encoding: UInt8) -> Int? {
        guard start < data.count else { return nil }

        if terminatorLength(for: encoding) == 2 {
            var index = start
            while index + 1 < data.count {
                if data[index] == 0, data[index + 1] == 0 {
                    return index
                }
                index += 2
            }
        } else {
            var index = start
            while index < data.count {
                if data[index] == 0 {
                    return index
                }
                index += 1
            }
        }

        return nil
    }

    private nonisolated func terminatorLength(for encoding: UInt8) -> Int {
        encoding == 1 || encoding == 2 ? 2 : 1
    }

    private nonisolated func decodeText(_ data: Data, encoding: UInt8) -> String? {
        let decoded: String?

        switch encoding {
        case 0:
            decoded = String(data: data, encoding: .isoLatin1)
        case 1:
            decoded = String(data: data, encoding: .utf16)
        case 2:
            decoded = String(data: data, encoding: .utf16BigEndian)
        case 3:
            decoded = String(data: data, encoding: .utf8)
        default:
            decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        }

        return decoded?.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
    }

    private nonisolated func isUsableLyricsText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        guard !trimmed.isEmpty else { return false }

        // Avoid treating generic metadata descriptions as lyrics.
        return trimmed.contains("\n") || trimmed.contains("[") || trimmed.count > 40
    }

    private nonisolated func readLittleEndianUInt64(from data: Data, offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }

        return UInt64(data[offset]) |
            UInt64(data[offset + 1]) << 8 |
            UInt64(data[offset + 2]) << 16 |
            UInt64(data[offset + 3]) << 24 |
            UInt64(data[offset + 4]) << 32 |
            UInt64(data[offset + 5]) << 40 |
            UInt64(data[offset + 6]) << 48 |
            UInt64(data[offset + 7]) << 56
    }

    private nonisolated func readLittleEndianUInt32(from data: Data, offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }

        return UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }

    private nonisolated func readBigEndianUInt32(from data: Data, offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }

        return UInt32(data[offset]) << 24 |
            UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 |
            UInt32(data[offset + 3])
    }

    private nonisolated func readSynchsafeUInt32(from data: Data, offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }

        return UInt32(data[offset]) << 21 |
            UInt32(data[offset + 1]) << 14 |
            UInt32(data[offset + 2]) << 7 |
            UInt32(data[offset + 3])
    }

    func parseLyrics(_ text: String, source: Lyrics.LyricsSource) -> Lyrics {
        // Check if lyrics are synced (contain timestamps like [00:12.34] or [00:12.345])
        let timestampPattern = #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#
        let hasSyncedLyrics = text.range(of: timestampPattern, options: .regularExpression) != nil

        if hasSyncedLyrics {
            let syncedLines = parseSyncedLyrics(text)
            let plainText = syncedLines.map { $0.text }.joined(separator: "\n")
            return Lyrics(plainLyrics: plainText, syncedLyrics: syncedLines, isInstrumental: false, source: source)
        } else {
            return Lyrics(plainLyrics: text, syncedLyrics: [], isInstrumental: false, source: source)
        }
    }

    func parseSyncedLyrics(_ lrcText: String) -> [LyricsLine] {
        var lines: [LyricsLine] = []
        // 只匹配时间戳（不含文本）：同一行可多个时间戳（[00:12.00][00:15.00]text，副歌重复标记常见），
        // 若在同一个正则里用 (.*) 抓文本，后续 [00:15.00] 会被吞进文本且第二个时间戳丢失
        let timestampPattern = #"\[(\d{1,3}):(\d{2})(?:\.(\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: timestampPattern) else {
            return lines
        }

        for line in lrcText.components(separatedBy: .newlines) {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            // Match common [mm:ss], [mm:ss.xx], and [mm:ss.xxx] timestamp formats.
            let matches = regex.matches(in: line, range: range)
            guard !matches.isEmpty else { continue }

            // 文本 = 行内容去掉全部时间戳标记后剩余部分（多时间戳行共享同一文本）
            // 直接构造可变字符串（原为 `nsLine.mutableCopy() as! NSMutableString`）：
            // 语义相同（只用于按 range 删除时间戳），但**没有 cast**、也没有强制解包。
            let textOnly = NSMutableString(string: line)
            for match in matches.reversed() {
                textOnly.deleteCharacters(in: match.range)
            }
            let text = textOnly.trimmingCharacters(in: .whitespacesAndNewlines)

            // 每个时间戳生成一条 LyricsLine（时间戳 = 分钟*60 + 秒 + 小数）
            for match in matches {
                let minutes = Double(nsLine.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(nsLine.substring(with: match.range(at: 2))) ?? 0
                let fractionRange = match.range(at: 3)
                let fractionText = fractionRange.location == NSNotFound ? "0" : nsLine.substring(with: fractionRange)
                let fractionDivisor = pow(10.0, Double(fractionText.count))
                let fraction = (Double(fractionText) ?? 0) / fractionDivisor

                let timestamp = (minutes * 60) + seconds + fraction
                lines.append(LyricsLine(timestamp: timestamp, text: text))
            }
        }

        return lines.sorted { ($0.timestamp ?? 0) < ($1.timestamp ?? 0) }
    }
}
