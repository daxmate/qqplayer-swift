//
//  SyncDiag.swift
//  QQPlayer
//
//  同步「一次尝试」的结构化量化诊断（2026-11-08 立，V1 观测批）。
//
//  为什么有这份东西：连接类问题（发现不到 / 连上不是那台 / 卡在握手 / 传一半停）
//  过去只能靠 SyncConnectDiag 的散文行一条条读，回答不了三个问题：
//   ① 成功率多少  ② 失败卡在哪个阶段  ③ 各阶段耗时分布是 p50/p90 多少
//  本文件把一次尝试收成一行固定字段的汇总（前缀 SYNCDIAG，k=v 空格分隔，值内不含空格），
//  一行 grep 就能按 failStage 聚合、按阶段算分位数。
//
//  ⚠️ 本文件是纯观测：不改变任何判定条件、重试策略、超时数值、调用顺序、帧格式与并发模型。
//  调用点只新增「记录事实」的调用；不读这些记录做决策。
//
//  两行/一次尝试的划分（本批实现口径，见任务包 §4 侦察结论）：
//    - kind=conn：一次连接尝试（discover/dial/handshake/negotiate；transfer/settle=跳过）
//    - kind=run ：一次编排运行（transfer/settle；前四段=跳过）
//  为什么拆两类：Mac 是监听端（SyncListener），连接由 iPhone 发起；一次连接可承载多次
//  同步运行，两类事件的起止天然不同，混成一行会让「耗时」失去意义。
//
//  落点：复用 AppLog（category .sync），不新建日志系统 / 轮转文件。
//
//  字段白名单（严禁越界）：attemptId、指纹前 8 位、通道名、阶段耗时、错误 domain/code、
//  候选数、字节数、文件数。禁止曲名 / 完整路径 / 设备全名 / IP 全量地址 / 任何用户内容。
//

import Foundation
import Network

// MARK: - 阶段

/// 一次尝试的阶段。六段固定参与计时；skipped 是不参与计时的哨兵值
/// （表示「本类尝试不包含该段」，汇总行里对应 d_* = -1）。
enum SyncDiagStage: String, CaseIterable, Sendable {
    /// 用户点同步 → 拿到候选地址（记录通道与候选数）
    case discover
    /// 开始拨号 → 连接 ready
    case dial
    /// 首帧发送 → 首帧收到（可解析）
    case handshake
    /// 版本/身份校验 → 协商完成（ready）
    case negotiate
    /// 首字节 → 传输结束
    case transfer
    /// 传输结束 → 收尾入库/计数完成
    case settle
    /// 哨兵：不属于本次尝试的阶段
    case skipped

    /// 汇总行的字段顺序（六段固定顺序，缺一即视为格式回归）。
    static let timed: [SyncDiagStage] = [.discover, .dial, .handshake, .negotiate, .transfer, .settle]
}

/// 尝试类型：连接（conn）/ 编排运行（run）。见文件头「两行/一次尝试」。
enum SyncDiagKind: String, Sendable {
    case conn
    case run
}

/// 发现通道。值直接进汇总行，不得含空格。
enum SyncDiagChannel: String, Sendable {
    case bonjour
    case txt
    case cache
    case manual
    /// 对端主动连进来（Mac 监听端）
    case inbound
    /// 复用已就绪会话的编排运行
    case session
    case unknown
}

// MARK: - 传输层错误

/// NWError 的可测替身：把「domain + code」摊平成可构造的值，
/// 测试能覆盖 timeout / refused / dns / cancelled 而不去构造真实 NWError。
enum SyncDiagTransportError: Equatable, Sendable {
    case posix(Int32)
    case dns(Int32)
    case tls(Int32)

    /// 汇总行 faildom 的取值。
    var domain: String {
        switch self {
        case .posix: return "posix"
        case .dns: return "dns"
        case .tls: return "tls"
        }
    }

    /// 汇总行 failcode 的取值（原始错误码，不做重编码）。
    var code: Int {
        switch self {
        case let .posix(value): return Int(value)
        case let .dns(value): return Int(value)
        case let .tls(value): return Int(value)
        }
    }

    /// 归一化原因 token（便于跨平台聚合；不进汇总行，供调用方与测试使用）。
    var reason: String {
        switch self {
        case let .posix(value):
            switch value {
            case ETIMEDOUT: return "timeout"
            case ECONNREFUSED: return "refused"
            case ECANCELED: return "cancelled"
            case ECONNRESET: return "reset"
            case ENETUNREACH, EHOSTUNREACH, ENETDOWN, EHOSTDOWN: return "unreachable"
            default: return "other"
            }
        case .dns:
            return "dns"
        case .tls:
            return "tls"
        }
    }
}

extension SyncDiagTransportError {
    /// 真实 NWError → 可记录形态。未知分支返回 nil（不编造 domain/code）。
    init?(nwError: NWError) {
        switch nwError {
        case let .posix(code):
            self = .posix(code.rawValue)
        case let .dns(code):
            self = .dns(code)
        case let .tls(code):
            self = .tls(code)
        default:
            // 未知分支（系统新增）：不记录 domain/code，避免编造事实。
            return nil
        }
    }
}

// MARK: - 一次尝试

/// 一次尝试的观测记录：阶段计时、首个失败阶段、计数，末尾一行汇总。
///
/// 并发：内部 NSLock 保护，@unchecked Sendable —— 与仓库既有同步类型
/// （SyncPeerSession / SyncCollectionSyncCoordinator）同一风格，不引入新的全局可变状态。
/// 时钟可注入（now），测试用假时钟断言精确耗时。
final class SyncDiagAttempt: @unchecked Sendable {
    /// 汇总行固定前缀（一行 grep 的锚点）。
    static let linePrefix = "SYNCDIAG"
    /// 行格式版本：字段增删改必须递增。
    static let schemaVersion = 1

    /// 尝试 ID（8 位小写十六进制，仅用于把同一尝试的多条记录串起来）。
    let id: String
    let kind: SyncDiagKind
    /// client / host
    let role: String
    let channel: SyncDiagChannel
    /// 发现阶段拿到的候选数（-1 = 本类尝试不适用 / 未测量）。
    let candidates: Int

    private let now: @Sendable () -> Int64
    private let emit: @Sendable (String) -> Void
    private let lock = NSLock()

    private let startedAt: Int64
    private var beginAt: [SyncDiagStage: Int64] = [:]
    private var durationMs: [SyncDiagStage: Int64] = [:]
    private var failStage: SyncDiagStage?
    private var failDomain = "-"
    private var failCode = 0
    private var peerPrefix = "-"
    private var byteCount: Int64 = -1
    private var fileCount: Int = -1
    /// 文件级并发峰值（0 = 未测量；可选字段，仅在有值时追加）
    private var concurrencyPeak = 0
    private var finished = false

    /// - Parameters:
    ///   - attemptId: 由调用方传入便于串联；缺省随机生成。
    ///   - peerDeviceID: 对端 Device ID（= 公钥指纹 base32），行内只留前 8 位。
    ///   - now: 时钟（毫秒）；缺省系统时钟。
    ///   - emit: 汇总行出口；缺省走 AppLog（category .sync）。
    init(
        attemptId: UUID = UUID(),
        kind: SyncDiagKind,
        role: String,
        channel: SyncDiagChannel,
        candidates: Int = -1,
        peerDeviceID: String? = nil,
        now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
        emit: @escaping @Sendable (String) -> Void = { AppLog.info(.sync, $0) }
    ) {
        let compact = attemptId.uuidString.replacingOccurrences(of: "-", with: "")
        self.id = String(compact.prefix(8)).lowercased()
        self.kind = kind
        self.role = role
        self.channel = channel
        self.candidates = candidates
        self.now = now
        self.emit = emit
        self.startedAt = now()
        if let peerDeviceID, !peerDeviceID.isEmpty {
            self.peerPrefix = SyncDiagAttempt.token(String(peerDeviceID.prefix(8)))
        }
    }

    // MARK: 记录

    /// 记录阶段起点（幂等：首值为准，重复调用不覆盖）。
    func begin(_ stage: SyncDiagStage) {
        guard stage != .skipped else { return }
        lock.lock()
        defer { lock.unlock() }
        guard beginAt[stage] == nil, durationMs[stage] == nil else { return }
        beginAt[stage] = now()
    }

    /// 记录阶段终点（只有已开始且未结束的阶段才落耗时）。
    func end(_ stage: SyncDiagStage) {
        guard stage != .skipped else { return }
        let timestamp = now()
        lock.lock()
        defer { lock.unlock() }
        guard let started = beginAt[stage], durationMs[stage] == nil else { return }
        durationMs[stage] = max(0, timestamp - started)
    }

    /// 记录首个失败阶段（互斥：首次调用生效，后续忽略）。
    func fail(_ stage: SyncDiagStage, domain: String, code: Int) {
        guard stage != .skipped else { return }
        lock.lock()
        defer { lock.unlock() }
        guard failStage == nil else { return }
        failStage = stage
        failDomain = SyncDiagAttempt.token(domain)
        failCode = code
    }

    /// 记录传输层失败（同时带上真实 domain/code）。
    func fail(_ stage: SyncDiagStage, error: SyncDiagTransportError) {
        fail(stage, domain: error.domain, code: error.code)
    }

    /// 记录计数事实（-1 = 未测量）。
    func record(files: Int, bytes: Int64) {
        lock.lock()
        defer { lock.unlock() }
        fileCount = files
        byteCount = bytes
    }

    /// 记录实际文件并发峰值（0 = 未测量 → 不打印，旧行形状不变）。
    func noteConcurrencyPeak(_ value: Int) {
        lock.lock()
        defer { lock.unlock() }
        concurrencyPeak = max(0, value)
    }

    /// 是否已开始计时（调用方可据此区分「计划阶段就失败」与「传了一半失败」）。
    func hasBegun(_ stage: SyncDiagStage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return beginAt[stage] != nil
    }

    /// 汇总：幂等 —— 重复调用只输出第一行。
    func finish() {
        guard let line = finishLine() else { return }
        emit(line)
    }

    /// 汇总（不落盘）：返回本次第一行汇总，重复调用返回 nil。
    /// 供「持锁路径」把落盘推迟到锁外（例：会话状态机把行当 effect 排队）。
    func finishLine() -> String? {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return nil
        }
        finished = true
        let line = renderLineLocked()
        lock.unlock()
        return line
    }

    // MARK: 汇总行

    /// 固定字段顺序（golden 测试锁这一行）：
    /// SYNCDIAG v=1 kind=<conn|run> id=<8hex> role=<client|host> chan=<channel> cand=<int>
    ///   peer=<8 位|-> ok=<0|1> fail=<stage|none> faildom=<token|-> failcode=<int>
    ///   d_discover=<> d_dial=<> d_handshake=<> d_negotiate=<> d_transfer=<> d_settle=<>
    ///   total=<> bytes=<> files=<>
    private func renderLineLocked() -> String {
        var fields: [String] = [
            Self.linePrefix,
            "v=\(Self.schemaVersion)",
            "kind=\(kind.rawValue)",
            "id=\(id)",
            "role=\(Self.token(role))",
            "chan=\(channel.rawValue)",
            "cand=\(candidates)",
            "peer=\(peerPrefix)",
            "ok=\(failStage == nil ? 1 : 0)",
            "fail=\(failStage?.rawValue ?? "none")",
            "faildom=\(failDomain)",
            "failcode=\(failCode)",
        ]
        for stage in SyncDiagStage.timed {
            fields.append("d_\(stage.rawValue)=\(durationMs[stage] ?? -1)")
        }
        fields.append("total=\(max(0, now() - startedAt))")
        fields.append("bytes=\(byteCount)")
        fields.append("files=\(fileCount)")
        // 可选字段（追加在末尾，旧行形状不变；golden 测试不设值时逐字一致）
        if concurrencyPeak > 0 { fields.append("concMax=\(concurrencyPeak)") }
        return fields.joined(separator: " ")
    }

    /// 值内不得含空格（路径/名称一律 basename 或省略；空白折成下划线）。
    static func token(_ raw: String) -> String {
        guard !raw.isEmpty else { return "-" }
        var out = ""
        out.reserveCapacity(raw.count)
        for character in raw {
            switch character {
            case " ", "\t", "\n", "\r":
                out.append("_")
            default:
                out.append(character)
            }
        }
        return out
    }
}
