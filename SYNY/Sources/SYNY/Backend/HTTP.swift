import Foundation

/// 极简同步 HTTP 客户端（对齐 Python 版 `core._http`）。
///
/// 两个关键点：
///   1. **不自动跟随跳转** —— 未认证时校园网关会把请求 302 到认证页，
///      必须拿到这个 3xx 响应本身（Location 头 / 正文里的认证页地址），
///      自动跟随反而会丢失线索；
///   2. 网络层失败时返回 `status == nil`，把异常降级成「探测未通过」，
///      让调用方继续尝试认证，而不是直接放弃。
struct HTTPResult {
    var status: Int?          // nil 表示网络层失败（DNS 不通 / 超时 / 连接被拒）
    var text: String = ""
    var headers: [String: String] = [:]   // key 统一小写，便于取值
    var error: String = ""

    var location: String { headers["location"] ?? "" }
}

enum HTTP {

    static let userAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/61.0.3163.91 Safari/537.36"

    /// 禁止跟随跳转的 URLSession。
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession,
                        task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            // 传 nil = 不跟随，直接把 3xx 响应交回调用方
            completionHandler(nil)
        }
    }

    private static let delegate = NoRedirectDelegate()

    /// 等待网络就绪的上限（秒）。
    ///
    /// 这个值同时决定 `waitsForConnectivity` 能等多久，必须覆盖**一次完整的
    /// Wi-Fi 重关联 + DHCP**。实测踩到：用户切换「私有 Wi-Fi 地址」后，链路有
    /// 近 1 分钟完全不可用；上限只有 12 秒时，请求恰好卡在「链路就绪的前一刻」
    /// 超时 —— 下一轮虽然能连上，认证窗口却已经被 macOS 系统登录页（CNA）或
    /// 网关的无感知认证抢走，用户看到的就是「后台服务没能完成重新认证」。
    ///
    /// 放宽到 30 秒后，第一个请求会一直挂在等待中，**链路一恢复立刻发出去**，
    /// 这才是能抢在 CNA 之前完成认证的姿态。
    /// 代价：真的长时间没有网络时每轮会等满这个上限，对后台服务可以接受
    /// —— 没有链路时本来也没别的事可做。
    private static let resourceTimeout: TimeInterval = 30

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = resourceTimeout

        // 断网 / Wi-Fi 重连的瞬间，系统还没确认「有没有网」，此时若不等一等，
        // URLSession 会**立刻**抛 `NSURLErrorNotConnectedToInternet`
        // （本地化文案就是「似乎已断开与互联网的连接。」）。
        // 实测踩到的后果：把「私有 Wi-Fi 地址」关掉后 Wi-Fi 重关联的那两分钟里，
        // 连给**内网门户**（172.16.100.201）的登录请求都被瞬间判失败，
        // 日志只剩一片 `登录请求失败：NSURLError`，看起来就是「登录功能坏了」。
        // 打开 waitsForConnectivity 后，请求会静候网络就绪再发，重连一到位就自动继续。
        configuration.waitsForConnectivity = true

        // 显式允许「按流量计费 / 低数据模式」的网络：
        // 校园网常被系统标记为受限网络，若被拦下同样表现为「连不上互联网」。
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true

        // 绕过系统代理，防止误判网络状态
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration,
                          delegate: delegate,
                          delegateQueue: nil)
    }()

    /// 发起请求并同步等待结果。
    static func request(_ url: String,
                        method: String = "GET",
                        body: String? = nil,
                        headers: [String: String] = [:],
                        timeout: TimeInterval = 10) -> HTTPResult {
        guard let target = URL(string: url) else {
            return HTTPResult(status: nil, error: "URL 非法：\(url)")
        }

        var request = URLRequest(url: target)
        request.httpMethod = method
        request.timeoutInterval = timeout
        var allHeaders = ["User-Agent": userAgent]
        for (key, value) in headers { allHeaders[key] = value }
        for (key, value) in allHeaders { request.setValue(value, forHTTPHeaderField: key) }
        if let body { request.httpBody = Data(body.utf8) }

        let semaphore = DispatchSemaphore(value: 0)
        var result: HTTPResult?

        let task = session.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                result = HTTPResult(status: nil,
                                    error: "\(type(of: error)): \(error.localizedDescription)")
                return
            }
            guard let http = response as? HTTPURLResponse else {
                result = HTTPResult(status: nil, error: "无 HTTP 响应")
                return
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            let payload = data ?? Data()
            result = HTTPResult(status: http.statusCode,
                                text: decode(payload, contentType: headers["content-type"] ?? ""),
                                headers: headers)
        }
        task.resume()

        // 外层等待必须 ≥ 会话的「等网络」上限，否则 URLSession 还在等链路、
        // 我们自己先把请求 cancel 了 —— 那 waitsForConnectivity 就白开了
        // （这正是之前「后台服务在重连期间完全没动作」的隐藏元凶）。
        let wait = max(timeout, resourceTimeout) + 3
        if semaphore.wait(timeout: .now() + wait) == .timedOut {
            task.cancel()
            return HTTPResult(status: nil, error: "请求超时：\(url)")
        }
        return result ?? HTTPResult(status: nil, error: "未知错误")
    }

    static func post(_ url: String, form: String,
                     headers: [String: String], timeout: TimeInterval = 12) -> HTTPResult {
        var headers = headers
        headers["Content-Type"] = "application/x-www-form-urlencoded; charset=UTF-8"
        return request(url, method: "POST", body: form, headers: headers, timeout: timeout)
    }

    // MARK: - 正文解码

    /// 按响应声明的字符集解码正文，解码不出来再靠试探兜底。
    ///
    /// 为什么必须做这件事：锐捷 eportal 返回的是 **GBK**，且 Content-Type 里
    /// 往往只写 `text/html` 不带 charset。旧实现一律 `String(decoding:as: UTF8.self)`，
    /// 后果不只是「门户中文提示显示成乱码」，更严重的是**所有基于中文关键字的
    /// 判断全部失效** —— 登录时的「已在线」、下线时的「下线/成功」、
    /// 门户页的「登录」标记、以及识别「WEB认证设备未注册」这类异常页面，
    /// 都会因为关键字匹配不上而走向错误分支。
    ///
    /// 顺序：显式 charset → 严格 UTF-8 → GB18030 → 有损 UTF-8（保证不丢响应）。
    private static func decode(_ data: Data, contentType: String) -> String {
        guard !data.isEmpty else { return "" }

        if let declared = contentType.lowercased().range(of: "charset=") {
            let name = contentType.lowercased()[declared.upperBound...]
                .prefix { ![";", " ", "\"", "'"].contains($0) }
            if let encoding = encoding(forCharset: String(name)),
               let text = String(data: data, encoding: encoding) {
                return text
            }
        }

        if let text = String(data: data, encoding: .utf8) { return text }

        if let text = String(data: data, encoding: GB18030) { return text }

        return String(decoding: data, as: UTF8.self)
    }

    /// GBK / GB2312 的公共超集，覆盖国内校园网门户的实际编码。
    private static let GB18030 = String.Encoding(rawValue:
        CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

    private static func encoding(forCharset name: String) -> String.Encoding? {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "utf-8", "utf8": return .utf8
        case "gbk", "gb2312", "gb-2312", "gb18030", "x-gbk", "cp936": return GB18030
        case "big5", "big-5": return String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue)))
        case "iso-8859-1", "latin1": return .isoLatin1
        case "us-ascii", "ascii": return .ascii
        default: return nil
        }
    }
}
