import Foundation

/// 锐捷 eportal 校园网认证（`core.py` 中网络部分的 Swift 移植）。
///
/// 认证流程与原 `ruijie_auto.sh` / Python 版完全一致：
///   1. 访问连通性探测地址，据此判断是否已在线
///      （204 空响应，或 200 且正文里没有任何认证页痕迹）；
///   2. 否则从响应正文 / Location 中取出认证页 URL（.../index.jsp?...）；
///   3. 把 index.jsp 换成 InterFace.do?method=login 作为登录接口；
///   4. 把认证页的 query 做「二次 URL 编码」后作为 queryString 放进 POST 表单；
///   5. 解析返回的 JSON，result == success 即认证成功。
enum PortalClient {

    // 备用探针：主探针不可用时依次尝试。
    //
    // 全部选大陆节点（小米 / vivo / 华为），校园网内一般都有 CDN 就近节点，
    // 解析与回包远快于境外地址；最后保留一个微软 connecttest（200 + 正文）
    // 作为「204 型探针全被拦」时的兜底。
    static let fallbackProbes = [
        "http://connect.rom.miui.com/generate_204",
        "http://wifi.vivo.com.cn/generate_204",
        "http://connectivitycheck.platform.hicloud.com/generate_204",
        "http://www.msftconnecttest.com/connecttest.txt",
    ]

    /// 触发式地址：用 IP 直连、不依赖 DNS。未认证时同样会被门户劫持，
    /// 从而在「DNS 不可用」的情况下依然能拿到带参数的认证页地址。
    static let ipTriggers = [
        "http://110.242.68.66/",
        "http://180.101.50.242/",
        "http://1.1.1.1/",
    ]

    /// 锐捷认证页里常见的参数（用于从页面正文重建认证页 URL）。
    ///
    /// 注意 MAC 有两个常见写法：网关跳转 URL 里是 `mac`，部分门户页面里是
    /// `usermac`（全大写形式 `userMac` 也会被正则大小写不敏感地命中）。
    /// 两个都要收，否则「从页面正文重建」这条路会缺掉客户端身份参数。
    static let portalParamKeys = [
        "wlanuserip", "wlanacname", "nasip", "wlanacip", "mac", "usermac",
    ]

    /// 锐捷登录页里常见的标记，用于判断「门户是否仍要求登录」
    static let portalLoginMarkers = [
        "userId", "password", "登录", "logon", "InterFace.do?method=login",
        "wlanuserip", "eportal",
    ]

    /// 抓取 userIndex 失败时的「内容指纹」，用于给重复失败去重。
    /// 守护进程每轮都会尝试抓取，失败原因通常一模一样，没必要反复写日志。
    private static var lastCaptureMissFingerprint = ""

    // MARK: - 探测

    /// 探测网络状态。
    ///
    /// 只以「配置的探测地址」为准判定是否在线 —— 部分校园网在未认证时会对
    /// 其它探测域名放行，若把那些返回当作在线依据，就会漏掉认证。
    ///
    /// 判定顺序（顺序本身就是正确性的一部分，别调换）：
    ///   1. **先查有没有被门户劫持**：认证页 URL 要么在 `Location` 头（302 劫持），
    ///      要么嵌在正文的 JS/HTML 里。这一步必须排在最前 —— 否则普通网站的
    ///      200 正文会被当成「在线」，或反过来把认证页当成正常响应。
    ///   2. 3xx 且跳到**同站** ⇒ 在线（网站自己的正常跳转，如 baidu 的 http→https）。
    ///   3. 204 ⇒ 在线（传统 `generate_204` 型探针）。
    ///   4. 200 ⇒ 正文空则在线；有正文时要求命中 `probeContentMarker`。
    ///      默认探针是 `http://captive.apple.com/hotspot-detect.html`，
    ///      返回 **200 + 一句 Success**，靠这一步才能被认成「已在线」。
    ///
    /// - online = true：已联网，无需认证
    /// - online = false 且 portal 非空：已定位到认证页
    /// - online = false 且 portal 为空：未能判断（DNS / 连接失败 / 疑似被劫持），
    ///   调用方仍应尝试认证
    static func probe(_ config: AppConfig, timeout: TimeInterval = 6)
        -> (online: Bool, portal: String, detail: String) {

        let url = config.captiveURL.isEmpty
            ? AppConfig().captiveURL
            : config.captiveURL
        let response = HTTP.request(url, timeout: timeout)

        // 1) 被门户劫持的识别优先于一切状态码判断。
        let portal = extractPortal(body: response.text, location: response.location)
        if looksLikePortal(portal) {
            let status = response.status.map(String.init) ?? "?"
            return (false, portal, "\(url) → HTTP \(status)，检测到认证页")
        }

        // 2) 3xx 跳转：HTTP 层被刻意设成**不自动跳转**（不跳才能看见劫持的 302），
        //    所以这里得自己判断这次跳转正不正常。
        //
        //    实测踩到的坑：`http://www.baidu.com` 会 302 到 `https://www.baidu.com/`。
        //    若不处理，这个「正常网站的正常跳转」会掉进最后那条「未识别到认证页」，
        //    被判成「未联网」—— 于是每轮都白跑一轮认证。
        //    判据：跳到**同站**算正常；跳到别的站则多半是门户/中间设备插入的跳转。
        if let status = response.status, (300...399).contains(status),
           !response.location.isEmpty {
            if sameSite(url, response.location) {
                return (true, "", "\(url) → HTTP \(status) 跳转到同站，网络已在线")
            }
            return (false, "", "\(url) → HTTP \(status) 跳转到 \(response.location.prefix(80))，疑似被劫持，按未认证处理")
        }

        // 3) 204 空响应：传统 `generate_204` 探针的「网络正常」。
        if response.status == 204 {
            return (true, "", "\(url) → HTTP 204，网络正常")
        }

        // 4) 200 + 正文：默认探针 `http://captive.apple.com/hotspot-detect.html`
        //    （以及 baidu 这类）的正常形态。
        if response.status == 200 {
            let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                return (true, "", "\(url) → HTTP 200 空响应，网络正常")
            }
            if let marker = probeContentMarker(url),
               !text.lowercased().contains(marker.lowercased()) {
                // 200 但没有期望内容 ⇒ 多半是门户 / 中间设备塞了一张自有页面。
                // 宁可判成「未联网」去走一轮认证，也别漏掉认证。
                return (false, "", "\(url) → HTTP 200，但正文缺少「\(marker)」，疑似被劫持，按未认证处理")
            }
            return (true, "", "\(url) → HTTP 200 正文正常，网络已在线")
        }

        guard let status = response.status else {
            return (false, "", "\(url) → 连接失败（\(String(response.error.prefix(80)))）")
        }
        return (false, "", "\(url) → HTTP \(status)，未识别到认证页")
    }

    /// 探针地址对应的「期望正文标记」。命中才允许把 200 判成「已在线」。
    ///
    /// 为什么需要它：认证门户常会用一张**自有页面**（200）顶替被劫持的请求，
    /// 那张页面里未必引用 `index.jsp`，光靠「无认证页痕迹」会误判成在线、
    /// 从而彻底漏掉认证。要求正文里出现探针站点自己的特征串，可以挡住这类情况。
    ///
    /// 返回 nil 表示「不校验正文」—— 用户自定义的探测地址无法预知内容，
    /// 只能沿用「无认证页痕迹即在线」的宽松规则。
    static func probeContentMarker(_ url: String) -> String? {
        let lower = url.lowercased()
        // 默认探针：Apple 的捕获探测页，正文就一句 Success。
        // 它与 macOS 自带登录页（CNA）用的是**同一个地址** —— 我们判「在线」的口径
        // 因此和系统判据完全一致：只要这里看到 Success，系统那次探测也会通过，
        // 不会再弹出「系统默认登录页」。
        if lower.contains("apple.com") { return "Success" }
        if lower.contains("baidu.com") { return "baidu" }
        if lower.contains("msftconnecttest") { return "Microsoft Connect Test" }
        return nil
    }

    /// 两个 URL 是否属于「同一个站点」，用来判断 3xx 跳转是不是正常跳转。
    ///
    /// 只做轻量近似：主机名去掉 `www.` 前缀后，允许「一方是另一方的后缀」。
    /// 例：`www.baidu.com` ↔ `baidu.com` 同站；`www.baidu.com` → `172.16.100.201` 不同站。
    /// 门户劫持只会把请求带到门户 / 校园网地址，因此这条足以区分
    /// 「网站自己的正常跳转」与「被中间设备劫持的跳转」。
    static func sameSite(_ a: String, _ b: String) -> Bool {
        func host(_ url: String) -> String {
            var h = WebUtil.split(url).netloc.lowercased()
            if let at = h.firstIndex(of: "@") { h = String(h[h.index(after: at)...]) }
            if let colon = h.firstIndex(of: ":") { h = String(h[..<colon]) }
            return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        }
        let ha = host(a)
        let hb = host(b)
        guard !ha.isEmpty, !hb.isEmpty else { return false }
        return ha == hb || ha.hasSuffix("." + hb) || hb.hasSuffix("." + ha)
    }

    /// 兼容旧接口。返回 (state, portal, detail)，state ∈ online/offline/error。
    static func detect(_ config: AppConfig, timeout: TimeInterval = 8)
        -> (state: String, portal: String, detail: String) {
        let result = probe(config, timeout: timeout)
        if result.online { return ("online", "", result.detail) }
        if !result.portal.isEmpty { return ("offline", result.portal, result.detail) }
        return ("error", "", result.detail)
    }

    /// 按优先级返回要尝试的探针地址（去重）。
    static func probeURLs(_ config: AppConfig) -> [String] {
        var urls = [config.captiveURL.isEmpty ? AppConfig().captiveURL : config.captiveURL]
        urls.append(contentsOf: fallbackProbes)
        var seen = Set<String>()
        var result: [String] = []
        for url in urls where !url.isEmpty {
            if seen.insert(url).inserted { result.append(url) }
        }
        return result
    }

    // MARK: - 认证页定位

    /// 从跳转头或响应正文里找出认证页 URL（原脚本取正文里第一个引号链接）。
    static func extractPortal(body: String, location: String) -> String {
        var candidates: [String] = []
        if !location.isEmpty { candidates.append(location) }
        candidates.append(contentsOf: Regex.allGroups(#"['"](https?://[^'"]+)['"]"#, in: body))
        for url in candidates where looksLikePortal(url) { return url }
        return candidates.first ?? ""
    }

    /// 判断一个 URL 是否像锐捷认证页（而非页面里的普通链接）。
    static func looksLikePortal(_ url: String) -> Bool {
        guard !url.isEmpty else { return false }
        return url.contains("index.jsp") || url.contains("InterFace.do")
    }

    /// 从认证页 HTML/JS 里提取锐捷参数（wlanuserip/wlanacname/nasip 等）。
    ///
    /// 未认证时 portal 服务器经常把本机 IP、AC 名、NAS IP 直接写进页面
    /// （隐藏表单域或 JS 变量），拿到这些就能拼出完整的 index.jsp 认证地址，
    /// 从而不依赖路由器的拦截跳转。
    static func scrapePortalParams(_ body: String) -> [String: String] {
        guard !body.isEmpty else { return [:] }
        var params: [String: String] = [:]
        for key in portalParamKeys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            // 1) <input ... name="wlanuserip" value="...">
            var value = Regex.firstGroup(
                "name=[\"']\(escaped)[\"'][^>]*?value=[\"']([^\"']*)[\"']",
                in: body, options: [.caseInsensitive])
            // 2) wlanuserip = "..." 或 wlanuserip:"..."（JS 赋值）
            //
            // 前置 `(?<![A-Za-z0-9_])` 是必须的：没有它，短键 `mac` 会匹配到
            // `apmac = "..."` / `usermac = "..."` 里 "mac" 那一段，
            // 从而把 AP 的 MAC 当成客户端 MAC 写进认证地址（登录必失败）。
            if value == nil {
                value = Regex.firstGroup(
                    "(?<![A-Za-z0-9_])\(escaped)\\s*[=:]\\s*[\"']([^\"']+)[\"']",
                    in: body, options: [.caseInsensitive])
            }
            if let value, !value.trimmingCharacters(in: .whitespaces).isEmpty {
                params[key] = value.trimmingCharacters(in: .whitespaces)
            }
        }
        return params
    }

    /// 用抓取到的参数拼出 index.jsp 认证地址。
    static func reconstructPortal(netloc: String, params: [String: String]) -> String {
        let pairs = portalParamKeys.compactMap { key -> (String, String)? in
            guard let value = params[key] else { return nil }
            return (key, value)
        }
        return "http://\(netloc)/eportal/index.jsp?\(WebUtil.formEncode(pairs))"
    }

    /// 在探针未直接给出认证页时，多路尝试定位认证页地址。
    ///
    /// 依次尝试：常规探针 → IP 直连触发（绕开 DNS）→ 门户地址线索（根路径会
    /// 自动追到 /eportal/index.jsp 并抓取页面里的 wlanuserip/wlanacname/nasip
    /// 参数重建）→ 用上次成功认证的参数重建。
    static func discover(_ config: AppConfig, timeout: TimeInterval = 5,
                         skipProbes: Bool = false) -> (portal: String, source: String) {
        var tried: [String] = []

        /// 对某个地址尝试：直接识别认证页 / 抓取参数重建 / 追到 index.jsp。
        func learn(_ url: String) -> String {
            let response = HTTP.request(url, timeout: timeout)
            guard response.status != nil else { return "" }

            let portal = extractPortal(body: response.text, location: response.location)
            if looksLikePortal(portal) { return portal }

            // 从页面正文抓取锐捷参数重建认证页（断网时路由器未做跳转也能用）
            let params = scrapePortalParams(response.text)
            let netloc = WebUtil.split(url).netloc
            if !params.isEmpty, !netloc.isEmpty {
                let rebuilt = reconstructPortal(netloc: netloc, params: params)
                cachePortal(rebuilt)
                return rebuilt
            }

            // 根路径或未知页：再追一层 /eportal/index.jsp（锐捷常用入口）
            guard !netloc.isEmpty else { return "" }
            let index = "http://\(netloc)/eportal/index.jsp"
            let second = HTTP.request(index, timeout: timeout)
            guard second.status != nil else { return "" }
            let secondParams = scrapePortalParams(second.text)
            if !secondParams.isEmpty {
                let rebuilt = reconstructPortal(netloc: netloc, params: secondParams)
                cachePortal(rebuilt)
                return rebuilt
            }
            let secondPortal = extractPortal(body: second.text, location: second.location)
            return looksLikePortal(secondPortal) ? secondPortal : ""
        }

        func attempt(_ url: String, label: String) -> String {
            let found = learn(url)
            if found.isEmpty { tried.append("\(label)：未识别到认证页") }
            return found
        }

        if !skipProbes {
            for url in probeURLs(config) {
                let found = attempt(url, label: url)
                if !found.isEmpty { return (found, "来自探针 \(url)") }
            }
            // IP 直连触发（绕开 DNS）也属于「主动探测」，必须同样受 skipProbes 约束。
            //
            // 曾经的 bug：这一层没被包进 `if !skipProbes`，于是调用方明确说
            // 「别探测了，用缓存」时，仍然会逐个去连这 3 个 IP；而它们在未认证
            // 网络里通常是被黑洞掉的，每个都要等满 `timeoutIntervalForRequest`，
            // 一轮白白烧掉 45~60 秒 —— 正好把「抢在系统登录页之前认证」的窗口用完。
            // 实测：探测在 15:54:59 完成，直到 15:56:00 才发出登录请求。
            for url in ipTriggers {
                let found = attempt(url, label: url)
                if !found.isEmpty { return (found, "来自 IP 直连 \(url)") }
            }
        }
        let hint = config.portalHint.trimmingCharacters(in: .whitespaces)
        if !hint.isEmpty {
            let found = attempt(hint, label: hint)
            if !found.isEmpty { return (found, "来自门户线索 \(hint)") }
        }
        let rebuilt = cachedPortal()
        if !rebuilt.isEmpty { return (rebuilt, "由上次成功认证的参数重建") }

        return ("", tried.joined(separator: "；"))
    }

    /// 在线时也尝试预学习门户地址并写入缓存，供断线后重建。
    ///
    /// 这是「用户当前在线、无法复现 captive 页面」场景下的兜底：趁着门户服务器
    /// 可达，先把 wlanacname/nasip 等固定参数存下来，下次断网就能直接复用。
    static func learnPortalWhileOnline(_ config: AppConfig, timeout: TimeInterval = 5) -> String {
        var cached = cachedPortal()
        if cached.isEmpty {
            let hint = config.portalHint.trimmingCharacters(in: .whitespaces)
            if !hint.isEmpty {
                let found = discover(config, timeout: timeout, skipProbes: true)
                if !found.portal.isEmpty { cached = found.portal }
            }
        }
        guard !cached.isEmpty else { return "" }

        // 本机读不到网卡 MAC 时（受限执行环境，见 localMac 注释），趁门户可达，
        // 用门户口径回传的 `userMac` 回填缓存：那是门户**实际绑定**的设备身份，
        // 比缓存里那个可能已经过期的值可信。这样缓存会自我修复 ——
        // 下次断网重建认证地址时，用的就是门户认得的那台设备。
        if localMac().isEmpty {
            let authoritative = portalBoundMac(config, timeout: timeout)
            if !authoritative.isEmpty {
                cached = settingQuery(cached, key: "mac", value: authoritative)
                Log.write("本机无法读取网卡 MAC，已按门户口径回填 \(authoritative)")
            }
        }
        cachePortal(cached)
        return cached
    }

    /// 交叉校验：探测域名若被放行（误判在线），直接问门户是否还需登录。
    static func portalNeedsLogin(_ config: AppConfig, timeout: TimeInterval = 5) -> Bool {
        let hint = config.portalHint.trimmingCharacters(in: .whitespaces)
        guard !hint.isEmpty else { return false }
        let response = HTTP.request(hint, timeout: timeout)
        guard response.status != nil else { return false }

        // 已认证时门户通常 302 跳到 success 页，或正文含「已登录/成功」
        let location = response.location.lowercased()
        if location.contains("success") || location.contains("already")
            || location.contains("online") {
            return false
        }
        let lower = response.text.lowercased()
        return portalLoginMarkers.contains { lower.contains($0.lowercased()) }
    }

    // MARK: - 登录 / 下线

    /// 向锐捷 eportal 提交登录。返回 (success, message)。
    static func login(portalURL: String, username: String, password: String,
                      timeout: TimeInterval = 12) -> (Bool, String) {
        let parts = WebUtil.split(portalURL)
        var path = parts.path.isEmpty ? "/" : parts.path
        if path.contains("index.jsp") {
            path = path.replacingOccurrences(of: "index.jsp", with: "InterFace.do")
        } else if !path.contains("InterFace.do") {
            path = "/eportal/InterFace.do"
        }
        let loginURL = "\(parts.scheme)://\(parts.netloc)\(path)?method=login"

        // 与原脚本一致：query 做二次 URL 编码后放进 queryString
        let doubled = WebUtil.quote(WebUtil.quote(parts.query))
        let form = [
            "userId=" + WebUtil.quote(username),
            "password=" + WebUtil.quote(password),
            "service=",
            "queryString=" + doubled,
            "operatorPwd=",
            "operatorUserId=",
            "validcode=",
            "passwordEncrypt=false",
        ].joined(separator: "&")

        let response = HTTP.post(loginURL, form: form, headers: [
            "Referer": portalURL,
            "Cookie": "EPORTAL_COOKIE_USERNAME=; EPORTAL_COOKIE_PASSWORD=;",
        ], timeout: timeout)

        guard let status = response.status else {
            return (false, "登录请求失败：\(response.error)")
        }
        guard let payload = tryJSON(response.text) else {
            return (false, "响应无法解析(HTTP \(status))：\(String(response.text.prefix(160)))")
        }

        // 记录会话标识 userIndex，供「手动下线」使用（响应未直接给则尝试从正文提取）
        var userIndex = JSONValue.string(payload["userIndex"])
        if userIndex.isEmpty {
            userIndex = Regex.firstGroup("userIndex=([^&\\s\"'<>]+)", in: response.text) ?? ""
        }
        if !userIndex.isEmpty {
            let decoded = WebUtil.unquote(userIndex).trimmingCharacters(in: .whitespaces)
            if !decoded.isEmpty { saveSessionUserIndex(decoded) }
        }

        let result = JSONValue.string(payload["result"]).trimmingCharacters(in: .whitespaces).lowercased()
        let rawMessage = JSONValue.string(payload["message"])
        let message = rawMessage.isEmpty ? JSONValue.string(payload["msg"]) : rawMessage

        if result == "success" { return (true, message.isEmpty ? "认证成功" : message) }
        // 门户以「目标状态已达成」为语义回复的几种说法，都应算成功而不是失败。
        // 实测：设备已有会话时锐捷会返回
        // `{"result":"fail","message":"当前设备已存在在线用户!"}` ——
        // 注意它里面**没有**「已在线」三个连续字（是「已存在在线用户」），
        // 用松散的 contains("已在线") 匹配会漏掉，从而把「本来就是通的」报成 ❌，
        // 用户看到的就是「登录功能坏了」。
        let alreadyOnlineMarkers = [
            "已在线", "已经在线", "已存在在线用户", "无需重复登录", "重复登录",
        ]
        if alreadyOnlineMarkers.contains(where: { message.contains($0) }) {
            return (true, message)
        }
        return (false, message.isEmpty ? "认证失败(HTTP \(status))" : message)
    }

    /// 手动下线（注销当前锐捷会话）。返回 (success, message)。
    ///
    /// 关键点：锐捷下线接口 `InterFace.do?method=logout` 必须带**会话标识
    /// userIndex**，而该值只有「本次会话确实由认证页建立」时才拿得到。
    /// 若校园网启用了无感知认证（按设备 MAC 自动放行），门户侧没有交互式会话，
    /// 注销请求不会立刻断网 —— 所以这里在下线后追加一次连通性复检，
    /// 把「门户接受了注销，但网络仍可访问」这个真实结论如实写进日志与提示，
    /// 而不是简单报「成功」或「失败」。
    static func logout(_ config: AppConfig, timeout: TimeInterval = 12) -> (Bool, String) {
        let host = portalNetloc(config)
        guard !host.isEmpty else {
            let message = "无法确定认证门户地址，请在「高级设置 → 认证门户」中填写。"
            Log.write("手动下线失败：\(message)", level: "WARN")
            return (false, message)
        }

        Log.write("手动下线：门户=\(host)")

        // 第一顺位（权威）：问门户口径 getOnlineUserInfo。
        // 注意：本地缓存的 userIndex 不可信 —— 它可能来自上一轮早已失效的会话。
        // 若拿旧值直接去注销，门户会回「用户已不在线」，从而被误报成「下线失败」。
        // 因此一律先以门户口径为准，缓存只在门户联系不上时才兜底。
        let (portalIndex, portalNote) = fetchOnlineUserIndex(config, timeout: timeout)
        let portalUnreachable = portalNote.hasPrefix("门户不可达")
        var userIndex = portalIndex
        if !userIndex.isEmpty {
            Log.write("手动下线：门户口径返回会话 userIndex=\(portalIndex)，直接使用")
        }

        // 第二顺位：门户跳转兜底（部分门户未实现 getOnlineUserInfo）。
        if userIndex.isEmpty && !portalUnreachable {
            userIndex = captureUserIndexIfOnline(config, timeout: timeout)
            if !userIndex.isEmpty {
                Log.write("手动下线：改由门户跳转抓到 userIndex=\(userIndex)")
            }
        }

        // 第三顺位：本地缓存（可能是本软件此前登录留下的）。仅在门户联系不上时使用，
        // 因为此时无从判断缓存是否已失效，只能尽力一试。
        if userIndex.isEmpty && portalUnreachable {
            userIndex = loadSessionUserIndex()
            if !userIndex.isEmpty {
                Log.write("手动下线：门户不可达，改用本地缓存 userIndex 尝试注销")
            }
        }

        guard !userIndex.isEmpty else {
            if portalUnreachable {
                let message = "无法联系认证门户（\(host)）确认会话状态：\(portalNote)\n"
                    + "请确认当前处于校园网环境后重试。"
                Log.write("手动下线失败：\(message)", level: "WARN")
                return (false, message)
            }
            // 门户可达、且明确表示没有会话。这**不是故障**：
            // 校园网侧「免认证 / MAC 白名单（无感知认证）」会让设备无会话直通，
            // 门户注销无从下手。如实说明，不要报「失败」误导用户。
            clearSessionUserIndex()
            let message = "门户（\(host)）侧没有你的在线会话，因此无需下线。\n\n"
                + "你的网络很可能由校园网侧「免认证 / MAC 白名单（无感知认证）」放行，"
                + "这种情况门户注销无法断开网络。\n"
                + "如需断网，请在系统 Wi-Fi 菜单里断开该网络，或改用有线 / 热点。"
            Log.write("手动下线：门户口径确认本机无在线会话"
                + "（\(portalNote.isEmpty ? "无会话" : portalNote)），无需注销")
            return (true, message)
        }

        let url = "http://\(host)/eportal/InterFace.do?method=logout"
        let form = "userIndex=" + WebUtil.quote(userIndex)
        let response = HTTP.post(url, form: form, headers: [
            "Referer": "http://\(host)/eportal/success.jsp",
            "Cookie": "EPORTAL_COOKIE_USERNAME=; EPORTAL_COOKIE_PASSWORD=;",
        ], timeout: timeout)

        guard let status = response.status else {
            let message = "下线请求失败：\(response.error)"
            Log.write("手动下线失败：\(message)", level: "WARN")
            return (false, message)
        }

        let body = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.write("手动下线：HTTP \(status) 响应=\(String(body.prefix(200)))")

        // 判定门户是否接受了注销
        var succeeded = false
        // 门户反馈「该会话本就不存在」（如「用户已不在线」「用户可能已经下线」）。
        // 目标状态（未登录）已达成，属正常结果，不应报成「下线失败」。
        var alreadyOffline = false
        var message = ""
        if let payload = tryJSON(response.text) {
            let result = JSONValue.string(payload["result"])
                .trimmingCharacters(in: .whitespaces).lowercased()
            let rawMessage = JSONValue.string(payload["message"])
            message = rawMessage.isEmpty ? JSONValue.string(payload["msg"]) : rawMessage
            if message.contains("不在线") || message.contains("已经下线")
                || message.contains("已下线") {
                alreadyOffline = true
            } else if ["success", "logout"].contains(result)
                || message.contains("成功") || message.contains("下线") {
                succeeded = true
            }
        }
        if alreadyOffline {
            clearSessionUserIndex()
            let note = message.isEmpty ? "会话已不存在" : message
            let finalMessage = "门户（\(host)）侧该会话已不存在（\(note)），无需重复下线。\n\n"
                + "如需断网，请在系统 Wi-Fi 菜单里断开该网络，或改用有线 / 热点。"
            Log.write("手动下线：会话已不存在（\(note)），无需重复注销")
            if config.notify {
                Notifier.notify(title: AppPaths.appTitle, message: "会话已不存在（无需下线）")
            }
            return (true, finalMessage)
        }
        if !succeeded {
            let lower = body.lowercased()
            if lower.contains("success") || body.contains("下线") || body.contains("成功") {
                succeeded = true
                message = "已下线成功"
            }
        }
        guard succeeded else {
            let text = message.isEmpty ? String(body.prefix(160)) : message
            Log.write("手动下线失败：HTTP \(status) \(text)", level: "WARN")
            return (false, "下线失败(HTTP \(status))：\(text)")
        }

        clearSessionUserIndex()

        // 复检：门户说注销成功，但「无感知认证 / MAC 绑定」的网络会立刻重新放行，
        // 用户主观感受就是「下线没生效、始终能上网」。这里如实标注。
        let stillOnline = probe(config, timeout: 4).online
        var finalMessage = message.isEmpty ? "已下线成功" : message
        if stillOnline {
            finalMessage += "\n\n注意：注销请求已被门户接受，但复检显示网络仍可访问。"
                + "这通常意味着该网络启用了无感知认证（按设备 MAC 自动放行），"
                + "门户注销不会立即断网。"
            Log.write("手动下线：门户已接受注销，但复检仍在线（疑似无感知认证）", level: "WARN")
        } else {
            Log.write("手动下线成功：\(finalMessage)")
        }

        if config.notify {
            Notifier.notify(title: AppPaths.appTitle,
                            message: stillOnline ? "已提交下线（网络仍可访问）" : "已手动下线")
        }
        return (true, finalMessage)
    }

    /// 执行一轮「探测 + 必要时认证」。
    ///
    /// - Returns: (ok, message, needAuth)，needAuth 表示本轮确实发起了认证请求。
    ///
    /// 与原脚本的关键差别：探测失败（DNS 不通、连接超时）不再直接放弃，
    /// 而是继续尝试定位认证页并登录 —— 这正是「断网后浏览器弹出认证页、
    /// 自动认证却没反应」的根因。
    static func authenticate(_ config: AppConfig) -> (ok: Bool, message: String, attempted: Bool) {
        let username = config.username
        guard !username.isEmpty else { return (false, "尚未配置账号", false) }

        let probed = probe(config)
        if probed.online {
            return (true, "网络已在线，无需认证（\(probed.detail)）", false)
        }

        // 探测失败、又没能识别出认证页时，先确认「认证门户到底通不通」。
        //
        // 不通 = 链路还没就绪（Wi-Fi 刚关联、DHCP 还没下来、或改 MAC 后正在重连）。
        // 此时若照样往下走，多路探测（IP 直连 / 门户线索 / 缓存重建）每一条都要等满
        // 超时，再叠上登录请求与两次重试，**一轮能吃掉 30~60 秒**；而这段时间恰好就是
        // 链路恢复的窗口 —— 等本工具转完一圈回来，macOS 的系统登录页（CNA）或网关的
        // 无感知认证早把网认证掉了。用户看到的就是「后台服务没能完成重新认证」。
        //
        // 实测证据（2026-09-24 15:09~15:10）：链路不可用期间连续两轮探针超时，
        // 一轮用陈旧缓存重建的登录请求挂死后进程被重启，等下一轮探针回来时
        // 网络已由系统侧认证完毕（门户口径 userUrl 是 captive.apple.com）。
        //
        // 改为快速返回（attempted=false）：守护进程安静等链路事件，PathMonitor 一
        // 唤醒就重新探测，链路一就绪立刻探测到认证页并登录。
        if probed.portal.isEmpty, !campusPortalReachable(config) {
            let detail = probed.detail.isEmpty ? "探针未通过" : probed.detail
            Log.writeThrottled(
                "链路尚未就绪（\(detail)，且认证门户不可达），本轮不发起认证，等链路恢复后自动重试",
                tag: "link-not-ready", window: 60)
            return (false, "链路尚未就绪（认证门户不可达），等待链路恢复", false)
        }

        let password = Keychain.password(username: username)
        guard !password.isEmpty else {
            return (false, "钥匙串中没有该账号的密码，请重新保存设置", false)
        }

        var portal = probed.portal
        var source = "探测直接识别"
        if !looksLikePortal(portal) {
            let discovered = discover(config, skipProbes: true)
            portal = discovered.portal
            source = discovered.source
        }
        guard !portal.isEmpty else {
            return (false, "未能定位认证页地址（\(source.isEmpty ? probed.detail : source)）", false)
        }

        Log.write("尝试认证：认证页=\(portal)（\(source)）")
        let (ok, message) = login(portalURL: portal, username: username, password: password)
        if ok {
            cachePortal(portal)
            // 顺手抓取 userIndex（已在线时门户会 302 到 success.jsp?userIndex=...）
            _ = captureUserIndexIfOnline(config)
        }
        return (ok, message, true)
    }

    static func authenticateOnce(_ config: AppConfig) -> (Bool, String) {
        let result = authenticate(config)
        return (result.ok, result.message)
    }

    // MARK: - 门户缓存 / 会话标识

    /// 记录一次成功认证所用的门户主机与参数，供网络异常时重建。
    static func cachePortal(_ portalURL: String) {
        let parts = WebUtil.split(portalURL)
        let params = WebUtil.queryDictionary(parts.query)
        guard !parts.netloc.isEmpty, !params.isEmpty else { return }
        AppPaths.ensureSupportDir()
        let payload: [String: Any] = [
            "netloc": parts.netloc,
            "path": parts.path,
            "params": params,
            "saved_at": timestamp(),
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted]) else { return }
        AppConfig.writeAtomically(data, to: AppPaths.portalCachePath)
    }

    /// 由上次成功认证的参数重建的认证页地址（无缓存时返回空串）。
    static func cachedPortal() -> String {
        guard let data = FileManager.default.contents(atPath: AppPaths.portalCachePath),
              let object = try? JSONSerialization.jsonObject(with: data),
              let cached = object as? [String: Any] else { return "" }

        let netloc = JSONValue.string(cached["netloc"])
        var params = (cached["params"] as? [String: Any]) ?? [:]
        guard !netloc.isEmpty, !params.isEmpty else { return "" }

        // 缓存里只有 `wlanacname` / `nasip` / `ssid` / `t` 这类**网络侧参数**是长期
        // 有效的；`wlanuserip` 与 `mac` 描述的是**这台机器此刻的身份**，必须每次用
        // 实时值覆盖：
        //   - 换网络 / 重连 DHCP 会换 IP；
        //   - macOS「私有 Wi-Fi 地址」默认**轮替**随机 MAC，用户一旦把它关闭
        //     （或换网络），网卡 MAC 就变了。
        // 缓存里留着旧身份，门户会按一台并不存在的设备去放行，登录必然失败，
        // 而日志里看不到任何门户侧报错 —— 表现为「网络明明是通的，本软件就是登不上」。
        // 实测踩到：用户把「私有 Wi-Fi 地址」关掉、MAC 由随机 `f64e6ff66c4e`
        // 变成固定 `6c7e67c15c09` 之后，缓存里那条 mac 一直没跟着更新。
        if params["wlanuserip"] != nil {
            let ip = localIP()
            if !ip.isEmpty { params["wlanuserip"] = ip }
        }
        let mac = localMac()
        if !mac.isEmpty {
            var corrected = false
            for key in ["mac", "usermac"] where params[key] != nil {
                if JSONValue.string(params[key]).lowercased() != mac { corrected = true }
                params[key] = mac
            }
            if corrected {
                // 只在真的发生更正时记一条，避免每轮刷日志
                Log.write("门户缓存中的客户端 MAC 与本机不一致，已按当前网卡 MAC \(mac) 更正")
            }
        } else {
            // 本机读不到网卡 MAC（受限执行环境的典型表现，见 localMac 注释）。
            // 这里**保留**缓存里的旧值而不是删掉：实测锐捷门户并不校验 mac 参数
            // （带旧值 / 带真值 / 完全不带，响应完全一致），真正决定绑定的是源 IP；
            // 去掉反而可能在某些门户实现上被判「参数不完整」。
            // 但这件事必须在日志里可见，否则又会退化成「网络明明是通的、
            // 本工具就是登不上」这种无从下手的故障。
            Log.writeThrottled(
                "本机读不到网卡 MAC（当前执行环境屏蔽了链路层地址），"
                + "重建认证地址时沿用缓存中的 \(JSONValue.string(params["mac"]))",
                tag: "mac-unreadable")
        }

        var path = JSONValue.string(cached["path"])
        if !path.contains("index.jsp") { path = "/eportal/index.jsp" }

        let pairs = params.map { (key: $0.key, value: JSONValue.string($0.value)) }
        return "http://\(netloc)\(path)?\(WebUtil.formEncode(pairs))"
    }

    /// 返回认证门户主机（优先用缓存的门户，其次门户线索地址）。
    static func portalNetloc(_ config: AppConfig) -> String {
        let cached = cachedPortal()
        if !cached.isEmpty {
            let netloc = WebUtil.split(cached).netloc
            if !netloc.isEmpty { return netloc }
        }
        let hint = config.portalHint.trimmingCharacters(in: .whitespaces)
        return WebUtil.split(hint.isEmpty ? AppConfig().portalHint : hint).netloc
    }

    /// 门户页面是否处于「学校侧异常」状态。
    ///
    /// 实测见过的一种：`/eportal/index.jsp` 不再返回登录页，而是返回
    /// `<script>alert('WEB认证设备未注册，请确认SAM+/portal/设备上的参数配置是否一致');</script>`。
    /// 这属于学校认证设备（SAM+ / portal 对接参数）的配置问题，
    /// 与本软件无关，但会让「抓 userIndex」「打开认证页」全部失效，
    /// 因此单独识别出来，避免笼统地报成「未含 userIndex」误导排查方向。
    static func portalPageIsAbnormal(_ text: String) -> Bool {
        let lower = text.lowercased()
        if lower.contains("<script>alert(") && lower.contains("未注册") { return true }
        return text.contains("WEB认证设备未注册")
    }

    /// 向门户口径查询「本机当前的在线会话」，返回 (userIndex, 门户说明)。
    ///
    /// 锐捷 `InterFace.do?method=getOnlineUserInfo` 会直接给出当前会话的
    /// userIndex；门户侧没有会话时返回
    /// `{"userIndex":null,"result":"fail","message":"获取用户信息失败，用户可能已经下线"}`。
    /// 这是判断「到底有没有会话可下线」最权威的一手信息，比解析 index.jsp
    /// 跳转可靠得多（后者在门户页面异常时完全拿不到线索）。
    /// userIndex 为空 = 门户侧确认没有会话。
    static func fetchOnlineUserIndex(_ config: AppConfig,
                                    timeout: TimeInterval = 6) -> (String, String) {
        let host = portalNetloc(config)
        guard !host.isEmpty else { return ("", "门户地址未确定") }
        let url = "http://\(host)/eportal/InterFace.do?method=getOnlineUserInfo"
        let response = HTTP.request(url, timeout: timeout)
        guard response.status != nil else {
            return ("", "门户不可达（\(String(response.error.prefix(60)))）")
        }

        let payload = tryJSON(response.text)
        let index = JSONValue.string(payload?["userIndex"]).trimmingCharacters(in: .whitespaces)
        var message = JSONValue.string(payload?["message"])
        if message.isEmpty { message = JSONValue.string(payload?["msg"]) }

        if !index.isEmpty {
            saveSessionUserIndex(index)
            return (index, message)
        }
        let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ("", message.isEmpty ? String(trimmed.prefix(120)) : message)
    }

    /// 已在线时访问门户入口，门户会 302 跳到 success.jsp?userIndex=...，借此拿到会话标识。
    @discardableResult
    static func captureUserIndexIfOnline(_ config: AppConfig, timeout: TimeInterval = 8) -> String {
        let host = portalNetloc(config)
        guard !host.isEmpty else {
            Log.write("抓取 userIndex：门户地址未知，跳过")
            return ""
        }
        let entry = "http://\(host)/eportal/index.jsp"
        let response = HTTP.request(entry, timeout: timeout)
        guard response.status != nil else {
            Log.write("抓取 userIndex：\(entry) 连接失败（\(String(response.error.prefix(80)))）")
            return ""
        }

        let haystack = response.location.isEmpty ? response.text : response.location
        guard let raw = Regex.firstGroup("userIndex=([^&\\s\"'<>]+)", in: haystack) else {
            // 失败很常见（门户口径无会话 / 门户页面异常 / 该门户不是本网段的认证设备），
            // 且守护进程会周期性重试，因此这里按「内容指纹」去重：
            // 同样的失败只记一次，避免每轮都往日志里灌一段 HTML 片段。
            let fingerprint = "\(response.status ?? -1)|\(haystack.prefix(120))"
            guard fingerprint != lastCaptureMissFingerprint else { return "" }
            lastCaptureMissFingerprint = fingerprint

            if portalPageIsAbnormal(haystack) {
                Log.write("抓取 userIndex：门户认证页异常（学校侧配置问题，非本软件故障），"
                    + "\(entry) 返回：\(String(haystack.prefix(90)))")
            } else {
                Log.write("抓取 userIndex：\(entry) 返回 HTTP \(response.status ?? -1)，未含 userIndex"
                    + "（响应片段：\(String(haystack.prefix(80)))）")
            }
            return ""
        }
        lastCaptureMissFingerprint = ""
        let value = WebUtil.unquote(raw).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return "" }
        saveSessionUserIndex(value)
        return value
    }

    /// 记录本次登录得到的 userIndex（锐捷会话标识），供「手动下线」使用。
    static func saveSessionUserIndex(_ userIndex: String) {
        guard !userIndex.isEmpty else { return }
        AppPaths.ensureSupportDir()
        let payload: [String: Any] = ["userIndex": userIndex, "saved_at": timestamp()]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted]) else { return }
        AppConfig.writeAtomically(data, to: AppPaths.sessionPath)
        Log.write("已记录会话标识 userIndex（手动下线可用）")
    }

    static func loadSessionUserIndex() -> String {
        guard let data = FileManager.default.contents(atPath: AppPaths.sessionPath),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return "" }
        return JSONValue.string(dict["userIndex"])
    }

    static func clearSessionUserIndex() {
        try? FileManager.default.removeItem(atPath: AppPaths.sessionPath)
    }

    // MARK: - WiFi / 本机地址

    /// 返回当前 WiFi 的 SSID；没有 WiFi 连接或无法读取时返回空串。
    ///
    /// 依次尝试 en0/en1/en2（不同 Mac 上 WiFi 接口名不同），用 networksetup 读取。
    /// 未关联到任何 WiFi（如接以太网 / 飞行模式）时返回空串。
    ///
    /// 注意：networksetup 的输出会跟随系统语言本地化，因此这里强制 `LC_ALL=C`
    /// 以稳定拿到英文输出，同时仍兼容中文/英文两种标记，双保险。
    static func currentWifiSSID() -> String {
        let markers = [
            "Current Wi-Fi Network:",
            "Wi-Fi 网络:",
            "Wi-Fi 网络：",
            "无线网络:",
            "无线网络：",
        ]
        for interface in ["en0", "en1", "en2"] {
            let result = Shell.capture("/usr/sbin/networksetup",
                                       ["-getairportnetwork", interface],
                                       env: environmentWithCLocale(), timeout: 5)
            let output = result.out.isEmpty ? result.err : result.out
            let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
            for marker in markers {
                if let range = text.range(of: marker) {
                    let ssid = String(text[range.upperBound...])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !ssid.isEmpty { return ssid }
                }
            }
            // 该接口不是 WiFi 或没有关联网络：尝试下一个接口
        }
        return ""
    }

    /// 当前是否连接在名称含 syny 的 WiFi 上（大小写不敏感）。
    ///
    /// 注意：读不到 SSID 时这里恒为 false，**不能**用它单独判断「是否在校园网」——
    /// macOS 13 起未获「定位服务」授权的进程一律拿不到 SSID（见 `wifiStatus()`），
    /// 校园网判定请用 `evaluateCampusAccess(_:)`。
    static func wifiIsSyny() -> Bool {
        let ssid = currentWifiSSID()
        guard !ssid.isEmpty else { return false }
        return ssid.lowercased().contains("syny")
    }

    // MARK: - 校园网判定
    //
    // 背景：macOS 13 起，**未获「定位服务」授权的进程读不到 SSID**——
    //   CoreWLAN 的 `CWWiFiClient.shared().interface().ssid()` 返回 nil，
    //   `networksetup -getairportnetwork en0` 退化成
    //   「You are not associated with an AirPort network」，
    //   `ipconfig getsummary` / `system_profiler` 里的网络名显示为 <redacted>。
    //   实测 macOS 27.0 依然如此，且 ad-hoc 签名每次重编译都会重置授权，
    //   所以不能把「能读到 SSID」当作前提。
    //
    // 对策：SSID 读得到就按原语义匹配；读不到时降级为「校园门户是否可达」——
    //   门户是内网地址（如 172.16.100.201），只有身处校园网才连得上。
    //   用**纯 TCP 连接**而非 HTTP：既不会触发 captive 弹窗，
    //   也不经过系统代理，判定结果不会被 VPN/代理污染。

    /// 无线网卡状态（供诊断与降级判定使用）。
    struct WifiStatus {
        var ssid = ""
        var interfaceName = ""
        var hasWifiInterface = false     // 本机存在 Wi-Fi 硬件端口
        var wifiHasAddress = false       // 该接口已拿到 IPv4，即已连上某个网络

        /// 已连上 Wi-Fi，但系统不允许我们读取网络名（缺定位授权）。
        var nameIsRedacted: Bool {
            hasWifiInterface && wifiHasAddress && ssid.isEmpty
        }

        /// 给人看的一句话描述。
        var summary: String {
            if !ssid.isEmpty { return ssid }
            if nameIsRedacted { return "(已连接，但系统未授权读取网络名)" }
            if hasWifiInterface { return "(未连接 Wi-Fi)" }
            return "(无无线网卡)"
        }
    }

    /// 采集无线网卡状态。
    static func wifiStatus() -> WifiStatus {
        var status = WifiStatus()
        status.ssid = currentWifiSSID()

        if let device = wifiHardwareDevice() {
            status.interfaceName = device
            status.hasWifiInterface = true
            status.wifiHasAddress = interfaceHasIPv4(device)
        } else {
            // 解析失败时退回最常见的接口名（Apple Silicon 与多数 Intel Mac 都是 en0）
            status.interfaceName = "en0"
            for candidate in ["en0", "en1", "en2"] where interfaceHasIPv4(candidate) {
                status.hasWifiInterface = true
                status.wifiHasAddress = true
                status.interfaceName = candidate
                break
            }
        }
        return status
    }

    /// 校园网判定结论。关联值是判定依据，直接写进日志便于排查。
    enum CampusVerdict {
        case onCampus(String)
        case offCampus(String)

        var isOnCampus: Bool {
            if case .onCampus = self { return true }
            return false
        }

        var reason: String {
            switch self {
            case .onCampus(let reason), .offCampus(let reason): return reason
            }
        }
    }

    /// 判断「现在是否处于校园网」。
    static func evaluateCampusAccess(_ config: AppConfig) -> CampusVerdict {
        let wifi = wifiStatus()

        // 判据一：SSID 能读到且名称含 syny —— 最快，不必再探门户。
        if !wifi.ssid.isEmpty, wifi.ssid.lowercased().contains("syny") {
            return .onCampus("WiFi「\(wifi.ssid)」名称含 syny")
        }

        // 判据二（主判据）：校园门户是否可达。
        //   - SSID 不可读（macOS 未授予定位权限，本机常态）时，这是唯一可用的判据；
        //   - SSID 可读但名称不含 syny 时**也不能**就此断定「不在校园网」：
        //     校内 SSID 未必叫 syny，只看名字会把「在校内网但不叫 syny」误判成
        //     「不在校园网」从而拒绝认证。所以名字只用来「认定在校」，不再用来「否认」。
        let host = portalHost(config)
        let reachable = campusPortalReachable(config)
        let situation = wifi.ssid.isEmpty
            ? (wifi.nameIsRedacted ? "WiFi 名称不可读" : "未连接 Wi-Fi")
            : "WiFi「\(wifi.ssid)」名称不含 syny"
        if reachable {
            return .onCampus("校园门户 \(host ?? "?") 可达（\(situation)）")
        }
        return .offCampus("\(situation)，且校园门户 \(host ?? "?") 不可达")
    }

    /// 从配置的「认证门户」里取出主机名（用作校园网可达性判据）。
    static func portalHost(_ config: AppConfig) -> String? {
        guard let url = URL(string: config.portalHint), let host = url.host,
              !host.isEmpty else { return nil }
        return host
    }

    private static func portalPort(_ config: AppConfig) -> UInt16 {
        guard let url = URL(string: config.portalHint), let port = url.port,
              (1...65535).contains(port) else { return 80 }
        return UInt16(port)
    }

    /// 校园门户是否可达（纯 TCP 连接，默认 1.5 秒超时）。
    static func campusPortalReachable(_ config: AppConfig, timeout: TimeInterval = 1.5) -> Bool {
        guard let host = portalHost(config) else { return false }
        return tcpReachable(host: host, port: portalPort(config), timeout: timeout)
    }

    /// 非阻塞 connect + poll 实现可控超时的 TCP 可达性探测。
    static func tcpReachable(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else {
            return false
        }
        defer { freeaddrinfo(info) }

        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            defer { node = current.pointee.ai_next }
            let descriptor = socket(current.pointee.ai_family,
                                    current.pointee.ai_socktype,
                                    current.pointee.ai_protocol)
            if descriptor < 0 { continue }

            let flags = fcntl(descriptor, F_GETFL, 0)
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

            if connect(descriptor, current.pointee.ai_addr,
                       current.pointee.ai_addrlen) == 0 {
                close(descriptor)
                return true
            }
            guard errno == EINPROGRESS else { close(descriptor); continue }

            var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pollDescriptor, 1, Int32(timeout * 1000))
            if ready > 0 {
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length)
                close(descriptor)
                if socketError == 0 { return true }
            } else {
                close(descriptor)
            }
        }
        return false
    }

    /// 解析 `networksetup -listallhardwareports`，找出 Wi-Fi 对应的设备名。
    private static func wifiHardwareDevice() -> String? {
        let result = Shell.capture("/usr/sbin/networksetup",
                                   ["-listallhardwareports"],
                                   env: environmentWithCLocale(), timeout: 5)
        let text = result.out.isEmpty ? result.err : result.out
        let lines = text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where line.hasPrefix("Hardware Port:") {
            guard line.contains("Wi-Fi") else { continue }
            for follow in lines[(index + 1)...] where follow.hasPrefix("Device:") {
                let device = follow.dropFirst("Device:".count)
                    .trimmingCharacters(in: .whitespaces)
                if !device.isEmpty { return device }
            }
        }
        return nil
    }

    /// 指定接口是否已拿到 IPv4 地址（用 getifaddrs，不 fork 子进程）。
    private static func interfaceHasIPv4(_ name: String) -> Bool {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            if String(cString: current.pointee.ifa_name) == name { return true }
        }
        return false
    }

    /// 取本机在当前网络下的出口 IP（UDP connect 不实际发包）。
    static func localIP() -> String {
        for (address, port) in [("223.5.5.5", 80), ("114.114.114.114", 80)] {
            let descriptor = socket(AF_INET, SOCK_DGRAM, 0)
            if descriptor < 0 { continue }
            defer { close(descriptor) }

            var target = sockaddr_in()
            target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            target.sin_family = sa_family_t(AF_INET)
            target.sin_port = in_port_t(UInt16(port).bigEndian)
            guard inet_pton(AF_INET, address, &target.sin_addr) == 1 else { continue }

            let connected = withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { continue }

            var local = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let resolved = withUnsafeMutablePointer(to: &local) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getsockname(descriptor, $0, &length)
                }
            }
            guard resolved == 0 else { continue }

            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addr = local.sin_addr
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                continue
            }
            let ip = String(cString: buffer)
            if !ip.isEmpty, !ip.hasPrefix("127.") { return ip }
        }
        return ""
    }

    /// 取当前无线网卡的 MAC，返回 12 位小写十六进制（如 `6c7e67c15c09`），
    /// 与锐捷认证地址里 `mac` 参数的格式完全一致；读不到时返回空串。
    ///
    /// 先定位真正的 Wi-Fi 设备（多网卡机器上 en0 未必是无线网卡），再退回 en0/en1/en2。
    /// 之所以要「实时读」而不是从配置里存一份：锐捷门户按 **IP + MAC** 绑定会话，
    /// 用户关掉「私有 Wi-Fi 地址」后 MAC 会变，写死的旧值会让登录一路失败。
    static func localMac() -> String {
        // 来源一：getifaddrs 直接读链路层地址 —— 不 fork 子进程，最快也最稳。
        if let mac = linkLayerMac(interface: wifiHardwareDevice()) { return mac }

        // 来源二：解析 `ifconfig` 输出（兜底）
        var candidates: [String] = []
        if let wifi = wifiHardwareDevice() { candidates.append(wifi) }
        candidates.append(contentsOf: ["en0", "en1", "en2"])

        var seen = Set<String>()
        for name in candidates where seen.insert(name).inserted {
            let result = Shell.capture("/sbin/ifconfig", [name],
                                       env: environmentWithCLocale(), timeout: 3)
            let text = result.out.isEmpty ? result.err : result.out
            guard let range = text.range(of: "ether ") else { continue }
            let raw = text[range.upperBound...]
                .prefix { $0 != " " && $0 != "\n" && $0 != "\t" }
            let mac = raw.replacingOccurrences(of: ":", with: "").lowercased()
            guard isPlausibleMac(mac) else { continue }
            return mac
        }
        return ""
    }

    /// 是否是「像真实网卡」的 12 位小写十六进制 MAC。
    ///
    /// 排除两类占位值：
    ///   - 全 0（接口未初始化 / 占位）；
    ///   - 末 5 字节全 0（实测某些受限执行环境会把二进制读到的硬件地址统一替换成
    ///     `02:00:00:00:00:00`，`ifconfig` 与 `getifaddrs` 两条路都会被替换）。
    /// 真实网卡末 3 字节是厂商分配的唯一序列号，不可能整段为 0。
    /// 宁可判定「读不到」，也不要把垃圾写进门户缓存。
    static func isPlausibleMac(_ mac: String) -> Bool {
        guard mac.count == 12,
              mac.allSatisfy({ $0.isHexDigit }),
              mac != "000000000000",
              !mac.hasSuffix("0000000000") else { return false }
        return true
    }

    /// 用 `getifaddrs` 读链路层地址（MAC），不依赖任何子进程。
    ///
    /// 优先级：指定接口 → 任意 `en*`。必须挑接口，是因为 `awdl0` / `bridge0` /
    /// `anpi*` 这类虚拟接口同样有链路层地址，乱取会把虚拟 MAC 当成网卡 MAC。
    private static func linkLayerMac(interface: String?) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var fallback: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let name = String(cString: current.pointee.ifa_name)
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK) else { continue }

            let link = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_dl.self)
            let nameLength = Int(link.pointee.sdl_nlen)
            let macLength = Int(link.pointee.sdl_alen)
            guard macLength == 6 else { continue }

            // sockaddr_dl 的 sdl_data 紧跟在 8 字节定长头之后，MAC 从 sdl_data + sdl_nlen 起
            let start = UnsafeRawPointer(address).advanced(by: 8 + nameLength)
            let bytes = Array(UnsafeBufferPointer(
                start: start.assumingMemoryBound(to: UInt8.self), count: macLength))
            let mac = bytes.map { String(format: "%02x", $0) }.joined()
            guard isPlausibleMac(mac) else { continue }

            if let interface, name == interface { return mac }
            if fallback == nil, name.hasPrefix("en") { fallback = mac }
        }
        return fallback
    }

    /// 门户口径告诉我们「它把哪台设备认成了本机」。
    ///
    /// 这是本地读不到 MAC 时的权威兜底：受限执行环境下 `ifconfig` 与 `getifaddrs`
    /// 都只会给占位值，而门户 `getOnlineUserInfo` 回传的 `userMac` 就是它实际
    /// 绑定的设备身份。
    ///
    /// 必须连 `userIp` 一起校验：只有门户那条会话的 IP 就是本机当前 IP 时，
    /// 那个 `userMac` 才属于本机（否则会把别人的 MAC 写进缓存）。
    static func portalBoundMac(_ config: AppConfig, timeout: TimeInterval = 4) -> String {
        let host = portalNetloc(config)
        guard !host.isEmpty else { return "" }
        let response = HTTP.request(
            "http://\(host)/eportal/InterFace.do?method=getOnlineUserInfo", timeout: timeout)
        guard response.status != nil, let payload = tryJSON(response.text) else { return "" }

        let mac = JSONValue.string(payload["userMac"])
            .replacingOccurrences(of: ":", with: "").lowercased()
        guard isPlausibleMac(mac) else { return "" }

        let boundIP = JSONValue.string(payload["userIp"])
        let mineIP = localIP()
        guard !boundIP.isEmpty, !mineIP.isEmpty, boundIP == mineIP else { return "" }
        return mac
    }

    /// 把 URL 里的某个查询参数改成指定值（其余原样保留）。
    private static func settingQuery(_ url: String, key: String, value: String) -> String {
        let parts = WebUtil.split(url)
        var pairs = WebUtil.queryDictionary(parts.query)
        pairs[key] = value
        let path = parts.path.isEmpty ? "/" : parts.path
        return "\(parts.scheme)://\(parts.netloc)\(path)?"
            + WebUtil.formEncode(pairs.map { ($0.key, $0.value) })
    }

    // MARK: - 内部工具

    /// 解析响应正文里的 JSON（允许正文前后混有其它内容）。
    private static func tryJSON(_ text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dict = object as? [String: Any] {
            return dict
        }
        guard let block = Regex.firstGroup("\\{.*\\}", in: trimmed,
                                           options: [.dotMatchesLineSeparators]),
              let data = block.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }

    private static func environmentWithCLocale() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        return env
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
