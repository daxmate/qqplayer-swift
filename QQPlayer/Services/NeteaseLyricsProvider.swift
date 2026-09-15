//
//  NeteaseLyricsProvider.swift
//  QQPlayer
//
//  网易云音乐歌词源（eapi 官方接口，协议与桌面版 QQPlayer 后端一致）
//
//  链路位置: 内嵌元数据 → 网易云（原文+中文翻译） → lrclib 兜底
//
//  eapi 协议说明（公开逆向协议，Swift 独立实现）:
//  - 请求加密: AES-128-ECB（key = "e82ckenh8dichen8"）
//    报文 = "{uri}-36cd479b6b5-{json}-36cd479b6b5-{md5 digest}"
//    digest = md5("nobody{uri}use{json}md5forencrypt")
//    加密结果 hex 大写作为表单 params 提交
//  - 响应解密: content-type 为 json 直接解析；否则 AES 解密后解析
//    （密文可能是 hex 字符串或原始二进制）
//  - JSON 序列化必须保持 key 插入顺序（与桌面端 json.dumps 一致），
//    否则同一请求每次密文不同，无法与桌面端基准向量对齐
//

import CommonCrypto
import CryptoKit
import Foundation

// MARK: - 模型

/// 网易云搜索候选歌曲
struct NeteaseSong: Codable, Equatable, Sendable {
    let id: Int
    let title: String
    let artist: String
    let duration: Double
}

/// 网易云歌词响应（原文 + 中文翻译）
struct NeteaseLyricResult: Sendable {
    let lrc: String
    let tlyric: String?
    /// 罗马音 LRC（网易云 romalrc；仅部分曲目有，没有就是 nil）
    let romalrc: String?
}

// MARK: - 有序 JSON（eapi 报文序列化，与桌面端 json.dumps(separators=(",",":")) 字节级一致）

/// 保持插入顺序的 JSON 键值对（eapi 加密报文必须确定，不能依赖 Dictionary 随机顺序）
struct OrderedJSON {
    private(set) var items: [(key: String, value: Any)] = []

    init(@OrderedJSONBuilder _ builder: () -> [OrderedJSONEntry]) {
        items = builder().map { ($0.key, $0.value) }
    }

    /// 序列化为紧凑 JSON 字符串（无多余空格，非 ASCII 原样输出，与 Python json.dumps 对齐）
    func stringValue() -> String {
        serialize(items)
    }

    private func serialize(_ pairs: [(key: String, value: Any)]) -> String {
        let parts = pairs.map { key, value -> String in
            "\"\(escape(key))\":\(serializeValue(value))"
        }
        return "{\(parts.joined(separator: ","))}"
    }

    private func serializeValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            return "\"\(escape(string))\""
        case let number as Int:
            return String(number)
        case let number as Double:
            return String(number)
        case let bool as Bool:
            return bool ? "true" : "false"
        case let json as OrderedJSON:
            return json.stringValue()
        case let array as [OrderedJSON]:
            return "[\(array.map { $0.stringValue() }.joined(separator: ","))]"
        default:
            return "null"
        }
    }

    private func escape(_ string: String) -> String {
        var out = ""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"":
                out += "\\\""
            case "\\":
                out += "\\\\"
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            case "\u{08}":
                out += "\\b"
            case "\u{0C}":
                out += "\\f"
            default:
                if scalar.value < 0x20 {
                    // 与 Python json.dumps(ensure_ascii=False) 一致：0x20 以下除短转义外的
                    // 控制字符一律输出 \uXXXX（桌面端字节级对齐，防 eapi 报文分叉）
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    // 非 ASCII 原样输出（UTF-8）
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}

struct OrderedJSONEntry {
    let key: String
    let value: Any

    init(_ key: String, _ value: Any) {
        self.key = key
        self.value = value
    }
}

@resultBuilder
enum OrderedJSONBuilder {
    static func buildBlock(_ components: [OrderedJSONEntry]...) -> [OrderedJSONEntry] {
        components.flatMap { $0 }
    }

    static func buildArray(_ components: [[OrderedJSONEntry]]) -> [OrderedJSONEntry] {
        components.flatMap { $0 }
    }

    static func buildExpression(_ expression: OrderedJSONEntry) -> [OrderedJSONEntry] {
        [expression]
    }

    static func buildExpression(_ expression: [OrderedJSONEntry]) -> [OrderedJSONEntry] {
        expression
    }
}

// MARK: - eapi 加密/解密

enum NeteaseEAPI {
    static let key = "e82ckenh8dichen8"
    static let marker = "-36cd479b6b5-"

    /// eapi 请求加密：md5 摘要 + AES-128-ECB（PKCS7），返回大写 hex 作为 params 值
    static func encrypt(uri: String, payloadJSON: String) -> String {
        let digestText = "nobody\(uri)use\(payloadJSON)md5forencrypt"
        let digest = Insecure.MD5.hash(data: Data(digestText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let message = "\(uri)\(marker)\(payloadJSON)\(marker)\(digest)"
        let encrypted = aesECBEncrypt(Data(message.utf8), key: Data(key.utf8))
        return encrypted.map { String(format: "%02X", $0) }.joined()
    }

    /// 解密 eapi 响应：密文为 hex 字符串或原始二进制，解密后解析 JSON
    /// 兼容纯 JSON（content-type 含 json）与 "{uri}-36cd479b6b5-{json}-...-{digest}" 报文两种形态
    static func decrypt(_ content: Data, contentType: String = "") throws -> [String: Any] {
        let ct = contentType.lowercased()
        if ct.contains("json") {
            if let obj = try? JSONSerialization.jsonObject(with: content) as? [String: Any] {
                return obj
            }
        }

        let encrypted: Data
        let text = String(data: content, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty, text.count % 2 == 0, text.allSatisfy({ $0.isHexDigit }) {
            encrypted = Data(hexString: text) ?? content
        } else {
            encrypted = content
        }

        let decrypted = aesECBDecrypt(encrypted, key: Data(key.utf8))
        var decoded = String(data: decrypted, encoding: .utf8) ?? ""
        if decoded.contains(marker) {
            let parts = decoded.components(separatedBy: marker)
            if parts.count == 3, parts[0].hasPrefix("/api/") {
                decoded = parts[1]
            }
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(decoded.utf8)) as? [String: Any] else {
            throw NeteaseError.decryptFailed
        }
        return obj
    }

    // MARK: - AES-128-ECB（CommonCrypto）

    private static func aesECBEncrypt(_ data: Data, key: Data) -> Data {
        crypt(data: data, key: key, operation: CCOperation(kCCEncrypt))
    }

    private static func aesECBDecrypt(_ data: Data, key: Data) -> Data {
        crypt(data: data, key: key, operation: CCOperation(kCCDecrypt))
    }

    private static func crypt(data: Data, key: Data, operation: CCOperation) -> Data {
        let keyLength = kCCKeySizeAES128
        var outLength = 0
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)

        let status = key.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCCrypt(
                    operation,
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                    keyBytes.baseAddress, keyLength,
                    nil,
                    dataBytes.baseAddress, data.count,
                    &out, out.count,
                    &outLength
                )
            }
        }
        guard status == kCCSuccess else {
            return Data()
        }
        return Data(out.prefix(outLength))
    }
}

// MARK: - Provider

struct NeteaseLyricsProvider: Sendable {
    static let shared = NeteaseLyricsProvider()

    private let searchURL = URL(string: "https://interface.music.163.com/eapi/cloudsearch/pc")!
    private let lyricURL = URL(string: "https://interface3.music.163.com/eapi/song/lyric/v1")!
    private let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Safari/537.36 Chrome/91.0.4472.164 "
            + "NeteasyMusicDesktop/3.1.19.204510"
    private let session: URLSession
    private let deviceID: String

    init(session: URLSession = .shared) {
        self.session = session
        self.deviceID = NeteaseLyricsProvider.randomHex(length: 16)
    }

    /// 搜索歌曲，返回候选列表（按相关度排序）
    /// 搜索候选选择（桌面版逻辑：标题精确匹配 + 歌手包含；否则取第一个候选）
    /// 抽出供测试直调——测试不得内联重写此逻辑（2026-08-30 审计清尾）。
    static func selectBestCandidate(_ candidates: [NeteaseSong], title: String, artistName: String) -> NeteaseSong? {
        candidates.first(where: { candidate in
            candidate.title == title
                && (artistName.isEmpty || candidate.artist.contains(artistName))
        }) ?? candidates.first
    }

    func search(query: String, limit: Int = 8) async throws -> [NeteaseSong] {
        let payload = OrderedJSON {
            OrderedJSONEntry("header", requestHeader())
            OrderedJSONEntry("e_r", true)
            OrderedJSONEntry("s", query)
            OrderedJSONEntry("type", 1)
            OrderedJSONEntry("limit", max(1, min(50, limit)))
            OrderedJSONEntry("offset", 0)
            OrderedJSONEntry("total", true)
        }
        let body = try eapiBody(uri: "/api/cloudsearch/pc", payload: payload)
        let data = try await post(url: searchURL, body: body)
        let obj = try NeteaseEAPI.decrypt(data, contentType: "application/json")

        guard let result = obj["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            return []
        }
        return songs.compactMap { mapSong($0) }
    }

    /// 按歌曲 id 获取歌词，返回 (原文 LRC, 中文翻译 LRC)；无歌词返回 nil
    /// 新版逐字歌词（JSON-lines）自动转普通 LRC
    func getLyric(songID: Int) async throws -> NeteaseLyricResult? {
        let payload = OrderedJSON {
            OrderedJSONEntry("header", requestHeader())
            OrderedJSONEntry("e_r", true)
            OrderedJSONEntry("id", songID)
            OrderedJSONEntry("cp", false)
            OrderedJSONEntry("tv", 0)
            OrderedJSONEntry("lv", 0)
            OrderedJSONEntry("rv", 0)
            OrderedJSONEntry("kv", 0)
            OrderedJSONEntry("yv", 0)
            OrderedJSONEntry("ytv", 0)
            OrderedJSONEntry("yrv", 0)
        }
        let body = try eapiBody(uri: "/api/song/lyric/v1", payload: payload)
        let data = try await post(url: lyricURL, body: body)
        let obj = try NeteaseEAPI.decrypt(data, contentType: "application/json")

        guard let lrcDict = obj["lrc"] as? [String: Any],
              let lrcRaw = lrcDict["lyric"] as? String,
              !lrcRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let lrc = wordJSONToLRC(lrcRaw)
        // 附轨（中文翻译 tlyric / 罗马音 romalrc）解析：{"lyric": ...} → LRC；空白串按 nil。
        // 唯一实现：两条附轨共用同一份解析，别再各写一份。
        func parseAttachedTrack(_ key: String) -> String? {
            guard let dict = obj[key] as? [String: Any],
                  let raw = dict["lyric"] as? String else { return nil }
            let converted = wordJSONToLRC(raw)
            return converted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : converted
        }
        return NeteaseLyricResult(
            lrc: lrc,
            tlyric: parseAttachedTrack("tlyric"),
            romalrc: parseAttachedTrack("romalrc")
        )
    }

    // MARK: - 内部

    private func requestHeaderItems() -> [(key: String, value: String)] {
        [
            ("os", "pc"),
            ("appver", "3.1.19.204510"),
            ("requestId", "0"),
            ("osver", "Microsoft-Windows-11-Home-China-build-22631-64bit"),
            ("deviceId", deviceID),
            ("MUSIC_U", ""),
        ]
    }

    private func requestHeader() -> OrderedJSON {
        OrderedJSON {
            for (key, value) in requestHeaderItems() {
                OrderedJSONEntry(key, value)
            }
        }
    }

    private func cookieHeader() -> String {
        requestHeaderItems().map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    private func eapiBody(uri: String, payload: OrderedJSON) throws -> Data {
        let jsonString = payload.stringValue()
        let params = NeteaseEAPI.encrypt(uri: uri, payloadJSON: jsonString)
        return Data("params=\(params)".utf8)
    }

    private func post(url: URL, body: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(cookieHeader(), forHTTPHeaderField: "Cookie")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NeteaseError.httpError
        }
        return data
    }

    private func mapSong(_ song: [String: Any]) -> NeteaseSong? {
        guard let id = song["id"] as? Int else { return nil }
        let title = song["name"] as? String ?? "未知歌曲"
        let artist = joinArtists(song["ar"] as? [[String: Any]])
        let duration = (song["dt"] as? Double ?? 0) / 1000.0
        return NeteaseSong(id: id, title: title, artist: artist, duration: duration)
    }

    private func joinArtists(_ artists: [[String: Any]]?) -> String {
        guard let artists else { return "" }
        return artists.compactMap { $0["name"] as? String }.joined(separator: ", ")
    }

    private static func randomHex(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 逐字歌词转换

/// 新版逐字歌词（JSON-lines：每行 {"t": 毫秒, "c": [{"tx": 文本}]}）→ 普通 LRC
/// 逐行转换：JSON 对象行按 t/c 拼成 [mm:ss.xx]文本；非 JSON 行原样保留
func wordJSONToLRC(_ text: String) -> String {
    guard !text.isEmpty else { return text }
    var out: [String] = []
    for rawLine in text.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty {
            out.append("")
            continue
        }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chars = obj["c"] as? [[String: Any]] else {
            out.append(line)
            continue
        }
        let lyricText = chars.compactMap { $0["tx"] as? String }.joined()
        let t = (obj["t"] as? Int) ?? 0
        let sec = t / 1000
        let ms = t % 1000
        out.append(String(format: "[%02d:%02d.%02d]%@", sec / 60, sec % 60, ms / 10, lyricText))
    }
    return out.joined(separator: "\n")
}

// MARK: - 错误

enum NeteaseError: Error {
    case httpError
    case decryptFailed
}

// MARK: - 工具扩展

private extension Data {
    init?(hexString: String) {
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard next <= hexString.endIndex,
                  let byte = UInt8(hexString[index ..< next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}
