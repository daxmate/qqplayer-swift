//
//  QuarkClient.swift
//  QQPlayer
//
//  夸克网盘客户端（web 版 backend/quark_provider.py 538 行移植，E2 下载批 2026-09）。
//  QQPlayer 共享层：Services 文件 iOS 也编译（禁 AppKit/UIKit），QQPlayerMac target
//  走 B1A 白名单（pbxproj membershipExceptions）。web 为唯一事实源，语义逐字对齐。
//
//  语义对齐（web quark_provider.py，此处逐条注释）：
//  - 扫码登录：login_qrcode()（uop.quark.cn，浏览器 UA）生成二维码内容 →
//    login_status(qr_id) 由调用方每 2s 轮询（本层只做单次查询）→ 扫码成功拿
//    service_ticket → GET pan.quark.cn/account/info 换会话 Cookie → 持久化到本地文件
//  - Cookie 持久化：会话 cookie 存系统钥匙串（kSecClassGenericPassword，
//    service/account 见 QuarkKeychainCookieStore；与 SyncIdentity 同步私钥同款
//    系统安全存储，不再落明文盘）。每次请求都从钥匙串重载 cookie，
//    登录态变更（扫码/退出）立即可见（web _get_drive_client 语义）
//  - 旧版明文文件（Application Support/QQPlayerMac/quark_cookies.json）首次读取时
//    迁入钥匙串并安全删除（migrateLegacyCookieFileIfNeeded）；迁移/钥匙串失败有
//    日志，并保留旧文件降级可读（不静默丢登录态）
//  - 分享解析：resolve_share(share_url) 匿名列文件（sharepage/token + sharepage/detail，
//    目录型分享递归进入深度 ≤3、翻页、fid 去重）；分享失败返回空数组不抛（web 语义）
//  - ⚠️ stoken 绑定 share_fid_token：下载直链必须用同一次 resolve_share_verbose 返回的
//    stoken（新 stoken + 旧 fid_token → 41020 转存文件token校验异常）
//  - 音质挑选 pick_file：mp3（默认）/ flac 可选，找不到偏好格式自动降级，
//    最后兜底任何音频扩展；同格式多个取 size 最大（纯逻辑，可单测）
//  - 下载直链 get_download_url：登录后把分享文件换成签名直链（~10min 有效）。
//    ⚠️ web 自己标注未真实联调（无真实登录 cookie 无法离线验证）；实现参照 alist
//    quark_uc 驱动（POST /1/clouddrive/file/download）请求约定。真实联调由 maintainer
//    扫码登录后完成，本批所有网络路径经 URLProtocol mock 验证，不发真实网络
//  - refresh_puus()：发一次不带 __puus 的 GET /1/clouddrive/config（alist#830 方案）
//    触发服务端重新下发 __puus；只有确认重新下发才持久化；失败静默（web 语义）
//  - 401/403 不删 cookie 文件（保留现场便于诊断；web 注释：可能是凭证不全或参数问题，
//    未必是登录失效；删文件会导致扫码-下载-重扫死循环）
//
//  结构与 MusicBrainzClient 同款：struct + init 注入 protocolClasses（URLProtocol mock）
//  + sleep（预留节流钩子；web quark provider 无内部 sleep——扫码 2s 轮询由调用方负责，
//  本层 sleep 仅对齐既有骨架，暂无非零调用点）+ cookieStore 注入（便于测试）。
//
//  纯逻辑抽到 QuarkLogic（防回归单测）：share token 提取、扩展名、目录判定、
//  pick_file 降级决策、Set-Cookie 解析、cookie 序列化/反序列化（含损坏兜底）。
//  网络层每请求自带 UA/Referer（web 逐字段）；单次请求失败抛 QuarkClientError
//  （LocalizedError），绝不静默吞（resolve 汇总层的空数组是 web 语义，非吞错）。
//
//  2026-09-21 结构拆分（纯搬家，无逻辑变更）。同族文件：
//    · QuarkClient+Share.swift       — 分享解析（resolveShare/resolveShareVerbose/walk）/
//                                      下载直链 / __puus 会话保活 / 分享内部助手 + detailSuffix
//    · QuarkClient+CookieHTTP.swift  — 会话 cookie 存取 / 请求头组装 / 网络原语（全类工具箱）
//  本片保留：文件级私有类（QuarkQRTokenBox / QuarkLegacyMigrationState）、struct 声明、
//  注入缝（sleep / protocolClasses / cookieStore / legacyCookieFileURL）、init、
//  扫码登录段（loginQRCode / loginStatus / loginState / logout / exchangeTicket），
//  以及旧明文文件迁移（migrateLegacyCookieFileIfNeeded——它用文件级私有迁移状态
//  QuarkLegacyMigrationState，搬不出本文件，故留主片）。
//  跨片共享的成员去 private（逐个带「分片：跨文件可见」标记）：本片 protocolClasses /
//  cookieStore（存储属性，分片要读）与 migrateLegacyCookieFileIfNeeded（Cookie 片的
//  loadCookies 调用）；Cookie 片的 hasStoredCookies / loadCookies / saveCookies /
//  deleteCookieFile / anonHeaders / driveHeaders / setCookieHeaderValues / perform /
//  getJSON / postJSON / makeRequest / url / decode / randomHex32（主片与分享片调用）。
//

import Foundation

// MARK: - qr_id → 二维码 token 进程内映射（web 模块级 _QR_TOKENS）

/// 扫码 token 存储：qr_id → token（进程内有效；进程重启后查不到 → loginStatus
/// 返回 error「登录会话已失效」——web 语义）。class box 引用语义：struct 值拷贝间
/// 共享（web 是模块级全局 dict；Swift 侧要求调用方对 loginQRCode/loginStatus 使用
/// 同一 QuarkClient 实例——批量下载等长生命周期服务持有单实例即可）。
private final class QuarkQRTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]

    func store(_ qrID: String, _ token: String) {
        lock.lock()
        defer { lock.unlock() }
        tokens[qrID] = token
    }

    func token(for qrID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return tokens[qrID]
    }

    func remove(_ qrID: String) {
        lock.lock()
        defer { lock.unlock() }
        tokens.removeValue(forKey: qrID)
    }
}

/// 旧明文 cookie 文件迁移的「只跑一次」旗标（进程内；class 引用语义，
/// 保证同一 QuarkClient 值拷贝间共享；多次调用只有第一次返回 true）。
private final class QuarkLegacyMigrationState: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func beginOnce() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return false }
        done = true
        return true
    }
}

// MARK: - 客户端

struct QuarkClient {
    // MARK: 常量（web quark_provider.py 逐字对齐）

    /// 夸克客户端 UA：服务器校验，非客户端 UA 部分接口返回 404 混淆（web 注释原文）
    static let quarkClientUA = (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) quark-cloud-drive/2.5.20 Chrome/100.0.4896.160 "
            + "Electron/18.3.5.4-b478491100 Safari/537.36 Channel/pckk_other_ch"
    )
    /// 浏览器 UA：仅用于 uop.quark.cn 扫码登录流程（网页端 weblogin）
    static let browserUA = (
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    )

    static let driveAPIBase = "https://drive-pc.quark.cn/1/clouddrive"
    static let panBase = "https://pan.quark.cn"
    static let uopBase = "https://uop.quark.cn"
    static let qrScanPage = "https://su.quark.cn/4_eMHBJ"
    static let referer = "https://pan.quark.cn/"
    static let qrClientID = "532"
    static let qrExpireSeconds = 170          // 二维码 TTL（服务端 ~170s）
    static let poolTimeout: TimeInterval = 15.0
    static let maxShareDepth = 3              // 目录递归深度上限，防炸
    static let sharePageSize = 50

    /// 旧版明文 cookie 文件默认路径：Application Support/QQPlayerMac/quark_cookies.json
    /// （与 DatabasePathResolver macDatabaseURL 同目录惯例；web 存 Application
    /// Support/qqplayer——Mac 端沿用 QQPlayerMac 目录）。
    /// ⚠️ **已不再是主存储**：仅作迁移来源与降级读路径（主存储在钥匙串
    /// QuarkKeychainCookieStore）；路径注入便于测试。
    /// ⚠️ 本默认值仅供 macOS 运行期使用：iOS 沙盒无 homeDirectoryForCurrentUser
    /// （macOS-only API），fallback 用临时目录保证双平台可编译（iOS 不调用默认值）。
    static func defaultCookieFileURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("QQPlayerMac", isDirectory: true)
            .appendingPathComponent("quark_cookies.json")
    }

    // MARK: 注入点（MusicBrainzClient 骨架同款）

    /// 供测试注入的时钟/休眠（web quark provider 无内部 sleep——扫码 2s 轮询由
    /// 调用方负责；保留骨架，当前无非零调用点，测试注入 no-op）
    var sleep: (TimeInterval) async throws -> Void

    /// 测试注入：URLProtocol mock 类列表（nil = 真实网络）。网络请求每次临时构造
    /// URLSession（ephemeral + 手动 Cookie 管理），无法注入现成 session，故注入
    /// protocolClasses（MusicBrainzClient 同款）。
    /// 分片：跨文件可见（原 private）
    let protocolClasses: [AnyClass]?

    /// 会话 cookie 持久化后端（默认系统钥匙串；测试注入文件/故障桩）。
    /// 分片：跨文件可见（原 private）
    let cookieStore: any QuarkCookieStoring

    /// 旧版明文 cookie 文件路径：仅作**迁移来源**与降级读路径；
    /// nil = 不迁移（测试注入文件后端时）。默认 App Support/QQPlayerMac/quark_cookies.json。
    let legacyCookieFileURL: URL?

    /// 旧文件迁移只尝试一次（避免每次请求都扫盘）
    private let legacyMigrationState = QuarkLegacyMigrationState()

    /// qr_id → token 进程内映射（web 模块级 _QR_TOKENS）
    private let qrTokens = QuarkQRTokenBox()

    init(
        sleep: @escaping (TimeInterval) async throws -> Void = {
            try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
        },
        cookieStore: any QuarkCookieStoring = QuarkKeychainCookieStore(),
        legacyCookieFileURL: URL? = QuarkClient.defaultCookieFileURL(),
        protocolClasses: [AnyClass]? = nil
    ) {
        self.sleep = sleep
        self.cookieStore = cookieStore
        self.legacyCookieFileURL = legacyCookieFileURL
        self.protocolClasses = protocolClasses
    }

    // MARK: - 扫码登录（web login_qrcode / login_status / login_state / logout）

    /// 生成扫码登录二维码（web login_qrcode）。
    ///
    /// 流程：uuid4 request_id → GET uop.quark.cn/cas/ajax/getTokenForQrcodeLogin
    /// （client_id=532, v=1.2）拿 token → 生成本地 qr_id 并记住 token →
    /// 组装网页端 weblogin 二维码内容 URL（逐字对齐 web）。
    /// - Returns: 二维码内容 + qrID（供 loginStatus(qrID:) 轮询）+ TTL。
    /// - Throws: token 缺失 / 非 2xx / JSON 非法（web 均冒泡 500，不静默）。
    func loginQRCode() async throws -> QuarkQRCode {
        let url = Self.url(Self.uopBase, "/cas/ajax/getTokenForQrcodeLogin", query: [
            "client_id": Self.qrClientID,
            "v": "1.2",
            "request_id": Self.randomHex32(),
        ])
        let payload = try await getJSON(url: url, headers: Self.anonHeaders())
        let members = (payload["data"] as? [String: Any])?["members"] as? [String: Any]
        let token = members?["token"] as? String
        guard let token, !token.isEmpty else {
            let message = payload["message"] as? String ?? ""
            let detail = message.isEmpty ? "\(payload)" : message
            throw QuarkClientError.serverMessage("获取扫码 token 失败: \(detail)")
        }

        let qrID = UUID().uuidString
        qrTokens.store(qrID, token)

        // 二维码内容 URL（web f-string 逐字：uc_biz_str 已按服务端要求编码）
        let content = "\(Self.qrScanPage)?token=\(token)&client_id=\(Self.qrClientID)&ssb=weblogin"
            + "&uc_param_str=&uc_biz_str=S%3Acustom%7COPT%3ASAREA%400%7COPT%3AIMMERSIVE%401%7COPT%3ABACK_BTN_STYLE%400"
        return QuarkQRCode(qrID: qrID, contentURL: content, expiresIn: Self.qrExpireSeconds)
    }

    /// 单次查询扫码状态（web login_status；web 前端每 2s 调一次，Swift 侧由调用方轮询）。
    ///
    /// 状态机：unknown qr_id → error「登录会话已失效」；status=2000000 → 拿
    /// service_ticket 换会话 Cookie（成功即持久化）→ ok；50004001 → waiting；
    /// 50004002 → expired（弹出 token）；其余 → error。
    /// 首查 HTTP/传输错误折成 error 状态（web 返回 error 状态）；ticket 交换阶段
    /// 与 JSON 解析错误抛出（web _exchange_ticket 在 login_status 的 try 之外，
    /// 异常冒泡 500 对齐——由调用方捕获展示）。
    func loginStatus(qrID: String) async throws -> QuarkLoginStatus {
        guard let token = qrTokens.token(for: qrID) else {
            return .error(message: "登录会话已失效，请重新扫码")
        }
        let url = Self.url(Self.uopBase, "/cas/ajax/getServiceTicketByQrcodeToken", query: [
            "client_id": Self.qrClientID,
            "v": "1.2",
            "request_id": Self.randomHex32(),
            "token": token,
        ])
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.poolTimeout
        for (key, value) in Self.anonHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let data: Data
        let http: HTTPURLResponse
        do {
            (data, http) = try await perform(request)
        } catch {
            // 传输层错误 → error 状态（web except httpx.HTTPError 折 error 对齐）
            return .error(message: "轮询扫码状态失败: \(error.localizedDescription)")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            return .error(message: "轮询扫码状态失败: HTTP \(http.statusCode)")
        }
        let payload = try Self.decode(data)   // JSON 非法 → 抛出（web ValueError 冒泡对齐）

        switch (payload["status"] as? NSNumber)?.intValue {
        case 2_000_000:
            // 扫码成功：拿 service_ticket 换会话 Cookie（web _exchange_ticket）
            let members = (payload["data"] as? [String: Any])?["members"] as? [String: Any]
            let ticket = members?["service_ticket"] as? String
            guard let ticket, !ticket.isEmpty else {
                return .error(message: "登录响应缺少 service_ticket")
            }
            return try await exchangeTicket(ticket)
        case 50_004_001:
            return .waiting()
        case 50_004_002:
            qrTokens.remove(qrID)
            return .expired(message: "二维码已过期，请重新扫码")
        default:
            if let message = payload["message"] as? String, !message.isEmpty {
                return .error(message: message)
            }
            let statusValue = (payload["status"] as? NSNumber)?.intValue
            // web f"未知状态: {status}"：缺失打印 None（对齐 Python None 文案）
            let unknown = statusValue.map(String.init) ?? "None"
            return .error(message: "未知状态: \(unknown)")
        }
    }

    /// 检查是否已登录（web login_state）：cookie 文件存在且冒烟通过
    /// （GET pan.quark.cn/account/info 200 且 success）才算 logged_in。
    /// 非 200 / success=false → 清掉失效 cookie（web 手动检查状态码，无 raise）；
    /// JSON 解析失败/网络抖动 → 保留文件下次再试（web except ValueError/HTTPError 对齐）。
    func loginState() async -> (loggedIn: Bool, nickname: String?) {
        guard hasStoredCookies else {
            return (false, nil)
        }
        let url = Self.url(Self.panBase, "/account/info", query: [:])
        let request = makeRequest(url: url, headers: driveHeaders())
        do {
            let (data, http) = try await perform(request)
            if http.statusCode == 200 {
                if let payload = try? Self.decode(data) {
                    if payload["success"] as? Bool == true {
                        let nickname = (payload["data"] as? [String: Any])?["nickname"] as? String
                        return (true, nickname)
                    }
                    // success=false → cookie 已失效（web _clear_cookie_file 对齐）
                    deleteCookieFile()
                }
                // JSON 解析失败 → 保留文件（web except ValueError 对齐）
            } else {
                // 401 / 非 200 → cookie 已失效（web login_state 手动检查对齐）
                deleteCookieFile()
            }
        } catch {
            // 网络抖动等瞬时错误：不删 cookie，下次再试（web except HTTPError 对齐）
        }
        return (false, nil)
    }

    /// 退出登录：删除本地 cookie 文件（web logout）
    func logout() {
        deleteCookieFile()
    }

    /// 用 service_ticket 换会话 Cookie（web _exchange_ticket）：
    /// GET pan.quark.cn/account/info?st=&lw=scan（匿名浏览器 UA，收 Set-Cookie），
    /// 成功后把响应 cookie 持久化（新登录整体替换旧文件——web 用全新 client 语义）。
    /// - Throws: 非 2xx / JSON 非法（web 冒泡 500 对齐）。
    private func exchangeTicket(_ ticket: String) async throws -> QuarkLoginStatus {
        let url = Self.url(Self.panBase, "/account/info", query: ["st": ticket, "lw": "scan"])
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.poolTimeout
        for (key, value) in Self.anonHeaders() {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, http) = try await perform(request)
        guard (200 ..< 300).contains(http.statusCode) else {
            throw QuarkClientError.httpStatus(http.statusCode)
        }
        let payload = try Self.decode(data)
        guard payload["success"] as? Bool == true else {
            let message = payload["message"] as? String ?? ""
            return .error(message: message.isEmpty ? "扫码登录失败" : message)
        }
        // 全新匿名客户端只收到本次响应的 Set-Cookie（web 语义）→ 整体替换落盘
        let setCookieHeaders = Self.setCookieHeaderValues(from: http)
        let jar = QuarkLogic.parseSetCookieHeaders(setCookieHeaders)
        try saveCookies(jar)
        let nickname = (payload["data"] as? [String: Any])?["nickname"] as? String
        return .ok(nickname: nickname)
    }

    // MARK: - 明文文件迁移（旧版 → 钥匙串）

    /// 旧版明文 cookie 文件首次读取时迁入钥匙串，迁完安全删除文件（细节见
    /// QuarkCookieMigration；本方法只保证只跑一次 + 落日志）。
    /// 分片：跨文件可见（原 private）
    func migrateLegacyCookieFileIfNeeded() {
        guard let legacy = legacyCookieFileURL else { return }
        guard legacyMigrationState.beginOnce() else { return }
        switch QuarkCookieMigration.migrateIfNeeded(store: cookieStore, legacyFileURL: legacy) {
        case .noLegacyFile:
            break
        case let .migrated(count):
            AppLog.info(.scrape, "✅ [夸克会话] 旧明文 cookie 已迁入钥匙串（\(count) 项），已删除明文文件")
        case .alreadyInStore:
            AppLog.info(.scrape, "🔒 [夸克会话] 钥匙串已有凭据，已清理残留明文文件")
        case .discardedEmptyLegacy:
            AppLog.info(.scrape, "🔒 [夸克会话] 旧明文文件无可迁移凭据，已删除")
        case let .failed(message):
            AppLog.warn(.scrape, "⚠️ [夸克会话] 迁移钥匙串失败，保留明文文件降级可读: \(message)")
        }
    }

}
