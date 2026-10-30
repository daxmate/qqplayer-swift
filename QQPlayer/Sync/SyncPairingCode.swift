//
//  SyncPairingCode.swift
//  QQPlayer
//
//  局域网同步 · 批 1（2026-10-30）**6 位配对码（A 方案）纯逻辑**。
//
//  语义（docs/lan-sync-pairing-code.md）：
//  - 码空间 = 000000–999999（6 位十进制，前导零保留），由系统 CSPRNG 生成。
//  - 一次性：同一时刻只有一张有效码；生成新码即作废旧码（含未使用的旧码）。
//  - TTL = 120s：从生成时刻起算；过期后既不能验码，也不再占用「一次性」名额
//    （客户端拿过期码 → failure = .expired，与「从未生成」(.noActiveCode) 区分）。
//  - 单次使用：校验成功后立即标记 used（同码再提交 → .alreadyUsed，供重放判定）。
//  - 限速：同一对端 Device ID 每 60s 窗口内**失败** ≤ 5 次；超限一律 .rateLimited
//    （即使随后输入正确码也拒绝——窗口内先冷静）。
//  - 比较：constantTimeEquals（等长逐字节 XOR 累积），不因首个不同字节提前返回。
//
//  与既有 QR 路径的关系：码校验通过后 host 把**关联的一次性 nonce** 交给 client，
//  client 仍走标准 PairRequest（对 nonce 签名）→ host 现有 nonce 池验签 → 批准卡 →
//  批准 → 落库。即「6 位码 = 扫码的替代入口」，不新增信任根、不改落库语义。
//
//  本文件无 IO、无 UI、可注入 now/codeGenerator ⇒ 全部行为单测覆盖。
//

import Foundation

// MARK: - 失败原因

/// 配对码校验失败原因（rawValue 同时是线上 reason 码，见 SyncPairingCodeMessages）。
enum SyncPairingCodeFailure: String, Error, Equatable, Sendable, CaseIterable {
    /// 从没生成过码（或上一次已被新码替换）
    case noActiveCode = "no_active_code"
    /// 生成过，但已过 TTL
    case expired
    /// 该码已被成功使用过（重放）
    case alreadyUsed = "already_used"
    /// 码不匹配（输入错误）
    case mismatch
    /// 同对端失败次数超限（限速）
    case rateLimited = "rate_limited"
}

// MARK: - 生成结果

/// 一次配对码签发结果（host 侧展示 + 注册 nonce 用）。
struct SyncPairingCodeIssue: Equatable, Sendable {
    /// 6 位数字码（保留前导零；展示用 SyncPairingCodeStore.formatted 分组）
    let code: String
    /// 关联的一次性 nonce（host 注册进 nonce 池；client 拿到后对其签名）
    let nonce: Data
    let issuedAt: Date
    let expiresAt: Date
}

// MARK: - 码库

/// 6 位配对码库（线程安全、可注入时钟）。
///
/// 只在 host 侧持有（SyncListener.pairingCodes）；client 侧不需要本类型。
final class SyncPairingCodeStore: @unchecked Sendable {
    /// 缺省 TTL（秒）。任务口径：120s。
    static let defaultTTL: TimeInterval = 120
    /// 缺省限速：同一对端 60s 内最多 5 次失败。
    static let defaultMaxFailures = 5
    /// 缺省限速窗口（秒）。
    static let defaultFailureWindow: TimeInterval = 60
    /// 码长度（十进制位）
    static let codeLength = 6

    private struct Entry {
        let code: String
        let nonce: Data
        let issuedAt: Date
        let expiresAt: Date
        var usedAt: Date?
    }

    private let lock = NSLock()
    private let ttl: TimeInterval
    private let maxFailures: Int
    private let failureWindow: TimeInterval
    private let now: @Sendable () -> Date
    private let codeGenerator: @Sendable () -> String

    /// 当前有效码（nil = 无）。
    private var entry: Entry?
    /// 最近一次因过期被淘汰的码（区分 .expired 与 .noActiveCode）。
    private var lastExpired: Entry?
    /// 失败计数：peer Device ID → 失败时间戳（窗口外自动裁剪）。
    private var failures: [String: [Date]] = [:]

    init(
        ttl: TimeInterval = SyncPairingCodeStore.defaultTTL,
        maxFailures: Int = SyncPairingCodeStore.defaultMaxFailures,
        failureWindow: TimeInterval = SyncPairingCodeStore.defaultFailureWindow,
        now: @escaping @Sendable () -> Date = { Date() },
        codeGenerator: @escaping @Sendable () -> String = { SyncPairingCodeStore.randomCode() }
    ) {
        self.ttl = ttl
        self.maxFailures = maxFailures
        self.failureWindow = failureWindow
        self.now = now
        self.codeGenerator = codeGenerator
    }

    // MARK: 读取

    /// 当前可展示的码（已过期 ⇒ nil，并顺手淘汰）。
    var activeCode: String? {
        lock.lock()
        defer { lock.unlock() }
        purgeLocked()
        return entry?.code
    }

    /// 当前码的过期时刻（UI 倒计时用；无有效码 ⇒ nil）。
    var activeExpiry: Date? {
        lock.lock()
        defer { lock.unlock() }
        purgeLocked()
        return entry?.expiresAt
    }

    // MARK: 生成 / 作废

    /// 生成新码（作废此前未使用的码）。调用方负责把返回的 nonce 注册进 host nonce 池。
    @discardableResult
    func generate() -> SyncPairingCodeIssue {
        lock.lock()
        defer { lock.unlock() }
        purgeLocked()
        // 换码：旧码立即失效（一次性 = 同一时刻只有一张）
        entry = nil
        let stamp = now()
        let issue = Entry(
            code: Self.normalizeGenerated(codeGenerator()),
            nonce: Self.randomNonce(),
            issuedAt: stamp,
            expiresAt: stamp.addingTimeInterval(ttl),
            usedAt: nil
        )
        entry = issue
        lastExpired = nil
        return SyncPairingCodeIssue(
            code: issue.code,
            nonce: issue.nonce,
            issuedAt: issue.issuedAt,
            expiresAt: issue.expiresAt
        )
    }

    /// 作废当前码（配对完成 / 停止监听 / 用户取消展示）。
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
        lastExpired = nil
    }

    // MARK: 校验

    /// 校验一次码提交。
    /// - Returns: 成功返回关联 nonce（调用方回给 client）；失败返回具体原因。
    func verify(code rawCode: String, peerID: String) -> Result<Data, SyncPairingCodeFailure> {
        lock.lock()
        defer { lock.unlock() }
        purgeLocked()

        let stamp = now()
        let recent = recentFailuresLocked(peerID: peerID, now: stamp)
        guard recent.count < maxFailures else {
            return .failure(.rateLimited)
        }
        guard let current = entry else {
            return .failure(lastExpired == nil ? .noActiveCode : .expired)
        }
        if current.usedAt != nil {
            // 用过的码不再接受（重放）；同样记一次失败，防对已用码的无意义扫描。
            recordFailureLocked(peerID: peerID, now: stamp)
            return .failure(.alreadyUsed)
        }
        let normalized = Self.normalizedInput(rawCode) ?? ""
        guard Self.constantTimeEquals(normalized, current.code) else {
            recordFailureLocked(peerID: peerID, now: stamp)
            return .failure(.mismatch)
        }
        entry?.usedAt = stamp
        failures[peerID] = nil
        return .success(current.nonce)
    }

    /// 指定对端当前的失败次数（窗口内；测试/诊断用）。
    func failureCount(peerID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return recentFailuresLocked(peerID: peerID, now: now()).count
    }

    // MARK: 内部

    /// 淘汰过期码（锁内）。
    private func purgeLocked() {
        guard let current = entry else { return }
        if current.usedAt == nil, now() >= current.expiresAt {
            entry = nil
            lastExpired = current
        }
    }

    private func recentFailuresLocked(peerID: String, now stamp: Date) -> [Date] {
        guard let stamps = failures[peerID] else { return [] }
        let cutoff = stamp.addingTimeInterval(-failureWindow)
        return stamps.filter { $0 > cutoff }
    }

    private func recordFailureLocked(peerID: String, now stamp: Date) {
        var stamps = recentFailuresLocked(peerID: peerID, now: stamp)
        stamps.append(stamp)
        failures[peerID] = stamps
    }
}

// MARK: - 纯工具

extension SyncPairingCodeStore {
    /// 生成 6 位数字码（前导零保留；系统 CSPRNG）。
    static func randomCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = Int.random(in: 0 ..< 1_000_000, using: &generator)
        return String(format: "%06d", value)
    }

    /// 展示分组：123456 → 123 456。
    static func formatted(_ code: String) -> String {
        guard code.count == codeLength else { return code }
        let index = code.index(code.startIndex, offsetBy: 3)
        return String(code[..<index]) + " " + String(code[index...])
    }

    /// 输入归一（去掉空白与常见分隔符）；非 6 位 ASCII 数字 ⇒ nil。
    static func normalizedInput(_ raw: String) -> String? {
        let digits = raw.filter { $0.isNumber && $0.isASCII }
        guard digits.count == codeLength else { return nil }
        return String(digits)
    }

    /// 等长常量时间比较（逐字节 XOR 累积，不提前返回）。
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var diff: UInt8 = 0
        for index in left.indices {
            diff |= left[index] ^ right[index]
        }
        return diff == 0
    }

    /// 生成器输出兜底：非 6 位数字 ⇒ 重新取随机码（防注入坏值）。
    static func normalizeGenerated(_ raw: String) -> String {
        normalizedInput(raw) ?? randomCode()
    }

    /// 一次性 nonce（16B，CSPRNG）。
    static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0 ... 255, using: &generator)
        }
        return Data(bytes)
    }
}
