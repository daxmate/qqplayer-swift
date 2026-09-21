//
//  QuarkClient+Share.swift
//  QQPlayer
//
//  夸克分享解析与下载直链（web resolve_share / resolve_share_verbose / get_download_url /
//  refresh_puus 语义）：匿名解析分享目录（递归 ≤3 层、翻页、fid 去重）、登录后换取
//  签名直链、__puus 会话保活；以及分享内部助手（stoken / 目录列表 / 递归 / item 映射）
//  与业务错误文案后缀 detailSuffix（只被本片调用，故同片保留 private，不降级）。
//
//  2026-09-21 从 QuarkClient.swift 原样搬出（纯搬家，无逻辑变更）：类型/函数/访问级别
//  逐字未改；跨片共享的 HTTP/Cookie 原语按需放宽（见 QuarkClient+CookieHTTP.swift）。
//  结构体声明、注入缝、扫码登录在 QuarkClient.swift；Cookie 存取与网络原语在
//  QuarkClient+CookieHTTP.swift。改语义时一起看。
//

import Foundation

extension QuarkClient {
    // MARK: - 分享解析（匿名；web resolve_share / resolve_share_verbose）

    /// 匿名解析夸克分享链接（不需要登录）→ 文件列表（web resolve_share）。
    /// 目录型分享递归进入（深度 ≤3）；无文件/任何失败 → []（web 语义，不抛）。
    func resolveShare(_ shareURL: String) async -> [QuarkShareFile] {
        let (files, _) = await resolveShareVerbose(shareURL)
        return files
    }

    /// resolveShare + 本次解析使用的 stoken（web resolve_share_verbose）。
    ///
    /// ⚠️ share_fid_token 绑定本次 stoken：下载直链必须用同一个 stoken
    /// （新 stoken + 旧 fid_token → 41020 转存文件token校验异常）。
    /// 失败返回 ([], "")（web 语义，不抛）。
    func resolveShareVerbose(_ shareURL: String) async -> (files: [QuarkShareFile], stoken: String) {
        do {
            guard let pwdID = QuarkLogic.shareToken(from: shareURL) else {
                throw QuarkClientError.invalidShareURL(shareURL)
            }
            let stoken = try await fetchShareStoken(pwdID: pwdID)
            var files: [QuarkShareFile] = []
            var seen: Set<String> = []
            try await walkShare(
                pwdID: pwdID, stoken: stoken, pdirFid: "0", depth: 1,
                files: &files, seen: &seen
            )
            AppLog.info(.scrape, "✅ [夸克 resolve] 分享解析成功 shareURL=\(shareURL) files=\(files.count) stoken=\(stoken.prefix(8))…")
            return (files, stoken)
        } catch {
            // 诊断打点（2026-09-08 歌曲海下载 shareEmptyOrExpired 排查）：
            // resolve 失败原因曾被完全吞掉（web 语义失败返回空数组），UI 只能看到
            // shareEmptyOrExpired；这里把真实环节错误打出来（invalidShareURL /
            // stoken 获取失败 HTTP/目录列表失败/业务 message 等）。
            let detail = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            AppLog.error(.scrape, "❌ [夸克 resolve] 分享解析失败 shareURL=\(shareURL) error=\(detail)")
            return ([], "")
        }
    }

    // MARK: - 下载直链（登录后；web get_download_url）

    /// 登录后把分享文件换成签名直链（~10min 有效）。
    ///
    /// stoken 必须与 shareFidToken 同源（来自同一次 resolveShareVerbose）。
    /// 未登录（cookie 文件不存在/已失效）抛 loginRequired；401/403 同样抛
    /// loginRequired 但**不删 cookie 文件**（保留现场便于诊断，web 注释原文）。
    /// 实现对齐社区 quark-share-downloader（POST /file/download，fids/fids_token）。
    func getDownloadURL(
        shareURL: String,
        fid: String,
        shareFidToken: String,
        stoken: String
    ) async throws -> QuarkDownload {
        guard hasStoredCookies else {
            throw QuarkClientError.loginRequired
        }
        guard let pwdID = QuarkLogic.shareToken(from: shareURL) else {
            throw QuarkClientError.invalidShareURL(shareURL)
        }
        // 会话保活（2026-09-08 歌曲海下载 403 auth miss 修复）：扫码登录只存
        // 6 个 cookie，下载 CDN 校验需要的 __puus 仅由 /config 接口 Set-Cookie
        // 下发（Max-Age 24h）；refreshPUUS 此前定义了但从未被调用 → 下载必然
        // auth miss。每次取直链前刷一次保活（失败静默，不影响主流程）。
        // 位置在 shareToken 校验后：URL 非法直接抛，不做无谓保活请求。
        await refreshPUUS()
        let jar = loadCookies()
        var headers = driveHeaders(cookies: jar)
        headers["Origin"] = "https://pan.quark.cn"
        headers["Content-Type"] = "application/json"

        let url = Self.url(Self.driveAPIBase, "/file/download", query: [
            "entry": "ft", "fr": "pc", "pr": "ucpro",
        ])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.poolTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "fids": [fid],
            "fids_token": [shareFidToken],
            "pwd_id": pwdID,
            "stoken": stoken,
        ])
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, http) = try await perform(request)

        if http.statusCode == 401 || http.statusCode == 403 {
            // ⚠️ 不删 cookie 文件：401/403 可能是凭证不全或参数问题，未必是登录失效；
            // 删文件会导致扫码-下载-重扫死循环（web 注释原文）
            // 诊断打点（2026-09-08）：403 body 常含真实原因（如 41020 token 校验异常）
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            AppLog.error(.scrape, "❌ [夸克直链] 取直链被拒 status=\(http.statusCode) body=\(bodyPreview)")
            throw QuarkClientError.loginRequired
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let bodyPreview = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            AppLog.error(.scrape, "❌ [夸克直链] 取直链 HTTP 失败 status=\(http.statusCode) body=\(bodyPreview)")
            throw QuarkClientError.httpStatus(http.statusCode)
        }
        let payload = try Self.decode(data)
        // web 成功判定：status != 200 且 code != 0 才失败（缺省值按 web None 语义：
        // None != 200 / None != 0 均为 True → 视为失败）
        let statusCode = (payload["status"] as? NSNumber)?.intValue
        let businessCode = (payload["code"] as? NSNumber)?.intValue
        if statusCode != 200 && businessCode != 0 {
            let message = payload["message"] as? String ?? ""
            AppLog.error(.scrape, "❌ [夸克直链] 取直链业务失败 status=\(statusCode ?? -1) code=\(businessCode ?? -1) message=\(message)")
            let detail = message.isEmpty ? "" : ": \(message)"
            throw QuarkClientError.serverMessage("获取下载直链失败\(detail)")
        }
        guard let list = payload["data"] as? [Any],
              let first = list.first as? [String: Any],
              let downloadURLString = first["download_url"] as? String,
              !downloadURLString.isEmpty else {
            throw QuarkClientError.serverMessage("下载直链响应缺少 download_url")
        }
        // 下载头快照：与获取直链的请求一致（UA/Cookie/Referer/Origin），
        // 直链签名绑定它们（否则 412 Precondition Failed，web 注释原文）
        let downloadHeaders: [String: String] = [
            "User-Agent": Self.quarkClientUA,
            "Referer": Self.referer,
            "Origin": "https://pan.quark.cn",
            "Cookie": QuarkLogic.cookieHeader(jar),
        ]
        // 诊断打点（2026-09-08）：Cookie 值不打（日志卫生），只打是否携带；
        // url 截断（签名 URL 含 token，全量无意义且刷屏）
        AppLog.info(.scrape, "✅ [夸克直链] 取直链成功 url=\(downloadURLString.prefix(140))… cookie=\(downloadHeaders["Cookie"]?.isEmpty == false ? "携带(\(downloadHeaders["Cookie"]?.count ?? 0)字符)" : "无")")
        return QuarkDownload(urlString: downloadURLString, headers: downloadHeaders)
    }

    // MARK: - 会话 cookie 刷新（web refresh_puus）

    /// 刷新 __puus 会话 cookie（约 2h 过期）：发一次不带 __puus 的
    /// GET /1/clouddrive/config（alist#830 方案），服务端会重新下发 __puus；
    /// 只有确认重新下发才持久化，避免误删旧值。失败静默（web 语义）。
    func refreshPUUS() async {
        guard hasStoredCookies else { return }
        do {
            var jar = loadCookies()
            jar.removeValue(forKey: "__puus")   // 不带 __puus 请求，触发服务端重发
            let url = Self.url(Self.driveAPIBase, "/config", query: ["pr": "ucpro", "fr": "pc"])
            let (_, http) = try await perform(
                makeRequest(url: url, headers: driveHeaders(cookies: jar))
            )
            guard http.statusCode == 200 else { return }
            let responseCookies = QuarkLogic.parseSetCookieHeaders(
                Self.setCookieHeaderValues(from: http)
            )
            guard responseCookies["__puus"] != nil else { return }
            jar.merge(responseCookies) { _, new in new }
            try saveCookies(jar)
        } catch {
            // 刷新失败：忽略，下次调用自然恢复（web 注释原文）
        }
    }

    // MARK: - 分享内部：stoken / 目录列表 / 递归（web 同名函数）

    /// 匿名取分享 stoken（web _get_share_stoken：POST share/sharepage/token）
    private func fetchShareStoken(pwdID: String) async throws -> String {
        let url = Self.url(Self.driveAPIBase, "/share/sharepage/token", query: [
            "pr": "ucpro", "fr": "pc",
        ])
        var headers = driveHeaders()
        headers["Origin"] = "https://pan.quark.cn"
        headers["Content-Type"] = "application/json"
        let payload = try await postJSON(url: url, headers: headers, body: [
            "pwd_id": pwdID,
            "passcode": "",
            "support_visit_limit_private_share": true,
        ])
        if (payload["code"] as? NSNumber)?.intValue != 0 {
            throw QuarkClientError.serverMessage(
                "获取分享 token 失败\(Self.detailSuffix(payload["message"]))"
            )
        }
        let stoken = ((payload["data"] as? [String: Any])?["stoken"] as? String) ?? ""
        guard !stoken.isEmpty else {
            throw QuarkClientError.serverMessage("分享 token 响应缺少 stoken")
        }
        return stoken
    }

    /// 列分享目录单层（翻页；web _list_share_dir），返回原始 JSON 项（目录判定在
    /// walk 里做，保持 web item 字段可读）；失败抛异常由 resolve 汇总层兜底。
    private func listShareDirectory(
        pwdID: String, stoken: String, pdirFid: String
    ) async throws -> (items: [[String: Any]], total: Int) {
        var items: [[String: Any]] = []
        var total = 0
        var page = 1
        while true {
            let url = Self.url(Self.driveAPIBase, "/share/sharepage/detail", query: [
                "ver": "2",
                "pwd_id": pwdID,
                "stoken": stoken,
                "pdir_fid": pdirFid,
                "force": "0",
                "_page": String(page),
                "_size": String(Self.sharePageSize),
                "_fetch_total": "1",
                "_sort": "file_type:asc,updated_at:desc",
                "pr": "ucpro",
                "fr": "pc",
            ])
            let payload = try await getJSON(url: url, headers: driveHeaders())
            if (payload["code"] as? NSNumber)?.intValue != 0 {
                throw QuarkClientError.serverMessage(
                    "分享目录列表失败\(Self.detailSuffix(payload["message"]))"
                )
            }
            let batch = (((payload["data"] as? [String: Any])?["list"] as? [Any]) ?? [])
                .compactMap { $0 as? [String: Any] }
            items.append(contentsOf: batch)
            // web：metadata._total or len(items)（0/None → len 兜底）
            let metaTotal = ((payload["metadata"] as? [String: Any])?["_total"] as? NSNumber)?
                .intValue ?? 0
            total = metaTotal > 0 ? metaTotal : items.count
            if batch.isEmpty || items.count >= total || batch.count < Self.sharePageSize {
                break
            }
            page += 1
        }
        return (items, total)
    }

    // swiftlint:disable function_parameter_count
    // 6 参数与 web _walk_share(pwd_id, stoken, pdir_fid, depth, files, seen) 逐字对齐

    /// 递归列分享目录（web _walk_share）：深度 > MAX_SHARE_DEPTH 不再进入，fid 去重。
    /// 目录项本身也进文件列表（web 先 append 再递归，dir 的 fid 也占 seen）。
    private func walkShare(
        pwdID: String,
        stoken: String,
        pdirFid: String,
        depth: Int,
        files: inout [QuarkShareFile],
        seen: inout Set<String>
    ) async throws {
        guard depth <= Self.maxShareDepth else { return }
        let (items, _) = try await listShareDirectory(pwdID: pwdID, stoken: stoken, pdirFid: pdirFid)
        for item in items {
            guard let fid = item["fid"] as? String, !fid.isEmpty, !seen.contains(fid) else {
                continue
            }
            seen.insert(fid)
            if let file = Self.mapShareFile(item) {
                files.append(file)
            }
            if QuarkLogic.rawIsDirectory(item) {
                try await walkShare(
                    pwdID: pwdID, stoken: stoken, pdirFid: fid, depth: depth + 1,
                    files: &files, seen: &seen
                )
            }
        }
    }
    // swiftlint:enable function_parameter_count

    /// 分享列表原始项 → QuarkShareFile（web resolve 内层 dict 构造逐字段对齐）
    private static func mapShareFile(_ item: [String: Any]) -> QuarkShareFile? {
        guard let fid = item["fid"] as? String, !fid.isEmpty else { return nil }
        let fileName = item["file_name"] as? String ?? ""
        let size = (item["size"] as? NSNumber)?.int64Value ?? 0
        let formatType = ((item["format_type"] as? String) ?? "").lowercased()
        // web：share_fid_token or fid_token or ""（空值/缺失都落到下一个）
        let token: String
        if let first = item["share_fid_token"] as? String, !first.isEmpty {
            token = first
        } else {
            token = (item["fid_token"] as? String) ?? ""
        }
        return QuarkShareFile(
            fid: fid,
            fileName: fileName,
            size: size,
            formatType: formatType,
            shareFidToken: token,
            ext: QuarkLogic.extensionOf(fileName: fileName)
        )
    }

    /// 业务错误文案后缀（web f"...: {payload.get('message')}"；message 缺失不带冒号）
    private static func detailSuffix(_ message: Any?) -> String {
        guard let message = message as? String, !message.isEmpty else { return "" }
        return ": \(message)"
    }
}
